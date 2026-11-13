#!/usr/bin/env bash
# review-verdict.sh <PR> <owner/repo> [sha]
#
# The loop's stop condition for babysit-pr: does the reviewer's review OF THIS COMMIT
# carry any critical/major finding? Defaults to the PR's current head.
# (Was rabbit-verdict.sh, which read only one bot; generalised 2026-11-11.)
#
# Two reviewer families are understood:
#
# 1. Stamped reviewers: any bot comment that stamps the commit it read
#    (``_Reviewed `<sha7>`_``) and embeds `<!-- agent-review:findings:v1 <base64 json> -->`
#    (findings[].severity). That is what a GitHub Actions review workflow posting as
#    github-actions[bot] can write (marker `<!-- agent: <name> -->`), and the
#    format to adopt if you build your own reviewer. Without the block, the headline
#    is read ("N critical · N major", "no issues found",
#    "Agent review: clear").
# 2. Codex (chatgpt-codex-connector), used when no stamped review exists on the PR.
#    Its summary comment holds `codex-review-state:v1 {...}` (commit_sha, status); a
#    review of this commit that is not "completed" is ABSENT. Severity comes from the
#    badge on each review thread still unresolved and not outdated: P0 = critical,
#    P1 = major, P2/P3 = minor. Codex does not review pushes by itself, so a pushed
#    head stays ABSENT until babysit-pr posts "@codex review".
#
# Prints one line and exits:
#   CLEAR    <sha7> label=<review:*> reviewer=<r>                     exit 0
#   BLOCKING <sha7> critical=<n> major=<n> label=<...> reviewer=<r>   exit 1
#   ABSENT   <sha7> label=<...> reviewer=<r>                          exit 3
#            (note=reviewer-failed: the reviewer posted a verdict comment but its own
#            run failed, e.g. "This reviewer produced no verdict". Never clean:
#            a failed review counted 0 findings, and read as CLEAR on 2026-11-11.)
#   usage / guard error                                               exit 2
# reviewer=none means no supported reviewer has ever commented on the PR.
#
# Never judge from the review:* label alone: a push removes review:clear before the
# new review lands, and the label is not bound to a SHA. It is printed as a cross-check.

set -uo pipefail

PR=${1:-}; REPO=${2:-}; SHA=${3:-}
if [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "usage: $0 <PR> <owner/repo> [sha]" >&2; exit 2
fi
if [ -z "$SHA" ]; then
  SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid) \
    || { echo "cannot read PR $REPO#$PR" >&2; exit 2; }
fi
short=${SHA:0:7}
# An empty short SHA would make contains("") match every comment: a stale pass.
[[ "$short" =~ ^[0-9a-f]{7}$ ]] || { echo "could not resolve a commit SHA (got '$SHA')" >&2; exit 2; }

label=$(gh pr view "$PR" --repo "$REPO" --json labels \
        --jq '[.labels[].name | select(startswith("review:"))] | join(",")') || label="?"
label=${label:-none}

# Stream objects out of gh (its --jq takes no --arg and runs per page), slurp into jq.
comments=$(gh api --paginate "repos/$REPO/issues/$PR/comments" --jq '.[]') \
  || { echo "cannot read comments on $REPO#$PR" >&2; exit 2; }

# Stamped reviewers: bot comments carrying a "_Reviewed `sha7`_" stamp.
stamped_any=$(jq -rs '[ .[] | select(.user.type == "Bot") | select(.body | test("_Reviewed `[0-9a-f]{7}`_")) ] | length' <<<"$comments")
reviewer=none
verdict=ABSENT
if [ "${stamped_any:-0}" -gt 0 ]; then
  reviewer=$(jq -rs '[ .[] | select(.user.type == "Bot") | select(.body | test("_Reviewed `[0-9a-f]{7}`_")) ]
                     | max_by(.updated_at)
                     | ((.body | capture("<!-- agent: (?<a>[A-Za-z0-9._-]+) -->").a) // (.user.login | sub("\\[bot\\]$"; "")))' <<<"$comments")
  verdict=$(jq -rs --arg s "$short" '
      [ .[] | select(.user.type == "Bot") | select(.body | contains("_Reviewed `" + $s + "`_")) ]
      | if length == 0 then "ABSENT" else
          (max_by(.updated_at).body) as $b
          | ($b | capture("agent-review:findings:v1 (?<d>[A-Za-z0-9+/=]+)").d // null) as $d
          | if ($b | test("Agent review: blocking")) and ($b | test("produced no verdict|could not be assembled")) then "FAILED"
            elif $d != null then
              ($d | @base64d | fromjson | [.findings[]?.severity | ascii_downcase]) as $sev
              | "\([$sev[] | select(. == "critical")] | length) \([$sev[] | select(. == "major")] | length)"
            elif ($b | test("no issues found|Agent review: clear")) then "0 0"
            else "\(($b | capture("(?<n>[0-9]+) critical").n) // "0") \(($b | capture("(?<n>[0-9]+) major").n) // "0")"
            end
        end' <<<"$comments")
fi

codex_verdict() {  # prints "<crit> <major>", "ABSENT", or nothing when Codex is not on this PR
  local state owner name
  state=$(jq -r 'select((.user.login // "") | test("chatgpt-codex-connector")) | .body' <<<"$comments" \
          | grep -o 'codex-review-state:v1 {.*}' | sed 's/^codex-review-state:v1 //' | tail -1)
  [ -n "$state" ] || return 0
  jq -e --arg s "$SHA" '.code_review.commit_sha == $s and .code_review.status == "completed"' \
    <<<"$state" >/dev/null 2>&1 || { echo ABSENT; return 0; }
  owner=${REPO%/*}; name=${REPO#*/}
  gh api graphql -F o="$owner" -F n="$name" -F p="$PR" -f query='
    query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){
      reviewThreads(first:100){nodes{isResolved isOutdated comments(first:1){nodes{author{login} body}}}}}}}' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved | not) | select(.isOutdated | not)
            | .comments.nodes[0] | select((.author.login // "") | test("chatgpt-codex-connector"))
            | .body] as $b
          | "\([$b[] | select(test("badge/P0-"))] | length) \([$b[] | select(test("badge/P1-"))] | length)"'
}

if [ "$reviewer" = none ]; then
  cv=$(codex_verdict) || { echo "cannot read Codex review threads on $REPO#$PR" >&2; exit 2; }
  if [ -n "$cv" ]; then reviewer=codex; verdict=$cv; fi
fi

if [ "$verdict" = "FAILED" ]; then echo "ABSENT $short label=$label reviewer=$reviewer note=reviewer-failed"; exit 3; fi
if [ "$verdict" = "ABSENT" ]; then echo "ABSENT $short label=$label reviewer=$reviewer"; exit 3; fi
crit=${verdict% *}; maj=${verdict#* }
if [ "$crit" -eq 0 ] && [ "$maj" -eq 0 ]; then echo "CLEAR $short label=$label reviewer=$reviewer"; exit 0; fi
echo "BLOCKING $short critical=$crit major=$maj label=$label reviewer=$reviewer"; exit 1

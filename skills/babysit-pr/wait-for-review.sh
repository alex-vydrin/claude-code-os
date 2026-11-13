#!/usr/bin/env bash
# wait-for-review.sh <PR> <owner/repo>
#
# The one wait used by babysit-pr Step 1. Exits when a
# review-bearing bot has reported for the current round, or at the cap.
#
# The round start is DERIVED from GitHub, never passed in: the latest of the PR's
# createdAt, the head commit's committer date, and the newest "@<bot> review"
# re-trigger comment ("@codex review" and the like). There is deliberately no
# parameter for it. On 2026-10-05 a hand-typed round_start sat 14
# minutes in the future, so the review that had already arrived 3 minutes after
# the PR opened could never satisfy `?since=`, and the wait would have sat out its
# full 20-minute cap while the findings were already there.
#
# Floor and cap are measured from the ROUND START, not from when this script runs.
# Starting the wait late therefore costs nothing: a review that already arrived is
# found on the first check, and the floor only sleeps whatever is left of it.
#
# Exit: 0 ARRIVED, 1 TIMEOUT, 2 usage or guard error, 4 PR already MERGED or
# CLOSED (checked at start and on every poll). Run it backgrounded
# (run_in_background: true); the cap exceeds the foreground Bash timeout.
# Overrides for testing only: BABYSIT_FLOOR, BABYSIT_POLL, BABYSIT_CAP (seconds).

set -uo pipefail

PR=${1:-}; REPO=${2:-}
if [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "usage: $0 <PR> <owner/repo>" >&2; exit 2
fi
FLOOR=${BABYSIT_FLOOR:-180}   # nothing has ever arrived sooner than 2.2 min
POLL=${BABYSIT_POLL:-60}
CAP=${BABYSIT_CAP:-1200}      # 20 min per round, from the round start

to_epoch() {  # ISO-8601 UTC "YYYY-MM-DDTHH:MM:SSZ" -> epoch seconds (BSD or GNU date)
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}

# A merged or closed PR gets no more review rounds: stop instead of waiting.
# On 2026-10-20 a PR merged 2 min after the last push and two
# full 20-min waits, plus a re-trigger, ran on it before anyone looked.
pr_closed() {  # prints "MERGED <mergedAt>" / "CLOSED <closedAt>" and returns 0 when no longer open
  local st
  st=$(gh pr view "$PR" --repo "$REPO" --json state,mergedAt,closedAt \
       --jq 'if .state == "MERGED" then "MERGED \(.mergedAt)" elif .state == "CLOSED" then "CLOSED \(.closedAt)" else "" end' 2>/dev/null) \
    || return 1
  [ -n "$st" ] && { echo "$st"; return 0; }
  return 1
}
stop_if_closed() {
  local st
  st=$(pr_closed) && { echo "$st - PR is no longer open; nothing to wait for"; exit 4; }
  return 0
}
stop_if_closed

pr=$(gh pr view "$PR" --repo "$REPO" --json createdAt,headRefOid \
     --jq '"\(.createdAt) \(.headRefOid)"') || { echo "cannot read PR $REPO#$PR" >&2; exit 2; }
created=${pr% *}; head=${pr#* }
[ ${#head} -eq 40 ] || { echo "could not resolve head SHA (got '$head')" >&2; exit 2; }
committed=$(gh api "repos/$REPO/commits/$head" --jq .commit.committer.date) \
  || { echo "cannot read head commit $head" >&2; exit 2; }

round_start=$created; source="PR opened"
if [[ "$committed" > "$created" ]]; then round_start=$committed; source="head ${head:0:7} committed"; fi
# A manual re-trigger opens a round too: an "@<bot> review" comment (Codex does not
# review pushes on its own, so babysit-pr asks with "@codex review" after every push;
# other app reviewers are asked the same way after a TIMEOUT). Without this, a wait
# started after that comment would measure its cap from the commit and could time out
# on its first check. A workflow reviewer re-run by `gh workflow run` / `gh run rerun`
# leaves no comment; its round start stays the commit, which is what it reviews.
retrigger=$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq '.[] | select(.body | test("^\\s*@[A-Za-z0-9-]+ review")) | "\(.created_at) \(.body | capture("@(?<b>[A-Za-z0-9-]+)").b)"' | sort | tail -1)
if [ -n "$retrigger" ] && [[ "${retrigger% *}" > "$round_start" ]]; then
  round_start=${retrigger% *}; source="@${retrigger#* } review requested"
fi

rs=$(to_epoch "$round_start") || { echo "cannot parse round start '$round_start'" >&2; exit 2; }
now=$(date -u +%s)
if [ "$rs" -gt $((now + 60)) ]; then  # a derived start can only be in the future on clock skew
  echo "round start $round_start is in the future (now $(date -u +%Y-%m-%dT%H:%M:%SZ)) - refusing to wait on it" >&2
  exit 2
fi
short=${head:0:7}
echo "round start $round_start ($source); floor ${FLOOR}s, cap ${CAP}s from that point"

arrived() {  # 0 = a review-bearing bot reported this round, 1 = not yet
  # 1) Stamped reviewers (any bot stamping ``_Reviewed `sha7`_``, e.g. a
  #    workflow reviewer posting as github-actions[bot]):
  #    a stamped report for the current head, or any stamped report created or edited
  #    since the round start (edit-in-place and per-head modes).
  gh api --paginate "repos/$REPO/issues/$PR/comments" --jq '.[]
      | select(.user.type == "Bot")
      | select(.body | test("_Reviewed `[0-9a-f]{7}`_"))
      | "\(.updated_at) \(.body | capture("_Reviewed `(?<s>[0-9a-f]{7})`_").s // "")"' \
    | awk -v t="$round_start" -v s="$short" '$1 >= t || $2 == s { f=1 } END { exit !f }' \
    && return 0
  # 2) CodeRabbit: a summary comment that has left placeholder state
  gh api --paginate "repos/$REPO/issues/$PR/comments?since=$round_start" --jq '.[]
      | select((.user.login // "") | test("coderabbitai"))
      | select(.body | test("review in progress|Currently processing new changes") | not)
      | .id' | grep -q . && return 0
  # 3) CodeRabbit: a REVIEW body. That endpoint takes no `?since`, and `gh --jq`
  #    takes no `--arg`: stream out, slurp into real jq.
  local n
  n=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" --jq '.[]' \
      | jq -s --arg t "$round_start" '[ .[]
          | select((.user.login // "") | test("coderabbitai"))
          | select(.submitted_at >= $t)
          | select(.body != "") ] | length')
  [ "${n:-0}" -gt 0 ] && return 0
  # 4) Codex (chatgpt-codex-connector): its summary comment carries a machine-readable
  #    state, edited in place. Arrived = code review "completed" for the current head.
  #    (While running the state says "running"; with no findings it still completes.)
  gh api --paginate "repos/$REPO/issues/$PR/comments" --jq '.[]
      | select((.user.login // "") | test("chatgpt-codex-connector"))
      | .body' \
    | grep -o 'codex-review-state:v1 {.*}' | sed 's/^codex-review-state:v1 //' \
    | jq -e --arg h "$head" 'select(.code_review.commit_sha == $h and .code_review.status == "completed")' \
      >/dev/null 2>&1
}

elapsed() { echo $(( $(date -u +%s) - rs )); }
report_arrival() { echo "ARRIVED $(elapsed)s after round start"; exit 0; }

arrived && report_arrival                    # started late? it may already be there
left=$(( FLOOR - $(elapsed) )); [ "$left" -gt 0 ] && sleep "$left"
while [ "$(elapsed)" -lt "$CAP" ]; do
  arrived && report_arrival
  stop_if_closed
  gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1 \
    || echo "poll: GitHub API call failed - this silence may be an outage, not a quiet bot" >&2
  sleep "$POLL"
done
arrived && report_arrival                    # the last sleep can straddle the cap
echo "TIMEOUT - no review-bearing comment $(elapsed)s after round start"
exit 1

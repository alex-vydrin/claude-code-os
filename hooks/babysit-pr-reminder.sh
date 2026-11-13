#!/usr/bin/env bash
# PostToolUse hook (Bash): after a SUCCESSFUL `gh pr create`, remind the
# agent to run the bounded babysit-pr routine, then the watch-pr-merge-verify
# follow-on. Requires jq.
if ! command -v jq >/dev/null 2>&1; then
  echo "babysit-pr-reminder: jq not found: install jq to enable the auto-babysit reminder." >&2
  exit 0   # non-blocking: never break the tool flow over a missing optional dep
fi

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
out=$(printf '%s' "$input" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response // {} | tojson) end')

# Fire only when a `gh pr create` ACTUALLY opened a PR. Two conditions, and the
# second is the real one: the command match is just a word-boundary mention of
# `gh pr create`, because every attempt to enumerate legal prefixes kept losing to
# shapes nobody thought of (`url=$(gh pr create)`, `if gh pr create; then`, `time`,
# `timeout 60`, `!`) and its trailing boundary must be "not a word character", not
# whitespace, or it loses `if gh pr create; then`, `gh pr create&&x`,
# `gh pr create|tee f` and `bash -c "gh pr create"`; the gate is that a PR URL sits
# alone on a line of STDOUT, which is what `gh pr create` prints on success.
# A failed create is excluded: gh puts the error and any existing-PR URL on stderr,
# and the `already exists` wording is rejected outright in case a harness merges
# the streams. Keep condition 2 if you ever loosen condition 1.
# Table-driven test for this matcher: tests/babysit-pr-reminder.test.sh. Run it
# after any edit here.
stdout=$(printf '%s' "$input" | jq -r '
  (.tool_response // {}) as $r
  | if   ($r|type) == "string" then $r
    elif ($r|type) == "object" then ($r.stdout // "")
    else "" end' 2>/dev/null)
CREATE_RE='(^|[^[:alnum:]_.-])gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_-]|$)'
PR_URL_LINE_RE='^[[:space:]]*https://github\.com/[^[:space:]]+/pull/[0-9]+[[:space:]]*$'
if printf '%s' "$cmd" | grep -Eq "$CREATE_RE" \
   && printf '%s\n' "$stdout" | grep -Eq "$PR_URL_LINE_RE" \
   && ! printf '%s' "$out" | grep -qiE 'a pull request for branch .* already exists'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "A PR was just opened with `gh pr create`. Per your personal auto-babysit rule: (1) run the babysit-pr skill, following its SKILL.md exactly, then (2) run watch-pr-merge-verify. Do NOT work from this reminder: it is deliberately not a summary of either protocol, and anything it restated (wait lengths, which comment surfaces to fetch, the reviewer lookup, the marker preconditions) would drift out of date the moment a skill changed. Read the skills. These hold regardless, because they are safety rails rather than tunables: review rounds run until the review of the CURRENT head has no critical/major (review-verdict.sh), at most the reviewer cap in the babysit-pr table (5 stamped/workflow reviewer, 3 Codex, 2 with no verdict), Codex is asked with @codex review after every push and other reviewers re-triggered only after a timeout, once per head, and no re-polling after the report; resolve only bot threads, never a human reviewer'\''s; an auto-merge marker only where a workflow reads it; check mergeable before reporting; then watch-pr-merge-verify reads or builds the repo deploy profile in ~/.claude/deploy-profiles and confirms the deploy is live, smoked and its logs read; and never --no-verify, force-push, merge, or deploy to production to work around feedback or to enable a verification. If a skill is not installed, say so and stop rather than improvising a shorter version of it."
    }
  }'
fi

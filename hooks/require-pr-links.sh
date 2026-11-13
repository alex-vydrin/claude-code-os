#!/usr/bin/env bash
# Stop hook: a turn may not end without a full PR URL when
#   (a) the final message names a PR by a bare number ("#123", "PR 45",
#       "pull request #123"), or
#   (b) a PR is in flight in this session AND the message talks about PR work
#       (PR, babysit, round, marker, merge, CI, review) without a number.
#       Narrowed 2026-10-15: the 2026-10-06 version demanded the URL on EVERY
#       message once a PR existed, which stamped an unrelated PR link onto
#       unrelated status lines. Link a PR when the
#       message is ABOUT it, never as a stamp on unrelated messages.
#
# The final message is every assistant text block after the last GENUINE user
# message (not a tool result). Reading only the last transcript entry, as the
# first version did, saw just the tail of a reply split across entries: it
# missed a URL earlier in the same reply and blocked a message that had one.
#
# Rationale: the user asked, more than once, that EVERY summary link PRs with a
# clickable URL. Asking did not stick across sessions; a hook does.

input=$(cat)
# Second pass after a block: never block again, or a hook that cannot see the
# re-sent text would loop forever.
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$transcript" ] || [ ! -f "$transcript" ] && exit 0

# Index of the last genuine user message: a user entry whose content is a
# string or carries a text block (tool results are user entries too).
final_text=$(jq -rs '
  def genuine_user:
    .type == "user"
    and ((.message.content | type) == "string"
         or ([.message.content[]? | select(.type == "text")] | length) > 0);
  . as $all
  | ([range(0; length) | select($all[.] | genuine_user)] | last // -1) as $u
  | [ $all[($u + 1):][] | select(.type == "assistant")
      | .message.content[]? | select(.type == "text") | .text ]
  | join("\n")
' "$transcript" 2>/dev/null)
# Prefer the text Claude Code hands the hook directly: when a Stop hook runs,
# the final reply is not yet in the transcript, so reading it there saw only the
# chunks BEFORE the last tool call and blocked a reply that carried the URL
# (2026-10-06). The transcript stays as the fallback.
direct=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty | if type == "string" then . else tostring end' 2>/dev/null)
[ -n "$direct" ] && final_text="$direct"
[ -z "$final_text" ] && exit 0

# A real PR URL anywhere in the final message satisfies the rule.
if printf '%s' "$final_text" | grep -Eiq '/pull/[0-9]+'; then
  exit 0
fi

# Base URL for the hint, from the session repo's origin remote. The hint used
# to hardcode one org, which pointed agents at the wrong org in other repos
# (2026-10-20).
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
slug=$(git -C "${cwd:-.}" remote get-url origin 2>/dev/null \
  | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')
case "$slug" in
  */*) pr_base="https://github.com/$slug/pull" ;;
  *)   pr_base="https://github.com/<org>/<repo>/pull" ;;
esac

block() {
  jq -n --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

# (a) Bare PR references with no /pull/ URL.
if printf '%s' "$final_text" | grep -Eiq '(\bPR\b[[:space:]]*#?[0-9]+|pull request[[:space:]]*#?[0-9]+|#[0-9]{2,})'; then
  block "Your final message references a PR by a bare number (e.g. #123 / PR 45) with no clickable link. The user requires EVERY PR reference to carry its full URL. Re-send the message with each PR as $pr_base/<n>. Fix status-table cells too: the PR column must be the full URL, not #n. Then end the turn."
fi

# (b) A PR in flight in this session, and the message is about PR work.
# English by default; add your own language's words via PR_LINKS_TOPIC.
pr_topic=${PR_LINKS_TOPIC:-'(\bPR\b|pull request|babysit|\bround [0-9]|marker|\bmerge|\bCI\b|review)'}
if printf '%s' "$final_text" | grep -Eiq "$pr_topic"; then
  in_flight=$(jq -rs '
    # A PR counts as in flight when one was really opened (gh pr create prints its
    # URL alone on a stdout line, so a tool result carries it) or a reply named one.
    # Matching "gh pr create" in command text, as before, fired on sessions that
    # only mentioned the string, e.g. in test data (2026-11-13).
    [ .[] | .message.content[]?
      | ( select(.type == "tool_result")
          | (.content | if type == "string" then . else ([.[]? | .text? // empty] | join("\n")) end)
          | select(test("(?m)^\\s*https://github\\.com/[^/ ]+/[^/ ]+/pull/[0-9]+\\s*$")) ),
        ( select(.type == "text") | .text | select(test("github\\.com/[^/ ]+/[^/ ]+/pull/[0-9]+")) )
    ] | length
  ' "$transcript" 2>/dev/null)
  if [ "${in_flight:-0}" -gt 0 ]; then
    block "A PR is in flight in this session and this message talks about PR work (PR / babysit / round / marker / merge / CI / review) without its URL. Add the full $pr_base/<n> to the line about the PR, then end the turn. Do NOT add PR links to lines that are not about the PR."
  fi
fi

exit 0

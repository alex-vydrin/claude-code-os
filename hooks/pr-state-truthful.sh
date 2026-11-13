#!/usr/bin/env bash
# Stop hook: refuse to end a turn that hands the user a PR as OUTSTANDING
# when it is already MERGED or CLOSED.
#
# Rationale, 2026-10-05: over one session I repeatedly listed
# a PR as "what's left on you" for hours after it had merged
# (10:29:26Z), and in the same session called a PR "ready to merge" without
# having babysat it at all. Memory and prose both failed; this is the
# deterministic backstop, same shape as require-pr-links.sh.
#
# It does NOT object to naming a merged PR -- that is normal evidence. It
# objects only to naming one in a FORWARD-LOOKING context ("ready to merge",
# "waiting on you", "still open", ...) while its real state is
# MERGED/CLOSED. The block reason carries every PR's real state, so the
# correction is one re-send with accurate wording.
#
# Fails OPEN on anything it cannot determine (no gh, no network, timeout, API
# error): a hook that wedges a session over an API blip is worse than the bug.

input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

last_text=$(jq -rs '
  [ .[] | select(.type == "assistant") ] | last // empty
  | .message.content[]? | select(.type == "text") | .text
' "${transcript:-/dev/null}" 2>/dev/null)
# Prefer the text Claude Code hands the hook directly. When a Stop hook runs, the
# final reply is often not yet in the transcript, so the transcript read checked the
# PREVIOUS reply: clean re-sends were blocked with spans quoted from the message
# before (2026-11-02, same lag require-pr-links.sh hit on 2026-10-06). The
# transcript stays as the fallback for builds that do not send the field.
direct=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty | if type == "string" then . else tostring end' 2>/dev/null)
[ -n "$direct" ] && last_text="$direct"
[ -z "$last_text" ] && exit 0

command -v gh >/dev/null 2>&1 || exit 0

# `timeout` is GNU coreutils and missing on a stock Mac; fall back to gtimeout,
# then to running without a limit, so the hook degrades instead of going silent.
with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"; fi
}


# `timeout` is GNU coreutils and missing on a stock Mac; fall back to gtimeout,
# then to running without a limit, so the hook degrades instead of going silent.
with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"; fi
}


# Forward-looking markers: the message is presenting work as still to be done.
# English by default. Extend both lists for the language you talk to the agent in
# via PR_TRUTH_PENDING / PR_TRUTH_RESOLVED.
PENDING=${PR_TRUTH_PENDING:-'ready to merge|ready for merge|waiting on you|waiting for you|left for you|left on you|needs your|pending your|your merge|still open|awaiting|to merge|remaining'}
# ...unless the SAME line already states the true outcome.
RESOLVED=${PR_TRUTH_RESOLVED:-'merged|closed|landed|shipped'}

offenders=""
states=""
checked=0

while IFS= read -r url; do
  [ "$checked" -ge 8 ] && break
  owner_repo=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*$#\1#p')
  num=$(printf '%s' "$url" | sed -nE 's#^.*/pull/([0-9]+).*$#\1#p')
  [ -z "$owner_repo" ] || [ -z "$num" ] && continue
  checked=$((checked + 1))

  state=$(with_timeout 20 gh pr view "$num" --repo "$owner_repo" --json state --jq '.state' 2>/dev/null)
  [ -z "$state" ] && continue          # fail open: unknown state objects to nothing
  states="${states}
  $owner_repo#$num = $state"

  case "$state" in MERGED|CLOSED) ;; *) continue ;; esac

  # The line carrying the URL, plus the one before it (list items follow a
  # heading like "Still on you:"), minus any line that states the outcome.
  ctx=$(printf '%s' "$last_text" | grep -n -F "$url" | cut -d: -f1 | while read -r n; do
          printf '%s' "$last_text" | sed -n "$((n>1 ? n-1 : 1)),${n}p"
        done)
  printf '%s' "$ctx" | grep -Eiq "$RESOLVED" && continue
  printf '%s' "$ctx" | grep -Eiq "$PENDING" || continue

  offenders="${offenders}
  $owner_repo#$num is $state, but the message presents it as outstanding"
done <<EOF
$(printf '%s' "$last_text" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | sort -u)
EOF

[ -z "$offenders" ] && exit 0

jq -n --arg off "$offenders" --arg st "$states" '{
  decision: "block",
  reason: ("Your final message hands the user a PR as still outstanding, but it is not:\n" + $off +
  "\n\nReal state of every PR URL in the message:" + $st +
  "\n\nThis is the 2026-10-05 rule: never present a PR as pending without checking its state in the same turn, and never say \"ready to merge\" before the babysit has stopped on its verdict (cleared, or blocked with a reason) AND the mergeable check. Re-send the message with the true state, and if nothing is actually waiting on them, say that plainly instead of listing merged work.")
}'
exit 0

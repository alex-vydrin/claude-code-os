#!/usr/bin/env bash
# PostToolUse hook (Bash): bind PRs to the session that owns them, for
# pr-pilot (~/.claude/bin/pr-pilot) and its Stop guard pr-pilot-guard.sh.
#
# 1. `pr-pilot track` prints "PR-PILOT-TRACKED owner/repo#N": stamp this
#    session's id into that PR's state file.
# 2. A successful `gh pr create` (same detection as babysit-pr-reminder.sh: a PR
#    URL alone on a stdout line) auto-tracks the new PR, so the chain is enforced
#    from the moment the PR exists, without anyone remembering to register it.
#
# Fails open: any error exits 0 silently.

command -v jq >/dev/null 2>&1 || exit 0
PILOT="${PR_PILOT_BIN:-$HOME/.claude/bin/pr-pilot}"
DIR="${PR_PILOT_DIR:-$HOME/.claude/pr-pilot/state}"
[ -x "$PILOT" ] || exit 0

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


input=$(cat)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
stdout=$(printf '%s' "$input" | jq -r '
  (.tool_response // {}) as $r
  | if ($r|type) == "string" then $r elif ($r|type) == "object" then ($r.stdout // "") else "" end' 2>/dev/null)

stamp() {  # stamp <owner/repo> <pr>
  local f="$DIR/${1%%/*}__${1##*/}__$2.json" tmp
  [ -f "$f" ] || return 0
  tmp=$(mktemp "$DIR/.tmp.XXXXXX") || return 0
  jq --arg s "$session" '.session = $s' "$f" > "$tmp" && mv "$tmp" "$f"
}

CREATE_RE='(^|[^[:alnum:]_.-])gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_-]|$)'
if printf '%s' "$cmd" | grep -Eq "$CREATE_RE"; then
  url=$(printf '%s\n' "$stdout" | grep -Eo '^[[:space:]]*https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+[[:space:]]*$' | tail -1 | tr -d '[:space:]')
  if [ -n "$url" ]; then
    repo=$(printf '%s' "$url" | sed -E 's#https://github\.com/([^/]+/[^/]+)/pull/.*#\1#')
    pr=${url##*/}
    with_timeout 30 "$PILOT" track "$repo" "$pr" >/dev/null 2>&1 && stamp "$repo" "$pr"
  fi
fi

printf '%s\n' "$stdout" | sed -nE 's/^PR-PILOT-TRACKED ([^ #]+\/[^ #]+)#([0-9]+).*/\1 \2/p' \
  | while read -r repo pr; do stamp "$repo" "$pr"; done
exit 0

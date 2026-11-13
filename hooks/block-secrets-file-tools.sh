#!/usr/bin/env bash
# PreToolUse hook: hard-deny every dedicated file tool on the secrets
# store at ~/.config/claude-secrets/.
#
# Rationale: the standing rule says secrets.env is shell-only, never Read/Write/
# Edit/Glob. The reason is not politeness - a file opened by a file tool becomes
# tracked by the editor environment, and a later external edit is pushed back to
# the model as a change notification WITH the new line's content. That is how a
# CMS API token leaked on 2026-08-10 with nobody reading anything.
#
# Before this hook the rule was prose in CLAUDE.md, i.e. it held only as long as the
# model remembered it. This makes it structural. Shell access (grep/cut/printf)
# is deliberately untouched: it creates no tracking, and it is the sanctioned
# path.
#
# Deny mechanism: PreToolUse JSON with permissionDecision "deny". The legacy
# top-level {"decision":"block"} is emitted too so an older Claude Code build
# still blocks rather than silently allowing.

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  Read|Write|Edit|MultiEdit|NotebookEdit|NotebookRead|Glob|Grep) ;;
  *) exit 0 ;;
esac

# Only path-shaped fields are inspected. Checking the whole tool_input would
# false-positive on legitimate work, e.g. writing documentation that merely
# mentions the file by name.
candidates=$(printf '%s' "$input" | jq -r '
  (.tool_input // {}) as $i
  | [ $i.file_path?, $i.path?, $i.notebook_path?, $i.pattern?, $i.glob?,
      ($i.paths?[]?), ($i.file_paths?[]?) ]
  | map(select(type == "string"))
  | .[]
' 2>/dev/null)

[ -z "$candidates" ] && exit 0

while IFS= read -r p; do
  [ -z "$p" ] && continue
  # Normalise ~ and $HOME so /home/me/... and ~/... compare the same.
  expanded=${p/#\~/$HOME}
  case "$expanded" in
    *claude-secrets*|*secrets.env*)
      jq -n --arg tool "$tool" --arg path "$p" '{
        decision: "block",
        reason: ("Blocked: \($tool) on \($path). The secrets store is shell-only - a file tool makes the editor track it, and a later external edit is then pushed back with the new line'"'"'s content (this leaked a token on 2026-08-10). Read one named variable instead: TOKEN=$(grep -m1 '"'"'^NAME='"'"' ~/.config/claude-secrets/secrets.env | cut -d= -f2-). Presence check: grep -q '"'"'^NAME=.\\+'"'"' ... && echo set || echo empty. To add an entry, append with printf >> via Bash. Never echo a value."),
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Secrets store is shell-only. \($tool) on \($path) denied by ~/.claude/hooks/block-secrets-file-tools.sh - use Bash grep/cut for a single named variable.")
        }
      }'
      exit 0
      ;;
  esac
done <<< "$candidates"

exit 0

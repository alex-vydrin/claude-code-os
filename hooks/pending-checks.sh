#!/bin/bash
# SessionStart hook: surface dated verification items whose time has come.
#
# Why this exists: memory recall fires on RELEVANCE, never on a DATE, so
# "check this next week" reliably drowns there. This reads
# ~/.claude/pending-checks.md and injects only the items that are due.
#
# Once a day, not once a session (2026-10-05): the author runs ~10 sessions a day and
# the same items were pushed ahead of his question in every one of them. The
# first session of the day raises them; later sessions get a one-line note
# telling the model NOT to raise them. The stamp records today's date plus a
# hash of the due set, so a newly due or edited item is raised again.
#
# Silent when nothing is due. Never blocks, never fails a session.
#
# Testing: PENDING_CHECKS_LEDGER=f.md PENDING_CHECKS_TODAY=YYYY-MM-DD PENDING_CHECKS_STAMP=/tmp/x ~/.claude/hooks/pending-checks.sh
set -uo pipefail

LEDGER="${PENDING_CHECKS_LEDGER:-$HOME/.claude/pending-checks.md}"
STAMP="${PENDING_CHECKS_STAMP:-$HOME/.claude/.pending-checks-raised}"
MAX_LINES=5   # header + check + pass + context, one blank-free block
[ -r "$LEDGER" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

TODAY="${PENDING_CHECKS_TODAY:-$(date +%Y-%m-%d)}"

# Due items: a `###` line whose date is <= today, plus its check/pass/context lines.
due=$(awk -v today="$TODAY" '
  /^### / {
    line = substr($0, 5)
    split(line, parts, " | ")
    d = parts[1]
    gsub(/^[ \t]+|[ \t]+$/, "", d)
    emit = (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && d <= today)
    if (emit) {
      overdue = (d < today) ? " [OVERDUE since " d "]" : " [due today]"
      print "- " substr(line, index(line, "|") + 2) overdue
    }
    next
  }
  emit && /^(check|pass|context):/ { print "    " $0 }
  /^$/ { emit = 0 }
' "$LEDGER")

# Items the parser cannot use, so a bad one is loud instead of invisible:
#  - a `##` heading or `[due ...]` bullet inside Open items (never fires on any day)
#  - a `###` header whose first field is not a date (e.g. "SETTLED ...", left undeleted)
#  - an item longer than MAX_LINES (the ledger grew to 88 KB of diary that way)
problems=$(awk -v max="$MAX_LINES" '
  function flush() { if (h != "" && n > max) print "  TOO LONG (" n " lines, max " max "): " h; h = ""; n = 0 }
  /^## Open items/ { open = 1; next }
  !open { next }
  /^### / {
    flush(); h = substr($0, 5); n = 1
    split(h, p, " | "); d = p[1]; gsub(/^[ \t]+|[ \t]+$/, "", d)
    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) print "  NO DATE (settled? delete it): " h
    next
  }
  /^## / { flush(); print "  UNPARSEABLE heading: " substr($0, 4); next }
  /^- .*\[due [0-9]{4}-[0-9]{2}-[0-9]{2}\]/ { print "  UNPARSEABLE bullet: " substr($0, 3) }
  /^$/ { flush(); next }
  h != "" { n++ }
  END { flush() }
' "$LEDGER" | cut -c1-160)

[ -z "$due" ] && [ -z "$problems" ] && exit 0

key="$TODAY $(printf '%s\n%s' "$due" "$problems" | shasum | cut -c1-12)"
if [ -r "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$key" ]; then
  n=$(printf '%s\n' "$due" | grep -c '^- ')
  msg="Pending-checks ledger: $n item(s) due today were already raised in an earlier session today. Do NOT raise them again; mention them only if the user asks."
else
  printf '%s\n' "$key" > "$STAMP" 2>/dev/null
  msg="Dated checks are due from the pending-checks ledger (~/.claude/pending-checks.md). Answer the user's own message first; then mention these in ONE short line at the end of your reply and ask whether to run them now. Do not put them ahead of their ask.

$due

When one is run: report the real number against its pass line, then delete the item or change its due date. Never append notes to it; history belongs in the issue tracker."
  [ -n "$problems" ] && msg="$msg

LEDGER PROBLEMS (fix them when you touch the file: delete settled items, move history to the issue tracker, keep each item to 5 lines):
$problems"
fi

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0

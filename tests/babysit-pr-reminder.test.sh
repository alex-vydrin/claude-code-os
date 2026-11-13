#!/usr/bin/env bash
# Table-driven tests for babysit-pr-reminder.sh: does the hook fire exactly when a
# `gh pr create` actually opened a PR?
#
# This exists because the matcher has silently mis-fired twice, once in each
# direction: a bare substring match fired on any command that merely MENTIONED the
# string, and the anchored replacement that fixed it stopped firing on
# `url=$(gh pr create --fill)`, the shape agents write most often. Both were found by
# a reviewer, not by anyone running the hook. Run this after touching the matcher.
#
#   bash tests/babysit-pr-reminder.test.sh
#
# Requires `jq`. Runs every case and exits non-zero if any failed.
set -uo pipefail
# It tests the hook in ../hooks. Override HOOK to run the same table against
# another copy:
#   HOOK=/path/to/babysit-pr-reminder.sh bash tests/babysit-pr-reminder.test.sh
HOOK="${HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/babysit-pr-reminder.sh}"
if [ ! -f "$HOOK" ]; then
  echo "babysit-pr-reminder.test.sh: no hook at $HOOK" >&2
  exit 2
fi
URL="https://github.com/example-org/example-repo/pull/92"
pass=0; fail=0

# run <expect fire: yes|no> <description> <command> <stdout> [stderr]
run() {
  local expect="$1" desc="$2" command="$3" out="${4:-}" err="${5:-}"
  local payload got
  payload=$(jq -n --arg c "$command" --arg o "$out" --arg e "$err" \
    '{tool_input: {command: $c}, tool_response: {stdout: $o, stderr: $e}}')
  got=$(printf '%s' "$payload" | bash "$HOOK" | tr -d '[:space:]')
  local fired="no"; [ -n "$got" ] && fired="yes"
  if [ "$fired" = "$expect" ]; then
    pass=$((pass + 1)); printf '  ok   %-58s (fired=%s)\n' "$desc" "$fired"
  else
    fail=$((fail + 1)); printf '  FAIL %-58s expected fire=%s, got %s\n' "$desc" "$expect" "$fired"
  fi
}

echo "should FIRE: a PR really was opened:"
run yes "plain create"                 "gh pr create --fill"                         "$URL"
run yes "captured in a variable"       "url=\$(gh pr create --fill)"                 "$URL"
run yes "chained after &&"             "git push && gh pr create --fill"            "$URL"
run yes "env-assignment prefix"        "GH_TOKEN=x gh pr create"                    "$URL"
run yes "env(1) prefix"                "env GH_TOKEN=x gh pr create"                "$URL"
run yes "inside a subshell"            "(cd apps/web && gh pr create)"              "$URL"
run yes "absolute path"                "/opt/homebrew/bin/gh pr create --fill"      "$URL"
run yes "command builtin"              "command gh pr create"                       "$URL"
run yes "URL among other stdout lines" "gh pr create --fill"          "Creating pull request...
$URL"
run yes "if/then wrapper"              "if gh pr create --fill; then echo ok; fi"    "$URL"
run yes "time prefix"                  "time gh pr create"                          "$URL"
run yes "timeout wrapper"              "timeout 60 gh pr create --fill"             "$URL"
run yes "negated"                      "! gh pr create"                             "$URL"
# Each of these four is terminated by something that is NOT whitespace. The first
# trailing boundary was `[[:space:])]` and missed every one of them.
run yes "terminated by ;"              "if gh pr create; then echo ok; fi"          "$URL"
run yes "terminated by && (no space)"  "gh pr create&&echo done"                    "$URL"
run yes "piped (no space)"             "gh pr create|tee /tmp/out"                  "$URL"
run yes "terminated by a closing quote" "bash -c \"gh pr create\""                   "$URL"
run yes "unrelated 'already exists' noise on stderr" "git checkout -b feat; git push && gh pr create --fill" "$URL" \
                                       "fatal: a branch named 'feat' already exists"

echo "should NOT fire: no PR was opened by this command:"
run no  "merely mentioned in a heredoc" "cat <<EOF
gh pr create is documented here
EOF"                                                                                 "gh pr create is documented here"
run no  "mentioned in an echo"          "echo 'run gh pr create next'"               "run gh pr create next"
run no  "editing this very file"        "sed -i '' 's/x/y/' .claude/hooks/babysit-pr-reminder.sh # gh pr create" ""
run no  "create failed, no URL"         "gh pr create --fill"                        ""  "pull request create failed"
run no  "already exists (URL on stderr)" "gh pr create --fill"                       ""  "a pull request for branch \"x\" into branch \"develop\" already exists:
$URL"
run no  "already exists (merged output)" "gh pr create --fill"                       "a pull request for branch \"x\" already exists:
$URL"
run no  "dry run prints no URL"          "gh pr create --dry-run"                    "would create a pull request"
run no  "a different gh subcommand"      "gh pr view 29674 --json url"               "$URL"
run no  "prose quoting a PR URL"         "gh pr list"                                "see $URL for context"

# These two isolate condition 1: stdout carries a lone PR URL, so only the command
# matcher can reject them. The mention-only cases above deliberately do NOT do this  - 
# under a word-boundary matcher they match condition 1 by design and are gated by
# condition 2, which is the arrangement this hook is built on.
run no  "a longer subcommand (suffix boundary)" "gh pr create-draft --fill"         "$URL"
run no  "a different binary (prefix boundary)"  "ghx pr create"                     "$URL"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

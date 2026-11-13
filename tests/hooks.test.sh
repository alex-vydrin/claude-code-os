#!/usr/bin/env bash
# Behaviour tests for the hooks and helpers that have no test file of their own.
# Each case feeds the hook the JSON Claude Code would send and checks whether it
# blocks, injects context, or stays silent. `gh` is replaced by a stub on PATH, so
# nothing here touches the network.
#
#   bash tests/hooks.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
H="$ROOT/hooks"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check() {  # check <description> <expected: block|silent|context|match:<regex>> <actual output>
  local desc="$1" want="$2" out="$3" got
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then got=silent
  elif printf '%s' "$out" | jq -e '.decision == "block" or .hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then got=block
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then got=context
  else got=other; fi
  case "$want" in
    match:*) printf '%s' "$out" | grep -Eq "${want#match:}" && got="$want" ;;
  esac
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$desc"
  else fail=$((fail + 1)); printf '  FAIL %s: expected %s, got %s\n' "$desc" "$want" "$got"; fi
}

# A transcript with one genuine user message and one assistant reply.
transcript() {  # transcript <file> <assistant text> [tool command] [its stdout]
  jq -cn '{type:"user", message:{content:"go"}}' > "$1"
  [ -n "${3:-}" ] && jq -cn --arg c "$3" '{type:"assistant", message:{content:[{type:"tool_use", input:{command:$c}}]}}' >> "$1"
  [ -n "${4:-}" ] && jq -cn --arg o "$4" '{type:"user", message:{content:[{type:"tool_result", content:$o}]}}' >> "$1"
  jq -cn --arg t "$2" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}' >> "$1"
}

echo "block-secrets-file-tools:"
run_secrets() { jq -n --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p}}' | bash "$H/block-secrets-file-tools.sh"; }
check "Read on secrets.env is denied"          block  "$(run_secrets Read "$HOME/.config/claude-secrets/secrets.env")"
# shellcheck disable=SC2088  # the literal ~ is the point: the hook must expand it
check "Edit via ~ path is denied"              block  "$(run_secrets Edit "~/.config/claude-secrets/INVENTORY.md")"
check "Glob pattern into the store is denied"  block  "$(jq -n '{tool_name:"Glob", tool_input:{pattern:"~/.config/claude-secrets/*"}}' | bash "$H/block-secrets-file-tools.sh")"
check "Read on an ordinary file passes"        silent "$(run_secrets Read "$ROOT/README.md")"
check "Bash is never inspected"                silent "$(jq -n '{tool_name:"Bash", tool_input:{command:"cat secrets.env"}}' | bash "$H/block-secrets-file-tools.sh")"
check "Write of a doc that names the file"     silent "$(jq -n '{tool_name:"Write", tool_input:{file_path:"/tmp/doc.md", content:"see secrets.env"}}' | bash "$H/block-secrets-file-tools.sh")"

echo "redact:"
out=$(printf '{"Id":1,"ApiKey":"k1","nested":{"ApiAccessKey":"k2","Name":"lib"},"list":[{"password":"p"}]}' | python3 "$ROOT/bin/redact")
check "masks every credential-named field at any depth" "match:^all-masked$" "$(printf '%s' "$out" | jq -r 'if [.ApiKey, .nested.ApiAccessKey, .list[0].password] == ["<redacted>","<redacted>","<redacted>"] then "all-masked" else "leak" end')"
check "keeps ordinary fields"                  "match:lib" "$out"
out=$(printf '{"Id":1,"Name":"lib","Secret":"s"}' | python3 "$ROOT/bin/redact" Id Name)
check "allowlist mode prints only named fields" "match:^\\{\"Id\":1,\"Name\":\"lib\"\\}$" "$(printf '%s' "$out" | jq -c .)"
check "plain text: known token shapes masked"  "match:^token <redacted>$" "$(printf 'token ghp_abcdefghijklmnop1234' | python3 "$ROOT/bin/redact")"

echo "require-pr-links:"
run_links() { transcript "$TMP/t.jsonl" "$1" "${2:-}" "${3:-}"; jq -n --arg t "$TMP/t.jsonl" --arg m "$1" '{transcript_path:$t, last_assistant_message:$m, cwd:"/"}' | bash "$H/require-pr-links.sh"; }
check "bare #123 is blocked"                   block  "$(run_links "Fixed in #123, waiting for review.")"
check "full URL passes"                        silent "$(run_links "Fixed in https://github.com/o/r/pull/123.")"
check "PR talk with a PR in flight is blocked" block  "$(run_links "Round 2 review is clear." "gh pr create --fill" "https://github.com/o/r/pull/7")"
check "unrelated message with a PR in flight"  silent "$(run_links "The migration ran on staging." "gh pr create --fill" "https://github.com/o/r/pull/7")"
check "gh pr create only mentioned, no PR"     silent "$(run_links "Round 2 review is clear." "echo 'gh pr create' > notes.txt" "")"
check "second pass never blocks (no loop)"     silent "$(jq -n '{stop_hook_active:true}' | bash "$H/require-pr-links.sh")"

echo "pr-state-truthful (gh stubbed):"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh pr view <n> --repo <r> --json state --jq .state
case "$3" in 1) echo MERGED ;; 2) echo OPEN ;; *) exit 1 ;; esac
EOF
chmod +x "$TMP/bin/gh"
run_truth() { jq -n --arg m "$1" '{last_assistant_message:$m}' | PATH="$TMP/bin:$PATH" bash "$H/pr-state-truthful.sh"; }
check "merged PR presented as ready to merge"  block  "$(run_truth "https://github.com/o/r/pull/1 is ready to merge.")"
check "merged PR reported as merged"           silent "$(run_truth "https://github.com/o/r/pull/1 merged at 10:29.")"
check "open PR presented as ready to merge"    silent "$(run_truth "https://github.com/o/r/pull/2 is ready to merge.")"
check "unknown state fails open"               silent "$(run_truth "https://github.com/o/r/pull/9 is ready to merge.")"

echo "pending-checks:"
cat > "$TMP/ledger.md" <<'EOF'
## Open items

### 2026-01-10 | Export job writes the new column
check: run the count query
pass: count > 0
context: https://example.com/T-1

### 2099-01-01 | Far future item
check: x
pass: y
context: z
EOF
run_pc() { PENDING_CHECKS_LEDGER="$TMP/ledger.md" PENDING_CHECKS_TODAY=2026-01-12 PENDING_CHECKS_STAMP="$TMP/stamp" bash "$H/pending-checks.sh"; }
out=$(run_pc)
check "due item is raised, with OVERDUE"       "match:Export job.*OVERDUE since 2026-01-10" "$out"
check "future item is not raised"              "match:^0$" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext | grep -c 'Far future')"
check "second session the same day stays quiet" "match:already raised" "$(run_pc)"
printf '### someday | no date here\ncheck: a\n' >> "$TMP/ledger.md"; rm -f "$TMP/stamp"
check "undated item is flagged"                "match:NO DATE" "$(run_pc)"

echo "pr-pilot-register:"
mkdir -p "$TMP/reg"
cat > "$TMP/fake-pilot" <<EOF
#!/usr/bin/env bash
# fake pr-pilot: "track o/r 7" writes a state file like the real one
printf '{"repo":"%s","pr":%s,"session":""}' "\$2" "\$3" > "$TMP/reg/\${2%%/*}__\${2##*/}__\$3.json"
echo "PR-PILOT-TRACKED \$2#\$3 phase=babysit"
EOF
chmod +x "$TMP/fake-pilot"
run_reg() { jq -n --arg c "$1" --arg o "$2" '{session_id:"S9", tool_input:{command:$c}, tool_response:{stdout:$o}}' \
  | PR_PILOT_BIN="$TMP/fake-pilot" PR_PILOT_DIR="$TMP/reg" bash "$H/pr-pilot-register.sh"; }
run_reg "gh pr create --fill" "https://github.com/o/r/pull/7" >/dev/null
check "successful gh pr create is tracked and stamped" "match:^S9$" "$(jq -r .session "$TMP/reg/o__r__7.json" 2>/dev/null)"
run_reg "gh pr create --fill" "see https://github.com/o/r/pull/8 for context" >/dev/null
check "no lone PR URL on stdout, nothing tracked" "match:^none$" "$( [ -f "$TMP/reg/o__r__8.json" ] && echo created || echo none)"

echo "pr-pilot-guard:"
mkdir -p "$TMP/state"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg u "$now" '{repo:"o/r", pr:5, phase:"merge", session:"S1", watcher_pid:"", updated:$u}' > "$TMP/state/o__r__5.json"
run_guard() { jq -n --arg s "$1" '{session_id:$s}' | PR_PILOT_DIR="$TMP/state" bash "$H/pr-pilot-guard.sh"; }
check "unwatched PR of this session blocks"    block  "$(run_guard S1)"
check "another session's PR is ignored"        silent "$(run_guard S2)"
sleep 300 & live=$!
jq --arg p "$live" '.watcher_pid = $p' "$TMP/state/o__r__5.json" > "$TMP/s" && mv "$TMP/s" "$TMP/state/o__r__5.json"
check "a live watcher satisfies the guard"     silent "$(run_guard S1)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
jq '.phase = "done"' "$TMP/state/o__r__5.json" > "$TMP/s" && mv "$TMP/s" "$TMP/state/o__r__5.json"
check "a done PR never blocks"                 silent "$(run_guard S1)"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]

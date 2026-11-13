#!/usr/bin/env bash
# Stop hook: refuse to end a turn while a PR tracked by THIS session is
# unfinished and nothing is watching it.
#
# Why (2026-10-27): babysit-pr and watch-pr-merge-verify already waited in
# background shells; what kept failing was the step after a wait. A last round
# skipped, a merge nobody acted on, a deploy nobody waited for: each time the
# turn simply ended. This is the deterministic backstop.
#
# A tracked PR passes when its phase is done, or when its recorded
# `pr-pilot wait` process is still alive. Otherwise the turn is blocked with the
# exact command to run. Only PRs stamped with this session's id are considered,
# so parallel sessions never block each other; state untouched for 24 h is
# ignored. Fails open on anything it cannot determine.
#
# 2026-10-29: `human` is no longer exempt. A PR held for a human can still be
# merged (by them, or force-merged), and an unwatched human phase is how such a
# merge went unnoticed; `pr-pilot wait` in that phase watches for the merge.

command -v jq >/dev/null 2>&1 || exit 0
DIR="${PR_PILOT_DIR:-$HOME/.claude/pr-pilot/state}"
[ -d "$DIR" ] || exit 0

input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session" ] || exit 0

cutoff=$(( $(date -u +%s) - 86400 ))
problems=""
for f in "$DIR"/*.json; do
  [ -e "$f" ] || continue
  line=$(jq -r --arg s "$session" '
    select(.session == $s) | select(.phase != "done")
    | "\(.repo)|\(.pr)|\(.phase)|\(.watcher_pid // "")|\(.updated)"' "$f" 2>/dev/null) || continue
  [ -n "$line" ] || continue
  IFS="|" read -r repo pr phase pid updated <<<"$line"
  up=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$updated" +%s 2>/dev/null || date -u -d "$updated" +%s 2>/dev/null || echo 0)
  [ "$up" -lt "$cutoff" ] && continue
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && continue
  case "$phase" in
    babysit) hint="next review round: run '~/.claude/bin/pr-pilot wait $repo $pr' in the background, or, if a stop condition is met, post the marker, check mergeable, '~/.claude/bin/pr-pilot set $repo $pr phase=merge' and wait" ;;
    merge)   hint="run '~/.claude/bin/pr-pilot wait $repo $pr' in the background to watch for the merge" ;;
    deploy)  hint="merged: do the queued next actions, then '~/.claude/bin/pr-pilot wait $repo $pr' in the background for the deploy, or '~/.claude/bin/pr-pilot done $repo $pr \"<why nothing waits on the deploy>\"'" ;;
    human)   hint="held for a human: run '~/.claude/bin/pr-pilot wait $repo $pr' in the background so their merge (or a force-merge) is seen; it costs nothing while they decide" ;;
    verify)  hint="deployed: run the verification plan now, then '~/.claude/bin/pr-pilot done $repo $pr \"<result>\"'" ;;
    *)       hint="unknown phase; '~/.claude/bin/pr-pilot status' and fix the state" ;;
  esac
  problems="${problems}
  - https://github.com/$repo/pull/$pr is in phase '$phase' with no watcher: $hint"
done

[ -z "$problems" ] && exit 0
jq -n --arg p "$problems" '{
  decision: "block",
  reason: ("A PR this session owns is unfinished and nothing is watching it:" + $p +
  "\n\nDo that step now instead of ending the turn. If a human has to decide something, run ~/.claude/bin/pr-pilot set <repo> <pr> phase=human, say what they must decide, and keep `pr-pilot wait` running so their merge is seen. If the PR genuinely needs nothing more, run ~/.claude/bin/pr-pilot done <repo> <pr> \"<reason>\".")
}'
exit 0

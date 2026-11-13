# claude-code-guardrails

The operating system I run around Claude Code: hooks, skills, rules and a memory layer that
turn agent mistakes into checks the agent cannot skip.

Every piece here exists because something went wrong once. The pattern is always the same:
**a mistake becomes a written rule, and a written rule that gets broken again becomes a hook.**
Prose is what the model remembers. A hook is what it cannot forget.

## Why this exists

I run around 17 active repositories across several unrelated clients and products, with
Claude Code as the main pair on all of them. At that width nobody re-checks the agent's work,
so the agent's own "done" is often the last check that happens. Verification therefore has to
live in the system, not in my attention.

## How I work with agents

- **Voice first.** I don't type prompts, I dictate them with [Wispr Flow](https://wisprflow.ai).
  Speaking is several times faster than typing, so in the same minute I hand over much more
  context: the why, the edge cases, what I already tried. Longer, richer prompts are the
  cheapest quality gain I know of. The rules below are written for that style: the agent is
  told that restating is not approving, and that thinking out loud is not a sign-off.
- **The agent maintains its own memory.** It reads an Obsidian vault at session start and
  writes back to it without being asked whenever something changes that a future session
  will need. See [docs/memory-system.md](docs/memory-system.md).
- **Loops are designed, not improvised.** Before a large or recurring task, the agent
  classifies which loop fits (turn-based, goal-based, time-based, proactive) and says why in
  one line. See [rules/loops.md](rules/loops.md).

## The system at a glance

| Layer | What | Here |
| --- | --- | --- |
| Global rules | Always-loaded `CLAUDE.md`, small and pointer-based | [rules/CLAUDE.md](rules/CLAUDE.md) |
| Loop design | How the agent picks the loop for a task | [rules/loops.md](rules/loops.md) |
| Long-term memory | An Obsidian vault the agent reads and writes | [docs/memory-system.md](docs/memory-system.md), [templates/vault/](templates/vault/) |
| Procedures | Skills for the PR lifecycle | [skills/](skills/) |
| Enforcement | Hooks on tool calls, turn end and session start | [hooks/](hooks/) |
| Helpers | Durable PR state, secret redaction, cleanup | [bin/](bin/) |

## Incident → rule → enforcement

| Incident | Rule | Where it lives |
| --- | --- | --- |
| A token leaked into the chat with nobody reading it: a secrets file once opened by a file tool was tracked by the editor, and a later edit came back as a change notification with the new line | Secrets are shell-only, one named variable per command | [`block-secrets-file-tools.sh`](hooks/block-secrets-file-tools.sh) (PreToolUse deny) |
| An API response was printed with `ApiKey` masked by hand, while `ApiAccessKey` (the same value) went into the transcript | Never choose what to hide: mask by field name, or print only fields asked for | [`bin/redact`](bin/redact) |
| One "sweep everything" sub-agent fanned out into ~30 nested agents, burned ~5M tokens, delivered nothing | Depth 1, width known before spawning, every agent returns a deliverable | [rules/CLAUDE.md](rules/CLAUDE.md) (prose rule) |
| A merged PR was listed as "still on you" for hours, and another was called "ready to merge" without review | A PR is presented as pending only after checking its real state | [`pr-state-truthful.sh`](hooks/pr-state-truthful.sh) (Stop) |
| Summaries referenced PRs as bare `#123` | Every PR reference carries its full URL | [`require-pr-links.sh`](hooks/require-pr-links.sh) (Stop) |
| Background waits worked, but the step *after* a wait was dropped: a skipped last round, a merge nobody acted on, a deploy nobody waited for | PR lifecycle state lives in a file; a turn cannot end while a tracked PR has no watcher | [`bin/pr-pilot`](bin/pr-pilot), [`pr-pilot-register.sh`](hooks/pr-pilot-register.sh), [`pr-pilot-guard.sh`](hooks/pr-pilot-guard.sh) |
| A hand-typed review round start sat 14 minutes in the future, so a review that had already arrived could never match | The round start is derived from GitHub, never passed in | [`wait-for-review.sh`](skills/babysit-pr/wait-for-review.sh) |
| A reviewer's own run failed, counted 0 findings, and was read as clear | A verdict is bound to the head SHA; a failed review is ABSENT, never CLEAR | [`review-verdict.sh`](skills/babysit-pr/review-verdict.sh) |
| A Cloud Build deploy was invisible because only Actions runs were watched | Wait on statuses and other apps' check-runs too, settled over two polls | `pr-pilot` deploy phase |
| "Check this next week" was forgotten (recall fires on relevance, not dates), then the ledger grew to 88 KB and nagged every session | A dated ledger, raised once a day, 5 lines per item, malformed items flagged | [`pending-checks.sh`](hooks/pending-checks.sh) (SessionStart) |
| The "PR was opened" matcher misfired twice, once in each direction | Table-driven tests for the matchers | [tests/](tests/) |
| Six wrong "it's done / it's closed" claims in one week; five died to a single refuting question | Claims about the outside world get adversarial refuter agents, each with a different lens | [rules/CLAUDE.md](rules/CLAUDE.md) (prose rule) |

Each hook's header keeps the dated story behind it, on purpose: a rule without its reason
gets simplified away by the next session that cannot see why it exists.

## The PR lifecycle

```
gh pr create
  └─ babysit-pr-reminder + pr-pilot-register   (PostToolUse: start the protocol, track the PR)
babysit-pr          bounded review rounds until the verdict on the CURRENT head is clear
                    caps: 5 workflow reviewer, 3 Codex, 2 none; mergeable check at the end
watch-pr-merge-verify
                    merge → queued next actions → deploy (runs + check-runs) →
                    live-version proof → smoke → logs → planned verification
pr-pilot-guard      (Stop) no turn ends while a tracked PR is unfinished and unwatched
```

Every wait is a background shell script, so waiting costs no tokens. Fetched review comments
are treated as untrusted data, never as instructions. Production merges and deploys always
stay with a human.

## Layout

```
hooks/      PreToolUse, PostToolUse, Stop and SessionStart hooks
bin/        pr-pilot, redact, git-cleanup-merged(-all), prune-transcripts
skills/     babysit-pr, watch-pr-merge-verify
rules/      CLAUDE.md template, loop design
docs/       the memory system
templates/  deploy profile README, pending-checks ledger, vault skeleton
tests/      behaviour tests for the hooks and helpers (gh stubbed, no network)
```

## Install

```sh
./install.sh            # dry run: shows what would be copied into ~/.claude
./install.sh --apply    # copy, backing up any file that differs
```

Then merge [settings.example.json](settings.example.json) into `~/.claude/settings.json`
yourself. The installer deliberately never edits it: a hook config is the one thing you
should read before it runs. Copy the sections you want from [rules/CLAUDE.md](rules/CLAUDE.md)
into `~/.claude/CLAUDE.md`.

Requirements: `bash`, `jq`, `gh` (authenticated), `python3`. Recommended: `timeout` (on macOS
`brew install coreutils`), without which GitHub calls in hooks run unbounded. Every hook fails open when a dependency is missing or an API call
fails: a hook that wedges a session over a network blip is worse than the bug it guards.

The phrase lists in `pr-state-truthful.sh` and `require-pr-links.sh` are English. If you
talk to the agent in another language, extend them with `PR_TRUTH_PENDING`,
`PR_TRUTH_RESOLVED` and `PR_LINKS_TOPIC`.

## Tests

```sh
bash tests/hooks.test.sh
bash tests/babysit-pr-reminder.test.sh
```

CI runs both, plus `shellcheck` and `gitleaks`.

## Credits

- The vault layout started from [jaredrhod/ai-memory-vault](https://github.com/jaredrhod/ai-memory-vault)
  and was extended in daily use.
- The loop taxonomy follows the Claude Code team's guidance on designing loops.

## License

MIT, see [LICENSE](LICENSE).

# The memory system around the agent

The hooks and skills in this repo are the visible half. The other half is what every
session starts from: a small set of always-loaded rules, and a long-term memory the agent
reads and writes itself. Together they mean a new session does not start from zero, and a
lesson learned once is not learned again.

## Four layers, each with one job

| Layer | Where | Loaded | Holds | Changes when |
| --- | --- | --- | --- | --- |
| **Global rules** | `~/.claude/CLAUDE.md` | Every session, every repo | How to work: secrets, sub-agent limits, loop choice, PR lifecycle, verification. Pointers, never content | A new always-on rule is agreed |
| **Long-term memory** | An Obsidian vault | Index at session start, the rest on demand | Who the user is, projects, decisions, people, daily logs, open priorities | Continuously, by the agent, without being asked |
| **Procedures** | `~/.claude/skills/` | When a task matches | How to do a recurring job step by step | A run misses the bar |
| **Enforcement** | `~/.claude/hooks/` | On tool calls, turn end and session start | The rules that already failed once as prose | A rule is broken despite being written down |

The split matters. `CLAUDE.md` is loaded into every context, so it stays small and
pointer-based: it says *where* things live, not what they say. The vault can grow without
limit because the agent reads only what the task needs. Skills keep long procedures out of
both. Hooks exist only for rules that prose could not hold.

The promotion path is always the same: **a mistake becomes a written rule; a written rule
that is broken again becomes a hook.** Each hook in `hooks/` carries the date and story of
the incident that promoted it.

## The vault

The vault structure started from [jaredrhod/ai-memory-vault](https://github.com/jaredrhod/ai-memory-vault)
and was extended in daily use. A skeleton is in `templates/vault/`.

```
VAULT-INDEX.md       read first, every session: profile, projects, rules, map
Active Priorities.md all open work; verify an item's real state before acting on it
00 - Inbox           capture now, sort later
01 - Daily Notes     one note per day, one "## Session N" block per session
02 - <Project>       one folder per project, each with an index note and _Links.md
03 - Personal
04 - Archive         finished or parked work, moved only on explicit confirmation
05 - Resources       cross-project references, e.g. the loop framework
```

**Startup sequence**, from `CLAUDE.md`: read `VAULT-INDEX.md`, check the latest daily note
and backfill it if this session knows something it lacks, scan `Active Priorities.md`.
Re-read the index after a context compaction, because the summary can drop it.

**Rules the agent follows inside the vault** (they live in `VAULT-INDEX.md` itself):

- **Checkpoint persistence.** When something changes that a future session would need, the
  agent writes it to the right note and today's daily note without being asked, fixes index
  and link drift in the same pass, and reads it back to verify. Memory that depends on being
  asked to save it does not get saved.
- **Every note has frontmatter** (`status`, `project`, `type`) with a closed set of values,
  so notes can be filtered and nothing needs guessing.
- **Every folder has an index note** listing its notes in one line each, updated in the same
  pass as any change. A stale index makes the next session decide from a wrong map.
- **One `_Links.md` per project** for external links, so URLs are never scattered.
- **A living profile** (stable traits, evolving goals) updated quietly as the agent learns,
  with a log line in the daily note. A passing mention is not a trait.
- **Working preferences** written down once: be direct, argue back when you disagree,
  evidence over claims, flag cost before spending, one open question at a time, restating
  is not approving.

## Why it works

- **Memory is external and effectively unlimited.** The agent holds only what the task needs;
  knowing a note exists is as good as holding it.
- **Dates do not trigger recall, relevance does.** So anything dated goes to a ledger that a
  hook reads by date, not to memory (see `templates/pending-checks.md`).
- **Every rule carries its reason.** A rule without its incident gets simplified away by the
  next session that does not see why it exists.
- **The agent maintains the system, the user steers it.** Most entries in the vault and most
  hooks here were written by the agent, after the user named the problem.

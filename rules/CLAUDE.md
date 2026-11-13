# Agent operating rules (template)

Drop the sections you want into `~/.claude/CLAUDE.md`. Each rule names the incident that
produced it, because a rule without its reason gets "optimised away" by the next session.
Where a rule matters enough, it is also enforced by a hook in `hooks/`: prose is what the
model remembers, a hook is what it cannot forget.

## Secrets live in one shell-only file

Every API token goes in `~/.config/claude-secrets/secrets.env` (dir `700`, file `600`,
outside every repo). The user pastes the value there and tells the agent only the
**variable name**.

**The hard rule: `secrets.env` is never touched by `Read`, `Write`, `Edit` or `Glob`.**
A file opened by a file tool becomes tracked by the editor environment, and a later
external edit is then pushed to the model as a change notification *with the new line's
content*. That is how a token leaked without anyone reading anything. Shell access does not
create that tracking.

- Read one named variable per command, never the whole file:
  `TOKEN=$(grep -m1 '^SERVICE_SCOPE_KIND=' ~/.config/claude-secrets/secrets.env | cut -d= -f2-)`
- Presence check: `grep -q '^NAME=.\+' ~/.config/claude-secrets/secrets.env && echo set || echo empty`
- Never `curl -v`, `env`, `set`, or echo a value.
- **Never print an API response whole, and never choose which fields to hide.** Choosing
  what to hide is a denylist, and it is always one field short: a response was once printed
  with `ApiKey` masked by hand while `ApiAccessKey`, the same value under another name, went
  into the transcript. Pipe every response through `bin/redact`, or better, name the fields
  you want (`... | redact Id Name`): a field never asked for cannot leak.
- Need a new secret? Never ask for it in chat. Append a named, empty entry via the shell and
  tell the user which name to fill in.
- Anything that ever reached a chat window is leaked and must be rotated: transcripts keep it.

Enforced by `hooks/block-secrets-file-tools.sh`.

## Sub-agents: bound depth and breadth, or don't spawn

One "sweep the whole tree" agent once fanned out into ~30 nested agents, burned ~5M tokens,
and produced no deliverable.

1. **Never hand breadth to an agent that can itself spawn.** A delegate gets a narrow leaf
   task, or a tool-restricted agent type with no Agent tool. Depth is capped at 1.
2. **Know the width before you spawn.** Scout inline to get a finite work-list, then one
   bounded agent per item. State the count before launching.
3. **Every agent returns a concrete deliverable**: a diff, a commit, a PR, or a
   decision-grade answer. An "audit" that lands nowhere burned tokens for nothing.
4. **You can't stop what you can't name.** Nested children cannot be killed by their parent's
   id, which is the other reason depth is capped.
5. **When in doubt, do it inline.**

## Classify the loop before a large task

Before any large, multi-step or recurring task, ask three questions: can I write a
deterministic verification check? Is "done" crisply defined? Does the work arrive on a
schedule? Then pick the simplest primitive that fits: turn-based with a verification step,
a goal with a turn cap, a scheduled loop, or a workflow. Say which one and why in one line.
When a result misses the bar, fix the system (the skill, the check), not just the instance.

## A claim about the outside world gets a refuter before "done"

Before reporting *"it is closed / it works / nobody can see it / it is deployed / it is
clean"*, try to kill the claim and report only what survives.

- Run refuters as separate agents. The context that produced the claim already believes it.
- Give each a different lens: does it reproduce, who else can reach it, what does the raw
  response actually say, what would make this false.
- A refuter returns a verdict with evidence (a status code, a listing, a diff), never "looks
  right".
- If refuters disagree, hand the disagreement to the user. Do not pick the comfortable one.
- Not for drafts or opinions. Only for claims about the state of the world.

In one week this killed five of six wrong claims: a canonical-URL field that no code read,
an index "invisible to search" on a route the site never published, a repo "properly closed"
while three contractors still held read access.

## Verify later: a dated ledger, not memory

Memory recall fires on relevance, never on a date. When asked to check something later, add
a 5-line item to `~/.claude/pending-checks.md` (format in `templates/pending-checks.md`).
`hooks/pending-checks.sh` raises due items once a day, in the first session. Never append
notes to an item: history goes to the issue tracker. The ledger once grew to 88 KB of diary
and nagged every session; the 5-line limit is now checked by the hook.

## Open a PR: babysit it, then watch it to deploy

After `gh pr create`, run the `babysit-pr` skill: bounded rounds until the reviewer's
verdict on the **current head** has no Critical/Major, capped per reviewer. End with the
`mergeable` check; a conflict is a finding, and reading the other side first can mean
closing your own PR because someone already fixed it better. Then run
`watch-pr-merge-verify`: merge, the deploy described by the repo's deploy profile, proof the
new version is live, smoke, logs.

Never merge or deploy to production to enable a verification. Production is human-approval
only.

Enforced by `hooks/babysit-pr-reminder.sh`, `hooks/pr-pilot-register.sh`,
`hooks/pr-pilot-guard.sh`, `hooks/pr-state-truthful.sh` and `hooks/require-pr-links.sh`.

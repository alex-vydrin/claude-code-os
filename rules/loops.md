# Designing loops: how the agent picks one

Adapted from the Claude Code team's "designing loops" guidance, plus how it is wired into
daily work. The reframe: instead of prompting an agent turn by turn, **design the loop**.
Decide what gets handed off, what the stop condition is, and which primitive runs it.

`CLAUDE.md` makes this automatic: before any large, multi-step or recurring task the agent
classifies the work first and states its choice in one line ("goal-based: the stop condition
is `npm run verify` passing, cap 5 turns"). It never free-styles turns on a big task.

## The four loop types

| Loop | Triggered by | Stops when | You hand off | Use it when | Primitive |
| --- | --- | --- | --- | --- | --- |
| **Turn-based** | A prompt | The agent judges it done | the *check* | Short, one-off work; exploring | The normal loop plus a verification skill |
| **Goal-based** | A prompt | Goal met **or** turn cap hit | the *stop condition* | "Done" is deterministic | `/goal` with a turn cap |
| **Time-based** | An interval | Cancelled, or the work completes | the *trigger* | Recurring work, polling an external system | `/loop` locally, `/schedule` in the cloud |
| **Proactive** | An event or schedule, no human | Each task exits at its goal | the *prompt* | A stream of well-defined work: triage, migrations, upgrades | `/schedule` + `/goal` + skills + workflows, composed |

## The three diagnostics

The agent asks these, in order, and takes the simplest loop that fits:

1. **Can I write a deterministic verification check?** Yes: lean goal-based, or encode the
   check as a skill so a turn-based loop can verify itself.
2. **Is "done" crisply defined?** Yes: goal-based, always with a turn cap.
3. **Does the work arrive on a schedule or from an external system?** Yes: time-based or
   proactive. Match the interval to how often the watched thing actually changes.

Escalate only when the simpler loop stalls. A workflow that fans out to many agents is
piloted on a slice first, so its cost is known before the full run.

## How it shows up in practice

- **Implementation ticket in a repo with a verify ladder** (lint, typecheck, tests, e2e):
  the ladder is a ready-made goal condition, "don't stop until `verify` passes, max 5 tries".
- **A PR after it is opened**: a time-based loop with hard caps, run by `babysit-pr` and
  `pr-pilot` in this repo. The wait is a background script, so polling costs no tokens.
- **"Check this next week"**: not a loop at all. A dated line in the pending-checks ledger,
  raised by a SessionStart hook. A daemon is the exception, built only when something must
  fire at an exact time with nobody at the keyboard.
- **A question asked of every project at once** (which repos have no CI, whose tokens
  expire): a read-only workflow, one agent per item, count stated before launch.
- **Idea validation**: an adversarial bull/bear/judge pass with pre-registered kill
  thresholds, i.e. a deterministic stop condition rather than a vibe.

## Quality and cost rules around any loop

- Give it a way to verify. "What good looks like" belongs in a skill, quantitative where
  possible.
- Review with a second agent in a fresh context, never self-review.
- Use scripts for deterministic steps. Running a script beats re-reasoning it every turn.
- Don't over-poll. A CI run that takes 8 minutes deserves one check at 8 minutes.
- Every loop has a convergence counter. A bare `while` is how a run burns millions of tokens.
- **When a result misses the bar, fix the system, not the instance.** Encode the lesson in a
  skill, a check or a hook so every later iteration inherits it. Most hooks in this repo
  exist because of that rule.

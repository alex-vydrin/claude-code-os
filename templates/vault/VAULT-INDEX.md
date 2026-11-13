---
status: active
project: meta
type: index
---
# VAULT INDEX

Read this file at the start of every conversation to understand who I am, how I work, and
how this vault is organised.

## Who I am

<role, current focus, what I am building, constraints worth knowing>

## Projects

### <Project name> (`02 - <Project>`)
<one paragraph: what it is, my role, where the code lives, the current state>

## Vault structure

```
00 - Inbox          capture everything, sort later
01 - Daily Notes    dated logs, monthly subfolders
02 - <Project>      one folder per project
03 - Personal
04 - Archive        completed or parked work
05 - Resources      cross-project reference and templates
```

## What's active right now

All open work lives in [[Active Priorities]]. Check it at the start of every conversation;
verify an item's real state before acting, because a listed item may already be done.

## My preferences for working with AI

- Plain language, be direct, no hedging.
- Be a partner, not a yes-man: argue your position when you think I am wrong.
- Evidence over claims: verify from the actual file, command or API before saying "done".
- Flag cost before any real spend.
- When you ask me a question, stop and wait for the answer. One open question at a time.
- Restating is not approving: lock a decision only when I say so.

## How my memory works (for the AI)

This vault is your memory. It is external and effectively unlimited. Hold only what the
current task needs; everything else is one search away. Start at this index, follow folder
indexes and wikilinks, or search.

## Vault rules for AI

### Frontmatter
Every note has YAML frontmatter with `status`, `project`, `type`. Add it when you create a
note, fix it when you edit one that lacks it. Infer the values; never ask.

- status: `active` | `completed` | `parked` | `idea` | `archived`
- project: `<project-slug>` | `personal` | `meta`
- type: `index` | `reference` | `guide` | `plan` | `log`

### Wikilinks
Link people, named products and platforms, and any note this one references. Never link
generic words, the same target twice, or the note's own title.

### Folder indexes
Every folder with substantial content has an index note named after the folder, listing each
note with one line. Update it in the same pass as any change to the folder.

### Checkpoint persistence
When anything changes that a future session would need, persist it without being asked:
update the relevant note and today's daily note, and only for a new always-on rule,
`~/.claude/CLAUDE.md`. Fix index and link drift in the same pass. Verify by reading it back.

### Project links
Each project folder keeps external links in `_Links.md` at its root. Save any link worth
keeping there; never scatter links across other notes.

### Archiving
On "done" or "archive": set `status: archived`, move to `04 - Archive`, confirm what moved
where. Never archive on your own initiative.

### Daily notes
`01 - Daily Notes/NN - Month YYYY/YYYY-MM-DD.md`. A date heading, then an `## Index` block
with one line per session. One note per day; append `## Session N`, never overwrite. Check
the actual date first.

### Living profile
Keep a profile note (stable traits) and a growth note (evolving goals) up to date as you
learn, logging each update in the daily note. A passing mention is not a trait.

---
name: watch-pr-merge-verify
description: The follow-on to babysit-pr. After babysit-pr's bounded review rounds, keep an in-session, time-boxed watch on the PR until it merges; on merge, do the next actions the merge unblocks, then wait for the deploy the repo's deploy profile describes (GitHub Actions runs, Cloud Build / Cloudflare / Vercel check-runs), confirm the new version is actually live, smoke it, read the logs since the deploy, and run any verification this session implies (a test token was given, "test it on dev once merged", tests were planned) without being asked. Builds the repo's deploy profile first when it has none. When nothing is queued and nothing needs verifying, announce the merge and stop. Triggers automatically after babysit-pr per ~/.claude/CLAUDE.md, and on "watch the PR until it merges", "verify after deploy", "test it on dev once it's merged".
---

# Watch PR -> merge -> deploy -> verify

The continuation of `babysit-pr`. That skill drives review rounds and stops; this one
answers a different question: *"once this PR merges and ships, is there anything to do
or to check, and if so, do it without being asked?"* It never re-runs comment triage.

The hard part is not the wait, it is knowing **what a merge deploys, where, and how to
see it**. That knowledge lives in a per-repo **deploy profile**,
`~/.claude/deploy-profiles/<owner>__<repo>.md` (format and discovery recipe in
`~/.claude/deploy-profiles/README.md`). Repos where nothing deploys on merge are listed
in `~/.claude/deploy-profiles/ci-only.md`.

## pr-pilot drives the waits

Same state file as babysit-pr:

```bash
P=~/.claude/bin/pr-pilot
# Step 0: persist the intent, so a later wake-up cannot lose it
$P set <owner/repo> <pr> phase=merge verify="<what/where/with what/pass signal>" next="<numbered actions>"
# Steps 1 and 3: one command, run_in_background: true, re-run after each ACTION
$P wait <owner/repo> <pr>
```

- **merge phase**: polls the PR state every 5 s (2 h cap) and prints `ACTION merged`
  with the deploy profile's path (or `MISSING`). `ACTION held` = an `automerge-blocked`
  marker exists (only in repos with an automerge workflow): surface the decision.
  `ACTION new-head` = a push after the review finished: back to babysit.
- **deploy phase**: waits until every push run, commit status **and check-run of a
  non-Actions app** on the merge commit has finished, stable over two polls (45 min
  cap), then `ACTION deployed` with failures listed and the profile path. Check-runs
  matter: Cloud Build, Cloudflare Workers Builds and Vercel report only there.
- **verify phase**: run Step 4, report, `$P done ... "<result>"`.
- **human phase**: held for a person; `wait` still watches for their merge.

The Stop guard `~/.claude/hooks/pr-pilot-guard.sh` blocks the turn while any of these
phases has no live watcher.

## When this runs

- **Automatically**, in the same turn as `babysit-pr`'s report (its Step 5), per the
  "Open a PR" rule in `~/.claude/CLAUDE.md`.
- **On request**: "watch the PR until it merges", "verify after deploy", "test it on
  dev once it's merged".

## Step 0 - Capture the intent and the profile NOW (before any wait)

While the session context is fresh, decide three things and persist them with `$P set`.

**a) The deploy profile.** Look for `~/.claude/deploy-profiles/<owner>__<repo>.md`, or
the repo's row in `ci-only.md`.
- Found: read it. Note which run or check-run is the deploy and which are only CI.
- **Missing: build it now** with the read-only recipe in the README (workflows,
  `cloudbuild.yaml` / `wrangler.toml` / Terraform triggers, and the check-runs on the
  last merge to the default branch as ground truth). Write the file, then tell the user in
  one short paragraph what it says, so a wrong guess gets corrected before it matters.
  If the repo deploys nothing on merge, add a row to `ci-only.md` instead.

**b) Is post-deploy verification pending?** Signals in this session:
- The user gave a test token, credentials or a specific account for this change.
- They said "test it after it deploys", "verify on dev once merged", "check it is live".
- You ran or planned tests (Playwright, API smoke, a script) for this change and were
  waiting for a deployed environment.
- The change is only meaningfully checked deployed (a backend route, a webhook, a
  migration, a worker), and the session was driving toward that check.

If any: write the plan as *what* to test, *where* (env + URL from the profile), *with
what* (token/account, by secrets.env NAME, never a value), and the *pass signal*. If
none: `verify=""`. **The default checks of Step 4 (live version, smoke, logs) still run
whenever the profile shows a deploy**, plan or no plan: a deploy nobody looked at is
how a broken revision stays up.

**c) Next actions this merge unblocks.** Anything waiting on *this* merge:
- a check on another PR that fails until this lands (re-run it, re-triage that PR);
- a first-run / enable step the merged code needs (a job, a scheduler, a migration);
- a plan item whose dependency this PR satisfies;
- a follow-up PR you said you would open "once this merges".
Write them as a numbered list with the command for each. A non-empty list makes the
watch mandatory even when nothing needs verifying.

## Step 1 - Watch for the merge (in-session, time-boxed)

`$P wait <owner/repo> <pr>` in the background (`run_in_background: true`). When it exits,
read its last line:
- `ACTION merged` -> Step 2.
- `ACTION closed` -> "PR closed without merging, nothing to verify", stop.
- `TIMEOUT` -> "still unmerged after 2 h, stopping the merge watch; ask me to resume",
  `$P set ... phase=human`, stop. Never watch forever.

Several PRs: one `$P wait` per PR, each in the background.

This watch lives in the session. A watch that survives the session is a scheduled job:
only when the user asks (and then usually a `~/.claude/pending-checks.md` line, per CLAUDE.md).

## Step 2 - On merge: queued actions first

1. **Next actions queued** -> do them now, in this turn, before any deploy wait. Prod
   steps still need the user's word: ask once, with the exact steps ready. Each new PR
   re-enters babysit-pr and this skill.
2. **The profile shows a deploy** -> announce the merge and go to Step 3.
3. **CI only, nothing queued, nothing to verify** -> *"PR merged (<url>). This repo
   deploys nothing on merge (<profile>), so I'm stopping here."* `$P done`, stop.

## Step 3 - Wait for the deploy

`$P wait` again in the background. On `ACTION deployed`:
- `Failed: [...]` not empty -> the deploy (or CI) failed. Say so plainly with the failing
  run or check-run, fetch its log (`gh run view <id> --log-failed`; for Cloud Build the
  build log per the profile) and quote the failing step. **Do not verify against a
  stale deploy**: the old version is still serving.
- Only CI finished but the profile's deploy run/check-run is absent (the commit touched
  nothing deployable, e.g. a monorepo app filter) -> say which deploy did not run and why.
- `TIMEOUT` -> report what is still running, `$P set ... phase=human`, stop.

## Step 4 - Confirm, smoke, logs, then the plan

Run these from the profile, in order, without being asked:

1. **Is the new version live?** The profile's command (image tag == merge short SHA,
   Pages `Source` == merge SHA, the ready revision takes the traffic). A green build is
   not a live revision: a failed migration or health check leaves the old one serving.
2. **Smoke.** The profile's cheapest request (health, `/ready`, the page the change
   touched). Mind auth: an IAM-gated or Access-gated service answers 403 to an
   anonymous request by design, and that is not a failure.
3. **Logs since the deploy.** The profile's runtime log command, window = from the
   deploy time. Look for new errors/warnings tied to the change; quote at most a few
   lines, pick fields, never dump whole entries (env and URLs can hold secrets).
4. **The verification plan** from Step 0, if any, with the token/account named there.

Report: what was deployed where, live yes/no (with the evidence line), smoke result,
anything notable in the logs, plan result. Then `$P done <owner/repo> <pr> "<result>"`.
A claim that "it is live and works" gets the refuter treatment from CLAUDE.md only when
something rides on it beyond this PR.

If the profile was wrong anywhere (a check-run name changed, a URL moved), fix the
profile file in the same turn.

## Guardrails

- **Never** merge the PR or deploy to **production** to make verification possible.
  Prod paths (release tags, approvals) are in each profile's Limits: the user's call only.
- Time-box every wait (merge 2 h, deploy 45 min). Never poll indefinitely.
- Don't re-run babysit's review triage here.
- Secrets by NAME from `~/.config/claude-secrets/secrets.env`, read in the shell, never
  printed; API responses through `~/.claude/bin/redact`.
- If what to verify is genuinely ambiguous, announce the merge, run the default checks
  of Step 4, and ask rather than invent a test.

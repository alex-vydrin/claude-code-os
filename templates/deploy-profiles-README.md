# Deploy profiles

One file per repository, `<owner>__<repo>.md`, read by `watch-pr-merge-verify`
(and pointed at by `~/.claude/bin/pr-pilot` when a PR merges). A profile answers
the questions a merge leaves open, so the agent does not rediscover them on every PR:

1. **What a merge triggers** - which branch, which runs, which environment.
2. **The "deploy finished" signal** - which GitHub Actions runs or check-runs on the
   merge commit mean the deploy is done. `pr-pilot wait` in the deploy phase already
   waits for ALL push runs, commit statuses and check-runs (Cloud Build, Cloudflare
   Workers Builds, Vercel all report as check-runs); the profile says which of them
   is the actual deploy and what is only CI.
3. **Is the new code live?** - a command that proves the running version is the merge
   commit (an image tag, a deployment's commit hash), not just "the build is green".
4. **Smoke** - the cheapest request that shows the service works.
5. **Logs** - where runtime and build logs are, as a command for the time window
   right after the deploy.
6. **Limits** - what the agent must never do (prod deploys, approvals).

Every fact in a profile was read from a file or an API on the date it names. When a
profile turns out wrong, fix the profile in the same session, not just the instance.

## A repo has no profile yet - build one (read-only, ~5 minutes)

Do this in Step 0 of `watch-pr-merge-verify`, before the merge, and show the user the
new profile in one short paragraph.

1. `ls .github/workflows/` and, for each, the `on:` block and the deploy steps
   (`wrangler`, `gcloud run`, `npm run deploy`, `vercel`, `railway up`, ...).
2. Deploy config outside Actions: `cloudbuild.yaml`, `wrangler.toml`, `railway.*`,
   `vercel.json`, `fly.toml`, Terraform triggers (`google_cloudbuild_trigger`).
3. **Ground truth: what actually ran on the last merge to the default branch.**
   ```bash
   sha=$(gh api repos/<o>/<r>/commits/<default-branch> --jq .sha)
   gh api repos/<o>/<r>/commits/$sha/check-runs --jq '.check_runs[] | "\(.app.slug) | \(.name) | \(.conclusion)"'
   gh run list -R <o>/<r> --commit $sha --json name,event,conclusion
   ```
   A deploy that is not a GitHub run shows up here as a check-run of another app
   (`google-cloud-build`, `cloudflare-workers-and-pages`, `vercel`).
4. Where it runs and how to read its version and logs (Cloud Run service + project,
   Pages project, Worker name). Confirm which cloud identity is active before reading
   anything (`gcloud config list`, `aws sts get-caller-identity`).
5. If nothing deploys on merge, write that down too: a one-line profile saying
   "CI only, no deploy on merge" stops the next agent from waiting for one.

## Shared recipe: is a Cloudflare Pages deploy live?

Account IDs and tokens in secrets.env can carry stray spaces: trim them.
```bash
export CLOUDFLARE_API_TOKEN=$(grep -m1 '^<TOKEN_NAME>=' ~/.config/claude-secrets/secrets.env | cut -d= -f2- | tr -d ' ')
export CLOUDFLARE_ACCOUNT_ID=$(grep -m1 '^<ACCOUNT_NAME>=' ~/.config/claude-secrets/secrets.env | cut -d= -f2- | tr -d ' ')
npx --yes wrangler@4 pages deployment list --project-name <project> --environment production --json \
  | jq -r '.[0] | "\(.Source) \(.Status) \(.Deployment)"'
```
Live when `Source` equals the merge commit's short SHA. `Source` is empty for a direct
upload made outside a git checkout; then the newest
production deployment must be younger than the merge, and the deploy run's log names
its `*.pages.dev` URL. Run it from a scratch directory, not inside the repo.

## Template

```markdown
# <owner>/<repo>
checked: <date>, from <files / API calls>

## On merge to <branch>
- <run or check-run name> (<app>): <what it does> -> <environment>
- CI only (not a deploy): <names>

## Deploy finished
<which check-run / run conclusion means the new version is out>

## Is it live?
<command proving the running version == merge commit>

## Smoke
<command>, expect <signal>

## Logs
- runtime: <command, window = since the deploy>
- build: <command or console link>

## Limits
<prod path, approvals, what the agent never does>
```

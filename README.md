# workflows

Reusable GitHub Actions workflows and composite actions for the fleet
(33 chrischall repos + 6 nullnet-app repos). Consumers reference `@main`.

| Component | Kind | Consumers |
|---|---|---|
| `.github/workflows/reusable-pr-auto-review.yml` | reusable workflow | all |
| `.github/workflows/reusable-auto-merge.yml` | reusable workflow | all |
| `.github/workflows/reusable-claude.yml` | reusable workflow | all |
| `.github/workflows/reusable-mcp-ci.yml` | reusable workflow | node repos |
| `.github/workflows/reusable-cloudflare-deploy.yml` | reusable workflow | web repos (OpenNext → Cloudflare Workers) |
| `.github/workflows/reusable-mcp-connector-deploy.yml` | reusable workflow | MCP repos with a hosted connector (plain `wrangler deploy`) |
| `.github/workflows/reusable-fly-deploy.yml` | reusable workflow | repos with a Fly.io backend |
| `.github/workflows/reusable-dependabot-lockfix.yml` | reusable workflow | repos with derived lockfiles dependabot can't refresh |
| `.github/actions/arm-gate` | composite action | bespoke-CI repos (gradle, swift) |
| `templates/ci-gradle.yml` | starter template | Gradle/KMP repos |
| `templates/dependabot-lockfix-{npm,gradle}.yml` | stub templates | repos with `lockfix` set in `fleet.json` |
| `.github/actions/mcp-publish` | composite action | MCP publishers |
| `.github/actions/install-mcp-publisher` | composite action | via mcp-publish |

The pipeline contract: non-release PR → auto-review emits a mandatory
`pass|warn|fail` verdict → `pass` or `warn` adds `ready-to-merge` → label arms
native auto-merge and fires deferred CI (the required check) → merge on green.
Deferred CI blocks un-armed PRs in one of two gate modes: legacy `fail` (the
required `ci / ci` job fails red until armed) or `status` (a yellow
`ci-gated: pending` commit status blocks instead and the `ci / ci` job is
*skipped* while un-armed — no misleading green for a build that never ran, and
red then only ever means a real failure). Status mode needs the stub to grant
`statuses: write` and the ruleset to require the `ci-gated` context
(`scripts/update-ruleset.sh <repo> ci-gated --execute`); flip both together.
Status mode also suppresses the duplicate CI run a non-arming label would
trigger on an already-armed PR (#12) — unsafe to suppress in fail mode, where
a green skip would overwrite a legitimately red check on the same SHA.
Fork PRs are the one case status mode cannot gate with a status at all: their
`GITHUB_TOKEN` is capped read-only whatever the stub requests, so the
`ci-gated` POST 403s. The gate arms CI for them and posts nothing, so the run
shows a real pass/fail while the unreported `ci-gated` context keeps the merge
blocked for a human — never green by accident. Bespoke-CI repos get the same
rule from `arm-gate`, which publishes `is_fork` for their reporter step to
guard on (`templates/ci-gradle.yml` shows the shape).

**Merging a fork PR.** Nothing posts `ci-gated`, so the required context is never
satisfied and the merge is blocked by design. "Blocked until a maintainer acts"
means *you post the status*, after reading the run:

```sh
gh api repos/<owner>/<repo>/statuses/<head-sha> \
  -f state=success -f context=ci-gated \
  -f description="fork PR - CI verified by maintainer"
gh pr merge <n> --squash          # no --admin needed once the context is green
```

`gh pr merge --admin` does **not** help: it bypasses classic branch protection,
not a repository **ruleset**, which only yields to an entry in its
`bypass_actors` list. Adding yourself there works, but loosens every rule in the
ruleset for every PR — posting one status for one SHA does not.
Any review that surfaced findings — a `warn`/`fail` verdict, or a `pass`
whose structured output still lists nits — also opens or updates a per-PR
`auto-review-followup` issue holding every finding (linked from the verdict
comment): `pass`/`warn` still auto-merge — the issue carries the nits
forward — while `fail` keeps a human in the loop. When a later review pass on
the same PR comes back **clean** (a `pass` with no findings), that is taken as
proof the findings were addressed: the pipeline appends `Closes #<issue>` to
the PR body so the issue closes on merge. It links rather than closing outright
because the fix is not on the default branch yet, and it does this only on a
clean re-review — on `warn`/`fail` the convention still holds that deferred
items stay open. The one exit that path cannot cover is a PR that closes
**without** merging (a duplicate, a superseded branch): nothing would ever
close its follow-up issue, and the issue reads exactly like a live one.
`followup-orphan-sweep.yml` walks the fleet daily for that state and comments
on the issue plus labels it `orphaned-followup` — deliberately without closing
it, because a finding on an abandoned PR is often still true of `main` (that is
the mcp-host case in #139, where the abandoned nit shipped uncorrected).
The checklist is regenerated on every review round, so it carries prior tick
state forward — matched on the exact finding text, never on a reworded one —
and stamps the commit the round reviewed, since a round judging a stale diff
can re-list a finding that is already fixed. Release-please PRs follow the same gate, except the
review is triggered by adding `release-ready` (not on open): `release-ready`
starts the review, the review's `pass`/`warn` adds `ready-to-merge`, and only
then does deferred CI run — so CI never runs ahead of a successful review.

A verdict is bound to the commit it reviewed, which is why
`rereview_on_push` exists. Once a PR is armed, a force-push replaces the code
but not the standing verdict or the arming label, so the PR can merge on a
review describing code it no longer contains — that is how
`opencode-copilot-plugin#7` merged. Setting the input re-runs the review on
`synchronize`, at the cost of a review per push.

It is opt-in per repo, off by default, and recorded in `fleet.json` as
`"rereview_on_push": "true"` rather than hand-edited into a stub — a hand-edit
there is silently reverted by the next `rollout.sh --execute` (issue #76).
`rollout.sh` drops the line entirely when the value is empty, so repos that do
not opt in render byte-identical stubs; a bare `rereview_on_push:` would pass
an explicit null where the caller means unset. Currently one repo carries it,
as the canary for #126 — flipping the default would change review behaviour in
every repo at once, which is a separate decision from having the input.

`mcp-publish` is a composite action (not a reusable workflow) on purpose:
npm trusted publishing and mcp-publisher validate the OIDC token's workflow
identity, which must remain the consuming repo's own `release-please.yml`.

`arm-gate` is the deferred-merge gate as a composite action so bespoke CI jobs
(Gradle/KMP, Swift) — which carry repo-specific build steps and so can't call a
reusable workflow — still get the one load-bearing rule centrally: an un-armed
PR FAILS the required `ci` check rather than skipping it (a skipped required
check counts as satisfied and would let the merge button go live before CI ran).
Drop it in as the first step of the CI job; `templates/ci-gradle.yml` is a
ready-to-adapt Gradle/KMP starting point that uses it.

`reusable-cloudflare-deploy.yml` standardizes shipping a Next.js `web/` app to
Cloudflare Workers via OpenNext (`npm ci` → `opennextjs-cloudflare build` →
`deploy`), authed with a `CLOUDFLARE_API_TOKEN` repo secret + a non-secret
account-id input. An optional `java-version` provisions a Temurin JDK first for
apps with a JVM/Gradle prebuild (a shared KMP engine). Onboard a repo by copying
`templates/deploy-web.yml` (swap `__ACCOUNT_ID__`); see
`docs/cloudflare-web-deploy.md`. Live consumers: allotmint-clients/web (with a
JDK prebuild) and curtaincall/web (plain).

`reusable-mcp-connector-deploy.yml` is the *other* Cloudflare deploy: an MCP
server's hosted connector Worker, deployed with a plain `wrangler deploy` from
the repo root — no framework build, no `web/`. It takes a `ref` so a release
deploys the released source rather than whatever `main` happens to be, and pairs
with `reusable-fly-deploy.yml` for connectors that also run a Fly backend (a
Worker cannot execute a binary, so `gogcli-mcp` runs the `gog` CLI on Fly).

Wire the automatic path into `release-please.yml` gated on
`release_created == 'true'`; copy `templates/deploy-connector.yml` for the
on-demand `workflow_dispatch` path. Both jobs pass their deploy token
explicitly (never `secrets: inherit`, which would hand a deploy workflow every
secret the repo holds, `RELEASE_PAT` included) and scope themselves to
`contents: read`. Both warn-and-pass when their token is absent, so a missing
secret never reports an otherwise-good release as broken. When a repo deploys both halves,
deploy Fly first and make the Worker job `needs:` it.

These exist because hand-deployed connectors drift: one had drifted far enough
to keep serving a tool schema its repo had already replaced.

`reusable-dependabot-lockfix.yml` regenerates derived lockfiles on dependabot
PRs and pushes them back with the release PAT (so CI retriggers), for bumps
dependabot can't fully materialize itself: npm repos whose root
package-lock.json embeds a `file:` package the security updater bumps in
isolation, and Gradle/KMP repos whose `kotlin-js-store/yarn.lock` only a
gradle run can refresh. Call from a stub on `pull_request_target`
(types: [opened, synchronize]) passing the repo's release PAT; runs are
double-guarded to PRs both authored and triggered by dependabot[bot], and the
PR head is checked out without credentials so the lockfix command never sees
the PAT. The stub must grant `contents: read` — a `permissions: {}` caller
startup-fails, since the called job requests `contents: read` for checkout.
Onboard a repo by setting `lockfix: npm|gradle` in `fleet.json` and running
`scripts/rollout.sh`; off-board by clearing `lockfix` there and deleting the
rendered stub, in that order — the file alone comes back on the next rollout.
Live consumer: curtaincall (gradle). untappd-mcp was the npm one until its
`file:`-linked package moved to its own repo and the derived lockfile stopped
existing (untappd-mcp#105, #83).

Rollout tooling: `fleet.json` (per-repo parameters), `scripts/rollout.sh`
(stub-conversion PRs; `--check` reports drift without opening one, `--only
<stub>` narrows any mode to a single workflow file — prefer it for
single-template rollouts, since full regeneration reverts hand-edits, #76),
`scripts/update-ruleset.sh` (required-check rename). `fleet-drift.yml` runs
`--check` across the whole fleet daily and maintains one marker-tagged drift
issue, so a hand-edited stub or unrolled template change surfaces the day it
happens instead of during the next sweep.
Design: `docs/superpowers/specs/2026-06-12-fleet-reusable-workflows-design.md`.

`docs/fleet-conventions.md` is the canonical home for the technical conventions
the MCP repos share — publishing constraints, bundling and `.mcpb` rules, stdio,
versioning guards, write-verification, transport archetypes, testing traps. Link
to it from a repo's `CLAUDE.md` instead of copying a section into it.

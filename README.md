# workflows

Reusable GitHub Actions workflows and composite actions for the fleet
(33 chrischall repos + 6 nullnet-app repos). Consumers reference `@main`.

| Component | Kind | Consumers |
|---|---|---|
| `.github/workflows/reusable-pr-auto-review.yml` | reusable workflow | all |
| `.github/workflows/reusable-auto-merge.yml` | reusable workflow | all |
| `.github/workflows/reusable-mcp-ci.yml` | reusable workflow | node repos |
| `.github/workflows/reusable-cloudflare-deploy.yml` | reusable workflow | web repos (OpenNext → Cloudflare Workers) |
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
required `ci / ci` job fails red until armed) or `status` (the job stays green
and a yellow `ci-gated: pending` commit status blocks instead — red then only
ever means a real failure). Status mode needs the stub to grant
`statuses: write` and the ruleset to require the `ci-gated` context
(`scripts/update-ruleset.sh <repo> ci-gated --execute`); flip both together.
Status mode also suppresses the duplicate CI run a non-arming label would
trigger on an already-armed PR (#12) — unsafe to suppress in fail mode, where
a green skip would overwrite a legitimately red check on the same SHA.
Any review that surfaced findings — a `warn`/`fail` verdict, or a `pass`
whose structured output still lists nits — also opens or updates a per-PR
`auto-review-followup` issue holding every finding (linked from the verdict
comment): `pass`/`warn` still auto-merge — the issue carries the nits
forward — while `fail` keeps a human in the loop. Release-please PRs follow the same gate, except the
review is triggered by adding `release-ready` (not on open): `release-ready`
starts the review, the review's `pass`/`warn` adds `ready-to-merge`, and only
then does deferred CI run — so CI never runs ahead of a successful review.

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
`scripts/rollout.sh`. Live consumers: untappd-mcp (npm) and curtaincall
(gradle).

Rollout tooling: `fleet.json` (per-repo parameters), `scripts/rollout.sh`
(stub-conversion PRs), `scripts/update-ruleset.sh` (required-check rename).
Design: `docs/superpowers/specs/2026-06-12-fleet-reusable-workflows-design.md`.

`docs/fleet-conventions.md` is the canonical home for the technical conventions
the MCP repos share — publishing constraints, bundling and `.mcpb` rules, stdio,
versioning guards, write-verification, transport archetypes, testing traps. Link
to it from a repo's `CLAUDE.md` instead of copying a section into it.

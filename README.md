# workflows

Reusable GitHub Actions workflows and composite actions for the fleet
(33 chrischall repos + 6 nullnet-app repos). Consumers reference `@main`.

| Component | Kind | Consumers |
|---|---|---|
| `.github/workflows/reusable-pr-auto-review.yml` | reusable workflow | all |
| `.github/workflows/reusable-auto-merge.yml` | reusable workflow | all |
| `.github/workflows/reusable-mcp-ci.yml` | reusable workflow | node repos |
| `.github/actions/arm-gate` | composite action | bespoke-CI repos (gradle, swift) |
| `templates/ci-gradle.yml` | starter template | Gradle/KMP repos |
| `.github/actions/mcp-publish` | composite action | MCP publishers |
| `.github/actions/install-mcp-publisher` | composite action | via mcp-publish |

The pipeline contract: non-release PR → auto-review emits a mandatory
`pass|warn|fail` verdict → `pass` or `warn` adds `ready-to-merge` → label arms
native auto-merge and fires deferred CI (the required check) → merge on green.
A `warn`/`fail` verdict also opens or updates a per-PR `auto-review-followup`
issue holding every finding (linked from the verdict comment): `warn` (nits
only) still auto-merges — the issue carries the nits forward — while `fail`
keeps a human in the loop. Release-please PRs follow the same gate, except the
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

Rollout tooling: `fleet.json` (per-repo parameters), `scripts/rollout.sh`
(stub-conversion PRs), `scripts/update-ruleset.sh` (required-check rename).
Design: `docs/superpowers/specs/2026-06-12-fleet-reusable-workflows-design.md`.

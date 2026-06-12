# Fleet reusable workflows — design

Date: 2026-06-12
Status: approved-pending-review

## Problem

39 repos (33 chrischall + 6 nullnet-app) run copies of the same PR pipeline:
auto-review with a Claude verdict → `ready-to-merge` label on `pass` →
label-armed native auto-merge → label-deferred CI as the required check →
merge on green. A fleet audit (2026-06-12) found the copies have drifted:

- ~28 repos lack the per-label concurrency fix (a `labeled` event can cancel
  an in-flight review, leaving a PR with no verdict and no label).
- fetchproxy and realty-mcp arm auto-merge on `warn`, everyone else on `pass`.
- 5 nullnet-app repos set `track_progress: true` unconditionally, which
  hard-errors review re-runs on `labeled` events.
- nullnet-app repos (Free plan at audit time) had no required checks, so
  `gh pr merge --auto` merged before CI finished (curtaincall #127).
- aikidsbook-backend's auto-merge arm is broken (stale `RELEASE_PAT`).
- Only curtaincall (PR #128) forces a visible verdict and fails loud when the
  reviewer emits none.
- Every MCP repo's `release-please.yml` is the same file with the repo name
  string-substituted, with drifted action version pins.

## Decisions (settled with the owner)

1. **Home**: a new dedicated **public** repo `chrischall/workflows`. Not
   mcp-utils: mcp-utils is a versioned npm package (workflow maintenance would
   churn its changelog) and the consumers are no longer only MCP repos.
2. **Mechanism**: reusable workflows (`workflow_call`), not composite actions
   — the job-level `if:` guards are exactly what drifted, and they consolidate
   only at the job level.
3. **Scope**: all 33 chrischall non-fork repos + all 6 nullnet-app repos.
   Forks keep upstream workflows.
4. **Refs**: consumers reference `@main`. One merge updates the fleet;
   rollback is one revert.
5. **Arm policy**: `pass` only, everywhere. fetchproxy/realty-mcp lose
   warn-arming.
6. **nullnet-app** is now on the Team plan: native rulesets/required checks
   replace the StoryMint/PassMint poll-merge workaround, which is retired.
7. **`install-mcp-publisher` migrates** from mcp-utils to this repo. All its
   references live in the `release-please.yml` files this design replaces, so
   migration is absorbed by the rollout. mcp-utils keeps a deprecation note
   until the fleet is converted, then its copy is removed.

## Components

All reusable workflows live in `chrischall/workflows/.github/workflows/`.
Composite actions live in `chrischall/workflows/.github/actions/`.

### 1. `reusable-pr-auto-review.yml`

The canonical review job, with every audit fix baked in:

- Triggers via the caller's `pull_request` stub (opened, reopened,
  ready_for_review, synchronize, labeled).
- Guards (job-level `if:` inside the reusable workflow — caller context is
  the caller's event): non-draft, human-authored, same-repo head, skip
  release-please PRs unless `release-ready`, skip PRs already labeled
  `ready-to-merge`, `labeled` events only for `review-with-opus` /
  `release-ready`.
- Copilot reviewer request (best-effort, 422 swallowed).
- Model-by-size ladder (≤50 lines Haiku, ≤500 Sonnet, else Opus;
  `review-with-opus` forces Opus). Never a `[1m]` variant.
- `track_progress: ${{ github.event.action != 'labeled' }}` (the action
  hard-errors on labeled events otherwise).
- Schema-bound verdict `pass|warn|fail` via `--json-schema`.
- **Verdict step (curtaincall #128, as enhanced)**: posts/updates one
  marker-tagged PR comment with the verdict, recovers from the review comment
  when structured output is empty, exports `verdict` as a step output before
  any fallible command, and fails the job when no verdict exists. The arm
  step consumes the exported output — single source of truth.
- Arm step: on `verdict == pass`, add `ready-to-merge` via the caller's PAT.

Inputs: `conventions_hint` (string, optional) — repo-specific text appended
to the review prompt (curtaincall's TDD/Envers rules, app-store-connect's
version-sync rules, etc.).
Secrets: `claude_code_oauth_token` (required), `release_pat` (required —
callers map `RELEASE_PAT` or `NULLNET_RELEASE_PAT`).

### 2. `reusable-auto-merge.yml`

Both arm jobs from the canonical file:

- `arm-dependabot`: non-draft dependabot PRs, lifecycle events only.
- `arm-on-ready-label`: same-repo PRs on the `ready-to-merge` labeled event.
- Both: `gh pr merge --auto --squash` with the instant-merge-race fallback.
- Caller stub uses `pull_request_target` (dependabot token restriction);
  the reusable workflow never checks out PR code.

Inputs: none (squash everywhere in scope).
Secrets: `release_pat` (required).

### 3. `reusable-mcp-ci.yml`

The standard node CI job for the ~25 node repos:

- The deferred-CI gate `if:` (runs only when `ready-to-merge` /
  `release-ready` is present for human PRs; unconditionally for bot PRs;
  falls through for `workflow_call`-from-push).
- checkout → setup-node (npm cache) → `npm ci` → build → test.

Inputs: `node-version` (default `26`), `build-command` (default
`npm run build`), `test-command` (default `npm test`).

**Check-name consequence**: a reusable-workflow job reports as
`<caller job> / <called job>` (expected `ci / ci`). Each repo's required-check
ruleset is updated at conversion time by a script in this repo. The exact
context string is verified on the canary before the fleet rollout.

Outliers keep custom `ci.yml` (apple-swift-mcp: macOS/Xcode; outlook-to-pdf:
Python/uv; fetchproxy & realty-mcp keep their monorepo builds unless the
`build-command` input suffices).

### 4. `reusable-mcp-release.yml`

The MCP release pipeline, parameterized by `github.event.repository.name`
instead of string-substitution:

- release-please (PR + tag) → on release: npm publish with provenance →
  package `.skill` and `.mcpb` → clawhub publish → attach artifacts to the
  GitHub release → `install-mcp-publisher` + registry publish.

Inputs: boolean toggles `publish_npm`, `publish_skill`, `publish_mcpb`,
`publish_clawhub`, `publish_registry` (all default true); `package_name`
override (defaults to repo name).
Secrets: `release_pat`, `npm_token`, `clawhub_token` (optional per toggles).

Non-MCP release flows (PassMint/StoryMint tag-and-bump, encore-ios/curtaincall
deploy-testflight, nullnet deploy.yml, gogcli) are out of scope — they keep
their own release workflows but still consume workflows 1–2.

### 5. `install-mcp-publisher` composite action

Moved verbatim from mcp-utils. Referenced from `reusable-mcp-release.yml` by
full ref `chrischall/workflows/.github/actions/install-mcp-publisher@main`
(relative `./` refs resolve against the caller's checkout, so full refs are
mandatory inside reusable workflows).

### Per-repo stubs

The only workflow content remaining in each consumer:

- `pr-auto-review.yml`: `on:` triggers, the per-label concurrency group
  (workflow-level concurrency cannot live in a called workflow), permissions
  (`contents: read`, `pull-requests: write`, `issues: write`,
  `id-token: write`), `uses:` + `with:` + `secrets:`.
- `auto-merge.yml`: `pull_request_target` triggers, concurrency, permissions
  (`contents: write`, `pull-requests: write`), `uses:` + `secrets:`.
- `ci.yml` (node repos): triggers incl. `labeled`, `uses:` + `with:`.
- `release-please.yml` (MCP repos): `push: main` trigger, `uses:` + toggles +
  `secrets:`.

Stub templates live in `templates/` in this repo; a `scripts/rollout.sh`
generates stubs and updates rulesets per repo.

## Rollout

1. Bootstrap `chrischall/workflows` (public): reusable workflows, the
   migrated action, templates, rollout script. Dogfoods its own pipeline via
   local `uses:` refs, with a ruleset requiring its CI check.
2. **Canary: zola-mcp.** Verifies on a real PR: claude-code-action OIDC works
   when the workflow is called cross-repo (the one open risk — fallback is
   documented if the App rejects it), the verdict comment + fail-loud path,
   pass→label→CI→merge end-to-end, the exact `ci / ci` check context, and one
   full release.
3. **chrischall wave** (32 remaining repos): script opens a stub-conversion
   PR per repo + updates the ruleset. The fleet's own pipeline reviews and
   merges the wave.
4. **nullnet-app wave**: same conversion, plus — create required-check
   rulesets (Team plan) on every repo that has CI, retire StoryMint/PassMint
   poll-merge, switch aikidsbook-backend and nullnet to `NULLNET_RELEASE_PAT`,
   give nullnet a real `ci.yml`. aikidsbook gets the review + auto-merge
   stubs only; it gets a required-check ruleset when it first gains CI
   (a label-armed merge there waits on nothing, same as today — accepted).
5. Cleanup: deprecation note then removal of mcp-utils'
   `install-mcp-publisher`; update the mcp-fleet-builder skill docs to point
   at `chrischall/workflows`.

## Error handling

- Reviewer emits no verdict → verdict step posts the "no verdict" comment and
  fails the job; arm step sees an empty output and never arms. Fail-safe.
- Arm fails because the PR already merged → treated as success (race).
- Bad change to a reusable workflow → breaks fleet uniformly; revert on
  `chrischall/workflows` main restores everyone (the @main trade-off).
- A repo missing a mapped secret fails at the `secrets:` interface visibly,
  not silently.

## Testing

- `actionlint` on every workflow in this repo (its own CI).
- Canary checklist (rollout step 2) is the integration test.
- Rollout script is idempotent and dry-runs by default.

## Out of scope

- Forks (12) — upstream workflows.
- `claude.yml` (manual @claude fallback) — trivial, stays per-repo.
- release-please config/manifest JSON files — per-repo by design.
- Custom deploy workflows (TestFlight, Cloudflare, Fly).

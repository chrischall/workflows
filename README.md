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
| `templates/dependabot-{npm,gradle,actions}.yml` | repo-config template | renders `.github/dependabot.yml`; ecosystem picked by `dependabot` in `fleet.json` |
| `templates/release-please-config.json` | repo-config template | renders `release-please-config.json`; repos with `release_config: mcp` |
| `templates/release-notes.yml` | repo-config template | renders `.github/release.yml`; all repos unless `release_notes: none` |
| `.github/actions/mcp-publish` | composite action | MCP publishers |
| `.github/actions/install-mcp-publisher` | composite action | via mcp-publish |

The pipeline contract: non-release PR → auto-review emits a mandatory
`pass|warn|fail` verdict → `pass` or `warn` adds `ready-to-merge` → label arms
native auto-merge and fires deferred CI (the required check) → merge on green.

One commit gets **one verdict at a time**. Opening a PR with `--label` fires
`opened` and `labeled` back-to-back into separate concurrency groups (shared
ones let the second cancel the first, #182), so two LLM reviews of the same
diff used to race — and they can disagree. The younger run now stands down
while an older run of the same workflow is reviewing the same head SHA; run ids
give both runs the same total order, so exactly one proceeds and neither waits
on the other. A re-review triggered by a label *after* the first verdict lands
is not a duplicate and still runs, as does `/auto-review` at any time.

A `fail` does not merely decline to arm — it **de-arms**, removing
`ready-to-merge` *and* calling `gh pr merge --disable-auto`. Both are needed:
the label is only the trigger, and once auto-merge is enabled GitHub merges on
green whatever happens to the label afterwards. This is what stops a PR another
run armed a minute earlier from merging on a red review
(`chrischall/fetchproxy#274`). The same two-part de-arm applies wherever the
pipeline withdraws an arming, including `rereview_on_push`'s de-arm on a new
commit.

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
It further refuses to revert a *terminal* `ci-gated` (success/failure/error) on
a SHA back to `pending`: the status is last-writer-wins and the arming decision
reads labels from the event payload, a snapshot taken when GitHub queued the
delivery, so a late or duplicate delivery would otherwise re-decide a commit
whose CI already ran. `honeybook-mcp#160` wedged that way — a green status
reverted to pending four seconds later by a duplicate `synchronize` carrying
pre-arming labels, leaving a PR armed for auto-merge and blocked on a required
status with no further event coming to clear it (#188).
Fork PRs cannot post their OWN `ci-gated`: their `GITHUB_TOKEN` is capped
read-only whatever the stub requests, so the POST 403s. The `ci` job therefore
posts nothing for them. Bespoke-CI repos get the same rule from `arm-gate`,
which publishes `is_fork` for their reporter step to guard on
(`templates/ci-gradle.yml` shows the shape).

An UN-ARMED fork does not build at all. It used to — on the reasoning that the
unreported `ci-gated` context blocked the merge anyway — but `ci-fork-status.yml`
now reports that context, and running unreviewed fork code before a maintainer
has looked is the thing worth not doing. A fork waits for `ready-to-merge`
exactly as a same-repo PR does. The decision lives in TWO places that must stay
in step: `.github/actions/arm-gate/action.yml` and the inlined copy in
`.github/workflows/reusable-mcp-ci.yml`; `scripts/gate.test.sh` exercises both.

**Reviewing a fork PR.** Auto-review cannot run on a fork through
`pull_request`: GitHub withholds secrets from fork runs, so the reviewer has no
credential, and `pull_request_target` — the usual answer — is rejected by
Anthropic's OIDC backend. A maintainer therefore asks for it explicitly:

```
/auto-review
```

as a PR comment. `issue_comment` fires in the BASE repo with secrets intact, and
the `context` job checks `author_association` before anything runs — so a fork's
own author cannot trigger a review of their own PR. That command IS the gate:
unlike the same-repo path, no event starts a fork review on its own.

A fork verdict ARMS on `pass`/`warn`, exactly as a same-repo one does — the
command is the human gate, and a fork reaches the review no other way. Arming
is what starts a fork's CI: the arm-gate stops deferring, the real build runs,
and `ci-fork-status` posts the true `ci-gated`. It does not start a merge —
auto-merge excludes forks by head repo, so a fork PR still waits for a human to
press merge.

**Merging a fork PR.** `templates/ci-fork-status.yml` closes this: it triggers
on `workflow_run`, which fires in the BASE repo where the token really does
have `statuses: write`, and mirrors the completed run's conclusion into
`ci-gated`. So a fork PR now goes green on its own and no maintainer has to
hand-post a status.

That was a deliberate weakening of a fail-safe — previously the fork path could
only ever leave the gate closed. Two human gates remain and it rests on them:
GitHub holds fork runs at `action_required` until a maintainer approves them
(so CI never runs on unreviewed external code, and the reporter only mirrors an
approved run), and a fork is armed only when a maintainer types `/auto-review`
on it — never by an event, and only from an author_association the repo trusts.
Auto-merge excludes forks regardless, so what arming a fork buys is CI, not a
merge.

A repo that has not had the stub rolled out yet still has the old behaviour —
nothing posts `ci-gated` and the merge stays blocked. There, post it yourself
after reading the run:

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

Its publish steps are **idempotent and independently gated**, because the
recovery for a half-finished release is re-running the workflow. npm skips a
version it already has; the MCP Registry treats `cannot publish duplicate
version` as published; and ClawHub publishing and release-artifact attachment
run under `!cancelled()` so an upstream publish failure cannot skip them. One
step in the middle also *waits*: npm indexes a publish asynchronously, so a
version can be accepted and still 404 for the MCP Registry seconds later, and
the registry refuses to register what it cannot see. `scripts/npm-index.test.sh`
and `scripts/mcp-registry-publish.test.sh` pin all of it. The failure these
prevent is quiet and expensive — gogcli-mcp v2.28.0 published nine packages to
npm correctly, then shipped a release with **zero** artifacts because one
package indexed slowly and the resulting red step skipped everything after it.

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
<stub>` narrows any mode to a single stub, named by basename minus
extension so it reaches files outside `.github/workflows/` too — prefer it for
single-template rollouts, since full regeneration reverts hand-edits, #76;
`--reason <text>` adds a "Why this change" section to the PR body — use it
whenever the motive lives here rather than in the consumer, or the reviewer
there sees a diff and no reason for it),
`scripts/update-ruleset.sh` (required-check rename). `fleet-drift.yml` runs
`--check` across the whole fleet daily and maintains one marker-tagged drift
issue, so a hand-edited stub or unrolled template change surfaces the day it
happens instead of during the next sweep.

### Labels

`labels.json` is the fleet's canonical label set and `scripts/ensure-labels.sh
<repo>` applies it (`--check` reports drift, exit 1). `rollout.sh` calls it, so
every rollout keeps a repo's labels true.

Two families, both load-bearing and both failing **quietly**:

| family | what breaks when one is missing |
| --- | --- |
| pipeline (`ready-to-merge`, `release-ready`, `auto-review-followup`, …) | the workflow that wanted it does not error — it just does not find it |
| release-notes (`enhancement`, `bug`, `refactor`, `ci`, …) | `.github/release.yml` categorises by label, so the category is valid, real, and matches nothing; those PRs land in "Other Changes" |

The audit that prompted this found **0 of 81 repos fully correct**: 169 missing
labels and 168 wrong colours. `refactor` was absent from 36 repos, `ci` from 8;
`test` existed in 11 different colours and `ci` in 12. **Every colour is unique across both families**, and hue carries meaning:
amber is `release-ready` alone, purples are review, reds darken from `bug` to
`security`, blues are informational. That is not cosmetic — `fbca04` was worn
by `release-ready`, `auto-review-followup` and `ci` at once, so on a PR list an
automation state and a changelog category were the same swatch, and `test` was
a pale blue indistinguishable from `refactor`. Colours are **not** chosen to
minimise churn: `ensure-labels.sh` rewrites every label on every repo
regardless, so plurality buys nothing operationally and a legible palette is
worth more. The exceptions are `enhancement`/`bug`/`documentation` (GitHub
defaults) and `dependencies`/`github_actions` (Dependabot defaults), kept
because fighting those conventions costs more than it buys. The `--check`
comparison is case-insensitive, because the same label exists as both `FBCA04`
and `fbca04` and rewriting 71 repos to change nothing is not drift.

`feature`/`fix` were dropped from `release.yml`: they were aliases for
`enhancement`/`bug` and existed in 2 of 81 repos, so the categories they fed
matched almost nothing.

`scripts/labels.test.sh` pins the contract nothing else checks — **every label
`release.yml` categorises by must exist in `labels.json`**. If they drift
apart the only symptom is a changelog section that stays empty forever. It
also asserts no workflow defines a colour for a label `labels.json` already
owns, since `followup-orphan-sweep.yml` creates `orphaned-followup` on demand
and two definitions would mean the colour depends on who reached the repo
first.

### Repo-config templates (outside `.github/workflows/`)

Three of the fleet's config files are not workflows, and until they were
templated nothing rendered them — so they drifted in the dark, with no
`--check` and no daily sweep watching:

| file | before | shape of the drift |
| --- | --- | --- |
| `.github/dependabot.yml` | 72 repos, 17 variants | mostly a missing trailing newline, `vitest` vs `"vitest"`, and **three repos carrying three differently-worded comments about the same bug** |
| `release-please-config.json` | 79 repos, **78 unique copies** | JSON whitespace — but 8 repos had drifted to **no `changelog-sections` at all**, i.e. no release policy |
| `.github/release.yml` | 36 repos | simply **absent from 45** |

The stage rollout.sh builds is therefore repo-shaped rather than a flat bag of
workflow files: every mode walks it with `find`, and `--check` derives the
contents-API path from the same repo-relative path. A file staged flat would
have landed in `.github/workflows/`, where neither dependabot nor
release-please would ever look — a rollout that reports success and changes
nothing.

`fleet.json` keys: `dependabot` (`npm`|`gradle`|`actions`|`none`),
`dependabot_ignore` (a fragment name, see below), `release_config`
(`mcp`|`none`), `release_notes` (`on`|`none`), `package_name`, `release_type`,
`version_files` (comma-separated), and the optional release-please keys
`bump_minor_pre_major`, `initial_version`, `include_v_in_tag`,
`include_component_in_tag`.

**An empty optional release-please key means the key is ABSENT from the
rendered config, not defaulted.** That distinction is load-bearing:
`bump-minor-pre-major` is set in 21 repos and every one of them is still
pre-1.0, so dropping it would make their next breaking change bump 0.x
straight to 1.0.0 — a major nobody chose, fleet-wide. Three repos leave
`include-*-in-tag` unset and two of those tag as `<name>-v<version>`; writing
an explicit value where there was none could change the tag scheme, and
release-please finds the previous release *by tag*.

**A repo-specific `ignore:` block is a fragment, not a reason to opt out.**
`templates/fragments/dependabot-ignore-<name>.yml`, selected by
`dependabot_ignore`. `gogcli-mcp` (an `agents` ceiling mirroring
`mcp-connector`'s published peer range) and `curtaincall` (a permanent
javax-namespace JAXB hold) were both opted out of the dependabot template
purely to protect one block each — which also cost them the vitest pin and
every future fix. The splice marker is a *comment* line: a bare `__X__` at
column 0 renders to a top-level scalar and breaks the template parse, the same
shape as the placeholder that took out two repos' release workflows. An
unknown fragment name is a hard error, because the quiet failure is a config
that looks right and has simply lost the hold.

**`none` renders NO FILE, not an empty one.** That is the escape hatch for a
config that is deliberately bespoke, and it exists so a regeneration cannot
quietly revert a hand-written reason (#76). Two repos use `dependabot: none`
today — `StoryMint` (per-target Swift package directories) and `PassMint` (a
worker-only npm directory); `curtaincall` and `gogcli-mcp` were moved off it
onto `dependabot_ignore` fragments. Twenty-one repos set
`release_config: none` — their `extra-files` stamp versions into monorepo
paths the shared template does not have — and `gogcli-mcp` sets
`release_notes: none` for a `⚠️ Required gogcli version` category keyed on a
`gogcli-bump` label that means nothing in the other 80 repos.

`package_name` is **not** derivable from the repo name: **16 of the 60**
templated repos publish under a scoped `@chrischall/<name>`. (The repos whose
published name differs entirely — `gogcli-mcp-monorepo`,
`opencode-m365-copilot` — are bespoke monorepos that set
`release_config: none`, so they never reach this template at all.) An unset one
used to render `"package-name": ""`, which release-please accepts and then tags
as an empty component, so rollout.sh now fails loudly instead.

`--only` names the **destination basename**, not the template filename:
`.github/release.yml` is `--only release`, even though it renders from
`templates/release-notes.yml`. `rollout.test.sh` asserts that every
`--only <name>` a template recommends in its own header actually resolves — a
wrong instruction there is cheap now and expensive once it has rendered into
81 repos.

**Registering a repo does not back-fill the templates it missed.** A
`fleet.json` entry enrols a repo in every rollout from that day FORWARD; every
template that landed before it stays absent, because nothing replays past
rollouts. So a newly registered repo needs a `scripts/rollout.sh <repo>
--execute` sweep as well as its entry — the entry alone is half the job, and
the half that is missing is silent.

`myatriumhealth-mcp` is the worked example (#221). It was registered on
2026-09-03; `ci-fork-status.yml` had landed on 2026-08-30 and been rolled out
four days earlier, so the repo never received it. The registration PR's own
message — "without this entry the repo silently misses every fleet-wide
rollout" — was true and still left the gap, because it describes the future
tense only. The cost was concrete rather than cosmetic: `ci-gated` is a
REQUIRED status check there, and a fork PR cannot post it (GitHub caps
`GITHUB_TOKEN` to read-only for `pull_request` runs from a fork), so every
external contribution to that repo was unmergeable without a maintainer
hand-posting a status. Nobody noticed because nobody had opened one.

The daily drift sweep is what caught it, one day later, which is the sweep
working as designed — but it is a net, not a step. Roll the stubs out when you
register.
Design: `docs/superpowers/specs/2026-06-12-fleet-reusable-workflows-design.md`.

`docs/fleet-conventions.md` is the canonical home for the technical conventions
the MCP repos share — publishing constraints, bundling and `.mcpb` rules, stdio,
versioning guards, write-verification, transport archetypes, testing traps. Link
to it from a repo's `CLAUDE.md` instead of copying a section into it.

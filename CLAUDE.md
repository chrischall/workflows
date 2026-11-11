# workflows

Shared CI/CD for the fleet. `README.md` documents the pipeline contract
(verdict ladder, gate modes, `arm-gate`, why `mcp-publish` is a composite
action) — read it first and don't restate it here.

This file covers what the README doesn't: the blast radius, and how to change
things without breaking every repo in the fleet at once.

## Every consumer pins `@main`. There is no staged rollout.

Every repo in `fleet.json` references `chrischall/workflows/...@main`. Nothing
pins a tag or SHA. For how many that is, run `jq '.repos|length' fleet.json` —
the number is deliberately not written here, because it was written here three
times and was wrong by the third (78 while the file listed 80).

So a merge to `main` here is a fleet-wide deploy that takes effect on the next
workflow run in every one of them, with no canary and no rollback window. Treat any
change to `.github/workflows/reusable-*.yml` or `.github/actions/*` as a
production change to every repo simultaneously.

Consequences worth internalizing:

- **A syntax error in a composite action breaks CI everywhere at once**, and
  the failure surfaces in the consumer repo, where nothing points back here.
- **Adding a required input to an existing action is a breaking change.** Every
  consumer stub must be updated first, or their next run fails. Add new inputs
  with a default; make them required only after the fleet has been migrated.
- **Removing or renaming an action path breaks consumers immediately.** Keep
  the old path working, or roll out the rename before deleting.
- The nullnet-app repos use `NULLNET_RELEASE_PAT`, not `RELEASE_PAT` — check
  `fleet.json`'s per-repo `pat_secret` before assuming a secret name exists.
- **A comment-only edit to a template costs a full fleet rollout.** `--check`
  compares rendered bytes, so there is no such thing as a cosmetic template
  change: edit a comment and every repo rendering that stub drifts on the next
  sweep. Either roll it out or don't make it — "fix the wording later" is not
  available. A one-sentence correction to `ci-fork-status.yml`'s security note
  cost 61 PRs on 2026-08-31, and getting that sentence wrong cost 61 more.
  Prose here is under the same get-it-right-before-opening rule as code.

When a change is genuinely risky, land it behind a new opt-in input first, flip
one repo, confirm, then flip the rest via `scripts/rollout.sh`.

## A PR that edits the review's own workflow files gets no verdict on `pull_request`

`claude-code-action` exchanges an OIDC token for an app token, and that
exchange refuses when the workflow it runs in differs from the default branch.
It checks two things here:

- **The caller stub, `.github/workflows/pr-auto-review.yml`** — the file
  `GITHUB_WORKFLOW_REF` names. #153, #180 and #183 edited it and got no
  verdict:

      Workflow validation failed. The workflow file must exist and have
      identical content to the version on the repository's default branch.

- **Any reusable workflow in this repository that the caller reaches by local
  path.** The stub calls `./.github/workflows/reusable-pr-auto-review.yml`, so
  a PR editing that file is refused too:

      Workflow validation failed. A reusable workflow in this repository that
      the workflow calls (uses: ./.github/workflows/… or
      $/.github/workflows/…) must exist on the repository's default branch with
      identical content.

  This is newer than the stub check. #95 to #213 all edited the reusable file
  and got real verdicts; by 2026-11-11 #385 and #387 got none for it.

Editing `ci.yml`, or any workflow the review does not call, changes nothing.

On a refusal the action skips, emits no structured output, and `Post verdict
to PR` reports **"no verdict — treat this PR as un-reviewed"** rather than
inventing one, so the PR is not armed. The skip comes after the job's setup
steps, so those still run the PR's version: #387's own `pull_request` run
exercised its new sandbox-install step on a real runner before the action
skipped.

**To review such a PR, comment `/auto-review`.** That fires `issue_comment`,
which GitHub always runs from the default branch, so validation passes. The
review then judges the PR head's diff and arms on pass or warn like any other
review; #385, #386 and #387 were reviewed this way. The steps run main's
version, though, so a change to the review job itself is first exercised for
real after it merges. Reopening, or re-running the failed `pull_request` run,
does not help: both repeat the same validation.

**The stub half is fleet-wide.** Every consumer's stub is its own caller, so a
`rollout.sh --only pr-auto-review` PR gets no verdict in the target repo too
(chrischall/fetchproxy#250). The same holds for `claude.yml`, which calls
`claude-code-action` directly, but only for that workflow: a PR touching
`claude.yml` still gets a normal review, because the reviewing stub is
unchanged. The reusable-file half is local. Consumers call
`chrischall/workflows/...@main`, a workflow in another repository, so edits
here never trip the check for them.

So: expect no verdict on these PRs, do not treat the skip as a finding to chase,
and never add the arming label to force one through. Comment `/auto-review`
instead.

## fleet.json is the source of truth

`scripts/rollout.sh <owner/repo>` generates a repo's stubs from `fleet.json`
(`defaults` merged with the per-repo entry) and opens a PR. It is **dry-run by
default**; pass `--execute` to act. It deliberately does not merge and does not
add the arming label — the pipeline does that.

`scripts/update-ruleset.sh <repo> --execute` converges a repo's merge
protection on the fleet standard (the required `ci-gated` check, deletion and
force-push blocked, pull request required, auto-merge on, squash-only, delete
branch on merge) and `--audit` (one repo, or `--all` for fleet.json) reports
the gaps read-only. Every gap fails silently: insync-mcp merged every PR before
its armed CI run finished, with CI red for its whole history, because its
ruleset required nothing but the status check. The two gate modes need the stub
and the ruleset changed **together** — see the README's gate-mode paragraph.
Flipping one without the other either blocks every PR or lets un-armed PRs
merge. `scripts/update-ruleset.test.sh` runs the real script against stub `gh`
fixtures; add a case there for any change to what is PUT, POSTed or reported.

A repo not in `fleet.json` is rejected by `rollout.sh` by design. Adding a repo
to the fleet means adding it here first.

**Pick the target set before a fleet-wide `--only` roll.** `--only <stub>` is
an error, not a no-op, on a repo whose stub set lacks that file — deliberately,
so `--only ci` on a custom-CI repo fails loudly instead of silently doing
nothing. A single-stub roll must therefore select the repos that actually
render it:

    jq -r '.defaults.ci as $d | .repos[] | select((.ci // $d)=="standard") | .repo' fleet.json

The key is `.ci`, not `.ci_mode`. `.ci_mode` reads `null` for every repo, and
papering that over with a literal fallback — `(.ci_mode // "standard")` —
reports the whole fleet as `standard`, which reads like a confirmation rather
than a bug. It is most of the fleet but not all of it; the query above is the
count, and it moves. The rest are `custom` or `none`, and never receive
`ci.yml` or `ci-fork-status.yml`.

**The drift issue is a daily snapshot, not live state.** The sweep rewrites it
once a day, so it can be badly stale by the time anyone reads it: half of #181
had already been fixed by a rollout that landed five hours after the sweep
wrote it. Re-run `--check` against the repos it names before acting on it. The
count in the title is the least reliable part, and the body is truncated at
60 000 chars, so it lists fewer repos than it claims — #181 counted 79 and
showed 45.

## Editing the composite actions

`mcp-publish` resolves the skills to package in this order: an explicit
`skill-path` input, else a root `SKILL.md`, else *every* `skills/*/SKILL.md`.
Several candidates is no longer an error — #56 made it publish each under its
own directory-name slug. So `skill-path` now only means "publish just this one
of several", and dropping a pin doesn't fail a release, it silently starts
shipping the repo's other skills under new slugs. `docs/fleet-conventions.md`
is the canonical statement of this; don't restate it elsewhere.

The composite actions have no tests. The only way to validate an action change
is to run it against a real consumer repo, so make changes small and verify in
the Actions UI of the repo you rolled out to.

`scripts/` is different — `scripts/rollout.test.sh` unit-tests `rollout.sh
--check` by stubbing `gh` and pointing the real script at a fixture fleet, and
CI runs it. Add a case there for any `--check` change: its failure mode is a
report that quietly says less than it should, which nothing downstream notices.

## Fleet-wide conventions

`docs/fleet-conventions.md` holds the technical conventions the MCP repos share
(publishing constraints, bundling, stdio, versioning, write-verification,
transport archetypes). That doc is the canonical home — when a convention would
otherwise get copy-pasted into another repo's CLAUDE.md, put it there and link
it instead.

Policy that applies to *all* my work (PR/merge/label rules, auto-review
follow-ups) lives in `~/.claude/CLAUDE.md` and must not be duplicated here.

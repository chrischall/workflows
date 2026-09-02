# workflows

Shared CI/CD for the fleet. `README.md` documents the pipeline contract
(verdict ladder, gate modes, `arm-gate`, why `mcp-publish` is a composite
action) — read it first and don't restate it here.

This file covers what the README doesn't: the blast radius, and how to change
things without breaking 78 repos.

## Every consumer pins `@main`. There is no staged rollout.

`fleet.json` lists **78 repos**, and every one references
`chrischall/workflows/...@main`. Nothing pins a tag or SHA. That count has gone
stale twice — read it with `jq '.repos|length' fleet.json` rather than trusting
the number written here.

So a merge to `main` here is a fleet-wide deploy that takes effect on the next
workflow run in all 78 repos, with no canary and no rollback window. Treat any
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

## A PR that edits the CALLER stub cannot be reviewed

Only `.github/workflows/pr-auto-review.yml` — the thin stub. Not
`reusable-pr-auto-review.yml`, which holds the entire review and reviews
normally: #95, #97, #98, #99, #102, #105, #126, #142, #176, #179, #184, #186,
#198, #209, #211 and #213 all edited it and all got a real verdict and armed.
Every PR that touched the stub — #153, #180, #183 — got none.

The mechanism is not self-reference. `claude-code-action` exchanges an OIDC
token for an app token, and that exchange refuses when the workflow file
invoking it differs from the version on the default branch:

    Workflow validation failed. The workflow file must exist and have identical
    content to the version on the repository's default branch.

The action then skips, emitting no structured output, and `Post verdict to PR`
reports **"no verdict — treat this PR as un-reviewed"** rather than inventing
one. The validated file is the one `GITHUB_WORKFLOW_REF` names — the top-level
CALLER — which is why editing the reusable workflow the stub calls, or `ci.yml`
in the same PR, changes nothing.

The consequence is that such a PR is never armed: `ready-to-merge` is not
added, auto-merge never engages, and it sits until a human merges it
deliberately. Reopening does not help — #153 failed the same way twice on the
same SHA before being merged by hand.

**This is fleet-wide, not local.** Every consumer's stub is the caller too, so
a `rollout.sh --only pr-auto-review` PR is un-reviewable in the target repo for
the same reason (chrischall/fetchproxy#250 got no verdict and waited 21 minutes
for a human label). The same holds for any stub that calls `claude-code-action`
directly — `claude.yml` — but only for the workflow being edited: a PR touching
`claude.yml` still gets a normal review, because the reviewing stub is
unchanged.

So: expect no verdict on caller-stub PRs, do not treat the skipped review as a
finding to chase, and do not add the arming label to force it through. Get the
change right before opening, and let a human merge it.

## fleet.json is the source of truth

`scripts/rollout.sh <owner/repo>` generates a repo's stubs from `fleet.json`
(`defaults` merged with the per-repo entry) and opens a PR. It is **dry-run by
default**; pass `--execute` to act. It deliberately does not merge and does not
add the arming label — the pipeline does that.

`scripts/update-ruleset.sh <repo> <context> --execute` sets the required check.
The two gate modes need the stub and the ruleset changed **together** — see the
README's gate-mode paragraph. Flipping one without the other either blocks
every PR or lets un-armed PRs merge.

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
than a bug. It is 61 of 79; the rest are `custom` or `none` and never receive
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

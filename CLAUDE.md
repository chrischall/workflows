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

When a change is genuinely risky, land it behind a new opt-in input first, flip
one repo, confirm, then flip the rest via `scripts/rollout.sh`.

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

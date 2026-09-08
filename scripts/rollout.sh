#!/usr/bin/env bash
# Convert one fleet repo to chrischall/workflows stubs via PR.
#
# Usage: scripts/rollout.sh <owner/repo> [--execute|--check|--render <dir>|--pr-body]
#                          [--only <stub>[,<stub>...]] [--reason <text>]
# Dry-run by default: prints generated stubs and planned actions.
#
# --reason <text> adds a "Why this change" section to the PR body. Reach for it
# whenever the REASON for a sync lives in this repo rather than the consumer's:
# the generated body otherwise says only "regenerated from fleet.json", and the
# auto-review sitting in the consumer repo has no way to see the template change
# that motivated it. tock-mcp#73 was failed twice on exactly that — the reviewer
# read the repo's own (stale) CLAUDE.md, found it contradicted, and correctly
# refused. A cross-repo policy change needs its evidence carried across.
#
# --pr-body prints the PR body --execute would use and exits. No network, no
# clone — it exists so the body is testable, since its failure mode is a PR that
# merely under-explains itself, which nothing downstream flags.
#
# --only <stub>[,<stub>...] narrows every mode to the named stubs (e.g. `--only
# claude`, `--only dependabot,release,release-please-config`): --check diffs
# just those files, --execute syncs just those files. Names are the
# DESTINATION basename minus extension, not the template filename.
# Issue #76's sweep only needed claude.yml; regenerating everything is what
# turned a one-file rollout into a fleet-wide revert of hand-edits. Reach for
# --only whenever the change you are rolling out touches one template.
#
# Does NOT merge the PR and does NOT add ready-to-merge — the pipeline does.
# Run scripts/update-ruleset.sh after the PR is open.
set -euo pipefail

REPO="${1:?usage: rollout.sh <owner/repo> [--execute|--check|--render <dir>|--pr-body] [--only <stub>[,<stub>...]] [--reason <text>]}"
shift
EXECUTE=""; ONLY=""; ONLY_PATH=""; DEST=""; REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --execute|--check|--pr-body) EXECUTE="$1" ;;
    --render) EXECUTE="--render"; DEST="${2:?usage: rollout.sh <owner/repo> --render <dir>}"; shift ;;
    # `%.*` not `%.yml`: stub extensions vary now (release-please-config.json),
    # so stripping only .yml made `--only release-please-config.json` an error
    # while `--only ci.yml` worked.
    # Accepts a COMMA-SEPARATED list. Three repo-config stubs landed at once
    # (dependabot, release, release-please-config) and syncing them one at a
    # time is three PRs per repo — 213 across the fleet instead of 75, each
    # with its own review, CI run and auto-merge. Combining them is not just
    # cheaper: a repo either matches fleet.json or it does not, and splitting
    # that across three PRs makes a half-synced repo a normal intermediate
    # state rather than an anomaly.
    --only)   ONLY="${2:?--only needs one or more stub names, e.g. ci or dependabot,release}"; shift ;;
              # normalised below, once the whole arg list is parsed
    --reason) REASON="${2:?--reason needs text}"; shift ;;
    *) echo "::error::unknown argument: $1"; exit 1 ;;
  esac
  shift
done
# Normalise --only into a sorted, deduplicated list of bare stub NAMES.
#
# `%.*` rather than `%.yml`: stub extensions vary now (release-please-config
# .json), so stripping only .yml made `--only release-please-config.json` an
# error while `--only ci.yml` worked.
#
# Dedupe matters because the list feeds the PR body and commit message:
# `--only dependabot,dependabot` is one file, and listing it twice tells a
# reviewer the sync touched something it did not.
ONLY_NAMES=""
if [ -n "$ONLY" ]; then
  ONLY_NAMES=$(printf '%s' "$ONLY" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\.[^.]*$//' \
    | grep -v '^$' | sort -u)
  [ -n "$ONLY_NAMES" ] || { echo "::error::--only was given no usable stub names"; exit 1; }
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$HERE/fleet.json"
# Overridable because the default is a FIXED name: re-running against a repo
# converted earlier hits a leftover branch from that merge and the push is
# rejected non-fast-forward. Deleting the old ref would work but is other
# people's history; a fresh name is free. Set ROLLOUT_BRANCH to re-run.
# A single-stub sync gets its own default name for the same reason: it must
# not collide with the conversion branch a repo already merged.
if [ -n "${ROLLOUT_BRANCH:-}" ]; then
  BRANCH="$ROLLOUT_BRANCH"
elif [ -n "$ONLY" ]; then
  # Derived from the stubs actually requested. It was hardcoded to
  # "repo-config" for any list, which is right for the three config stubs this
  # was built for and a lie for every other combination: `--only ci,claude`
  # opened a branch and title announcing a repo-config sync. A name built from
  # the list is longer and always true.
  BRANCH="ci/sync-$(printf '%s' "$ONLY_NAMES" | tr '\n' '-' | sed 's/-$//')"
else
  BRANCH="ci/reusable-workflows"
fi

cfg() { # cfg <key> -> value with defaults applied
  jq -r --arg repo "$REPO" --arg key "$1" '
    (.repos[] | select(.repo == $repo)) as $r
    | ($r[$key] // .defaults[$key] // "")' "$FLEET"
}

FOUND=$(jq -r --arg repo "$REPO" '[.repos[] | select(.repo == $repo)] | length' "$FLEET")
[ "$FOUND" = "1" ] || { echo "::error::$REPO not in fleet.json"; exit 1; }

PAT_SECRET=$(cfg pat_secret)
CI_MODE=$(cfg ci)
RELEASE_MODE=$(cfg release)
NODE_VERSION=$(cfg node_version)
BUILD_COMMAND=$(cfg build_command)
TEST_COMMAND=$(cfg test_command)
HINT=$(cfg conventions_hint)
LOCKFIX=$(cfg lockfix)
JAVA_VERSION=$(cfg java_version)
# Deploy automation: `connector` = has a hosted Worker; `fly_dir` = directory
# holding fly.toml for repos that also run a Fly backend (implies a Fly job).
CONNECTOR=$(cfg connector)
FLY_DIR=$(cfg fly_dir)
# Repo-config templates. `dependabot` picks the ecosystem variant (npm/gradle/
# actions); `release_config` and `release_notes` are on/`none` switches.
# package_name is NOT derivable from the repo name: 16 of the 60 templated
# repos publish under a scoped @chrischall/<name>. (The repos whose published
# name differs entirely — gogcli-mcp-monorepo, opencode-m365-copilot — are
# bespoke monorepos that set release_config: none, so they never reach this
# template.) Recorded per repo; a missing one is a hard error below.
DEPENDABOT=$(cfg dependabot)
# Name of a templates/fragments/dependabot-ignore-<name>.yml block to splice in.
DEPENDABOT_IGNORE=$(cfg dependabot_ignore)
RELEASE_CONFIG=$(cfg release_config)
RELEASE_NOTES=$(cfg release_notes)
PACKAGE_NAME=$(cfg package_name)
RELEASE_TYPE=$(cfg release_type)
VERSION_FILES=$(cfg version_files)
# Optional release-please keys. Each is recorded per repo and an EMPTY value
# means the key is absent from the rendered config, not defaulted — the
# distinction is load-bearing:
#
#   bump-minor-pre-major  21 repos set it and every one of them is still
#                         pre-1.0. Dropping it makes the next breaking change
#                         bump 0.x straight to 1.0.0 instead of the minor —
#                         the encore-ios #39 failure, fleet-wide.
#   initial-version       only affects a repo's first release, but dropping a
#                         recorded value is still an unasked-for change.
#   include-*-in-tag      three repos leave these unset, and two of them tag as
#                         <name>-v<version>. Writing an explicit value where
#                         there was none could change the tag scheme, and
#                         release-please finds the previous release BY TAG.
BUMP_MINOR_PRE_MAJOR=$(cfg bump_minor_pre_major)
INITIAL_VERSION=$(cfg initial_version)
INCLUDE_V_IN_TAG=$(cfg include_v_in_tag)
INCLUDE_COMPONENT_IN_TAG=$(cfg include_component_in_tag)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Escape a fleet.json value for use as a sed REPLACEMENT string. `&` means "the
# whole match" and `|` is our delimiter, so an unescaped value containing either
# is silently corrupted rather than erroring: a test_command of
# `npm run typecheck && npm test` rendered as
# `npm run typecheck __TEST_COMMAND____TEST_COMMAND__ npm test`,
# because each `&` re-inserted the placeholder it had just matched.
sed_escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

# Stage paths are REPO-RELATIVE (".github/workflows/ci.yml",
# ".github/dependabot.yml", "release-please-config.json"), so the stage is a
# picture of the consumer repo rather than a flat bag of workflow files. Every
# mode below walks it with `find`, and --check derives the contents API path
# from the same relative path. A flat stage put dependabot.yml and
# release-please-config.json into .github/workflows/, where nothing reads them.
render() { # render <template> <repo-relative dest>
  mkdir -p "$STAGE/$(dirname "$2")"
  local dest="$STAGE/$2"
  sed -e "s|__PAT_SECRET__|$(sed_escape "$PAT_SECRET")|g" \
      -e "s|__NODE_VERSION__|$(sed_escape "$NODE_VERSION")|g" \
      -e "s|__JAVA_VERSION__|$(sed_escape "$JAVA_VERSION")|g" \
      -e "s|__BUILD_COMMAND__|$(sed_escape "$BUILD_COMMAND")|g" \
      -e "s|__TEST_COMMAND__|$(sed_escape "$TEST_COMMAND")|g" \
      -e "s|__CONVENTIONS_HINT__|$(sed_escape "$HINT")|g" \
      -e "s|__SKILL_PATH__|$(sed_escape "$SKILL_PATH")|g" \
      -e "s|__FLY_DIR__|$(sed_escape "$FLY_DIR")|g" \
      -e "s|__REREVIEW_ON_PUSH__|$(sed_escape "$REREVIEW_ON_PUSH")|g" \
      -e "s|__PACKAGE_NAME__|$(sed_escape "$PACKAGE_NAME")|g" \
      -e "s|__RELEASE_TYPE__|$(sed_escape "$RELEASE_TYPE")|g" \
      "$HERE/templates/$1" > "$dest"
  # An unset skill_path renders `skill-path:` with no value. That is harmless
  # (the action treats unset and empty identically) but it is a meaningless
  # line in every repo that does not pin one, so drop it. Done post-render
  # rather than by making the placeholder occupy its own line: a line-position
  # placeholder lands at column 0 in the template, which is precisely the break
  # that took out two repos' release workflows.
  #
  # rereview_on_push is the same shape and has to behave the same way, for a
  # sharper reason: the reusable workflow defaults it to false, so a bare
  # `rereview_on_push:` passes an explicit null where the caller means "unset".
  # Dropping the line is what keeps the other 70 repos rendering byte-identical
  # stubs while one canary carries the opt-in.
  # An unset skill_path drops the `skill-path:` line *and* the rationale
  # comment above it — that comment only makes sense next to a real pin, and
  # leaving it would have 60 repos explaining a line they don't have.
  #
  # Guarded on the value rather than run unconditionally as a sed range: an
  # unterminated range runs to end of file, so when the pin IS set (the end
  # pattern matches an empty value only) the range would swallow the rest of
  # the workflow. validate-render.rb caught exactly that.
  if [ -z "$SKILL_PATH" ]; then
    # Anchored on the comment block's opening words: reword its first line in
    # the template without updating this and 60-odd unpinned repos start
    # rendering an orphan comment, which YAML-parses fine and so slips past
    # validate-render.rb. Keep the two in sync.
    sed -i.bak -e '/^[[:space:]]*# skill-path pins ONE skill/,/^[[:space:]]*skill-path:[[:space:]]*$/d' \
               "$dest" && rm -f "$dest.bak"
  fi
  sed -i.bak -e '/^[[:space:]]*rereview_on_push:[[:space:]]*$/d' "$dest" && rm -f "$dest.bak"
  # Same guarded-range shape as skill-path above, and guarded for the same
  # reason: an unterminated sed range runs to end of file. Scoped to ci.yml so
  # the anchors cannot match anything in another template.
  if [ "$1" = "ci.yml" ] && [ -z "$CI_DISPATCH" ]; then
    sed -i.bak -e '/^  # A manual gate, for when the automatic one/,/^  workflow_dispatch:$/d' \
               "$dest" && rm -f "$dest.bak"
  fi
}

# Repos that pin a skill MUST record it here — regenerating without it silently
# drops the pin, and the publish job then fails in the quiet way: tag cut,
# GitHub Release created, npm never receives the package (issue #76).
# Rendered in VALUE position rather than as a whole line: an empty
# `skill-path:` is equivalent to omitting the input (the action treats unset
# and empty identically), and a line-position placeholder lands at column 0,
# which breaks the template-parse check in CI.
SKILL_PATH="$(cfg skill_path)"
REREVIEW_ON_PUSH="$(cfg rereview_on_push)"
# `workflow_dispatch` on ci.yml: a manual way to run CI when GitHub stops
# creating `pull_request` runs (observed on skylight-mcp, 2026-08-26). Opt-in
# rather than fleet-wide so the other 59 standard-CI repos keep rendering
# byte-identical stubs, and recorded HERE rather than hand-edited into the
# stub — a hand-edit is silently reverted by the next `--execute` (issue #76),
# which is precisely what was about to happen to skylight-mcp's.
CI_DISPATCH="$(cfg ci_dispatch)"

STAGE="$WORK/stage"; mkdir -p "$STAGE"
WF=".github/workflows"
render pr-auto-review.yml "$WF/pr-auto-review.yml"
render auto-merge.yml "$WF/auto-merge.yml"
render claude.yml "$WF/claude.yml"
[ "$CI_MODE" = "standard" ] && render ci.yml "$WF/ci.yml"
# Fork PRs cannot post their own `ci-gated` (read-only token), so a separate
# `workflow_run` workflow posts it from the base-repo context. Rendered
# alongside ci.yml and only in standard CI mode: it triggers on the "CI"
# workflow by name, so it is meaningless where that stub is not installed.
[ "$CI_MODE" = "standard" ] && render ci-fork-status.yml "$WF/ci-fork-status.yml"
if [ "$RELEASE_MODE" = "mcp" ]; then
  render release-please.yml "$WF/release-please.yml"
  # Deploy jobs are APPENDED to the release stub rather than living in a
  # separate workflow, because they must gate on release-please's
  # `release_created` output — which only exists inside this workflow.
  if [ -n "$FLY_DIR" ]; then
    render fragments/deploy-fly-job.yml ".frag/fly.yml"
    cat "$STAGE/.frag/fly.yml" >> "$STAGE/$WF/release-please.yml"
  fi
  if [ -n "$CONNECTOR" ]; then
    if [ -n "$FLY_DIR" ]; then
      render fragments/deploy-connector-job-after-fly.yml ".frag/conn.yml"
    else
      render fragments/deploy-connector-job.yml ".frag/conn.yml"
    fi
    cat "$STAGE/.frag/conn.yml" >> "$STAGE/$WF/release-please.yml"
    render deploy-connector.yml "$WF/deploy-connector.yml"
  fi
fi
[ -n "$LOCKFIX" ] && render "dependabot-lockfix-$LOCKFIX.yml" "$WF/dependabot-lockfix.yml"

# Repo-config stubs. These are the files that drifted worst precisely BECAUSE
# nothing rendered them: 78 unique release-please-config.json among 79 repos,
# 17 dependabot.yml variants among 72, and .github/release.yml simply absent
# from 45. They live outside .github/workflows/, which is why the stage is
# path-shaped.
#
# `none` opts a repo out entirely, and opting out renders NO FILE rather than
# an empty one. That is the escape hatch for a config that is deliberately
# bespoke — StoryMint's per-target Swift directories, curtaincall's permanent
# javax-namespace JAXB hold — and it exists so a regeneration cannot quietly
# revert a hand-written reason (issue #76).
rm -rf "$STAGE/.frag"

if [ "$DEPENDABOT" != "none" ]; then
  render "dependabot-$DEPENDABOT.yml" ".github/dependabot.yml"
  # A repo-specific `ignore:` block is the ONLY thing that made gogcli-mcp and
  # curtaincall "bespoke" — both are otherwise the stock config. Opting them out
  # entirely to protect one block meant they also missed the vitest pin and every
  # future template fix, so the block is a fragment instead: templated config,
  # repo-specific hold, and the hold's reasoning kept under review here rather
  # than only in the consumer.
  #
  # The marker is a COMMENT line. A bare __X__ at column 0 renders to a
  # top-level scalar and breaks CI's template parse — the same shape as the
  # placeholder that took out two repos' release workflows.
  DB="$STAGE/.github/dependabot.yml"
  if [ -n "$DEPENDABOT_IGNORE" ]; then
    FRAG="$HERE/templates/fragments/dependabot-ignore-$DEPENDABOT_IGNORE.yml"
    [ -f "$FRAG" ] || { echo "::error::$REPO: dependabot_ignore '$DEPENDABOT_IGNORE' has no fragment at $FRAG"; exit 1; }
    sed -e "/^    # __DEPENDABOT_IGNORE__$/r $FRAG" \
        -e '/^    # __DEPENDABOT_IGNORE__$/d' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  else
    sed -e '/^    # __DEPENDABOT_IGNORE__$/d' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  fi
fi
[ "$RELEASE_NOTES" != "none" ] && render release-notes.yml ".github/release.yml"
if [ "$RELEASE_CONFIG" != "none" ]; then
  # An unset package_name renders `"package-name": ""`, which release-please
  # accepts and then tags as an empty component — a broken release that looks
  # like a working config. Fail here instead, where the fix is one fleet.json
  # line.
  [ -n "$PACKAGE_NAME" ] || { echo "::error::$REPO: release_config is on but package_name is unset in fleet.json"; exit 1; }
  render release-please-config.json "release-please-config.json"
  # extra-files is a LIST and the optional keys must be able to be ABSENT, so
  # neither can be a sed placeholder. The template carries the shared object
  # entries (the six manifest/server/plugin paths every MCP repo stamps); jq
  # appends this repo's version files and applies the optional keys, deleting
  # each one whose fleet.json value is empty. Done with jq rather than string
  # surgery so a bad value fails here instead of shipping a
  # release-please-config.json that silently does not parse — which
  # release-please reports by skipping the repo, not by failing.
  RPC="$STAGE/release-please-config.json"
  jq --arg vf "$VERSION_FILES" \
     --arg bmpm "$BUMP_MINOR_PRE_MAJOR" \
     --arg iv "$INITIAL_VERSION" \
     --arg ivt "$INCLUDE_V_IN_TAG" \
     --arg ict "$INCLUDE_COMPONENT_IN_TAG" '
    def setbool($k; $v): if $v == "" then del(.[$k]) else .[$k] = ($v == "true") end;
    def setstr($k; $v):  if $v == "" then del(.[$k]) else .[$k] = $v end;
    .packages["."] |= (
        .["extra-files"] += ($vf | split(",") | map(select(length > 0)))
      | setbool("bump-minor-pre-major"; $bmpm)
      | setstr("initial-version"; $iv)
      | setbool("include-v-in-tag"; $ivt)
      | setbool("include-component-in-tag"; $ict)
    )' "$RPC" > "$RPC.tmp" && mv "$RPC.tmp" "$RPC"
fi

if [ -n "$ONLY" ]; then
  # Filter AFTER staging so the name is validated against what this repo
  # actually gets — `--only ci` on a custom-CI repo is an error, not a no-op.
  #
  # Stubs are now identified by NAME (basename minus extension) rather than
  # filename, because the extension is no longer always .yml and the same name
  # can only appear once across the stage. Matching a bare prefix would make
  # `--only release-please` ambiguous with release-please-config, so the
  # comparison is on the whole name.
  KEEP=""; MISSING=""
  # Resolve each requested name against what this repo actually stages, and
  # report EVERY unresolved one. Stopping at the first would hide the rest of
  # a bad list behind one name, and the operator would fix them one run at a
  # time.
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    hit=""
    while IFS= read -r f; do
      base="${f##*/}"
      [ "${base%.*}" = "$w" ] && hit="$f"
    done < <(cd "$STAGE" && find . -type f | sed 's|^\./||')
    if [ -n "$hit" ]; then KEEP="$KEEP$hit"$'\n'; else MISSING="$MISSING $w"; fi
  done < <(printf '%s\n' "$ONLY_NAMES")
  if [ -n "$MISSING" ]; then
    echo "::error::--only:$MISSING not in this repo's stub set ($(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' '))"
    exit 1
  fi
  while IFS= read -r f; do
    printf '%s\n' "$KEEP" | grep -qxF -- "$f" || rm -f "$STAGE/$f"
  done < <(cd "$STAGE" && find . -type f | sed 's|^\./||')
  find "$STAGE" -type d -empty -delete
  # sort -u: two spellings of one stub resolve to the same path, and a doubled
  # entry in the PR body claims the sync touched a file twice.
  ONLY_PATH=$(printf '%s' "$KEEP" | grep -v '^$' | sort -u | tr '\n' ' ')
  ONLY_PATH="${ONLY_PATH% }"
fi

if [ "$EXECUTE" != "--check" ] && [ "$EXECUTE" != "--render" ] && [ "$EXECUTE" != "--pr-body" ]; then
  echo "=== $REPO  (pat=$PAT_SECRET ci=$CI_MODE release=$RELEASE_MODE lockfix=${LOCKFIX:-none} connector=${CONNECTOR:-no} fly=${FLY_DIR:-no} dependabot=$DEPENDABOT) ==="
  while IFS= read -r f; do echo "--- $f"; cat "$STAGE/$f"; done \
    < <(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
fi

# The PR body --execute posts. A function rather than an inline block so
# `--pr-body` can print exactly what --execute would send without cloning
# anything: an under-explaining body is invisible to every check we have, and
# only shows up as a puzzled reviewer in someone else's repo.
pr_body() {
  if [ -n "$ONLY" ]; then
    n=$(printf '%s' "$ONLY_PATH" | wc -w | tr -d ' ')
    if [ "$n" = 1 ]; then
      echo "Single-stub sync: regenerates \`$ONLY_PATH\` from fleet.json and the current template. Other files are untouched."
    else
      echo "Multi-stub sync: regenerates these from fleet.json and the current templates. Other files are untouched."
      echo ""
      for f in $ONLY_PATH; do echo "- \`$f\`"; done
    fi
  else
    echo "Replaces vendored pipeline workflows with thin stubs calling chrischall/workflows@main."
  fi
  echo ""
  # The reason the sync exists, when it lives in chrischall/workflows rather
  # than here. Without it the reviewer sees a diff and no motive.
  if [ -n "$REASON" ]; then
    echo "## Why this change"
    echo ""
    echo "$REASON"
    echo ""
  fi
  if [ -z "$ONLY" ]; then
    echo "- pr-auto-review: reusable (forced verdict + fail-loud + pass-only arming)"
    echo "- auto-merge: reusable (dependabot + ready-to-merge label arms)"
    [ "$CI_MODE" = "standard" ] && echo "- ci: reusable node CI (deferred gate) — required check becomes \`ci / ci\`"
    [ "$RELEASE_MODE" = "mcp" ] && echo "- release-please: thin stub + mcp-publish composite action (OIDC identity preserved)"
    [ -n "$LOCKFIX" ] && echo "- dependabot-lockfix: reusable ($LOCKFIX — regenerates derived lockfiles dependabot can't refresh)"
    [ -n "$CONNECTOR" ] && echo "- deploy-connector: Worker deployed on release (reusable) + workflow_dispatch stub"
    [ -n "$FLY_DIR" ] && echo "- deploy-runner: Fly backend in \`$FLY_DIR\` deployed on release, before the Worker"
    echo ""
    echo "After this PR is open, run \`scripts/update-ruleset.sh $REPO\` in chrischall/workflows."
    echo ""
  fi
  echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
}

if [ "$EXECUTE" = "--pr-body" ]; then
  pr_body
  exit 0
fi

if [ "$EXECUTE" = "--render" ]; then
  # Write the rendered stubs somewhere and stop. Exists so CI can validate the
  # cross product of templates x fleet.json — the synthetic __X__ -> "x" parse
  # never sees a real value, so a placeholder that renders wrong for a specific
  # repo's config gets through it.
  mkdir -p "$DEST"
  # `cp -R "$STAGE"/. ` rather than `"$STAGE"/*`: the stage has directories
  # now, and a glob copy would flatten .github/workflows/ into $DEST or miss
  # dotfile-prefixed directories entirely.
  cp -R "$STAGE"/. "$DEST"/
  exit 0
fi

if [ "$EXECUTE" = "--check" ]; then
  # Drift detector: render what fleet.json SAYS this repo runs, diff it against
  # what the repo actually has, and report. Opens nothing. Exit 1 on drift so a
  # scheduled run can fail loudly instead of a future sweep reverting the repo.
  drift=0; unknown=0
  while IFS= read -r name; do
    f="$STAGE/$name"
    # A failed API call is NOT a missing file. Conflating them makes every
    # auth blip, rate-limit, or network hiccup look like a repo that lost a
    # workflow — which, once --check is scheduled (#76), is a false alarm that
    # trains you to ignore it. 404 means missing; anything else means unknown.
    # $name is already repo-relative, so this addresses .github/dependabot.yml
    # and release-please-config.json as readily as a workflow. Asking for the
    # wrong directory would 404 and report a correct repo as MISSING a file.
    if ! raw=$(gh api "repos/$REPO/contents/$name" --jq '.content' 2>"$WORK/gh.err"); then
      if grep -q "HTTP 404" "$WORK/gh.err"; then
        echo "MISSING  $REPO/$name"; drift=1
      else
        echo "ERROR    $REPO/$name — $(head -1 "$WORK/gh.err")"; unknown=1
      fi
      continue
    fi
    actual=$(printf '%s' "$raw" | base64 -d 2>/dev/null || true)
    # Compare with trailing newlines normalized away: several repos' files were
    # committed without one, and a "\ No newline at end of file" diff on every
    # repo makes the detector useless rather than informative. Both sides come
    # out of `$(...)`, which strips trailing newlines already, so a plain string
    # comparison IS the normalized comparison — and unlike `diff -q` it cannot
    # abandon a half-written pipe (see below).
    want=$(cat "$f")
    if [ "$actual" != "$want" ]; then
      echo "DRIFT    $REPO/$name"
      # `|| true` is load-bearing: `diff` exits 1 BY DESIGN when the files
      # differ (which is the only case that reaches this line). Under
      # `set -euo pipefail` that aborts the whole script mid-loop, and the
      # failure mode is silent UNDER-REPORTING — the first drifted stub is
      # printed, every later stub in the set is never even fetched, and the exit
      # code still says 1, so the report looks complete while hiding the rest
      # (issue #104).
      #
      # One `sed -n '1,20{s/^/    /;p;}'` rather than `sed 's/^/    /' | head
      # -20`: it does BOTH jobs the old pipeline split across two stages —
      # indent every reported line by four spaces, and cap the body at 20 — in
      # a single pass that reads to EOF.
      #
      # The cap is the part that matters. `head` EXITS at 20 lines, so on a
      # long diff everything upstream is left writing into a closed pipe, and a
      # bash builtin `printf` in a process substitution can report that as
      # `printf: write error: Broken pipe` on stderr — landing mid report,
      # between a DRIFT header and its own diff body, which is where it
      # corrupts the text pasted into the drift issue. A range-limited sed
      # consumes the whole stream and prints only the first 20, so the cap
      # costs a full read instead of abandoning a writer.
      #
      # This was observed once on CI and never reproduced locally (tried across
      # bash 3.2/5.3, BSD and GNU diff, up to 200k-line inputs) — it is a race
      # on who finishes first, so the fix is to remove the early-exiting reader
      # rather than to out-time it. The `diff -q` that used to sit above was
      # dropped for the same reason: it was a second reader over the same data
      # whose only job was a yes/no that a string comparison already answers.
      diff <(printf '%s\n' "$actual") <(printf '%s\n' "$want") | sed -n '1,20{s/^/    /;p;}' || true
      drift=1
    fi
  done < <(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
  # Distinct exit codes so a scheduled run can tell "this repo drifted" (1)
  # from "I could not find out" (2) — they need different responses.
  [ "$unknown" = 1 ] && exit 2
  [ "$drift" = 0 ] && echo "OK       $REPO"
  exit "$drift"
fi

if [ "$EXECUTE" != "--execute" ]; then
  echo "(dry run — pass --execute to open the conversion PR, --check to report drift)"
  exit 0
fi

# The canonical label set (idempotent). Delegated to ensure-labels.sh so there
# is ONE list: this loop carried four pipeline labels and knew nothing about
# the release-notes vocabulary, which is how `refactor` ended up missing from
# 36 repos and `ci` from 8 — and a label a repo does not have is a
# .github/release.yml category that silently never matches.
bash "$HERE/scripts/ensure-labels.sh" "$REPO" >/dev/null

gh repo clone "$REPO" "$WORK/clone" -- --depth 1 --quiet
cd "$WORK/clone"
git checkout -b "$BRANCH"
# Copy the staged TREE over the clone: the stage is already repo-shaped, so
# each file lands where the consumer keeps it (.github/workflows/, .github/,
# or the repo root) instead of everything being dumped into one directory.
cp -R "$STAGE"/. .
# Files not in the stub set are intentionally left untouched (custom ci.yml,
# deploy workflows, release workflows for custom repos). claude.yml IS in the
# stub set as of the reusable-claude rollout — a repo's local copy is replaced,
# which is the point: every hand-copied version checks out the default branch
# on `issue_comment` instead of the PR, and runs for any commenter.
# Add exactly the paths we rendered. `git add .` would sweep up anything else
# in the clone, and `git add .github/workflows` can no longer see the repo-root
# and .github/ stubs.
while IFS= read -r f; do git add -- "$f"; done \
  < <(cd "$STAGE" && find . -type f | sed 's|^\./||')
if git diff --cached --quiet; then
  echo "$REPO already converted — nothing to do."
  exit 0
fi
if [ -n "$ONLY" ]; then
  # The PR title is also the SQUASH SUBJECT on a single-commit PR, so the
  # commit below uses $TITLE verbatim rather than a second wording.
  n=$(printf '%s\n' "$ONLY_NAMES" | grep -c .)
  if [ "$n" = 1 ]; then
    TITLE="ci: sync the $ONLY_NAMES stub from chrischall/workflows"
  else
    # "a, b and c" — built from the stubs actually requested. A hardcoded
    # category was accurate only for the combination it was written for.
    list=$(printf '%s' "$ONLY_NAMES" | paste -sd, - | sed 's/,/, /g; s/, \([^,]*\)$/ and \1/')
    TITLE="ci: sync the $list stubs from chrischall/workflows"
  fi
else
  TITLE="ci: convert to chrischall/workflows reusable pipeline"
fi
EXTRAS=""
[ "$CI_MODE" = "standard" ] && EXTRAS="$EXTRAS/CI"
[ "$RELEASE_MODE" = "mcp" ] && EXTRAS="$EXTRAS/release"
[ -n "$LOCKFIX" ] && EXTRAS="$EXTRAS/lockfix"
if [ -n "$ONLY" ]; then
  # $ONLY_PATH, not templates/$ONLY.yml: the stub name is the DESTINATION
  # basename, so the old form named templates that do not exist
  # (templates/dependabot.yml, templates/release.yml).
  git commit -m "$TITLE

Regenerated $ONLY_PATH from fleet.json and the current templates.
Pipeline source: https://github.com/chrischall/workflows"
else
  git commit -m "$TITLE

Thin stubs replace the vendored auto-review/auto-merge${EXTRAS} workflows.
Pipeline source: https://github.com/chrischall/workflows"
fi
git push -u origin "$BRANCH"
pr_body > "$WORK/pr-body.md"
# Capture the URL: the label step below needs to name the PR, and `gh pr edit`
# with no argument only resolves a PR from the CURRENT branch — which is the
# fleet repo's checkout here, not the target repo's.
PR_URL=$(gh pr create --repo "$REPO" --head "$BRANCH" \
  --title "$TITLE" \
  --body-file "$WORK/pr-body.md")
echo "$PR_URL"

# Apply the release-notes label, where the repo has one.
#
# Several repos' CLAUDE.md require EXACTLY ONE release-notes label per PR, and
# auto-review fails a PR without it — so every sweep opened a PR that was
# guaranteed to fail review in those repos (flightaware-mcp#63 is the one that
# surfaced it). `ci` is the correct label for these: a stub sync ships no
# user-facing change, and `ci` maps to the hidden changelog section, matching
# the Conventional-Commit type in $TITLE.
#
# Best-effort by design. A repo without a `ci` label is not a failure — it has
# no such convention to satisfy — and the sync is already pushed and the PR
# already open, so a labelling hiccup must never look like a failed rollout.
# NOTE: this is a release-notes label, never an ARMING one; rollout.sh does not
# arm its own PRs.
if gh label list --repo "$REPO" --limit 100 --json name --jq '.[].name' 2>/dev/null | grep -qx "ci"; then
  if gh pr edit "$PR_URL" --repo "$REPO" --add-label ci >/dev/null 2>&1; then
    echo "Labelled 'ci' (release-notes label; repo requires one)."
  else
    echo "NOTE: could not apply the 'ci' label — add it by hand if this repo requires one." >&2
  fi
fi

echo "PR opened for $REPO."

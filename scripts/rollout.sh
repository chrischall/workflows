#!/usr/bin/env bash
# Convert one fleet repo to chrischall/workflows stubs via PR.
#
# Usage: scripts/rollout.sh <owner/repo> [--execute]
# Dry-run by default: prints generated stubs and planned actions.
#
# Does NOT merge the PR and does NOT add ready-to-merge — the pipeline does.
# Run scripts/update-ruleset.sh after the PR is open.
set -euo pipefail

REPO="${1:?usage: rollout.sh <owner/repo> [--execute]}"
EXECUTE="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$HERE/fleet.json"
BRANCH="ci/reusable-workflows"

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Escape a fleet.json value for use as a sed REPLACEMENT string. `&` means "the
# whole match" and `|` is our delimiter, so an unescaped value containing either
# is silently corrupted rather than erroring: a test_command of
# `npm run typecheck && npm test` rendered as
# `npm run typecheck __TEST_COMMAND____TEST_COMMAND__ npm test`,
# because each `&` re-inserted the placeholder it had just matched.
sed_escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

render() { # render <template> <dest>
  sed -e "s|__PAT_SECRET__|$(sed_escape "$PAT_SECRET")|g" \
      -e "s|__NODE_VERSION__|$(sed_escape "$NODE_VERSION")|g" \
      -e "s|__JAVA_VERSION__|$(sed_escape "$JAVA_VERSION")|g" \
      -e "s|__BUILD_COMMAND__|$(sed_escape "$BUILD_COMMAND")|g" \
      -e "s|__TEST_COMMAND__|$(sed_escape "$TEST_COMMAND")|g" \
      -e "s|__CONVENTIONS_HINT__|$(sed_escape "$HINT")|g" \
      -e "s|__FLY_DIR__|$(sed_escape "$FLY_DIR")|g" \
      "$HERE/templates/$1" > "$2"
}

STAGE="$WORK/stage"; mkdir -p "$STAGE"
render pr-auto-review.yml "$STAGE/pr-auto-review.yml"
render auto-merge.yml "$STAGE/auto-merge.yml"
[ "$CI_MODE" = "standard" ] && render ci.yml "$STAGE/ci.yml"
if [ "$RELEASE_MODE" = "mcp" ]; then
  render release-please.yml "$STAGE/release-please.yml"
  # Deploy jobs are APPENDED to the release stub rather than living in a
  # separate workflow, because they must gate on release-please's
  # `release_created` output — which only exists inside this workflow.
  if [ -n "$FLY_DIR" ]; then
    render fragments/deploy-fly-job.yml "$WORK/fly.frag"
    cat "$WORK/fly.frag" >> "$STAGE/release-please.yml"
  fi
  if [ -n "$CONNECTOR" ]; then
    if [ -n "$FLY_DIR" ]; then
      render fragments/deploy-connector-job-after-fly.yml "$WORK/conn.frag"
    else
      render fragments/deploy-connector-job.yml "$WORK/conn.frag"
    fi
    cat "$WORK/conn.frag" >> "$STAGE/release-please.yml"
    render deploy-connector.yml "$STAGE/deploy-connector.yml"
  fi
fi
[ -n "$LOCKFIX" ] && render "dependabot-lockfix-$LOCKFIX.yml" "$STAGE/dependabot-lockfix.yml"

echo "=== $REPO  (pat=$PAT_SECRET ci=$CI_MODE release=$RELEASE_MODE lockfix=${LOCKFIX:-none} connector=${CONNECTOR:-no} fly=${FLY_DIR:-no}) ==="
for f in "$STAGE"/*; do echo "--- $(basename "$f")"; cat "$f"; done

if [ "$EXECUTE" != "--execute" ]; then
  echo "(dry run — pass --execute to open the conversion PR)"
  exit 0
fi

# Labels the pipeline depends on (idempotent).
for L in "auto-review:bfdadc" "ready-to-merge:0e8a16" "review-with-opus:5319e7" "release-ready:fbca04"; do
  gh label create "${L%%:*}" --repo "$REPO" --color "${L##*:}" --force >/dev/null
done

gh repo clone "$REPO" "$WORK/clone" -- --depth 1 --quiet
cd "$WORK/clone"
git checkout -b "$BRANCH"
mkdir -p .github/workflows
cp "$STAGE"/* .github/workflows/
# Files not in the stub set are intentionally left untouched (custom ci.yml,
# claude.yml, deploy workflows, release workflows for custom repos).
git add .github/workflows
if git diff --cached --quiet; then
  echo "$REPO already converted — nothing to do."
  exit 0
fi
EXTRAS=""
[ "$CI_MODE" = "standard" ] && EXTRAS="$EXTRAS/CI"
[ "$RELEASE_MODE" = "mcp" ] && EXTRAS="$EXTRAS/release"
[ -n "$LOCKFIX" ] && EXTRAS="$EXTRAS/lockfix"
git commit -m "ci: convert to chrischall/workflows reusable pipeline

Thin stubs replace the vendored auto-review/auto-merge${EXTRAS} workflows.
Pipeline source: https://github.com/chrischall/workflows"
git push -u origin "$BRANCH"
{
  echo "Replaces vendored pipeline workflows with thin stubs calling chrischall/workflows@main."
  echo ""
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
  echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
} > "$WORK/pr-body.md"
gh pr create --repo "$REPO" --head "$BRANCH" \
  --title "ci: convert to chrischall/workflows reusable pipeline" \
  --body-file "$WORK/pr-body.md"
echo "PR opened for $REPO."

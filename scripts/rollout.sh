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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

render() { # render <template> <dest>
  sed -e "s|__PAT_SECRET__|$PAT_SECRET|g" \
      -e "s|__NODE_VERSION__|$NODE_VERSION|g" \
      -e "s|__BUILD_COMMAND__|$BUILD_COMMAND|g" \
      -e "s|__TEST_COMMAND__|$TEST_COMMAND|g" \
      -e "s|__CONVENTIONS_HINT__|${HINT//|/\\|}|g" \
      "$HERE/templates/$1" > "$2"
}

STAGE="$WORK/stage"; mkdir -p "$STAGE"
render pr-auto-review.yml "$STAGE/pr-auto-review.yml"
render auto-merge.yml "$STAGE/auto-merge.yml"
[ "$CI_MODE" = "standard" ] && render ci.yml "$STAGE/ci.yml"
[ "$RELEASE_MODE" = "mcp" ] && render release-please.yml "$STAGE/release-please.yml"

echo "=== $REPO  (pat=$PAT_SECRET ci=$CI_MODE release=$RELEASE_MODE) ==="
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
  echo ""
  echo "After this PR is open, run \`scripts/update-ruleset.sh $REPO\` in chrischall/workflows."
  echo ""
  echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
} > "$WORK/pr-body.md"
gh pr create --repo "$REPO" --head "$BRANCH" \
  --title "ci: convert to chrischall/workflows reusable pipeline" \
  --body-file "$WORK/pr-body.md"
echo "PR opened for $REPO."

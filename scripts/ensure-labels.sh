#!/usr/bin/env bash
# Apply the fleet's canonical label set (labels.json) to one repo.
#
# Usage: scripts/ensure-labels.sh <owner/repo> [--check]
#
# Two families, and BOTH are load-bearing:
#
#   pipeline       drives automation. `ready-to-merge` arms auto-merge,
#                  `release-ready` starts a release review,
#                  `auto-review-followup` / `orphaned-followup` are how the
#                  follow-up issues are found. A repo missing one does not
#                  fail loudly — the workflow that wanted it just does not
#                  find it.
#   release-notes  is the vocabulary `.github/release.yml` categorises by. A
#                  label the repo does not have is a category that silently
#                  never matches, and every PR under it lands in "Other
#                  Changes". That is the quiet failure this script exists for:
#                  the config is valid, the category is real, and it matches
#                  nothing.
#
# Colours are the fleet PLURALITY where one already existed, chosen so
# standardising rewrites as few repos as possible. `gh label create --force`
# is create-or-update, so this is idempotent and safe to re-run.
#
# --check reports drift and opens nothing (exit 1 if any label is missing or
# has the wrong colour), so it can run on a schedule the way rollout.sh
# --check does.
set -euo pipefail

REPO="${1:?usage: ensure-labels.sh <owner/repo> [--check]}"
MODE="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LABELS="$HERE/labels.json"
[ -f "$LABELS" ] || { echo "::error::no labels.json at $LABELS"; exit 1; }

# name<TAB>colour<TAB>description for every canonical label, both families.
spec() { jq -r '[.pipeline[], .["release-notes"][]][] | [.name, .color, .description] | @tsv' "$LABELS"; }

if [ "$MODE" = "--check" ]; then
  # One API call, not one per label: a 16-label check across 81 repos is 1296
  # requests the slow way, which is a rate-limit incident rather than a report.
  actual=$(gh api "repos/$REPO/labels?per_page=100" --jq '.[] | [.name, .color] | @tsv' 2>/dev/null || true)
  [ -n "$actual" ] || { echo "ERROR    $REPO — could not read labels"; exit 2; }
  drift=0
  while IFS=$'\t' read -r name color _desc; do
    have=$(printf '%s\n' "$actual" | awk -F'\t' -v n="$name" '$1==n {print $2; exit}')
    if [ -z "$have" ]; then
      echo "MISSING  $REPO/$name"; drift=1
    elif [ "$(printf '%s' "$have" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$color" | tr 'A-Z' 'a-z')" ]; then
      # Case-insensitive: GitHub stores what it was given, and the fleet has
      # the same label as both FBCA04 and fbca04. That is not drift worth a
      # write.
      echo "COLOUR   $REPO/$name — #$have, want #$color"; drift=1
    fi
  done < <(spec)
  [ "$drift" = 0 ] && echo "OK       $REPO"
  exit "$drift"
fi

while IFS=$'\t' read -r name color desc; do
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null
done < <(spec)
echo "labels applied to $REPO"

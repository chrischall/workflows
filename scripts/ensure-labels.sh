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
# Colours are NOT chosen to minimise churn: this script rewrites every label on
# every repo regardless, so matching whatever a repo already had buys nothing
# operationally. labels.json picks a legible palette instead — every colour
# unique across both families, hue carrying meaning — and its `_palette` note
# is the rationale. `gh label create --force` is create-or-update, so this is
# idempotent and safe to re-run.
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

# Retry each write. 16 labels x 81 repos is ~1300 create calls, and GitHub
# applies a SECONDARY rate limit to bursts of content-creating requests that
# the core quota does not show — a fleet run hit it on 6 repos, all of which
# succeeded immediately on retry.
#
# Without this the failure is worse than a failed run: `set -e` aborts on the
# first bad write, so the repo is left PARTIALLY labelled — some labels
# canonical, some not, and the script reporting failure with no record of how
# far it got. A half-labelled repo is the quiet state this whole script exists
# to eliminate.
failed=""
while IFS=$'\t' read -r name color desc; do
  ok=""
  for attempt in 1 2 3; do
    if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep $((attempt * 3))
  done
  [ -n "$ok" ] || failed="$failed $name"
done < <(spec)

if [ -n "$failed" ]; then
  # Name every label that did not land, so the repo can be finished rather
  # than blindly re-run, and exit non-zero so a sweep counts it.
  echo "::error::$REPO: could not apply after 3 attempts:$failed" >&2
  exit 1
fi
echo "labels applied to $REPO"

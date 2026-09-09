#!/usr/bin/env bash
# Compare each repo's released version to what is actually on npm.
#
# Usage: scripts/verify-publish.sh <owner/repo>
#
# Exit 0 in sync (or nothing to check), 1 tagged-but-not-published, 2 unknown.
#
# A GREEN TAG IS NOT A GREEN PUBLISH. release-please cuts the tag and creates
# the GitHub Release in one job; the npm publish is a separate one. When the
# publish fails, the repo looks released from every angle except the only one
# that matters to a consumer. ofw-mcp shipped v2.6.0, v2.6.1 and v2.6.2 that
# way — three tags, three GitHub Releases, npm sitting on 2.5.0 the whole time,
# and nobody noticed because nothing was red.
#
# This is the check that would have caught it, and it is cheap: one registry
# read per repo.
set -uo pipefail   # no -e: this script READS failures (a missing package.json,
                   # an unpublished version) and turns them into its 0/1/2 exit
                   # codes; -e would abort on the first one instead of reporting.

REPO="${1:?usage: verify-publish.sh <owner/repo>}"

pkg=$(gh api "repos/$REPO/contents/package.json" --jq .content 2>/dev/null \
      | base64 -d 2>/dev/null | jq -r 'select(.private != true) | .name // empty' 2>/dev/null)
# No package.json, or private: nothing is expected on npm.
[ -n "$pkg" ] || { echo "SKIP     $REPO (no public package.json)"; exit 0; }

manifest=$(gh api "repos/$REPO/contents/.release-please-manifest.json" --jq .content 2>/dev/null \
           | base64 -d 2>/dev/null | jq -r '.["."] // empty' 2>/dev/null)
# release-please not configured for the root package: nothing to compare.
[ -n "$manifest" ] || { echo "SKIP     $REPO (no release-please manifest)"; exit 0; }

published=$(npm view "$pkg" version 2>/dev/null)
if [ -z "$published" ]; then
  # Distinguish "never published" from "registry unreachable": the first is a
  # real finding, the second is noise that must not read as one.
  if npm view "$pkg" name >/dev/null 2>&1; then
    echo "UNKNOWN  $REPO — $pkg resolves but has no version"; exit 2
  fi
  echo "MISSING  $REPO — $pkg@$manifest tagged, nothing published"; exit 1
fi

if [ "$published" = "$manifest" ]; then
  echo "OK       $REPO ($pkg@$published)"
  exit 0
fi
echo "BEHIND   $REPO — $pkg tagged $manifest, npm has $published"
exit 1

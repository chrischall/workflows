#!/usr/bin/env bash
# Assert that R8 kept a $$serializer for every @Serializable type in the shared
# core that has one.
#
# Why this exists: kotlinx.serialization reaches those generated classes
# reflectively through the Companion, so R8 sees no call site. If a keep rule in
# proguard-rules.pro stops matching — a package rename, a model added outside
# com.chrischall.encore.shared — the minified build still COMPILES and still
# LAUNCHES, then throws SerializationException the first time it parses an API
# response. The unit suites run un-minified and cannot catch it, so the release
# pipeline checks the DEX directly.
#
# Which types are checked is decided by serializable_scan.py, not by grepping
# for @Serializable: enums, objects, sealed/abstract types and
# @Serializable(with = ...) never get a generated $$serializer, and demanding one
# would fail the release spuriously. Exempt types are reported, never silently
# dropped.
#
# TEMPLATE — copy this plus serializable_scan.py and test_serializable_scan.py
# into <app>/android/scripts/. It assumes the app-repo layout (script at
# android/scripts/, shared source at shared/src/commonMain); override the
# latter with ENCORE_SHARED_SRC. Nothing else is app-specific.
#
# Usage: android/scripts/verify-minified-serializers.sh [path/to/release.aab]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AAB="${1:-$REPO_ROOT/android/build/outputs/bundle/release/android-release.aab}"
SRC="${ENCORE_SHARED_SRC:-$REPO_ROOT/shared/src/commonMain}"

# The guard proves itself before it is trusted to block a release. It is a
# sub-second, dependency-free run, and a classifier that has quietly broken is
# indistinguishable from one that has nothing to report.
python3 "$SCRIPT_DIR/test_serializable_scan.py" > /dev/null || {
  echo "error: serializable_scan self-test failed — the guard itself is broken." >&2
  python3 "$SCRIPT_DIR/test_serializable_scan.py" >&2 || true
  exit 1
}

if [ ! -f "$AAB" ]; then
  echo "error: no bundle at $AAB — run :android:bundleRelease first" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$AAB" -d "$work"

# Types the source declares that DO generate a $$serializer. The scanner exits
# non-zero if it cannot classify a declaration — an unguarded type must stop the
# release, not pass quietly.
if ! python3 "$SCRIPT_DIR/serializable_scan.py" "$SRC" --report 2>"$work/report.txt" | sort -u > "$work/required.txt"; then
  cat "$work/report.txt" >&2
  exit 1
fi
grep '^  exempt:' "$work/report.txt" > "$work/exempt.txt" || true

if [ ! -s "$work/required.txt" ]; then
  echo "error: found no @Serializable types requiring a serializer under $SRC —" >&2
  echo "       this script's source scan has broken, so it is no longer guarding anything." >&2
  exit 1
fi

# Serializers that survived minification. The `|| true` matters: grep exits
# non-zero when it matches nothing, and "nothing matched" is precisely the
# failure this script reports — without it, pipefail would kill the script
# before it could say so.
{ for dex in "$work"/base/dex/*.dex; do strings "$dex"; done \
  | grep -oE 'L[a-zA-Z0-9/$_]*\$\$serializer;' \
  | sed -E 's#.*/([A-Za-z0-9_]+)\$\$serializer;#\1#' | sort -u || true; } > "$work/kept.txt"

missing=$(comm -23 "$work/required.txt" "$work/kept.txt" || true)

if [ -n "$missing" ]; then
  echo "error: R8 stripped the serializer for these @Serializable types —" >&2
  echo "       the app would throw SerializationException on its first API call:" >&2
  echo "$missing" | sed 's/^/         - /' >&2
  echo "       Fix the keep rules in android/proguard-rules.pro." >&2
  exit 1
fi

required=$(wc -l < "$work/required.txt" | tr -d ' ')
echo "OK: all $required @Serializable types that generate a serializer kept it after R8."
if [ -s "$work/exempt.txt" ]; then
  echo "Not asserted (these generate no \$\$serializer by design):"
  cat "$work/exempt.txt"
fi

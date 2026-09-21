#!/usr/bin/env bash
# Guard for the fleet's action-pin policy: third-party actions ride release
# TAGS (`@v5.0.0`), chrischall/workflows rides `@main`, and nothing is ever
# pinned to a commit SHA. A SHA pin is unreadable in review, and a
# `# vX.Y.Z` comment beside it is a claim nothing checks.
#
# #290 SHA-pinned release-please-action in the reusable release and it merged,
# because nothing here said no. This scans every workflow, template, fragment
# and skill reference the fleet copies from.
set -uo pipefail   # no -e: assertions need to observe failures
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; printf '%s\n' "$2" | sed 's/^/     /'; fail=$((fail+1)); }

SHA_PIN='uses:[[:space:]]*["'\'']?[^[:space:]"'\''#]+@[0-9a-fA-F]{40}'

# The pattern itself must catch the shapes #290 used, or a green run means nothing.
for line in \
  '      - uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7 # v5.0.0' \
  '        uses: r0adkll/upload-google-play@e738b9dd8f2476ea806d921b64aacd24f34515a5' \
  "        uses: 'owner/repo/sub@45996ed1f6d02564a971a2fa1b5860e934307cf7'"; do
  if printf '%s\n' "$line" | grep -Eq "$SHA_PIN"; then ok "pattern catches: ${line##*uses: }"
  else bad "pattern misses a SHA pin" "$line"; fi
done
for line in \
  '      - uses: googleapis/release-please-action@v5.0.0' \
  '    uses: chrischall/workflows/.github/workflows/reusable-mcp-ci.yml@main' \
  '      - uses: ./.github/actions/mcp-publish'; do
  if printf '%s\n' "$line" | grep -Eq "$SHA_PIN"; then bad "pattern flags a tag/branch pin" "$line"
  else ok "pattern allows: ${line##*uses: }"; fi
done

hits=$(grep -rEn --include='*.yml' --include='*.yaml' "$SHA_PIN" \
         .github templates skills 2>/dev/null || true)
if [ -z "$hits" ]; then
  ok "no action is pinned to a commit SHA"
else
  bad "actions pinned to a commit SHA (use the release tag, e.g. @v5.0.0)" "$hits"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

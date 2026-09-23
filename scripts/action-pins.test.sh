#!/usr/bin/env bash
# Guard for the fleet's action-pin policy: third-party actions ride release
# TAGS (`@v5.0.0`), chrischall/workflows rides `@main`, and nothing is ever
# pinned to a commit SHA or (third-party) to a branch. A SHA pin is unreadable in review, and a
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

# Branch refs (fleet-audit#286). `@master` / `@main` on a third-party
# action is mutable: a push to that branch changes what runs, secrets and all,
# in every consumer with no review. Third-party refs must be tag-shaped
# (`v5`, `v5.0.0`, `1.6`); only first-party chrischall/* actions ride `@main`.
# Prints the offending `uses:` value, or nothing when the ref is acceptable.
branch_ref() {
  printf '%s\n' "$1" | sed -nE 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'\'']?([^[:space:]"'\''#]+)["'\'']?.*/\2/p' | while read -r ref; do
    case "$ref" in ./*|docker://*|'${{'*) continue ;; esac
    case "$ref" in *@*) ;; *) continue ;; esac
    owner="${ref%%/*}"; version="${ref##*@}"
    [ "$owner" = chrischall ] && continue
    printf '%s\n' "$version" | grep -Eq '^v?[0-9]+(\.[0-9]+)*$' && continue
    printf '%s\n' "$ref"
  done
}

for line in \
  '      - uses: superfly/flyctl-actions/setup-flyctl@master' \
  '        uses: actions/checkout@main' \
  "      - uses: 'owner/repo@release-branch'"; do
  if [ -n "$(branch_ref "$line")" ]; then ok "branch check catches: ${line##*uses: }"
  else bad "branch check misses a branch ref" "$line"; fi
done
for line in \
  '      - uses: actions/checkout@v7' \
  '      - uses: googleapis/release-please-action@v5.0.0' \
  '      - uses: superfly/flyctl-actions/setup-flyctl@1.6' \
  '    uses: chrischall/workflows/.github/workflows/reusable-mcp-ci.yml@main' \
  '      - uses: chrischall/mcp-utils/.github/actions/install-mcp-publisher@main' \
  '      - uses: ./.github/actions/mcp-publish' \
  '      # a comment mentioning uses: foo/bar@master is not a step' \
  '            prose about a NEW `uses: foo/bar@master` in a prompt is not a step'; do
  if [ -n "$(branch_ref "$line")" ]; then bad "branch check flags an allowed ref" "$line"
  else ok "branch check allows: ${line##*uses: }"; fi
done

branch_hits=$(grep -rEn --include='*.yml' --include='*.yaml' '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]' \
                .github templates skills 2>/dev/null | while IFS= read -r hit; do
  r=$(branch_ref "${hit#*:*:}"); [ -n "$r" ] && printf '%s\n' "$hit"
done)
if [ -z "$branch_hits" ]; then
  ok "no third-party action rides a branch ref"
else
  bad "third-party actions on a branch ref (use a release tag, e.g. @v5.0.0)" "$branch_hits"
fi

# npx in the composite actions (fleet-audit#285). They run inside the publish
# job, which holds id-token: write (npm trusted publishing, MCP Registry OIDC)
# and a contents: write token, so `npx <pkg>` at whatever is latest on npm lets
# a compromised release of that package publish as the fleet. Every npx there
# must name an exact version, bumped through a reviewed change here.
unpinned_npx() {
  printf '%s\n' "$1" | grep -Eo 'npx([[:space:]]+-[-a-z]+)*[[:space:]]+[^[:space:]]+' \
    | awk '{print $NF}' | grep -Ev '^@?[^@[:space:]]+@[0-9]+\.[0-9]+\.[0-9]+$' || true
}
for line in \
  'if ! npx @anthropic-ai/mcpb pack; then' \
  'npx --yes clawhub login --no-browser' \
  'npx --yes clawhub@latest publish "$DIR"' \
  'npx clawhub@0 publish'; do
  if [ -n "$(unpinned_npx "$line")" ]; then ok "npx check catches: $line"
  else bad "npx check misses an unpinned package" "$line"; fi
done
for line in \
  'if ! npx --yes @anthropic-ai/mcpb@2.1.2 pack; then' \
  'npx --yes clawhub@0.23.3 publish "$SKILL_DIR"'; do
  if [ -n "$(unpinned_npx "$line")" ]; then bad "npx check flags an exact pin" "$line"
  else ok "npx check allows: $line"; fi
done
npx_hits=$(grep -rEn 'npx[[:space:]]' .github/actions 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' \
  | while IFS= read -r hit; do
      [ -n "$(unpinned_npx "${hit#*:*:}")" ] && printf '%s\n' "$hit"
    done)
if [ -z "$npx_hits" ]; then
  ok "every npx in a composite action names an exact version"
else
  bad "unpinned npx in a composite action (pin an exact version, e.g. pkg@1.2.3)" "$npx_hits"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

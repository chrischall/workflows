#!/usr/bin/env bash
# Guard for the fleet's action-pin policy: third-party actions ride EXACT
# release tags (`@v5.0.0`), chrischall/workflows rides `@main`, and nothing is
# ever pinned to a commit SHA, a branch, or (third-party) a moving major tag
# like `@v7`. A SHA pin is unreadable in review, and a `# vX.Y.Z` comment
# beside it is a claim nothing checks.
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

# Branch refs (fleet-audit#286) and moving major tags (fleet-audit#888).
# `@master` / `@main` on a third-party action is mutable: a push to that branch
# changes what runs, secrets and all, in every consumer with no review. A major
# tag (`@v7`) is the same thing one step removed: the action's owner moves it
# on every release. Third-party refs must be an exact release tag
# (`v5.0.0`, `1.2.3`); only first-party chrischall/* actions ride `@main`.
#
# This used to accept any tag-shaped ref (`v5`), so `actions/checkout@v7` sat
# in templates/release-please*.yml untouched — and a fleet re-sync from them
# undid repos' own exact pins (realty-mcp#76).
#
# One exception: superfly/flyctl-actions tags its releases MAJOR.MINOR only
# (`1.6`, no patch), so that is its exact form; its `1` is still a major tag.
# Prints the offending `uses:` value, or nothing when the ref is acceptable.
branch_ref() {
  printf '%s\n' "$1" | sed -nE 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'\'']?([^[:space:]"'\''#]+)["'\'']?.*/\2/p' | while read -r ref; do
    case "$ref" in ./*|docker://*|'${{'*) continue ;; esac
    case "$ref" in *@*) ;; *) continue ;; esac
    owner="${ref%%/*}"; version="${ref##*@}"
    [ "$owner" = chrischall ] && continue
    exact='^v?[0-9]+\.[0-9]+\.[0-9]+$'
    case "$ref" in superfly/flyctl-actions*@*) exact='^v?[0-9]+\.[0-9]+$' ;; esac
    printf '%s\n' "$version" | grep -Eq "$exact" && continue
    printf '%s\n' "$ref"
  done
}

for line in \
  '      - uses: superfly/flyctl-actions/setup-flyctl@master' \
  '        uses: actions/checkout@main' \
  "      - uses: 'owner/repo@release-branch'" \
  '      - uses: actions/checkout@v7' \
  '        uses: gradle/actions/setup-gradle@v4' \
  '      - uses: owner/repo@v4.4' \
  '      - uses: superfly/flyctl-actions/setup-flyctl@1'; do
  if [ -n "$(branch_ref "$line")" ]; then ok "ref check catches: ${line##*uses: }"
  else bad "ref check misses a branch or major-tag ref" "$line"; fi
done
for line in \
  '      - uses: actions/checkout@v7.0.1' \
  '      - uses: googleapis/release-please-action@v5.0.0' \
  '      - uses: superfly/flyctl-actions/setup-flyctl@1.6' \
  '    uses: chrischall/workflows/.github/workflows/reusable-mcp-ci.yml@main' \
  '      - uses: chrischall/mcp-utils/.github/actions/install-mcp-publisher@main' \
  '      - uses: ./.github/actions/mcp-publish' \
  '      # a comment mentioning uses: foo/bar@master is not a step' \
  '            prose about a NEW `uses: foo/bar@master` in a prompt is not a step'; do
  if [ -n "$(branch_ref "$line")" ]; then bad "ref check flags an allowed ref" "$line"
  else ok "ref check allows: ${line##*uses: }"; fi
done

branch_hits=$(grep -rEn --include='*.yml' --include='*.yaml' '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]' \
                .github templates skills 2>/dev/null | while IFS= read -r hit; do
  r=$(branch_ref "${hit#*:*:}"); [ -n "$r" ] && printf '%s\n' "$hit"
done)
if [ -z "$branch_hits" ]; then
  ok "every third-party action rides an exact release tag"
else
  bad "third-party actions on a branch or major tag (use the exact release tag, e.g. @v5.0.0)" "$branch_hits"
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

# Dependabot must see every pin it is meant to bump (fleet-audit#806). The
# github-actions ecosystem's `directory: /` means .github/workflows only, so a
# composite action's own `uses:` (mcp-publish's setup-node runs in the publish
# job of every fleet repo) was never raised and drifted behind the workflows.
# Every .github/actions/* directory must appear in .github/dependabot.yml.
# shellcheck disable=SC2016  # ruby source, not shell
uncovered=$(ruby -ryaml -e '
  cfg = YAML.load_file(".github/dependabot.yml")
  dirs = cfg["updates"].select { |u| u["package-ecosystem"] == "github-actions" }
           .flat_map { |u| [u["directory"], *Array(u["directories"])].compact }
  Dir.glob(".github/actions/*/action.y{a,}ml").map { |f| "/" + File.dirname(f) }.sort.each do |d|
    puts d unless dirs.include?(d)
  end' 2>&1)
if [ -z "$uncovered" ]; then
  ok "dependabot covers every composite action directory"
else
  bad "composite action directories dependabot never bumps (add them to .github/dependabot.yml directories:)" "$uncovered"
fi

# Remote scripts executed straight off the network (fleet-audit#805). CI here
# installed actionlint with `bash <(curl -s …/main/scripts/download-actionlint.bash)`:
# whatever sat on a third party's branch that minute ran in the job, and `-s`
# without `-f` would feed an HTTP error page to bash. A tool is installed the
# way install-mcp-publisher does it — a pinned release asset, SHA-256 checked.
piped_remote() {
  printf '%s\n' "$1" | grep -E '(bash|sh)[[:space:]]+<\([[:space:]]*(curl|wget)|(curl|wget)[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh([[:space:]]|$)' || true
}
for line in \
  'bash <(curl -s https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) 1.7.7' \
  'curl -fsSL https://example.com/install.sh | bash' \
  'curl -sL https://example.com/install.sh | sudo sh' \
  'wget -qO- https://example.com/i.sh | sh -s -- 1.2.3'; do
  if [ -n "$(piped_remote "$line")" ]; then ok "remote-script check catches: $line"
  else bad "remote-script check misses a piped remote script" "$line"; fi
done
for line in \
  'curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v1.7.12/x.tar.gz" -o "$tarball"' \
  'echo "${SHA}  ${tarball}" | sha256sum -c -' \
  'gh api user --jq .login | head -1'; do
  if [ -n "$(piped_remote "$line")" ]; then bad "remote-script check flags a safe line" "$line"
  else ok "remote-script check allows: $line"; fi
done
remote_hits=$(grep -rEn --include='*.yml' --include='*.yaml' '(curl|wget)' .github templates 2>/dev/null \
  | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' | while IFS= read -r hit; do
      [ -n "$(piped_remote "${hit#*:*:}")" ] && printf '%s\n' "$hit"
    done)
if [ -z "$remote_hits" ]; then
  ok "no workflow pipes a downloaded script into a shell"
else
  bad "a downloaded script is piped into a shell (download a pinned release asset and verify its SHA-256)" "$remote_hits"
fi
# The same finding: this repo's own CI ran on the repo-default token. It only
# reads the checkout, so it asks for exactly that.
# shellcheck disable=SC2016  # ruby source, not shell
ci_perms=$(ruby -ryaml -e 'print YAML.load_file(".github/workflows/ci.yml")["permissions"].inspect')
if [ "$ci_perms" = '{"contents"=>"read"}' ] || [ "$ci_perms" = '{"contents" => "read"}' ]; then
  ok "ci.yml runs on a read-only token (permissions: contents: read)"
else
  bad "ci.yml runs on a read-only token" "top-level permissions: $ci_perms"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

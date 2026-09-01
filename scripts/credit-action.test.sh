#!/usr/bin/env bash
# Unit tests for credit-contributors' embedded bash — the half credit.test.py
# cannot reach.
#
# credit.test.py covers amend_changelog.py in isolation. The step around it
# owns the decisions that actually determine whether a contributor is thanked:
# who counts as external, which of the two targets still needs crediting, and
# whether the amended body is pushed back. None of that was exercised.
#
# Extracted from the shipped action.yml at run time (same technique as
# gate.test.sh / followup.test.sh), so this runs the file byte-for-byte with no
# test-only hooks in it.
#
# Usage: bash scripts/credit-action.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACT="$HERE/.github/actions/credit-contributors/action.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

ruby -ryaml -e '
  act = YAML.load_file(ARGV[0])
  step = act["runs"]["steps"].find { |s| s["run"] }
  abort("could not find a run step in credit-contributors") unless step
  File.write(ARGV[1], step["run"])
' "$ACT" "$TMP/credit.sh" || { echo "FAIL: could not extract step from $ACT"; exit 1; }

# --- fakes -----------------------------------------------------------------
# git is inert: the step's fetch/checkout/commit/push must not touch a real
# repo, and the assertions are about gh and the files, not about git.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  diff) [ -f "$WORK/changelog-dirty" ] && exit 1 || exit 0 ;;  # 1 = has changes
esac
exit 0
STUB

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$*" in
  "pr view "*"--json body"*)
    [ "${BODY_UNREADABLE:-}" = "1" ] && exit 1
    cat "$WORK/body-in.md" ;;
  "api repos/"*"/pulls/"*)
    # `[login, type, association]` for the PR under test, or a 404.
    [ "${PR_404:-}" = "1" ] && { echo '{"message":"Not Found"}'; exit 1; }
    printf '%s\t%s\t%s\n' "${AUTHOR:-Weetermachine}" "${UTYPE:-User}" "${ASSOC:-CONTRIBUTOR}" ;;
  "pr edit "*"--body-file"*)
    # Record the body that would have been pushed back.
    for a in "$@"; do [ -f "$a" ] && cp "$a" "$WORK/body-pushed.md"; done ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Built as separate literals, never with `${var/pat/repl}`: bash treats the
# left side as a GLOB, and these lines are full of `*` and `[...]`, so the
# substitution silently matched the wrong span and a "both already credited"
# fixture came out still uncredited.
ENTRY='* **chores:** inline category_id ([#148](https://github.com/o/r/issues/148)) ([abc](https://github.com/o/r/commit/abc))'
ENTRY_CREDITED='* **chores:** inline category_id (thanks @Weetermachine) ([#148](https://github.com/o/r/issues/148)) ([abc](https://github.com/o/r/commit/abc))'

# setup_case [VAR=VAL ...] — fresh $WORK plus the case's env. Runs NOTHING:
# the step is invoked exactly once per case, by new_case, after the fixtures
# exist. Invoking here too would spend a run on an empty dir, which exits
# early at the CHANGELOG.md check and proves nothing.
setup_case() {
  WORK="$(mktemp -d "$TMP/case.XXXXXX")"; export WORK
  export GH_CALLS="$WORK/gh"; : > "$GH_CALLS"
  unset BODY_UNREADABLE PR_404 AUTHOR UTYPE ASSOC
  export GH_TOKEN=x REPO=o/r EXCLUDE="" \
         PR_JSON='{"headBranchName":"release-please--x","number":9}' \
         GITHUB_ACTION_PATH="$HERE/.github/actions/credit-contributors"
  local kv; for kv in "$@"; do export "${kv?}"; done
}

wrote_changelog() { grep -q "thanks @" "$WORK/CHANGELOG.md" 2>/dev/null && echo yes || echo no; }
pushed_body()     { [ -f "$WORK/body-pushed.md" ] && echo yes || echo no; }

check() { local want="$2" got="$3"; [ "$got" = "$want" ] && ok "$1" || bad "$1" "got '$got', wanted '$want'"; }

# new_case <changelog> <body> [VAR=VAL ...] — lay the fixtures down, then run
# the extracted step once.
new_case() {
  local cl="$1" body="$2"; shift 2
  setup_case "$@"
  printf '%s\n' "$cl"   > "$WORK/CHANGELOG.md"
  printf '%s\n' "$body" > "$WORK/body-in.md"
  : > "$WORK/changelog-dirty"
  ( cd "$WORK" && bash "$TMP/credit.sh" ) > "$WORK/out" 2>&1
}

changelog_with() { printf '# Changelog\n\n## [1.0.0](x) (2026-09-01)\n\n%s' "$1"; }
body_with()      { printf ':robot: release\n\n## [1.0.0](x) (2026-09-01)\n\n%s' "$1"; }

CL="$(changelog_with "$ENTRY")"
BODY="$(body_with "$ENTRY")"
CL_CREDITED="$(changelog_with "$ENTRY_CREDITED")"
BODY_CREDITED="$(body_with "$ENTRY_CREDITED")"

echo "── an external contributor is credited in BOTH targets ──"
new_case "$CL" "$BODY"
check "changelog amended"  yes "$(wrote_changelog)"
check "PR body pushed back" yes "$(pushed_body)"
check "the pushed body carries the credit" yes \
  "$(grep -q 'thanks @Weetermachine' "$WORK/body-pushed.md" 2>/dev/null && echo yes || echo no)"

echo
echo "── the regression this exists for ──"
# Changelog already credited (committed on the branch and survives), body NOT
# (release-please regenerates it every run). Gating on the changelog alone left
# the body uncredited forever.
new_case "$CL_CREDITED" "$BODY"
check "an already-credited changelog still fixes the body" yes "$(pushed_body)"

echo
echo "── nothing to do ──"
new_case "$CL_CREDITED" "$BODY_CREDITED"
check "both already credited → no PR edit" no "$(pushed_body)"

echo
echo "── who counts as external ──"
new_case "$CL" "$BODY" ASSOC=OWNER
check "OWNER is not credited"        no "$(pushed_body)"
new_case "$CL" "$BODY" ASSOC=MEMBER
check "MEMBER is not credited"       no "$(pushed_body)"
new_case "$CL" "$BODY" ASSOC=COLLABORATOR
check "COLLABORATOR is not credited" no "$(pushed_body)"
new_case "$CL" "$BODY" UTYPE=Bot
check "a Bot is never credited (dependabot reports CONTRIBUTOR)" no "$(pushed_body)"
new_case "$CL" "$BODY" EXCLUDE=Weetermachine
check "an excluded login is not credited" no "$(pushed_body)"

echo
echo "── failures degrade, never corrupt ──"
new_case "$CL" "$BODY" PR_404=1
check "a 404 credits nobody (skylight-mcp#135)" no "$(pushed_body)"
check "and writes no JSON into the changelog"   no "$(wrote_changelog)"
new_case "$CL" "$BODY" BODY_UNREADABLE=1
check "an unreadable body still credits the changelog" yes "$(wrote_changelog)"
check "and never pushes a blank description"           no  "$(pushed_body)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Unit tests for the two halves of the auto-review follow-up lifecycle:
#
#   1. `Open or update follow-up issue` in reusable-pr-auto-review.yml — the
#      step that BUILDS the checklist. Its failure mode is the one from issue
#      #139: a later review round rewrites the body from scratch and silently
#      un-ticks items a human had verified and ticked, so the issue reports
#      unfixed work that was already fixed and pushed. Nothing errors; the
#      damage is a human redoing work they already did.
#
#   2. `Sweep every fleet repo for orphaned follow-up issues` in
#      followup-orphan-sweep.yml — the step that RETIRES a checklist whose PR
#      closed without merging. The documented flow only ever closes a follow-up
#      issue by its PR merging, so a duplicate/superseded PR leaves the issue
#      pointing at a dead PR, reading exactly like a live follow-up. In
#      mcp-host that shipped two uncorrected docs claims to main.
#
# Both are bash inside YAML — invisible to actionlint beyond syntax — and both
# fail quietly rather than loudly, which is precisely the shape that needs a
# test. Like gate.test.sh, the scripts are EXTRACTED from the shipped YAML at
# run time rather than copied here, so a workflow change that isn't reflected
# in these expectations fails instead of silently drifting.
#
# Usage: bash scripts/followup.test.sh
set -uo pipefail   # deliberately no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
SWEEP_WF="$HERE/.github/workflows/followup-orphan-sweep.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# --- extract the two shipped scripts ---------------------------------------
ruby -ryaml -e '
  rev = YAML.load_file(ARGV[0])
  step = rev["jobs"]["review"]["steps"].find { |s| s["name"] == "Open or update follow-up issue" }
  abort("could not find `Open or update follow-up issue` step") unless step
  File.write(ARGV[1], step["run"])
  File.write(ARGV[1] + ".shell", step["shell"].to_s)

  sw = YAML.load_file(ARGV[2])
  sstep = sw["jobs"].values.first["steps"].find { |s| s["name"] =~ /Sweep/ }
  abort("could not find the sweep step") unless sstep
  File.write(ARGV[3], sstep["run"])
  File.write(ARGV[3] + ".shell", sstep["shell"].to_s)
' "$REVIEW_WF" "$TMP/followup.sh" "$SWEEP_WF" "$TMP/sweep.sh" \
  || { echo "FAIL: could not extract steps from $REVIEW_WF / $SWEEP_WF"; exit 1; }

REPO=chrischall/example-mcp

# ===========================================================================
# 1. Checklist construction — tick preservation and provenance
# ===========================================================================

mkdir -p "$TMP/bin1"
cat > "$TMP/bin1/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
prev=""
body_file=""
for a in "$@"; do
  [ "$prev" = "--body-file" ] && body_file="$a"
  prev="$a"
done
case "$*" in
  "label create"*)        exit 0 ;;
  *"issues?state=open"*)  cat "$FIX_EXISTING" ;;
  "issue view"*)          [ -s "$FIX_OLD_BODY" ] && cat "$FIX_OLD_BODY"; exit 0 ;;
  "issue edit"*)          [ -n "$body_file" ] && cp "$body_file" "$CAPTURED"; exit 0 ;;
  "issue create"*)        [ -n "$body_file" ] && cp "$body_file" "$CAPTURED"
                          echo "https://github.com/x/y/issues/999" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin1/gh"

# followup_case <name> <existing-issue-or-empty> <old-body> <structured-out> <assertion-fn>
followup_case() {
  local name="$1" existing="$2" old="$3" out="$4" assert_fn="$5"
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  printf '%s' "$existing" > "$dir/existing"
  printf '%s' "$old"      > "$dir/oldbody"
  : > "$dir/captured"; : > "$dir/gh"
  (
    export PATH="$TMP/bin1:$PATH"
    export GITHUB_OUTPUT="$dir/out" GH_CALLS="$dir/gh" \
           FIX_EXISTING="$dir/existing" FIX_OLD_BODY="$dir/oldbody" CAPTURED="$dir/captured"
    export GH_TOKEN=x PR=42 REPO="$REPO" PR_TITLE="a change" VERDICT=warn \
           HEAD_SHA=abcdef1234567890abcdef1234567890abcdef12 OUT="$out"
    bash -e "$TMP/followup.sh"
  ) >"$dir/log" 2>&1
  if "$assert_fn" "$dir/captured"; then
    ok "followup: $name"
  else
    bad "followup: $name" "$(sed 's/^/     /' "$dir/captured" | head -30)
     --- log ---
$(sed 's/^/     /' "$dir/log" | head -10)"
  fi
}

FINDINGS='{"verdict":"warn","summary":"s","important_findings":["Fix DEPLOY.md min_machines_running"],"nits":["USAGE.md billing denominator claim"]}'

assert_fresh_unticked() {
  grep -qF -- '- [ ] Fix DEPLOY.md min_machines_running' "$1" &&
  grep -qF -- '- [ ] USAGE.md billing denominator claim' "$1"
}
assert_important_tick_kept() {
  grep -qF -- '- [x] Fix DEPLOY.md min_machines_running' "$1"
}
assert_nit_tick_kept() {
  grep -qF -- '- [x] USAGE.md billing denominator claim' "$1"
}
assert_reworded_not_ticked() {
  grep -qF -- '- [ ] Fix DEPLOY.md min_machines_running' "$1"
}
assert_sha_stamped() {
  grep -qF 'abcdef1' "$1"
}
assert_fallback() {
  grep -qF 'No structured findings were captured' "$1"
}

echo "── Follow-up checklist construction ──"
followup_case "new issue: every item starts unticked" "" "" "$FINDINGS" assert_fresh_unticked
followup_case "records the commit the review ran against" "" "" "$FINDINGS" assert_sha_stamped
followup_case "re-review keeps a human's tick on an important finding" \
  "7" '<!-- auto-review-followup:PR-42 -->

### 🔴 Important
- [x] Fix DEPLOY.md min_machines_running
' "$FINDINGS" assert_important_tick_kept
followup_case "re-review keeps a human's tick on a nit" \
  "7" '<!-- auto-review-followup:PR-42 -->

### 🟡 Nits
- [x] USAGE.md billing denominator claim
' "$FINDINGS" assert_nit_tick_kept
followup_case "a reworded finding comes back unticked (never a false tick)" \
  "7" '<!-- auto-review-followup:PR-42 -->

### 🔴 Important
- [x] Fix DEPLOY.md min_machines_running setting
' "$FINDINGS" assert_reworded_not_ticked
followup_case "an unticked prior item stays unticked" \
  "7" '<!-- auto-review-followup:PR-42 -->

### 🔴 Important
- [ ] Fix DEPLOY.md min_machines_running
' "$FINDINGS" assert_fresh_unticked
followup_case "empty structured output still produces a body" "" "" "" assert_fallback

# ===========================================================================
# 2. Orphan sweep
# ===========================================================================

mkdir -p "$TMP/bin2"
cat > "$TMP/bin2/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
case "$*" in
  *"/comments"*)
      # Page 2 exists only for a caller that passes --paginate. Dropping it
      # (issue #143) hides a marker there and earns a duplicate nag daily.
      cat "$FIX_COMMENTS"
      case "$*" in *--paginate*) cat "$FIX_COMMENTS_P2" ;; esac
      ;;
  *"issues?state=open"*)  cat "$FIX_ISSUES" ;;
  *"/pulls/"*)
      path=""
      for a in "$@"; do case "$a" in */pulls/*) path="$a" ;; esac; done
      grep "^${path##*/} " "$FIX_PULLS" | cut -d' ' -f2- ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin2/gh"

# sweep_case <name> <issues> <pulls> <comments> <want_comments> <want_labels> [ENV=val ...]
#
# <comments> is what the already-flagged lookup PRINTS: the id of each comment
# carrying the orphaned marker, one per line, empty when none match. A
# `---PAGE---` line splits page 1 from page 2 of the comment list.
sweep_case() {
  local name="$1" issues="$2" pulls="$3" comments="$4" want_c="$5" want_l="$6"; shift 6
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  printf '%s\n' "$issues"   > "$dir/issues"
  printf '%s\n' "$pulls"    > "$dir/pulls"
  : > "$dir/comments"; : > "$dir/comments.p2"
  local target="$dir/comments" line
  while IFS= read -r line; do
    if [ "$line" = "---PAGE---" ]; then target="$dir/comments.p2"; continue; fi
    [ -n "$line" ] && printf '%s\n' "$line" >> "$target"
  done <<< "$comments"
  : > "$dir/gh"
  cat > "$dir/fleet.json" <<JSON
{"defaults":{"pat_secret":"RELEASE_PAT"},"repos":[{"repo":"$REPO"}]}
JSON
  (
    cd "$dir" || exit 1
    export PATH="$TMP/bin2:$PATH"
    export GH_CALLS="$dir/gh" FIX_ISSUES="$dir/issues" FIX_PULLS="$dir/pulls" \
           FIX_COMMENTS="$dir/comments" FIX_COMMENTS_P2="$dir/comments.p2"
    export GITHUB_REPOSITORY=chrischall/workflows GITHUB_STEP_SUMMARY="$dir/summary" \
           RELEASE_PAT=tok NULLNET_RELEASE_PAT=tok2
    local kv; for kv in "$@"; do export "${kv?}"; done
    bash -e "$TMP/sweep.sh"
  ) >"$dir/log" 2>&1
  local got_c got_l
  got_c=$(grep -c 'issue comment' "$dir/gh" || true)
  got_l=$(grep -c -- '--add-label orphaned-followup' "$dir/gh" || true)
  if [ "$got_c" = "$want_c" ] && [ "$got_l" = "$want_l" ]; then
    ok "sweep: $name (comments=$got_c, labels=$got_l)"
  else
    bad "sweep: $name" "got comments=$got_c labels=$got_l; wanted $want_c/$want_l
     $(sed 's/^/     /' "$dir/log" | head -12)
     $(sed 's/^/     gh> /' "$dir/gh" | head -12)"
  fi
}

echo "── Orphaned follow-up sweep ──"
sweep_case "PR closed without merging → comment + label" "5 324" "324 closed false" "" 1 1
sweep_case "PR still open → left alone"                  "5 324" "324 open false"   ""  0 0
sweep_case "PR merged (deferred items) → left alone"     "5 324" "324 closed true"  ""  0 0
sweep_case "already flagged → no duplicate comment"      "5 324" "324 closed false" "90210" 0 0
sweep_case "already flagged on comment page 2 → no duplicate comment" \
  "5 324" "324 closed false" "---PAGE---
90211" 0 0
sweep_case "no follow-up issues → no calls"              ""      ""                 ""  0 0
sweep_case "several orphans in one repo"                 "5 324
6 400" "324 closed false
400 closed false" "" 2 2
sweep_case "repo whose PAT is absent is skipped, not probed" "5 324" "324 closed false" "" 0 0 RELEASE_PAT=

echo
# The harness must run each extracted step under the flags GitHub gives it —
# `bash -e` for a workflow `run:` block, `bash -eo pipefail` for a composite
# action's `shell: bash`. Under a plain `bash` an unguarded non-zero continues
# here and ABORTS in production, so every "the step still does its second job"
# assertion above silently tests nothing. That is exactly how #213 shipped a
# de-arm that skipped `--disable-auto` whenever the label call failed.
if grep -nE 'bash +"\$(TMP|WORK)/' "$0" >/dev/null; then
  bad "extracted steps run under an aborting shell" \
      "$(grep -nE 'bash +"\$(TMP|WORK)/' "$0" | head -3) — add -e (or -eo pipefail for a composite step)"
else ok "extracted steps run under an aborting shell, as GitHub does"; fi

# ...and that `-e` is still the RIGHT flag set. `-o pipefail` is not a free
# extra safety margin: production does not set it for a `run:` block with no
# `shell:`, so a failing non-final pipeline command aborts here and sails on
# there — the same blind spot as a plain `bash`, pointed the other way. If a
# step ever declares `shell: bash`, GitHub adds pipefail and so must the runner.
for shellfile in "$TMP"/*.sh.shell; do
  [ -e "$shellfile" ] || continue
  declared="$(cat "$shellfile")"
  stepname="$(basename "$shellfile" .sh.shell)"
  if [ -z "$declared" ]; then
    ok "$stepname: no shell: override, so -e alone matches production"
  else
    bad "$stepname: shell mismatch" \
        "the step now declares \`shell: $declared\`, which GitHub runs with -o pipefail — add it to the runner"
  fi
done
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

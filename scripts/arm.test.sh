#!/usr/bin/env bash
# Unit tests for reusable-pr-auto-review.yml's
# `Arm or de-arm auto-merge from the verdict` step.
#
# Extracted from the shipped YAML at run time (same technique as
# dedupe.test.sh / verdict.test.sh / gate.test.sh), so this exercises the file
# byte-for-byte with no test-only hooks in it.
#
# Two things are asserted here, and the second is the one that was missing.
#
# 1. A `pass`/`warn` run must not arm a PR another run has already failed.
#    (chrischall/fetchproxy#274 merged over a red verdict.)
#
# 2. A `fail` run must DE-ARM, not merely decline to arm. Declining is a no-op
#    on a PR that is already armed, and on #274 the losing `fail` review
#    reached this step 66 seconds after the winning `pass` had armed it:
#
#      run …348591 (opened)  verdict posted 18:19:44  ARMED 18:19:46
#      run …362171 (labeled) verdict posted 18:20:50  "not arming"  18:20:54
#
#    De-arming means BOTH removing `ready-to-merge` and calling
#    `gh pr merge --disable-auto`. The label is only the trigger:
#    reusable-auto-merge.yml calls `gh pr merge --auto --squash` the moment it
#    lands, and GitHub then merges on green whatever the label does afterwards.
#    Removing the label alone looks like a fix and changes nothing.
#
# Usage: bash scripts/arm.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

# Every extracted step is run under `bash -e`, because that is the shell
# GitHub gives a `run:` block (`shell: /usr/bin/bash -e {0}`). Running them
# under a plain `bash` hid an entire failure class: an unguarded non-zero
# aborts the step mid-way in production and completes it here, so a step that
# skips its second obligation on a transient error tests green.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME="Arm or de-arm auto-merge from the verdict"
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == ARGV[2] }
  abort("could not find `#{ARGV[2]}` step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/arm.sh" "$STEP_NAME" \
  || { echo "FAIL: could not extract step from $WF"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  # The recorded verdict on the PR — what another run may already have posted.
  "pr view"*comments*)        printf '%s' "$RECORDED_VERDICT"; exit 0 ;;
  # State/labels/auto-merge, read before de-arming. The sentinel models the
  # read FAILING (non-zero, no output), which is what the step's `|| true`
  # turns into an empty STATE.
  "pr view"*)                 [ "$PR_STATE" = "__UNREADABLE__" ] && exit 1
                              printf '%s' "$PR_STATE"; exit 0 ;;
  "pr edit"*--add-label*)     exit 0 ;;
  "pr edit"*--remove-label*)  [ "${LABEL_EDIT_FAILS:-}" = 1 ] && exit 1
                              exit 0 ;;
  "pr merge"*--disable-auto*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# An OPEN PR that a concurrent run has already armed: label on, auto-merge
# enabled. This is the state the losing `fail` run finds.
ARMED_PR='{"state":"OPEN","labels":[{"name":"bug"},{"name":"ready-to-merge"}],"autoMergeRequest":{"enabledAt":"2026-09-02T18:19:46Z"}}'
# An OPEN PR nobody has armed.
CLEAN_PR='{"state":"OPEN","labels":[{"name":"bug"}],"autoMergeRequest":null}'
# Auto-merge enabled but the label already gone — the half-state that proves
# the two de-arm actions are independent, not one guarded by the other.
NOLABEL_PR='{"state":"OPEN","labels":[{"name":"bug"}],"autoMergeRequest":{"enabledAt":"2026-09-02T18:19:46Z"}}'
# The race already lost: the PR merged before this run got here.
MERGED_PR='{"state":"MERGED","labels":[{"name":"ready-to-merge"}],"autoMergeRequest":null}'

# run_case <name> <verdict> <recorded comment> <pr state json>
# Exports CALLS for the assertions that follow each case.
run_case() {
  local name="$1" verdict="$2" recorded="${3:-}" state="${4:-$CLEAN_PR}"
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export CALLS="$dir/calls"; : > "$CALLS"
  export GH_TOKEN=x PR=274 REPO=chrischall/fetchproxy VERDICT="$verdict" \
         RECORDED_VERDICT="$recorded" PR_STATE="$state"
  bash -e "$TMP/arm.sh" >"$dir/log" 2>&1
  CASE="$name"; LOG="$dir/log"
}

did() { grep -qF -- "$1" "$CALLS"; }
# The expectation goes IN the line. Printing only the action name made
# `ok  empty verdict: arms` the report for a case asserting it must NOT arm,
# so a whole green suite read as the opposite of what it checked.
assert() { # assert <action> <yes|no> <needle>
  local want="$2" needle="$3" got=no
  did "$needle" && got=yes
  if [ "$got" = "$want" ]; then ok "$CASE: $1=$want"
  else bad "$CASE: $1=$want" "got $1=$got, log: $(tr '\n' ' ' < "$LOG")"; fi
}
armed()     { assert "arms" "$1" "--add-label"; }
unlabeled() { assert "removes-label" "$1" "--remove-label"; }
unarmed()   { assert "disables-auto-merge" "$1" "--disable-auto"; }
# Positive control for the cases that assert only ABSENCE: a step that died on
# line one also makes no calls, so absence alone cannot tell "correctly did
# nothing" from "never ran".
reached() { # reached <needle in log>
  if grep -qF -- "$1" "$LOG"; then ok "$CASE: reached \"$1\""
  else bad "$CASE: reached \"$1\"" "log: $(tr '\n' ' ' < "$LOG")"; fi
}

FAIL_COMMENT='<!-- auto-review-verdict -->
🔴 Auto-review verdict: **fail** — breaks the classifier.'
PASS_COMMENT='<!-- auto-review-verdict -->
✅ Auto-review verdict: **pass** — looks good.'
WARN_COMMENT='<!-- auto-review-verdict -->
🟡 Auto-review verdict: **warn** — nits only.'

echo "── arming ──"
run_case "pass" pass "$PASS_COMMENT"; armed yes
run_case "warn (nits do not block)" warn "$WARN_COMMENT"; armed yes
# No recorded verdict yet (this run is first to finish) — must still arm, or
# the ordinary single-review path would stop arming entirely.
run_case "pass with nothing recorded yet" pass ""; armed yes

echo "── not arming ──"
run_case "empty verdict" "" ""; armed no; reached "not arming"
# The #209 half: this run said pass, but a concurrent run already recorded a
# fail. Arming here is what merged fetchproxy#274 over a red verdict.
run_case "pass over a recorded fail" pass "$FAIL_COMMENT"; armed no
run_case "warn over a recorded fail" warn "$FAIL_COMMENT"; armed no

echo "── de-arming (the #274 ordering: fail finishes second) ──"
# The half #209 missed. Declining to arm is a no-op against a PR the winning
# run armed a minute ago; only actively de-arming can still stop the merge.
run_case "fail on an armed PR" fail "$FAIL_COMMENT" "$ARMED_PR"
armed no; unlabeled yes; unarmed yes
# Removing the label is NOT enough on its own and NOT sufficient reason to
# skip the other half: auto-merge outlives its trigger.
run_case "fail on a PR armed after its label was removed" fail "$FAIL_COMMENT" "$NOLABEL_PR"
unlabeled no; unarmed yes
# Nothing to undo — de-arming an unarmed PR must be quiet, not noisy.
run_case "fail on a PR nobody armed" fail "$FAIL_COMMENT" "$CLEAN_PR"
unlabeled no; unarmed no; reached "De-arming #274"
# A pass/warn run that defers to a recorded fail must clean up too: the fail
# run may itself have been the one that lost the race.
run_case "pass deferring to a recorded fail also de-arms" pass "$FAIL_COMMENT" "$ARMED_PR"
armed no; unlabeled yes; unarmed yes

echo "── de-arming is not for uncertainty ──"
# "No verdict" means un-reviewed, not red. De-arming a PR another run
# legitimately armed on its own pass would turn every flaky structured-output
# run into a silent merge block.
run_case "an empty verdict never de-arms" "" "$PASS_COMMENT" "$ARMED_PR"
armed no; unlabeled no; unarmed no; reached "not arming"

echo "── a read failure must not cost the de-arm ──"
# The state read only saves two no-op calls. If it fails, de-arm blind:
# undoing an arming that was never there is harmless, skipping one that WAS
# there merges a red PR.
run_case "fail when the PR state is unreadable" fail "$FAIL_COMMENT" "__UNREADABLE__"
unlabeled yes; unarmed yes

echo "── the race already lost ──"
# Too late to stop: say so loudly instead of pretending it was handled. The
# findings live on in the follow-up issue; the fix goes on a new PR.
run_case "fail on an already-merged PR" fail "$FAIL_COMMENT" "$MERGED_PR"
unlabeled no; unarmed no; reached "De-arming #274"
if grep -q "::warning::" "$LOG"; then ok "$CASE: warns that the PR merged over a fail"
else bad "$CASE: warns that the PR merged over a fail" "no ::warning:: in: $(tr '\n' ' ' < "$LOG")"; fi

echo "── De-arm on new commits (rereview_on_push) ──"
# The same two-part obligation, in the other de-arm. This step exists so a
# force-push cannot merge new code on a standing verdict — but removing the
# label alone leaves auto-merge ENABLED, so GitHub still merges the new diff
# the moment CI goes green. Live on chrischall/opencode-copilot-plugin.
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == "De-arm on new commits" }
  abort("could not find `De-arm on new commits` step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/pushdearm.sh" || { echo "FAIL: could not extract De-arm on new commits"; exit 1; }

push_dearm_case() { # push_dearm_case <name> [LABEL_EDIT_FAILS=1]
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export CALLS="$dir/calls"; : > "$CALLS"
  export GH_TOKEN=x PR=274 REPO=chrischall/fetchproxy PR_STATE="$ARMED_PR" \
         LABEL_EDIT_FAILS="${2:-}"
  bash -e "$TMP/pushdearm.sh" >"$dir/log" 2>&1
  CASE="$1"; LOG="$dir/log"
  unset LABEL_EDIT_FAILS
}

push_dearm_case "de-arm on push"
unlabeled yes
unarmed yes

# The two calls are independent obligations, and the FIRST one failing must not
# take the second with it. `bash -e` aborts the step on an unguarded non-zero,
# so a transient gh hiccup on the label would skip `--disable-auto` entirely —
# leaving auto-merge live on a PR the pipeline believes it de-armed, which is
# the bug this step exists to prevent.
push_dearm_case "de-arm on push when the label edit fails" 1
unarmed yes

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

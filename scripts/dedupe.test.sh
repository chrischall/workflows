#!/usr/bin/env bash
# Unit tests for reusable-pr-auto-review.yml's
# `Stand down if another run is already reviewing this commit` step.
#
# Extracted from the shipped YAML at run time (same technique as
# arm.test.sh / verdict.test.sh / gate.test.sh), so this exercises the file
# byte-for-byte with no test-only hooks in it.
#
# Why this exists: opening a PR with `--label` fires `opened` and `labeled`
# back-to-back, and the stub puts them in SEPARATE concurrency groups on
# purpose (a shared group lets the labeled event displace the queued review,
# #182). So two reviews of the same diff run concurrently. They are LLM
# reviews and can disagree — on chrischall/fetchproxy#274 they did, and the
# faster `pass` armed the PR 66 seconds before the slower `fail` existed:
#
#   run …348591 (opened)  model 79s   verdict posted 18:19:44  ARMED 18:19:46
#   run …362171 (labeled) model 140s  verdict posted 18:20:50  (too late)
#
# Consulting the recorded verdict before arming (#209) does not reach this:
# at 18:19:44 the only comment on record was the arming run's own `pass`.
# The failing review is systematically the SLOWER one — it has findings to
# write — so the losing ordering is the common one, not the rare one.
#
# The fix is for the second run never to start. Ordering is by run id, which
# is total and known to both runs, so exactly one stands down and no run can
# ever wait on a run that is waiting on it.
#
# Usage: bash scripts/dedupe.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

# The extracted step runs under `bash -e`, the shell GitHub gives a `run:`
# block (`shell: /usr/bin/bash -e {0}`). Under a plain `bash` an unguarded
# non-zero completes the step here and aborts it in production, which is how a
# step that skips its remaining work on a transient error tests green (#213).

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME="Stand down if another run is already reviewing this commit"
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == ARGV[2] }
  abort("could not find `#{ARGV[2]}` step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/solo.sh" "$STEP_NAME" \
  || { echo "FAIL: could not extract step from $WF"; exit 1; }

# --- fake gh ---------------------------------------------------------------
# Serves fixture JSON per endpoint and APPLIES the step's own `--jq` filter
# with real jq, so the filters in the shipped YAML are what get tested — a
# stub that returned pre-filtered scalars would pass even if the filter in
# the workflow were nonsense.
#
# A fixture with a `.2` sibling answers the SECOND call onward, which is how
# the poll case models an earlier run whose review job has not been created
# yet when we first look.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
endpoint=""; filter=""; want_jq=0
for a in "$@"; do
  if [ "$want_jq" = 1 ]; then filter="$a"; want_jq=0; continue; fi
  case "$a" in
    --jq) want_jq=1 ;;
    api|-*) ;;
    *) [ -z "$endpoint" ] && endpoint="$a" ;;
  esac
done

case "$endpoint" in
  *"/actions/runs?head_sha="*) fixture="$FIX/runs.json" ;;
  *"/actions/runs/"*"/jobs")   fixture="$FIX/jobs-${endpoint##*/actions/runs/}"; fixture="${fixture%/jobs}.json" ;;
  *"/actions/runs/"*)          fixture="$FIX/run-${endpoint##*/actions/runs/}.json" ;;
  *) exit 1 ;;
esac

# Call counter per fixture, so a `.2` variant can answer later polls.
key="$(basename "$fixture")"
n=$(( $(cat "$FIX/.calls.$key" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FIX/.calls.$key"
[ "$n" -ge 2 ] && [ -f "$fixture.2" ] && fixture="$fixture.2"

[ -f "$fixture" ] || exit 1
echo "$endpoint" >> "$FIX/.calls.log"
if [ -n "$filter" ]; then jq -r "$filter" "$fixture"; else cat "$fixture"; fi
STUB
chmod +x "$TMP/bin/gh"

# The step polls for an earlier run's review job to appear. Stub sleep so the
# 60s ceiling costs nothing here; the real interval stays in the YAML.
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/sleep"
export PATH="$TMP/bin:$PATH"

# job(<status> <conclusion>) -> a jobs payload with a review job in that state.
# The `context` job is always present and never matches: it is the reason the
# filter keys on a name ENDING in "review" rather than merely containing it.
job_payload() {
  jq -nc --arg s "$1" --arg c "$2" '
    {jobs: [
      {name: "review / context", status: "completed", conclusion: "success"},
      {name: "review / review",  status: $s, conclusion: (if $c == "" then null else $c end)}
    ]}'
}
no_review_job='{"jobs":[{"name":"review / context","status":"in_progress","conclusion":null}]}'

# run_case <name> <expected eligible> <setup fn>
# The run under test is always id 200 of workflow 7 on SHA deadbee.
run_case() {
  local name="$1" expect="$2" setup="$3"
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export FIX="$dir"
  export GITHUB_OUTPUT="$dir/out"; : > "$GITHUB_OUTPUT"
  export GH_TOKEN=pat REPO=chrischall/fetchproxy EVENT=pull_request \
         RUN_ID=200 SHA=deadbee ELIGIBLE=true
  "$setup" "$dir"
  bash -e "$TMP/solo.sh" >"$dir/log" 2>&1
  local got; got="$(grep -o 'eligible=[a-z]*' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"
  if [ "$got" = "$expect" ]; then ok "$name"
  else bad "$name" "expected eligible=$expect, got eligible=${got:-<none>} — log: $(tr '\n' ' ' < "$dir/log")"; fi
  LAST_DIR="$dir"
}

# Every case needs the run's own workflow id resolvable.
seed_self() { echo '{"id":200,"workflow_id":7,"status":"in_progress"}' > "$1/run-200.json"; }

# --- A: nothing else is running -------------------------------------------
case_alone() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":200,"workflow_id":7}]}' > "$1/runs.json"
}
run_case "A: the only run of this commit reviews it" true case_alone

# --- B: the fetchproxy#274 shape ------------------------------------------
# An earlier run of the same workflow on the same commit is mid-review. This
# run is the `labeled` twin and must not start a second review.
case_earlier_reviewing() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  job_payload in_progress "" > "$1/jobs-100.json"
}
run_case "B: stands down while an earlier run is reviewing this commit" false case_earlier_reviewing

# --- C: a deliberate re-review is NOT a duplicate --------------------------
# Adding a whitelisted label re-triggers the review on purpose — adding
# `release-notes` is the documented fix for a finding this reviewer itself
# issues. The earlier run has FINISHED, so its verdict is already recorded
# and this run is the re-review, not a twin. Suppressing it would strand the
# PR on a `fail` nothing can clear (flightaware-mcp#63's shape).
case_earlier_finished() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"completed"}' > "$1/run-100.json"
  job_payload completed success > "$1/jobs-100.json"
}
run_case "C: a label re-review still runs after the first review finished" true case_earlier_finished

# --- D: an earlier run that skipped its review job -------------------------
# A release-please PR before `release-ready`: the `opened` run exists and is
# live, but its review job skipped. It is reviewing nothing, so deferring to
# it would leave the release PR with no verdict at all.
case_earlier_skipped() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  job_payload completed skipped > "$1/jobs-100.json"
}
run_case "D: an earlier run whose review job SKIPPED is not a reviewer" true case_earlier_skipped

# --- E: the review job has not been created yet ----------------------------
# The earlier run's `context` job is still going, so its `review` job does not
# exist yet. This is the only genuinely unknown state and the only one worth
# waiting on — answering it "no reviewer" is what would let the duplicate
# through in exactly the 8-second window the two runs are actually born in.
case_job_appears_late() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  printf '%s' "$no_review_job" > "$1/jobs-100.json"
  job_payload queued "" > "$1/jobs-100.json.2"
}
run_case "E: waits for an earlier run's review job to appear, then stands down" false case_job_appears_late

# --- F: ordering is total, so nobody waits on their waiter -----------------
# The other run is NEWER. It will stand down for us; we must not stand down
# for it, or a PR opened with a label gets zero reviews instead of one.
case_later_reviewing() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":200,"workflow_id":7},{"id":300,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":300,"workflow_id":7,"status":"in_progress"}' > "$1/run-300.json"
  job_payload in_progress "" > "$1/jobs-300.json"
}
run_case "F: a NEWER run never makes this one stand down" true case_later_reviewing

# --- G: another workflow on the same commit is not us ----------------------
case_other_workflow() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":99},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":99,"status":"in_progress"}' > "$1/run-100.json"
  job_payload in_progress "" > "$1/jobs-100.json"
}
run_case "G: CI's own run on the same commit is not a review" true case_other_workflow

# --- H: /auto-review is never deduped away ---------------------------------
# The command IS the fork gate and the manual escape hatch. If a maintainer
# types it while something else is running, it must still review — otherwise
# the command silently does nothing and looks broken.
case_issue_comment() {
  seed_self "$1"
  export EVENT=issue_comment
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  job_payload in_progress "" > "$1/jobs-100.json"
}
run_case "H: /auto-review reviews even alongside a live run" true case_issue_comment

# --- I: an ineligible run passes through untouched -------------------------
case_ineligible() { seed_self "$1"; export ELIGIBLE=false; }
run_case "I: an already-ineligible event stays ineligible" false case_ineligible
if [ -s "$LAST_DIR/.calls.log" ]; then
  bad "I: costs no API calls" "queried the Actions API for an event that reviews nothing"
else ok "I: an ineligible event costs no API calls"; fi

# --- J: fail safe toward reviewing -----------------------------------------
# A read that fails must not silence the review: no verdict means no arming
# and a PR stuck forever, which is worse than one redundant review.
case_api_down() { echo '{"workflow_runs":[]}' > "$1/runs.json"; }   # no run-200.json
run_case "J: an Actions API failure reviews rather than risking no review" true case_api_down

# --- K: the poll has a ceiling ---------------------------------------------
# An earlier run wedged in `context` forever must not wedge this one too.
case_never_appears() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  printf '%s' "$no_review_job" > "$1/jobs-100.json"
}
run_case "K: gives up waiting on a wedged earlier run and reviews" true case_never_appears

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

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
  *"/actions/runs?event=issue_comment"*) fixture="$FIX/comment-runs.json" ;;
  *"/issues/"*"/comments"*)    fixture="$FIX/comments.json" ;;
  *"/actions/runs/"*"/jobs")   fixture="$FIX/jobs-${endpoint##*/actions/runs/}"; fixture="${fixture%/jobs}.json" ;;
  *"/actions/runs/"*)          fixture="$FIX/run-${endpoint##*/actions/runs/}.json" ;;
  *) exit 1 ;;
esac

# Call counter per fixture, so a `.2` variant can answer later polls.
key="$(basename "$fixture")"
n=$(( $(cat "$FIX/.calls.$key" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FIX/.calls.$key"
[ "$n" -ge 2 ] && [ -f "$fixture.2" ] && fixture="$fixture.2"

# An `.err` fixture stands in for a refused read: gh prints its error to
# stderr and exits 1, exactly what a token without `actions: read` gets on a
# PRIVATE repo (public run listings need no permission, which is how the gap
# hid on every public repo).
if [ -f "$fixture.err" ]; then cat "$fixture.err" >&2; exit 1; fi
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
         RUN_ID=200 SHA=deadbee ELIGIBLE=true \
         PR_NUMBER=42 COMMENT_ID=900 TITLE='feat: a "quoted" $title'
  # The issue_comment path looks the PR up in run listings and comments. Seed
  # empty ones so a pull_request case that never reads them still has them.
  echo '{"workflow_runs":[]}' > "$dir/comment-runs.json"
  echo '[]' > "$dir/comments.json"
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

FORBIDDEN='gh: Resource not accessible by personal access token (HTTP 403)'

# --- H: /auto-review is not deduped against the AUTOMATIC review ----------
# The command is the fork gate and the manual escape hatch — and on a PR that
# edits the caller stub, the pull_request run can never emit a verdict, so the
# command is the only way through. It must still review while a pull_request
# run is live, or the command silently does nothing and looks broken.
case_issue_comment() {
  seed_self "$1"
  export EVENT=issue_comment
  echo '{"workflow_runs":[{"id":100,"workflow_id":7,"created_at":"2026-10-06T09:00:00Z"},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  job_payload in_progress "" > "$1/jobs-100.json"
}
run_case "H: /auto-review reviews even alongside a live pull_request run" true case_issue_comment

# --- M..T: two /auto-review commands on one commit -------------------------
# zillow-mcp#297: `/auto-review` posted twice, 32s apart. Each comment gets
# its own concurrency group (so the reviewer's own progress comment can never
# cancel the review, #182), so both reviewed the same commit, posted two sets
# of inline comments, and the second run REGENERATED the follow-up issue —
# three nits only the first round found vanished from the tracker. The
# younger command must stand down while an elder command is still reviewing
# the same head. Same rule as the pull_request twins: younger yields, a
# FINISHED elder never suppresses a re-review.
#
# The comment-run payloads carry the PR title, because an issue_comment run's
# head_sha is the DEFAULT branch, not the PR — the title is what the Actions
# API offers. A title can collide across PRs, so an earlier command comment
# on THIS PR is required as well.
PUSHED='{"workflow_runs":[{"id":50,"workflow_id":7,"created_at":"2026-10-06T09:00:00Z"},{"id":51,"workflow_id":7,"created_at":"2026-10-06T09:30:00Z"},{"id":52,"workflow_id":99,"created_at":"2026-10-06T08:00:00Z"}]}'
# cmd <id> <created_at> [body] [association]
cmd() { jq -nc --argjson id "$1" --arg t "$2" --arg b "${3:-/auto-review}" --arg a "${4:-OWNER}" \
          '{id: $id, created_at: $t, body: $b, author_association: $a}'; }
# crun <id> <created_at> <status> [title] [workflow_id]
crun() { jq -nc --argjson id "$1" --arg t "$2" --arg s "$3" --arg d "${4-$TITLE}" --argjson w "${5:-7}" \
          '{id: $id, workflow_id: $w, created_at: $t, status: $s, display_title: $d}'; }

# The zillow-mcp#297 shape: elder command run 100 is mid-review.
seed_twin_commands() {
  seed_self "$1"
  export EVENT=issue_comment
  echo "$PUSHED" > "$1/runs.json"
  printf '[%s,%s]\n' "$(cmd 800 2026-10-06T09:58:40Z)" "$(cmd 900 2026-10-06T09:59:12Z)" > "$1/comments.json"
  printf '{"workflow_runs":[%s,%s]}\n' "$(crun 200 2026-10-06T09:59:16Z in_progress)" \
    "$(crun 100 2026-10-06T09:58:43Z in_progress)" > "$1/comment-runs.json"
  crun 100 2026-10-06T09:58:43Z in_progress > "$1/run-100.json"
}
case_twin_reviewing() { seed_twin_commands "$1"; job_payload in_progress "" > "$1/jobs-100.json"; }
run_case "M: a second /auto-review stands down while the first is reviewing" false case_twin_reviewing

case_twin_finished() { seed_twin_commands "$1"; crun 100 2026-10-06T09:58:43Z completed > "$1/run-100.json"
  job_payload completed success > "$1/jobs-100.json"; }
run_case "N: /auto-review after the first review FINISHED re-reviews" true case_twin_finished

case_twin_late_job() { seed_twin_commands "$1"; printf '%s' "$no_review_job" > "$1/jobs-100.json"
  job_payload queued "" > "$1/jobs-100.json.2"; }
run_case "O: waits for the elder command's review job, then stands down" false case_twin_late_job

# A push between the two commands: the elder reviews the OLD head. With
# rereview_on_push off (the default) the push itself reviews nothing, so this
# command is the only review the new head will get.
case_pushed_between() { seed_twin_commands "$1"; job_payload in_progress "" > "$1/jobs-100.json"
  printf '[%s,%s]\n' "$(cmd 800 2026-10-06T08:30:00Z)" "$(cmd 900 2026-10-06T09:59:12Z)" > "$1/comments.json"; }
run_case "P: an elder command from BEFORE the head was pushed does not count" true case_pushed_between

# Same title, different PR: a live command run elsewhere, but nobody asked
# for a review on THIS PR before us. Also: a mention, not a command, and a
# command from someone the gate does not trust.
case_no_earlier_command() { seed_twin_commands "$1"; job_payload in_progress "" > "$1/jobs-100.json"
  printf '[%s,%s,%s]\n' "$(cmd 700 2026-10-06T09:58:00Z 'please do not /auto-review yet')" \
    "$(cmd 800 2026-10-06T09:58:40Z /auto-review NONE)" "$(cmd 900 2026-10-06T09:59:12Z)" > "$1/comments.json"; }
run_case "Q: no earlier maintainer command on THIS PR — reviews" true case_no_earlier_command

# The elder live run belongs to another PR (different title), or to another
# workflow (claude.yml fires on every comment too).
case_other_title() { seed_twin_commands "$1"; job_payload in_progress "" > "$1/jobs-100.json"
  printf '{"workflow_runs":[%s,%s]}\n' "$(crun 100 2026-10-06T09:58:43Z in_progress 'fix: something else')" \
    "$(crun 101 2026-10-06T09:58:43Z in_progress "$TITLE" 99)" > "$1/comment-runs.json"
  job_payload in_progress "" > "$1/jobs-101.json"; }
run_case "R: a live run for another PR or workflow is not a twin" true case_other_title

# Bot progress comments start issue_comment runs too; their review job skips.
case_twin_skipped() { seed_twin_commands "$1"; job_payload completed skipped > "$1/jobs-100.json"; }
run_case "S: an elder comment run that skipped its review is not a reviewer" true case_twin_skipped

# The head's push time comes from this commit's pull_request runs. None found
# (or the read refused): the elder's head is unknowable, so review.
case_push_unknown() { seed_twin_commands "$1"; job_payload in_progress "" > "$1/jobs-100.json"
  echo '{"workflow_runs":[]}' > "$1/runs.json"; }
run_case "T: no record of when the head was pushed — reviews" true case_push_unknown

case_comments_refused() { seed_twin_commands "$1"; job_payload in_progress "" > "$1/jobs-100.json"
  echo "$FORBIDDEN" > "$1/comments.json.err"; }
run_case "U: a refused comment listing reviews rather than risking no review" true case_comments_refused
if grep -q '^::warning::' "$LAST_DIR/log"; then ok "U: warns"; else bad "U: warns" "log: $(tr '\n' ' ' < "$LAST_DIR/log")"; fi

# --- I: an ineligible run passes through untouched -------------------------
case_ineligible() { seed_self "$1"; export ELIGIBLE=false; }
run_case "I: an already-ineligible event stays ineligible" false case_ineligible
if [ -s "$LAST_DIR/.calls.log" ]; then
  bad "I: costs no API calls" "queried the Actions API for an event that reviews nothing"
else ok "I: an ineligible event costs no API calls"; fi

# --- J: fail safe toward reviewing -----------------------------------------
# A read that fails must not silence the review: no verdict means no arming
# and a PR stuck forever, which is worse than one redundant review.
#
# Reviewing is the right fallback, but it must not be a quiet one. A refused
# read used to surface only as a ::notice::, so when RELEASE_PAT lacked
# `actions: read` this step failed open on EVERY private repo and every
# `--label`ed PR got two reviews that could disagree — apple-swift-mcp#160
# got `pass` and `warn` on one commit, and nothing on the run said why.
case_api_down() {
  echo '{"workflow_runs":[]}' > "$1/runs.json"
  echo "$FORBIDDEN" > "$1/run-200.json.err"
}
run_case "J: an Actions API failure reviews rather than risking no review" true case_api_down
assert_warns() {   # <case> <log dir>
  if grep -q '^::warning::.*HTTP 403' "$2/log" && grep -q 'actions: read' "$2/log"; then
    ok "$1: warns with gh's error and the missing-permission hint"
  else bad "$1: warns with gh's error and the missing-permission hint" "log: $(tr '\n' ' ' < "$2/log")"; fi
}
assert_warns "J" "$LAST_DIR"

# --- L: the candidate listing can be refused too ---------------------------
# Same failure one call later: the run resolves but listing the commit's runs
# is refused. Swallowing that reads as "no other runs" and reviews silently.
case_list_refused() {
  seed_self "$1"
  echo "$FORBIDDEN" > "$1/runs.json.err"
}
run_case "L: a refused run listing reviews rather than risking no review" true case_list_refused
assert_warns "L" "$LAST_DIR"

# --- K: the poll has a ceiling ---------------------------------------------
# An earlier run wedged in `context` forever must not wedge this one too.
case_never_appears() {
  seed_self "$1"
  echo '{"workflow_runs":[{"id":100,"workflow_id":7},{"id":200,"workflow_id":7}]}' > "$1/runs.json"
  echo '{"id":100,"workflow_id":7,"status":"in_progress"}' > "$1/run-100.json"
  printf '%s' "$no_review_job" > "$1/jobs-100.json"
}
run_case "K: gives up waiting on a wedged earlier run and reviews" true case_never_appears

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
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

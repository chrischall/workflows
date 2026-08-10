#!/usr/bin/env bash
# Unit tests for reusable-mcp-ci.yml's `Arm gate` and `Report ci-gated status`
# scripts — the two places that decide whether CI runs and whether the required
# `ci-gated` context gets posted.
#
# Both are pure bash over env vars with a single external dependency (`gh`), so
# they can be tested hermetically the same way `rollout.test.sh` tests the
# drift detector: stub `gh` on PATH and run the REAL script. The scripts are
# extracted from the shipped YAML at run time rather than copied here, so this
# exercises the file byte-for-byte with no test-only hooks in it — a change to
# the workflow that isn't reflected here fails rather than silently drifting.
#
# Why this file exists at all: the gate is the fleet's merge interlock. Getting
# it wrong in either direction is expensive and invisible — posting `success`
# too eagerly opens the merge button before CI ran; failing to post at all
# wedges every PR in the repo. Both have happened. The fork-PR row in
# particular encodes a bug that shipped: a fork's token is capped read-only, so
# the ci-gated POST 403'd, the gate job failed, every build step was skipped by
# `needs: gate`, and the PR went red without a single test having run.
#
# Usage: bash scripts/gate.test.sh
set -uo pipefail   # deliberately no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-mcp-ci.yml"
ACT="$HERE/.github/actions/arm-gate/action.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# --- extract the two scripts from the shipped workflow ---------------------
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  gate = wf["jobs"]["gate"]["steps"].find { |s| s["name"] == "Arm gate" }
  rep  = wf["jobs"]["ci"]["steps"].find { |s| s["name"] == "Report ci-gated status" }
  abort("could not find `Arm gate` step") unless gate
  abort("could not find `Report ci-gated status` step") unless rep
  File.write(ARGV[1], gate["run"])
  File.write(ARGV[2], rep["run"])

  # The composite action carries the same gate rule for bespoke-CI repos
  # (Gradle/KMP, Swift), which cannot call a reusable workflow. It has drifted
  # from the workflow before, so it is tested against the same matrix.
  act = YAML.load_file(ARGV[3])
  step = act["runs"]["steps"].find { |s| s["run"] }
  abort("could not find a run step in arm-gate") unless step
  File.write(ARGV[4], step["run"])
' "$WF" "$TMP/gate.sh" "$TMP/report.sh" "$ACT" "$TMP/armgate.sh" \
  || { echo "FAIL: could not extract steps from $WF / $ACT"; exit 1; }

# --- fake gh ---------------------------------------------------------------
# Records the call instead of hitting the API, so a test can assert both THAT a
# status was posted and WHICH state it carried.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

BASE=chrischall/example-mcp

# posted_state — the `state=` of the ci-gated POST, or "none".
posted_state() {
  grep -q 'statuses/' "$1" || { echo none; return; }
  grep -oE 'state=[a-z]+' "$1" | head -1 | cut -d= -f2
}

# gate_case <name> <want_run> <want_post> [ENV=val ...]
gate_case() {
  local name="$1" want_run="$2" want_post="$3"; shift 3
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GITHUB_OUTPUT="$dir/out" GH_CALLS="$dir/gh"; : > "$GITHUB_OUTPUT"; : > "$GH_CALLS"
  # Baseline: same-repo, un-armed, human PR, status mode.
  export GH_TOKEN=x MODE=status EVENT_NAME=pull_request EVENT_ACTION=synchronize \
         EVENT_LABEL="" USER_TYPE=User HEAD_REF=feature HEAD_SHA=deadbeef \
         PR_HEAD_REPO="$BASE" LABELS="" REPO="$BASE"
  local kv; for kv in "$@"; do export "${kv?}"; done

  bash "$GATE_SCRIPT" >"$dir/log" 2>&1
  local got_run; got_run="$(grep -oE 'run=(true|false)' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"
  [ -z "$got_run" ] && got_run='(none)'
  local got_post; got_post="$(posted_state "$GH_CALLS")"

  if [ "$got_run" = "$want_run" ] && [ "$got_post" = "$want_post" ]; then
    ok "gate: $name (run=$got_run, post=$got_post)"
  else
    bad "gate: $name" "got run=$got_run post=$got_post; wanted run=$want_run post=$want_post
     $(sed 's/^/     /' "$dir/log")"
  fi
}

# report_case <name> <want_post> [ENV=val ...]
report_case() {
  local name="$1" want_post="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GH_CALLS="$dir/gh"; : > "$GH_CALLS"
  export GH_TOKEN=x JOB_STATUS=success GATE_RESULT=success HEAD_SHA=deadbeef \
         PR_HEAD_REPO="$BASE" REPO="$BASE"
  local kv; for kv in "$@"; do export "${kv?}"; done

  bash "$TMP/report.sh" >"$dir/log" 2>&1
  local got_post; got_post="$(posted_state "$GH_CALLS")"
  if [ "$got_post" = "$want_post" ]; then
    ok "report: $name (post=$got_post)"
  else
    bad "report: $name" "got post=$got_post; wanted $want_post
     $(sed 's/^/     /' "$dir/log")"
  fi
}

GATE_SCRIPT="$TMP/gate.sh"
echo "── Arm gate (reusable-mcp-ci.yml), status mode ──"
gate_case "same-repo un-armed → blocked by pending"  false pending
gate_case "same-repo armed → run, gate posts nothing" true none    LABELS=ready-to-merge
gate_case "armed + non-arming label → no duplicate"  false none    LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=documentation
gate_case "armed + ready-to-merge label → run"       true  none    LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=ready-to-merge
gate_case "bot PR → always run"                      true  none    USER_TYPE=Bot
gate_case "release-please un-armed → pending"        false pending HEAD_REF=release-please--branches--main
gate_case "push event → run"                         true  none    EVENT_NAME=push PR_HEAD_REPO=""

echo "── Arm gate, fork PRs (status mode) ──"
# A fork's token is read-only, so the pending POST is impossible. Run the build
# so `ci / ci` carries a real result, and post nothing: the unreported ci-gated
# context is what keeps the merge blocked.
gate_case "fork un-armed → run, post nothing"        true  none    PR_HEAD_REPO=someone/example-mcp
gate_case "fork armed → run, post nothing"           true  none    PR_HEAD_REPO=someone/example-mcp LABELS=ready-to-merge
gate_case "fork with release-please-shaped ref"      true  none    PR_HEAD_REPO=someone/example-mcp HEAD_REF=release-please--x
# #113: the fork short-circuit used to run BEFORE the armed case, pre-empting
# the duplicate-run suppression, so an already-armed fork PR rebuilt on every
# relabel where a same-repo PR was skipped. Same expectation as same-repo now.
gate_case "fork armed + non-arming label → no dup" false none    PR_HEAD_REPO=someone/example-mcp LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=documentation
gate_case "fork armed + ready-to-merge label → run" true none    PR_HEAD_REPO=someone/example-mcp LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=ready-to-merge

echo "── Arm gate, fail mode (legacy — must be untouched by the fork path) ──"
# In fail mode the un-armed block IS a red `ci / ci`. Arming a fork here would
# turn that block green before review, so the fork short-circuit must not apply.
gate_case "same-repo un-armed → no run, no post"     false none    MODE=fail
gate_case "same-repo armed → run"                    true  none    MODE=fail LABELS=ready-to-merge
gate_case "fork un-armed → still blocked red"        false none    MODE=fail PR_HEAD_REPO=someone/example-mcp
gate_case "fork armed → run"                         true  none    MODE=fail PR_HEAD_REPO=someone/example-mcp LABELS=ready-to-merge

echo "── arm-gate composite (same rule, bespoke-CI repos) ──"
GATE_SCRIPT="$TMP/armgate.sh"
gate_case "same-repo un-armed → blocked by pending"  false pending
gate_case "same-repo armed → run"                    true  none    LABELS=ready-to-merge
gate_case "bot PR → always run"                      true  none    USER_TYPE=Bot
gate_case "fork un-armed → run, post nothing"        true  none    PR_HEAD_REPO=someone/example
gate_case "fork armed → run, post nothing"           true  none    PR_HEAD_REPO=someone/example LABELS=ready-to-merge
gate_case "fail mode: fork un-armed stays blocked"   false none    MODE=fail PR_HEAD_REPO=someone/example
gate_case "fork armed + non-arming label → no dup"   false none    PR_HEAD_REPO=someone/example LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=documentation

# The composite's contract with a consumer's reporter step: `is_fork` must be
# published on EVERY path, or a reporter guarding on it 403s on a fork.
armgate_is_fork() {
  local name="$1" want="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GITHUB_OUTPUT="$dir/out" GH_CALLS="$dir/gh"; : > "$GITHUB_OUTPUT"; : > "$GH_CALLS"
  export GH_TOKEN=x MODE=status EVENT_NAME=pull_request EVENT_ACTION=synchronize \
         EVENT_LABEL="" USER_TYPE=User HEAD_REF=feature HEAD_SHA=deadbeef \
         PR_HEAD_REPO="$BASE" LABELS="" REPO="$BASE"
  local kv; for kv in "$@"; do export "${kv?}"; done
  bash "$TMP/armgate.sh" >"$dir/log" 2>&1
  local got; got="$(grep -oE 'is_fork=(true|false)' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2)"
  [ -z "$got" ] && got='(unset)'
  if [ "$got" = "$want" ]; then ok "arm-gate is_fork: $name (=$got)"
  else bad "arm-gate is_fork: $name" "got $got, wanted $want"; fi
}
armgate_is_fork "same-repo un-armed"  false
armgate_is_fork "same-repo armed"     false LABELS=ready-to-merge
armgate_is_fork "bot PR"              false USER_TYPE=Bot
armgate_is_fork "push event"          false EVENT_NAME=push PR_HEAD_REPO=""
armgate_is_fork "fork"                true  PR_HEAD_REPO=someone/example
armgate_is_fork "fork in fail mode"   true  MODE=fail PR_HEAD_REPO=someone/example

echo "── Report ci-gated status ──"
report_case "same-repo tests passed → success"       success
report_case "same-repo tests failed → failure"       failure JOB_STATUS=failure
report_case "gate job errored → failure, not success" failure GATE_RESULT=failure JOB_STATUS=success
report_case "fork passed → post nothing"             none    PR_HEAD_REPO=someone/example-mcp
report_case "fork failed → post nothing"             none    PR_HEAD_REPO=someone/example-mcp JOB_STATUS=failure
report_case "fork + gate errored → post nothing"     none    PR_HEAD_REPO=someone/example-mcp GATE_RESULT=failure

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

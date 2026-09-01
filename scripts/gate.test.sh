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
FORK="$HERE/.github/actions/fork-ci-status/action.yml"
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

  # The fork reporter posts the SAME required context from a different repo
  # context, so it is the third place that can satisfy or block a merge.
  fork = YAML.load_file(ARGV[5])
  fstep = fork["runs"]["steps"].find { |s| s["run"] }
  abort("could not find a run step in fork-ci-status") unless fstep
  File.write(ARGV[6], fstep["run"])
' "$WF" "$TMP/gate.sh" "$TMP/report.sh" "$ACT" "$TMP/armgate.sh" "$FORK" "$TMP/fork.sh" \
  || { echo "FAIL: could not extract steps from $WF / $ACT"; exit 1; }

# --- fake gh ---------------------------------------------------------------
# Records the call instead of hitting the API, so a test can assert both THAT a
# status was posted and WHICH state it carried.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
# The gate reads the SHA's existing ci-gated status before posting `pending`,
# so it never reverts a terminal result a real CI run left there. Answer that
# read from the case's env; every other call just gets recorded.
case "$*" in
  # The fork reporter re-derives the gate's arming decision from the PR's
  # labels, because the run conclusion alone cannot tell "CI passed" from
  # "CI was deferred and skipped".
  #
  # MODELS REAL GITHUB, deliberately: `commits/{sha}/pulls` answers `[]` for a
  # fork PR, because the fork's head commit is not in the base repo. The stub
  # used to answer it with the labels, which is why 84 green tests sat on top
  # of a reporter that could never see an armed fork (skylight-mcp#148). Any
  # future lookup that reaches for this endpoint gets reality back.
  *"/commits/"*"/pulls"*)
    printf '[]\n' ;;
  # The working lookup: a fork PR IS listed among the base repo's open PRs.
  *"/pulls?state=open"*)
    [ "${PR_LOOKUP_FAILS:-}" = "1" ] && exit 1
    if [ "${PR_ABSENT:-}" = "1" ]; then exit 0; fi
    LABELS="${PR_LABELS-}" HEAD_SHA="${SHA}" jq -nc '
      { head: { sha: env.HEAD_SHA },
        labels: (env.LABELS | if . == "" then [] else split(",") end
                 | map({name: .})) }' ;;
  *"/commits/"*"/statuses"*)
    [ "${CI_GATED_READ_FAILS:-}" = "1" ] && exit 1
    printf '%s\n' "${EXISTING_CI_GATED-}" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

BASE=chrischall/example-mcp

# posted_state — the `state=` of the ci-gated POST, or "none".
posted_state() {
  # Read the state off the POST line only. Scanning the whole call log made
  # this read `state=` out of any other recorded URL — the open-PR lookup
  # (`pulls?state=open`) landed first and every fork case reported "open".
  local line
  line="$(grep 'statuses/' "$1" | head -1)"
  [ -n "$line" ] || { echo none; return; }
  printf '%s' "$line" | grep -oE 'state=[a-z]+' | head -1 | cut -d= -f2
}

# gate_case <name> <want_run> <want_post> [ENV=val ...]
gate_case() {
  local name="$1" want_run="$2" want_post="$3"; shift 3
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GITHUB_OUTPUT="$dir/out" GH_CALLS="$dir/gh"; : > "$GITHUB_OUTPUT"; : > "$GH_CALLS"
  # Baseline: same-repo, un-armed, human PR, status mode, no ci-gated on the
  # SHA yet. These two are per-case knobs, so clear them or they leak forward.
  unset EXISTING_CI_GATED CI_GATED_READ_FAILS
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
# A fork's token is read-only, so the pending POST is impossible either way —
# the gate posts NOTHING for a fork, armed or not.
#
# What changed: an un-armed fork no longer RUNS. It used to build
# automatically, on the reasoning that the unreported `ci-gated` context blocked
# the merge regardless. `ci-fork-status.yml` now reports that context, so that
# reasoning is gone — and building unreviewed fork code before a maintainer has
# looked is the thing worth not doing. A fork now waits for `ready-to-merge`
# exactly as a same-repo PR does.
gate_case "fork un-armed → NO run, post nothing"     false none    PR_HEAD_REPO=someone/example-mcp
gate_case "fork armed → run, post nothing"           true  none    PR_HEAD_REPO=someone/example-mcp LABELS=ready-to-merge
gate_case "fork un-armed, release-please ref → none" false none    PR_HEAD_REPO=someone/example-mcp HEAD_REF=release-please--x
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

echo "── Arm gate, stale/duplicate delivery must not clobber a terminal ci-gated ──"
# honeybook-mcp#160. `ci-gated` is a mutable commit status keyed only by its
# context, so the last writer wins. The event payload's label list is a
# SNAPSHOT taken when GitHub queued the delivery: CI ran armed and posted
# `ci-gated: success`, then a duplicate `synchronize` for the SAME sha arrived
# ten seconds later carrying a label set from before `ready-to-merge` was
# added, took the un-armed path, and reverted the green to `pending`. The PR
# wedged — armed for auto-merge, blocked on a required status with no further
# event coming to clear it. A terminal state means real CI ran for this exact
# commit, so only a real run (the reporter, same SHA) may change it.
gate_case "un-armed, ci-gated success → leave it"    false none    EXISTING_CI_GATED=success
gate_case "un-armed, ci-gated failure → leave it"    false none    EXISTING_CI_GATED=failure
gate_case "un-armed, ci-gated error → leave it"      false none    EXISTING_CI_GATED=error
# Not terminal: re-posting pending is idempotent and keeps the block honest.
gate_case "un-armed, ci-gated pending → re-post"     false pending EXISTING_CI_GATED=pending
gate_case "un-armed, no ci-gated yet → post pending" false pending EXISTING_CI_GATED=""
# Fail-safe: if we cannot tell what is there, block.
gate_case "un-armed, status read fails → post"       false pending CI_GATED_READ_FAILS=1
# The guard is scoped to the un-armed POST only — an armed PR still runs real
# CI and its reporter still overwrites the SHA's status, green or red.
gate_case "armed, ci-gated success → still run CI"   true  none    LABELS=ready-to-merge EXISTING_CI_GATED=success
gate_case "armed, ci-gated failure → still run CI"   true  none    LABELS=ready-to-merge EXISTING_CI_GATED=failure
# fail mode posts nothing at all, so it cannot clobber and must not read.
gate_case "fail mode, ci-gated success → no post"    false none    MODE=fail EXISTING_CI_GATED=success

echo "── arm-gate composite (same rule, bespoke-CI repos) ──"
# Row-for-row the same matrix as the reusable workflow above. Keep them in
# lockstep: a row that exists on only one side is exactly how the two drifted
# apart before, and a divergence here is invisible until it wedges a repo.
GATE_SCRIPT="$TMP/armgate.sh"
gate_case "same-repo un-armed → blocked by pending"  false pending
gate_case "same-repo armed → run"                    true  none    LABELS=ready-to-merge
gate_case "armed + non-arming label → no duplicate"  false none    LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=documentation
gate_case "armed + ready-to-merge label → run"       true  none    LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=ready-to-merge
gate_case "bot PR → always run"                      true  none    USER_TYPE=Bot
gate_case "release-please un-armed → pending"        false pending HEAD_REF=release-please--branches--main
gate_case "push event → run"                         true  none    EVENT_NAME=push PR_HEAD_REPO=""
gate_case "fork un-armed → NO run, post nothing"     false none    PR_HEAD_REPO=someone/example
gate_case "fork armed → run, post nothing"           true  none    PR_HEAD_REPO=someone/example LABELS=ready-to-merge
gate_case "fork un-armed, release-please ref → none" false none    PR_HEAD_REPO=someone/example HEAD_REF=release-please--x
gate_case "fork armed + non-arming label → no dup"   false none    PR_HEAD_REPO=someone/example LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=documentation
gate_case "fork armed + ready-to-merge label → run"  true  none    PR_HEAD_REPO=someone/example LABELS=ready-to-merge EVENT_ACTION=labeled EVENT_LABEL=ready-to-merge
gate_case "fail mode: same-repo un-armed → no run"   false none    MODE=fail
gate_case "fail mode: same-repo armed → run"         true  none    MODE=fail LABELS=ready-to-merge
gate_case "fail mode: fork un-armed stays blocked"   false none    MODE=fail PR_HEAD_REPO=someone/example
gate_case "fail mode: fork armed → run"              true  none    MODE=fail PR_HEAD_REPO=someone/example LABELS=ready-to-merge
# Same clobber guard as the reusable workflow above — keep the rows in lockstep.
gate_case "un-armed, ci-gated success → leave it"    false none    EXISTING_CI_GATED=success
gate_case "un-armed, ci-gated failure → leave it"    false none    EXISTING_CI_GATED=failure
gate_case "un-armed, ci-gated error → leave it"      false none    EXISTING_CI_GATED=error
gate_case "un-armed, ci-gated pending → re-post"     false pending EXISTING_CI_GATED=pending
gate_case "un-armed, no ci-gated yet → post pending" false pending EXISTING_CI_GATED=""
gate_case "un-armed, status read fails → post"       false pending CI_GATED_READ_FAILS=1
gate_case "armed, ci-gated success → still run CI"   true  none    LABELS=ready-to-merge EXISTING_CI_GATED=success
gate_case "armed, ci-gated failure → still run CI"   true  none    LABELS=ready-to-merge EXISTING_CI_GATED=failure
gate_case "fail mode, ci-gated success → no post"    false none    MODE=fail EXISTING_CI_GATED=success

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

echo "── fork-ci-status reporter (posts ci-gated from the BASE repo) ──"
# skylight-mcp#148. This reporter used to mirror the workflow_run CONCLUSION
# straight into `ci-gated`, which is not the same question. An un-armed fork PR
# DEFERS CI: the `ci` job is skipped (reusable shape) or its build steps are
# guarded off (bespoke single-job shape), and either way the run still concludes
# `success`. So the reporter posted `ci-gated: success` — a green required
# check — for a commit where nothing was built and no test ran. A maintainer
# then saw an all-green fork PR one click from merge; the PR that exposed this
# would have failed CI on a coverage threshold.
#
# The fix re-derives the gate's own arming rule from the PR's labels, read in
# the BASE repo where the token can actually see them. Un-decidable blocks.
fork_case() {
  local name="$1" want_post="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GH_CALLS="$dir/gh"; : > "$GH_CALLS"
  unset EXISTING_CI_GATED CI_GATED_READ_FAILS PR_LOOKUP_FAILS PR_ABSENT
  # Baseline: un-armed fork whose run went green because CI never ran.
  export GH_TOKEN=x REPO="$BASE" SHA=deadbeef CONCLUSION=success RUN_URL="" PR_LABELS=""
  local kv; for kv in "$@"; do export "${kv?}"; done

  bash "$TMP/fork.sh" >"$dir/log" 2>&1
  local got_post; got_post="$(posted_state "$GH_CALLS")"
  if [ "$got_post" = "$want_post" ]; then
    ok "fork-status: $name (post=$got_post)"
  else
    bad "fork-status: $name" "got post=$got_post; wanted $want_post
     $(sed 's/^/     /' "$dir/log")"
  fi
}

# fork_desc_case <name> <want-substring> [ENV=val ...]
# Same fixture as fork_case, but asserts what the status SAYS. A leading "!"
# on the substring inverts the assertion. The state alone cannot catch #196:
# two different causes both post `pending`, and only the description tells a
# maintainer which one they are looking at.
fork_desc_case() {
  local name="$1" want="$2"; shift 2
  local negate=""; case "$want" in "!"*) negate=1; want="${want#!}" ;; esac
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GH_CALLS="$dir/gh"; : > "$GH_CALLS"
  unset EXISTING_CI_GATED CI_GATED_READ_FAILS PR_LOOKUP_FAILS PR_ABSENT
  export GH_TOKEN=x REPO="$BASE" SHA=deadbeef CONCLUSION=success RUN_URL="" PR_LABELS=""
  local kv; for kv in "$@"; do export "${kv?}"; done

  bash "$TMP/fork.sh" >"$dir/log" 2>&1
  local hit=""; grep -qF -- "$want" "$GH_CALLS" && hit=1
  if { [ -n "$negate" ] && [ -z "$hit" ]; } || { [ -z "$negate" ] && [ -n "$hit" ]; }; then
    ok "fork-status desc: $name"
  else
    bad "fork-status desc: $name" "wanted ${negate:+NOT }to find [$want] in the posted status
     $(sed 's/^/     /' "$GH_CALLS")"
  fi
}

# The bug, stated as a test: a green run on an un-armed fork must not go green.
fork_case "un-armed, run success → pending not success" pending
fork_case "un-armed, run failure → pending"             pending CONCLUSION=failure
fork_case "un-armed, other labels only → pending"       pending PR_LABELS=documentation,bug

# Armed: CI really ran, so mirror it. This is the only path that may go green.
fork_case "armed, run success → success"                success PR_LABELS=ready-to-merge
fork_case "armed + other labels → success"              success PR_LABELS=bug,ready-to-merge,documentation
fork_case "armed, run failure → failure"                failure PR_LABELS=ready-to-merge CONCLUSION=failure
fork_case "armed, run cancelled → failure"              failure PR_LABELS=ready-to-merge CONCLUSION=cancelled
fork_case "armed, run timed_out → failure"              failure PR_LABELS=ready-to-merge CONCLUSION=timed_out
# A skipped/neutral RUN built nothing either — the second instance of the same
# bug, which mapped both to success.
fork_case "armed, run skipped → pending not success"    pending PR_LABELS=ready-to-merge CONCLUSION=skipped
fork_case "armed, run neutral → pending not success"    pending PR_LABELS=ready-to-merge CONCLUSION=neutral

# Fail-safe: an undecidable arming state must block, never satisfy. Same
# direction the gate takes when its own status read fails.
fork_case "PR lookup fails → pending"                   pending PR_LOOKUP_FAILS=1 PR_LABELS=ready-to-merge
fork_case "no PR for the sha → pending"                 pending PR_ABSENT=1 PR_LABELS=ready-to-merge
fork_case "PR found with no labels at all → pending"    pending PR_LABELS=""

# No-clobber, same rule as the gate (honeybook-mcp#160): a TERMINAL ci-gated
# means real CI ran for this exact commit, so a later un-armed or deferred
# delivery must not revert it to pending and wedge the PR.
fork_case "un-armed, ci-gated success → leave it"       none    EXISTING_CI_GATED=success
fork_case "un-armed, ci-gated failure → leave it"       none    EXISTING_CI_GATED=failure
fork_case "un-armed, ci-gated error → leave it"         none    EXISTING_CI_GATED=error
fork_case "un-armed, ci-gated pending → re-post"        pending EXISTING_CI_GATED=pending
# A real armed result still overwrites whatever is there, green or red.
fork_case "armed success over stale pending → success"  success PR_LABELS=ready-to-merge EXISTING_CI_GATED=pending
fork_case "armed failure over success → failure"        failure PR_LABELS=ready-to-merge CONCLUSION=failure EXISTING_CI_GATED=success

# #196: both causes post `pending`, so the description is the ONLY thing that
# tells them apart. Reported identically, a maintainer staring at an
# already-armed fork PR would go hunting for a `ready-to-merge` label that is
# sitting right there, when the real cause is a stub that predates the
# `pull-requests: read` grant — the exact rollout gap the fix's own sequencing
# note warned about.
fork_desc_case "lookup failed names the permission"     "pull-requests: read" PR_LOOKUP_FAILS=1 PR_LABELS=ready-to-merge
fork_desc_case "lookup failed does not say un-armed"    "!arms this fork PR"  PR_LOOKUP_FAILS=1 PR_LABELS=ready-to-merge
fork_desc_case "genuinely un-armed says ready-to-merge" "ready-to-merge"      PR_LABELS=""
fork_desc_case "genuinely un-armed blames no permission" "!pull-requests: read" PR_LABELS=""

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Unit tests for reusable-auto-merge.yml's two arm steps:
#   `Arm auto-merge for dependabot`
#   `Arm auto-merge on ready-to-merge label`
#
# Extracted from the shipped YAML at run time (the technique arm.test.sh,
# relmsg.test.sh and gate.test.sh use), so the file is exercised byte for byte
# with no test-only hook in it — `ARM_RETRY_WAIT` is the one knob, and it only
# shortens a sleep.
#
# What this pins is the fallback for a PR that is ALREADY mergeable when it is
# armed. GitHub refuses to *enable* auto-merge when there is nothing to wait
# for:
#
#   GraphQL: Pull request Pull request is in unstable status
#   (enablePullRequestAutoMerge)
#
# chrischall/fetchproxy#416 (run 36283109716) was armed after its CI had
# already gone green, got exactly that, and sat labelled but unmerged until
# the owner merged it by hand — the step's only fallback was "already MERGED".
# A refused arm must now re-read the PR and, when it is open, not a draft,
# still armed, and CLEAN/UNSTABLE/HAS_HOOKS, merge it directly with the same
# method the arm would have used — never with `--admin`, and never on
# BLOCKED/BEHIND/DIRTY.
#
# Usage: bash scripts/auto-merge-arm.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-auto-merge.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

LABEL_STEP="Arm auto-merge on ready-to-merge label"
DEPS_STEP="Arm auto-merge for dependabot"

# Extract the step's `run` AND its env, because the arming label the fallback
# re-checks is declared in the step's env, not in the script.
extract() { # extract <step name> <out script> <out env>
  # shellcheck disable=SC2016  # ruby source, not shell
  ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
             .find { |s| s["name"] == ARGV[1] }
    abort("could not find `#{ARGV[1]}` step") unless step
    File.write(ARGV[2], step["run"])
    # Literal env values only; `${{ }}` expressions are supplied by the cases.
    lits = (step["env"] || {}).reject { |_, v| v.to_s.include?("${{") }
    File.write(ARGV[3], lits.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n")
  ' "$WF" "$1" "$2" "$3"
}
extract "$LABEL_STEP" "$TMP/label.sh" "$TMP/label.env" || { echo "FAIL: could not extract $LABEL_STEP"; exit 1; }
extract "$DEPS_STEP"  "$TMP/deps.sh"  "$TMP/deps.env"  || { echo "FAIL: could not extract $DEPS_STEP"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  "pr merge"*--auto*)
    if [ "${AUTO_RC:-0}" != 0 ]; then
      echo "GraphQL: Pull request Pull request is in unstable status (enablePullRequestAutoMerge)" >&2
      exit "$AUTO_RC"
    fi
    exit 0 ;;
  "pr merge"*)
    # A direct merge. DIRECT_RC models losing a race (or any refusal).
    exit "${DIRECT_RC:-0}" ;;
  "pr view"*)
    # One line of $VIEWS per call, the last line repeating — so a case can
    # say "UNKNOWN, then CLEAN" or "OPEN, then MERGED after the direct merge".
    n=$(( $(cat "$VIEW_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$VIEW_N"
    total=$(printf '%s\n' "$VIEWS" | grep -c .)
    [ "$n" -gt "$total" ] && n=$total
    line=$(printf '%s\n' "$VIEWS" | sed -n "${n}p")
    [ "$line" = "__UNREADABLE__" ] && exit 1
    printf '%s' "$line"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

ARMED_LABELS='[{"name":"autorelease: pending"},{"name":"ready-to-merge"}]'
pr() { # pr <state> <mergeStateStatus> [isDraft] [labels-json]
  printf '{"state":"%s","mergeStateStatus":"%s","isDraft":%s,"labels":%s,"headRefOid":"feedface"}' \
    "$1" "$2" "${3:-false}" "${4:-$ARMED_LABELS}"
}

# run_case <step: label|deps> <name> [views...]
# AUTO_RC / DIRECT_RC / OVERRIDE are read from the caller's environment.
run_case() {
  local step="$1" name="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  CALLS="$dir/calls"; : > "$CALLS"
  local views; views="$(printf '%s\n' "$@")"
  # The step's literal env (e.g. the arming label), then the expression-valued
  # inputs GitHub would have filled in.
  (
    set -a
    # shellcheck disable=SC1090  # the extracted step env
    . "$TMP/$step.env"
    set +a
    GH_TOKEN=x PR_URL=https://github.com/chrischall/fetchproxy/pull/416 \
      OVERRIDE="${OVERRIDE:-}" SUBJECT="${SUBJECT:-}" BODY="${BODY:-}" \
      AUTO_RC="${AUTO_RC:-0}" DIRECT_RC="${DIRECT_RC:-0}" \
      VIEWS="$views" VIEW_N="$dir/n" CALLS="$CALLS" ARM_RETRY_WAIT=0 \
      bash -e "$TMP/$step.sh"
  ) >"$dir/log" 2>&1
  RC=$?
  CASE="$step: $name"; LOG="$dir/log"
}

log1() { tr '\n' ' ' < "$LOG"; }
direct_merges() { grep '^pr merge' "$CALLS" | grep -v -- '--auto' || true; }
rc_is() {
  if [ "$1" = 0 ] && [ "$RC" -eq 0 ]; then ok "$CASE: succeeds"
  elif [ "$1" != 0 ] && [ "$RC" -ne 0 ]; then ok "$CASE: fails loudly"
  else bad "$CASE: rc want $1" "rc=$RC log: $(log1)"; fi
}
merged_directly() { # merged_directly <yes|no>
  local got=no; [ -n "$(direct_merges)" ] && got=yes
  if [ "$got" = "$1" ]; then ok "$CASE: merges directly=$1"
  else bad "$CASE: merges directly=$1" "calls: $(tr '\n' '|' < "$CALLS") log: $(log1)"; fi
}
never_admin() {
  if grep -q -- '--admin' "$CALLS"; then bad "$CASE: never bypasses required checks" "$(tr '\n' '|' < "$CALLS")"
  else ok "$CASE: never uses --admin"; fi
}
errors() {
  if grep -q '::error::' "$LOG"; then ok "$CASE: reports ::error::"
  else bad "$CASE: reports ::error::" "log: $(log1)"; fi
}

for S in label deps; do
  echo "── $S: --auto accepted (unchanged behaviour) ──"
  AUTO_RC=0 run_case "$S" "auto ok" "$(pr OPEN BLOCKED)"
  rc_is 0; merged_directly no
  if [ "$(grep -c . "$CALLS")" = 1 ]; then ok "$CASE: one gh call, nothing re-read"
  else bad "$CASE: one gh call, nothing re-read" "$(tr '\n' '|' < "$CALLS")"; fi

  echo "── $S: --auto refused, already mergeable → merge directly ──"
  for st in CLEAN UNSTABLE HAS_HOOKS; do
    AUTO_RC=1 run_case "$S" "refused + $st" "$(pr OPEN "$st")"
    rc_is 0; merged_directly yes; never_admin
  done
  # Pinned to the head that was read as mergeable: a push landing between the
  # read and the merge must make GitHub refuse, not merge unreviewed code.
  AUTO_RC=1 run_case "$S" "refused + CLEAN pins head" "$(pr OPEN CLEAN)"
  if direct_merges | grep -q -- '--match-head-commit feedface'; then ok "$CASE: direct merge pins the head commit read"
  else bad "$CASE: direct merge pins the head commit read" "$(direct_merges)"; fi

  echo "── $S: merge method is the arm's method ──"
  AUTO_RC=1 run_case "$S" "method matches" "$(pr OPEN CLEAN)"
  arm_method=$(grep -- '--auto' "$CALLS" | grep -oE -- '--(squash|merge|rebase)' | head -1)
  direct_method=$(direct_merges | grep -oE -- '--(squash|merge|rebase)' | head -1)
  if [ -n "$arm_method" ] && [ "$arm_method" = "$direct_method" ]; then ok "$CASE: direct merge uses $arm_method, as the arm did"
  else bad "$CASE: direct merge uses the arm's method" "arm=[$arm_method] direct=[$direct_method]"; fi

  echo "── $S: not mergeable → still fails loudly ──"
  for st in BLOCKED BEHIND DIRTY; do
    AUTO_RC=1 run_case "$S" "refused + $st" "$(pr OPEN "$st")"
    rc_is 1; merged_directly no; errors
  done
  AUTO_RC=1 run_case "$S" "refused + UNKNOWN twice" "$(pr OPEN UNKNOWN)"
  rc_is 1; merged_directly no; errors
  AUTO_RC=1 run_case "$S" "refused + UNKNOWN, then CLEAN on retry" "$(pr OPEN UNKNOWN)" "$(pr OPEN CLEAN)"
  rc_is 0; merged_directly yes
  AUTO_RC=1 run_case "$S" "refused + draft" "$(pr OPEN CLEAN true)"
  rc_is 1; merged_directly no
  AUTO_RC=1 run_case "$S" "refused + closed" "$(pr CLOSED CLEAN)"
  rc_is 1; merged_directly no; errors
  AUTO_RC=1 run_case "$S" "refused + PR unreadable" "__UNREADABLE__"
  rc_is 1; merged_directly no; errors

  echo "── $S: races ──"
  # The instant-merge race the step always handled.
  AUTO_RC=1 run_case "$S" "refused + already MERGED" "$(pr MERGED UNKNOWN)"
  rc_is 0; merged_directly no
  # The direct merge loses to a concurrent merge: MERGED is success.
  AUTO_RC=1 DIRECT_RC=1 run_case "$S" "direct merge loses a race" "$(pr OPEN CLEAN)" "$(pr MERGED UNKNOWN)"
  rc_is 0; merged_directly yes
  # …but a direct merge that fails and leaves the PR open is a real failure.
  AUTO_RC=1 DIRECT_RC=1 run_case "$S" "direct merge refused, PR still open" "$(pr OPEN CLEAN)" "$(pr OPEN BLOCKED)"
  rc_is 1; errors
done

echo "── label: the arming label was removed meanwhile ──"
# A fail verdict de-arms by removing the label (arm.test.sh). A PR that has
# lost its label since this job was triggered must not be merged by it.
AUTO_RC=1 run_case label "label removed" "$(pr OPEN CLEAN false '[{"name":"bug"}]')"
rc_is 0; merged_directly no
if grep -q '::warning::' "$LOG"; then ok "$CASE: warns why it did not merge"
else bad "$CASE: warns why it did not merge" "log: $(log1)"; fi

echo "── deps: no arming label to require ──"
AUTO_RC=1 run_case deps "no label, CLEAN" "$(pr OPEN CLEAN false '[{"name":"dependencies"}]')"
rc_is 0; merged_directly yes

echo "── deps: an overridden squash message survives the direct merge ──"
OVERRIDE=true SUBJECT="fix(deps): bump x" BODY="Body omitted" AUTO_RC=1 \
  run_case deps "override + CLEAN" "$(pr OPEN CLEAN false '[]')"
rc_is 0
if direct_merges | grep -qF -- '--subject fix(deps): bump x --body Body omitted'; then ok "$CASE: direct merge carries the replaced subject/body"
else bad "$CASE: direct merge carries the replaced subject/body" "$(direct_merges)"; fi
OVERRIDE=true SUBJECT="fix(deps): bump x" BODY="Body omitted" AUTO_RC=0 \
  run_case deps "override + auto ok" "$(pr OPEN BLOCKED)"
if grep -qF -- 'pr merge --auto --squash --subject fix(deps): bump x --body Body omitted https://' "$CALLS"; then ok "$CASE: arm command unchanged"
else bad "$CASE: arm command unchanged" "$(tr '\n' '|' < "$CALLS")"; fi
AUTO_RC=0 run_case deps "no override, auto ok"
if grep -qxF -- 'pr merge --auto --squash https://github.com/chrischall/fetchproxy/pull/416' "$CALLS"; then ok "$CASE: arm command unchanged"
else bad "$CASE: arm command unchanged" "$(tr '\n' '|' < "$CALLS")"; fi
AUTO_RC=0 run_case label "auto ok"
if grep -qxF -- 'pr merge --auto --squash https://github.com/chrischall/fetchproxy/pull/416' "$CALLS"; then ok "$CASE: arm command unchanged"
else bad "$CASE: arm command unchanged" "$(tr '\n' '|' < "$CALLS")"; fi

echo "── both steps carry the same fallback ──"
# Two jobs cannot share a shell function, so the block is written twice. The
# cases above run against both; this catches a comment-only drift too, so the
# next edit is made in both places or neither.
tail_from() { sed -n '/# --auto was refused/,$p' "$1"; }
if [ -n "$(tail_from "$TMP/label.sh")" ] && diff <(tail_from "$TMP/label.sh") <(tail_from "$TMP/deps.sh") >/dev/null; then
  ok "the fallback block is identical in both arm steps"
else bad "the fallback block is identical in both arm steps" "$(diff <(tail_from "$TMP/label.sh") <(tail_from "$TMP/deps.sh") | head -20)"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

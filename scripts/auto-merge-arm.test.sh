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

# ─────────────────────────────────────────────────────────────────────────────
# Re-arming a release PR that release-please rewrote.
#
# chrischall/mcp-utils#313 (the 2.11.0 release PR): `ready-to-merge` landed at
# 18:39:40 and armed auto-merge. 38 seconds later another PR merged, and
# release-please force-pushed the release branch to regenerate it — GitHub
# answers that with `auto_merge_disabled`. The `synchronize` run that followed
# skipped this job (it ran only on `labeled`), so the PR sat labelled, green,
# CLEAN and un-armed until the owner removed and re-added the label.
#
# The re-arm is for RELEASE PRs ONLY. On any other PR the label means "this
# commit passed auto-review"; a push after the pass is new, unreviewed code
# and must go back through review, never be re-armed blindly. A release PR's
# content is generated by release-please from commits that were each reviewed
# on their own PR, which is what makes it the one safe exception — and only
# while the push really came from the release identity.
# ─────────────────────────────────────────────────────────────────────────────
JOB_ID="arm-on-ready-label"
GATE_STEP="Gate re-arm of a rewritten release PR"
RECHECK_STEP="Re-check the arming label after a re-arm"

# The job `if:` is policy, not bash, and actionlint checks only its syntax.
# Evaluate it for real: transliterate the (small) expression subset it uses
# into Ruby and run it against synthetic payloads.
cat > "$TMP/evalif.rb" <<'RUBY'
require "yaml"; require "json"
wf = YAML.load_file(ARGV[0])
job = wf["jobs"][ARGV[1]] or abort("no job #{ARGV[1]}")
ev = JSON.parse(ARGV[2]); repo = ARGV[3]
expr = job["if"].to_s.gsub(/\s+/, " ")
def dig(h, *ks) ks.reduce(h) { |a, k| a.is_a?(Hash) ? a[k] : nil } end
def contains(a, b) a.is_a?(Array) ? a.include?(b) : a.to_s.include?(b.to_s) end
def startsWith(a, b) a.to_s.start_with?(b.to_s) end
rb = expr
  .gsub("github.event.pull_request.labels.*.name", '(dig(ev,"pull_request","labels")||[]).map{|l| l["name"]}')
  .gsub(/github\.event((?:\.[A-Za-z_]+)+)/) { "dig(ev," + $1.split(".").drop(1).map(&:inspect).join(",") + ")" }
  .gsub("github.repository", "repo")
abort("untranslated context in: #{rb}") if rb =~ /github\.|steps\.|inputs\./
print(eval(rb) ? "true" : "false")
RUBY
# event <action> <head_ref> <labels csv> [head repo] [draft] [label added]
event() {
  local labels; labels=$(printf '%s' "$3" | jq -Rc 'split(",") | map(select(. != "") | {name: .})')
  jq -nc --arg a "$1" --arg ref "$2" --argjson labels "$labels" \
    --arg hr "${4:-chrischall/mcp-utils}" --argjson draft "${5:-false}" --arg lab "${6:-}" '
    {action: $a, sender: {login: "chrischall"},
     pull_request: {draft: $draft, head: {ref: $ref, repo: {full_name: $hr}},
                    labels: $labels, user: {login: "chrischall"}}}
    + (if $lab == "" then {} else {label: {name: $lab}} end)'
}
job_runs() { # job_runs <want true|false> <name> <event json>
  local got; got=$(ruby "$TMP/evalif.rb" "$WF" "$JOB_ID" "$3" chrischall/mcp-utils 2>&1)
  if [ "$got" = "$1" ]; then ok "job if: $2 → runs=$1"
  else bad "job if: $2 → runs=$1" "got: $got"; fi
}
REL=release-please--branches--main--components--mcp-utils
echo "── job if: the labeled arm is unchanged ──"
job_runs true  "labeled ready-to-merge"            "$(event labeled feat/x ready-to-merge chrischall/mcp-utils false ready-to-merge)"
job_runs false "labeled something else"            "$(event labeled feat/x ready-to-merge,bug chrischall/mcp-utils false bug)"
job_runs false "labeled ready-to-merge on a fork"  "$(event labeled feat/x ready-to-merge someone/mcp-utils false ready-to-merge)"
job_runs false "labeled ready-to-merge, draft"     "$(event labeled feat/x ready-to-merge chrischall/mcp-utils true ready-to-merge)"
echo "── job if: a rewritten release PR re-arms ──"
job_runs true  "synchronize, armed release PR (mcp-utils#313)" "$(event synchronize "$REL" "autorelease: pending,ready-to-merge")"
job_runs true  "reopened, armed release PR"         "$(event reopened "$REL" "autorelease: pending,ready-to-merge")"
job_runs true  "synchronize, single-component release branch" "$(event synchronize release-please--branches--main "autorelease: pending,ready-to-merge")"
echo "── job if: nothing else re-arms on a push ──"
job_runs false "synchronize, armed NON-release PR"  "$(event synchronize feat/x "ready-to-merge")"
job_runs false "synchronize, armed PR on a lookalike branch" "$(event synchronize feat/release-please--branches--main "autorelease: pending,ready-to-merge")"
job_runs false "reopened, armed NON-release PR"     "$(event reopened feat/x "ready-to-merge")"
job_runs false "synchronize, release PR not armed"  "$(event synchronize "$REL" "autorelease: pending")"
job_runs false "synchronize, release branch without autorelease: pending" "$(event synchronize "$REL" "ready-to-merge")"
job_runs false "synchronize, release branch from a fork" "$(event synchronize "$REL" "autorelease: pending,ready-to-merge" someone/mcp-utils)"
job_runs false "synchronize, release PR is a draft" "$(event synchronize "$REL" "autorelease: pending,ready-to-merge" chrischall/mcp-utils true)"
job_runs false "opened, armed release PR"           "$(event opened "$REL" "autorelease: pending,ready-to-merge")"

echo "── step wiring ──"
step_if() { # step_if <step name>
  # shellcheck disable=SC2016  # ruby source, not shell
  ruby -ryaml -e '
    s = YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["steps"].find { |x| x["name"] == ARGV[2] }
    print(s ? s["if"].to_s.gsub(/\s+/, " ") : "__MISSING__")' "$WF" "$JOB_ID" "$1"
}
step_id() {
  # shellcheck disable=SC2016  # ruby source, not shell
  ruby -ryaml -e '
    s = YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["steps"].find { |x| x["name"] == ARGV[2] }
    print(s ? s["id"].to_s : "")' "$WF" "$JOB_ID" "$1"
}
GATE_ID=$(step_id "$GATE_STEP")
if [ -n "$GATE_ID" ]; then ok "gate step has an id ($GATE_ID)"; else bad "gate step has an id" "missing step or id"; fi
gif=$(step_if "$GATE_STEP")
if [ "$gif" = "github.event.action != 'labeled'" ]; then ok "gate runs on every non-labeled event the job admits"
else bad "gate runs on every non-labeled event the job admits" "if: $gif"; fi
aif=$(step_if "$LABEL_STEP")
if printf '%s' "$aif" | grep -qF "github.event.action == 'labeled'" \
   && printf '%s' "$aif" | grep -qF "steps.$GATE_ID.outputs.rearm == 'true'" \
   && printf '%s' "$aif" | grep -qF "||"; then ok "arm step: on labeled, or on the gate's say-so only"
else bad "arm step: on labeled, or on the gate's say-so only" "if: $aif"; fi
rif=$(step_if "$RECHECK_STEP")
if printf '%s' "$rif" | grep -qF "steps.$GATE_ID.outputs.rearm == 'true'"; then ok "re-check runs after a re-arm"
else bad "re-check runs after a re-arm" "if: $rif"; fi

extract "$GATE_STEP"    "$TMP/gate.sh"    "$TMP/gate.env"    || bad "extract $GATE_STEP" "missing"
extract "$RECHECK_STEP" "$TMP/recheck.sh" "$TMP/recheck.env" || bad "extract $RECHECK_STEP" "missing"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  "api user"*)
    [ -n "${PAT_LOGIN:-}" ] || exit 1
    printf '%s\n' "$PAT_LOGIN"; exit 0 ;;
  "pr view"*)
    [ "$LIVE" = "__UNREADABLE__" ] && exit 1
    printf '%s' "$LIVE"; exit 0 ;;
  "pr merge"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

live() { # live <labels csv> [state] [isDraft] [headRefName]
  local labels; labels=$(printf '%s' "$1" | jq -Rc 'split(",") | map(select(. != "") | {name: .})')
  printf '{"state":"%s","isDraft":%s,"headRefName":"%s","labels":%s}' \
    "${2:-OPEN}" "${3:-false}" "${4:-$REL}" "$labels"
}
LIVE_ARMED="$(live "autorelease: pending,ready-to-merge")"
# gate_case <want true|false> <name> [VAR=value ...]  — defaults model #313.
gate_case() {
  local want="$1" name="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/gate.XXXXXX")"; : > "$dir/out"; : > "$dir/calls"
  (
    set -a
    # shellcheck disable=SC1090  # the extracted step env
    . "$TMP/gate.env"
    export GH_TOKEN=x PR_URL=https://github.com/chrischall/mcp-utils/pull/313
    export REPO=chrischall/mcp-utils HEAD_REPO=chrischall/mcp-utils HEAD_REF="$REL"
    export ACTION=synchronize SENDER=chrischall AUTHOR=chrischall PAT_LOGIN=chrischall
    export LIVE="$LIVE_ARMED" GITHUB_OUTPUT="$dir/out" CALLS="$dir/calls"
    for kv in "$@"; do export "${kv?}"; done
    set +a
    bash -e "$TMP/gate.sh"
  ) >"$dir/log" 2>&1
  local rc=$? got; got=$(sed -n 's/^rearm=//p' "$dir/out" | tail -1)
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "gate: $name → rearm=$want"
  else bad "gate: $name → rearm=$want" "rc=$rc rearm=[$got] log: $(tr '\n' ' ' < "$dir/log")"; fi
  if grep -q '^pr merge' "$dir/calls"; then bad "gate: $name: never merges or arms itself" "$(tr '\n' '|' < "$dir/calls")"; fi
}
echo "── gate: the #313 case re-arms ──"
gate_case true  "release-please force-push, label + autorelease: pending live"
gate_case true  "reopened" ACTION=reopened
gate_case true  "a nullnet repo, whose release PAT is another identity" SENDER=nullnet-bot AUTHOR=nullnet-bot PAT_LOGIN=nullnet-bot
echo "── gate: never re-arm anything else (security) ──"
gate_case false "non-release PR" HEAD_REF=feat/x LIVE="$(live "ready-to-merge" OPEN false feat/x)"
gate_case false "lookalike branch" HEAD_REF=feat/release-please--branches--main
gate_case false "live head ref is not a release branch" LIVE="$(live "autorelease: pending,ready-to-merge" OPEN false feat/x)"
gate_case false "fork" HEAD_REPO=someone/mcp-utils
gate_case false "push by someone other than the release identity" SENDER=collaborator
gate_case false "PR authored by someone other than the release identity" AUTHOR=collaborator
gate_case false "release identity unreadable" PAT_LOGIN=
gate_case false "labeled event (the arm step's own path)" ACTION=labeled
gate_case false "opened" ACTION=opened
gate_case false "label removed since the event" LIVE="$(live "autorelease: pending")"
gate_case false "no longer autorelease: pending" LIVE="$(live "autorelease: tagged,ready-to-merge")"
gate_case false "PR closed" LIVE="$(live "autorelease: pending,ready-to-merge" CLOSED)"
gate_case false "PR now a draft" LIVE="$(live "autorelease: pending,ready-to-merge" OPEN true)"
gate_case false "PR unreadable" LIVE=__UNREADABLE__

# recheck_case <disables yes|no> <name> <live>
recheck_case() {
  local want="$1" name="$2"
  local dir; dir="$(mktemp -d "$TMP/recheck.XXXXXX")"; : > "$dir/calls"
  (
    set -a
    # shellcheck disable=SC1090  # the extracted step env
    . "$TMP/recheck.env"
    export GH_TOKEN=x PR_URL=https://github.com/chrischall/mcp-utils/pull/313
    export LIVE="$3" CALLS="$dir/calls"
    set +a
    bash -e "$TMP/recheck.sh"
  ) >"$dir/log" 2>&1
  local rc=$? got=no
  grep -q -- '^pr merge.*--disable-auto' "$dir/calls" && got=yes
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "re-check: $name → disables auto-merge=$want"
  else bad "re-check: $name → disables auto-merge=$want" "rc=$rc calls: $(tr '\n' '|' < "$dir/calls") log: $(tr '\n' ' ' < "$dir/log")"; fi
}
echo "── re-check: a concurrent de-arm wins ──"
# rereview_on_push de-arms a pushed PR (remove label, then --disable-auto) in
# a different workflow, racing this one. Whichever order they land in, a PR
# whose label is gone after the re-arm must end with auto-merge OFF.
recheck_case no  "label still there"       "$LIVE_ARMED"
recheck_case yes "label removed meanwhile" "$(live "autorelease: pending")"
recheck_case yes "PR unreadable (fail safe: back to un-armed)" "__UNREADABLE__"
recheck_case no  "already merged"          "$(live "autorelease: pending,ready-to-merge" MERGED)"
# A merged or closed PR is never touched, even with the label gone — the
# state short-circuit, not the label check, is what spares it (#323).
recheck_case no  "merged, label gone"      "$(live "autorelease: pending" MERGED)"
recheck_case no  "closed, label gone"      "$(live "autorelease: pending" CLOSED)"

# ─────────────────────────────────────────────────────────────────────────────
# Who applied the label (fleet-audit#807).
#
# The labeled arm used to run `gh pr merge --auto` with the owner's PAT for
# whoever added `ready-to-merge`. In an org repo a triage-only member can label
# but cannot merge — so they could label any same-repo PR (a `fail` verdict, a
# WIP branch) and the PAT would merge it once CI went green. The arm now
# requires the labeler to be the release identity (the pipeline's own label,
# applied with the PAT) or someone who could merge anyway (admin/write; GitHub
# reports maintain as write and triage as read). Any doubt → do not arm.
# ─────────────────────────────────────────────────────────────────────────────
LABELER_STEP="Gate a ready-to-merge label by who applied it"
echo "── labeler gate: step wiring ──"
LABELER_ID=$(step_id "$LABELER_STEP")
if [ -n "$LABELER_ID" ]; then ok "labeler gate has an id ($LABELER_ID)"; else bad "labeler gate has an id" "missing step or id"; fi
lif=$(step_if "$LABELER_STEP")
if [ "$lif" = "github.event.action == 'labeled'" ]; then ok "labeler gate runs on the labeled path"
else bad "labeler gate runs on the labeled path" "if: $lif"; fi
aif=$(step_if "$LABEL_STEP")
if [ -n "$LABELER_ID" ] && printf '%s' "$aif" | grep -qF "steps.$LABELER_ID.outputs.allowed == 'true'"; then
  ok "arm step: the labeled path requires the labeler gate's say-so"
else bad "arm step: the labeled path requires the labeler gate's say-so" "if: $aif"; fi
# The re-arm path must not be reachable via a bare labeled event any more.
if printf '%s' "$aif" | grep -qE "^github\.event\.action == 'labeled' \|\|"; then
  bad "arm step: a labeled event alone no longer arms" "if: $aif"
else ok "arm step: a labeled event alone no longer arms"; fi

extract "$LABELER_STEP" "$TMP/labeler.sh" "$TMP/labeler.env" || bad "extract $LABELER_STEP" "missing"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  "api user"*)
    [ -n "${PAT_LOGIN:-}" ] || exit 1
    printf '%s\n' "$PAT_LOGIN"; exit 0 ;;
  "api repos/"*"/collaborators/"*"/permission"*)
    [ "${PERM:-}" = "__FAILS__" ] && exit 1
    printf '%s\n' "${PERM:-}"; exit 0 ;;
  "pr merge"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

# labeler_case <want true|false> <name> [VAR=value ...] — defaults: the
# pipeline's own label, applied with the release PAT.
labeler_case() {
  local want="$1" name="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/labeler.XXXXXX")"; : > "$dir/out"; : > "$dir/calls"
  (
    set -a
    # shellcheck disable=SC1090  # the extracted step env
    . "$TMP/labeler.env"
    export GH_TOKEN=x REPO=nullnet-app/encore-ios SENDER=chrischall PAT_LOGIN=chrischall PERM=admin
    export GITHUB_OUTPUT="$dir/out" CALLS="$dir/calls"
    for kv in "$@"; do export "${kv?}"; done
    set +a
    bash -e "$TMP/labeler.sh"
  ) >"$dir/log" 2>&1
  local rc=$? got; got=$(sed -n 's/^allowed=//p' "$dir/out" | tail -1)
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "labeler: $name → allowed=$want"
  else bad "labeler: $name → allowed=$want" "rc=$rc allowed=[$got] log: $(tr '\n' ' ' < "$dir/log")"; fi
  if grep -q '^pr merge' "$dir/calls"; then bad "labeler: $name: never merges or arms itself" "$(tr '\n' '|' < "$dir/calls")"; fi
  if [ "$want" = false ] && ! grep -q '::warning::' "$dir/log"; then bad "labeler: $name: warns why it did not arm" "log: $(tr '\n' ' ' < "$dir/log")"; fi
}
echo "── labeler gate: who may arm ──"
labeler_case true  "the pipeline (release identity) labelled it"
labeler_case true  "a nullnet release identity labelled it" SENDER=nullnet-bot PAT_LOGIN=nullnet-bot PERM=none
labeler_case true  "an admin labelled it"           SENDER=owner2 PERM=admin
labeler_case true  "a writer (or maintainer) labelled it" SENDER=dev PERM=write
labeler_case true  "release identity unreadable, labeler is a writer" SENDER=dev PAT_LOGIN= PERM=write
echo "── labeler gate: never arm for someone who could not merge (security) ──"
labeler_case false "a triage-only member labelled it" SENDER=triager PERM=read
labeler_case false "a non-collaborator labelled it"   SENDER=stranger PERM=none
labeler_case false "permission lookup fails"          SENDER=dev PERM=__FAILS__
labeler_case false "permission is something unexpected" SENDER=dev PERM=
labeler_case false "no sender in the payload"         SENDER= PERM=admin

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

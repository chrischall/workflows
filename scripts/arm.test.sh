#!/usr/bin/env bash
# Unit tests for reusable-pr-auto-review.yml's `Arm auto-merge on pass or warn`
# step — specifically that it will not arm a PR another run has already failed.
#
# Extracted from the shipped YAML at run time (same technique as
# verdict.test.sh / gate.test.sh), so this exercises the file byte-for-byte
# with no test-only hooks in it.
#
# Why this exists: a `labeled` event re-reviews (the label whitelist in the
# `context` guard is deliberate), so labelling a PR seconds after opening it
# runs TWO reviews of the same diff concurrently. They are LLM reviews and can
# disagree. On chrischall/fetchproxy#274 they did:
#
#   run …348591 (opened)  Verdict=pass — added ready-to-merge   18:19:46Z
#   run …362171 (labeled) Verdict=fail — not arming             18:20:54Z
#
# The PR merged at 18:20:45Z — nine seconds before the failing run reached its
# arming step. Each run's arm decision was individually correct; neither could
# see the other. The fix is for arming to consult the RECORDED verdict, which
# is a shared fact, rather than only its own.
#
# Usage: bash scripts/arm.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == "Arm auto-merge on pass or warn" }
  abort("could not find `Arm auto-merge on pass or warn` step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/arm.sh" || { echo "FAIL: could not extract step from $WF"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  # The recorded verdict on the PR — what another run may already have posted.
  "pr view"*comments*) printf '%s' "$RECORDED_VERDICT"; exit 0 ;;
  # The arm itself.
  "pr edit"*--add-label*) printf 'armed\n' > "$ARMED"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# armed: "yes" or "no"
run_case() {
  local name="$1" expect="$2" verdict="$3" recorded="${4:-}"
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export ARMED="$dir/armed"; : > "$ARMED"
  export GH_TOKEN=x PR=274 REPO=chrischall/fetchproxy VERDICT="$verdict" \
         RECORDED_VERDICT="$recorded"
  bash "$TMP/arm.sh" >"$dir/log" 2>&1
  local got=no; [ -s "$ARMED" ] && got=yes
  if [ "$got" = "$expect" ]; then ok "$name"
  else bad "$name" "expected armed=$expect, got armed=$got — log: $(tr '\n' ' ' < "$dir/log")"; fi
}

FAIL_COMMENT='<!-- auto-review-verdict -->
🔴 Auto-review verdict: **fail** — breaks the classifier.'
PASS_COMMENT='<!-- auto-review-verdict -->
🟢 Auto-review verdict: **pass** — looks good.'
WARN_COMMENT='<!-- auto-review-verdict -->
🟡 Auto-review verdict: **warn** — nits only.'

run_case "pass arms"                         yes pass "$PASS_COMMENT"
run_case "warn arms (nits do not block)"     yes warn "$WARN_COMMENT"
run_case "fail does not arm"                 no  fail "$FAIL_COMMENT"
run_case "empty verdict does not arm"        no  ""   ""
# The regression: this run said pass, but a concurrent run already recorded a
# fail. Arming here is what merged fetchproxy#274 over a red verdict.
run_case "pass does NOT arm over a recorded fail" no pass "$FAIL_COMMENT"
run_case "warn does NOT arm over a recorded fail" no warn "$FAIL_COMMENT"
# No recorded verdict yet (this run is first to finish) — must still arm, or
# the ordinary single-review path would stop arming entirely.
run_case "pass arms when nothing is recorded yet" yes pass ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

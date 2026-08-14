#!/usr/bin/env bash
# Unit tests for fleet-drift.yml's sweep script — the daily "is fleet.json still
# true?" run.
#
# The step is pure bash over `jq`, `scripts/rollout.sh --check` and `gh`, so it
# can be tested hermetically the same way gate.test.sh tests the arm-gate: stub
# the dependencies on PATH and run the REAL script, extracted from the shipped
# YAML at run time rather than copied here, so a workflow change that isn't
# reflected here fails rather than silently drifting.
#
# Why this file exists: every failure mode of this sweep is a *quiet* one. It
# reports coverage in prose ("no drift in the 61 repos checked"), and nothing
# downstream reads that. Issue #122 is the worked example — 8 of 71 repos had
# never once been checked because their pat_secret was not a secret on this
# repo, the run was green every single day, and the only trace was a
# `::warning::` nobody opens a green run to read. The rows below pin the two
# distinctions that make the run's colour mean something: a permanent coverage
# hole (missing secret) is red, a transient one (API error) is not, and neither
# may ever let a stale drift issue be closed as "clean".
#
# Usage: bash scripts/fleet-drift.test.sh
set -uo pipefail   # deliberately no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/fleet-drift.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# --- extract the sweep script from the shipped workflow --------------------
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"]["check"]["steps"].find { |s| s["name"] =~ /Check every fleet repo/ }
  abort("could not find the sweep step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/sweep.sh" || { echo "FAIL: could not extract the sweep step from $WF"; exit 1; }

# --- fake fleet root -------------------------------------------------------
# Three repos: two on the default pat_secret, one on a distinct one — the exact
# shape that produced #122.
ROOT="$TMP/root"
mkdir -p "$ROOT/scripts"
cat > "$ROOT/fleet.json" <<'JSON'
{
  "defaults": { "pat_secret": "RELEASE_PAT" },
  "repos": [
    { "repo": "FAKE/a" },
    { "repo": "FAKE/b" },
    { "repo": "NULL/c", "pat_secret": "NULLNET_RELEASE_PAT" }
  ]
}
JSON

# --- fake rollout.sh -------------------------------------------------------
# Exit code per repo comes from $CHECK_PLAN ("FAKE/a=0 FAKE/b=1"), defaulting
# to 0. Also records which token each repo was probed with: probing a private
# repo with the wrong token 404s, which --check reads back as MISSING, i.e.
# false drift — so "right token per repo" is a correctness property, not a nit.
cat > "$ROOT/scripts/rollout.sh" <<'STUB'
#!/usr/bin/env bash
repo="$1"
echo "$repo ${GH_TOKEN:-(none)}" >> "$PROBES"
code=0
for pair in ${CHECK_PLAN:-}; do
  case "$pair" in "$repo="*) code="${pair#*=}" ;; esac
done
case "$code" in
  1) echo "-  ci.yml: uses: chrischall/workflows/...@main"
     echo "+  ci.yml: uses: chrischall/workflows/...@v1" ;;
  2) echo "gh: Internal Server Error (HTTP 500)" >&2 ;;
esac
exit "$code"
STUB
chmod +x "$ROOT/scripts/rollout.sh"

# --- fake gh ---------------------------------------------------------------
# Records every call, and serves the marker-issue lookup from $EXISTING_ISSUE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
if [ "${1:-}" = "api" ]; then printf '%s\n' "${EXISTING_ISSUE:-}"; fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# sweep <name> <want_exit> <want_issue_action> [ENV=val ...]
#   want_issue_action: create | edit | close | none
sweep() {
  local name="$1" want_exit="$2" want_action="$3"; shift 3
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GH_CALLS="$dir/gh" PROBES="$dir/probes" GITHUB_STEP_SUMMARY="$dir/summary"
  : > "$GH_CALLS"; : > "$PROBES"; : > "$GITHUB_STEP_SUMMARY"
  # Baseline: both secrets present, every repo clean, no open drift issue.
  export RELEASE_PAT=rp NULLNET_RELEASE_PAT=np CHECK_PLAN="" EXISTING_ISSUE="" \
         GITHUB_REPOSITORY=chrischall/workflows GITHUB_RUN_ID=1 \
         GITHUB_SERVER_URL=https://github.com GH_TOKEN=gt
  local kv; for kv in "$@"; do export "${kv?}"; done

  # -eo pipefail: what Actions actually runs a `run:` step with.
  ( cd "$ROOT" && bash -eo pipefail "$TMP/sweep.sh" ) >"$dir/log" 2>&1
  local got_exit=$?
  local got_action=none
  grep -q 'issue create' "$GH_CALLS" && got_action=create
  grep -q 'issue edit'   "$GH_CALLS" && got_action=edit
  grep -q 'issue close'  "$GH_CALLS" && got_action=close

  if [ "$got_exit" = "$want_exit" ] && [ "$got_action" = "$want_action" ]; then
    ok "$name (exit=$got_exit, issue=$got_action)"
  else
    bad "$name" "got exit=$got_exit issue=$got_action; wanted exit=$want_exit issue=$want_action
     $(sed 's/^/     /' "$dir/log")"
  fi
  LAST_DIR="$dir"
}

echo "── fully checked sweeps ──"
sweep "all clean, no open issue → green, nothing to do"     0 none
sweep "all clean, open issue → green, close it"             0 close  EXISTING_ISSUE=42
sweep "drift, no open issue → red, open one"                1 create CHECK_PLAN="FAKE/b=1"
sweep "drift, open issue → red, update it"                  1 edit   CHECK_PLAN="FAKE/b=1" EXISTING_ISSUE=42

echo "── transient coverage gaps (API error) ──"
# An outage is not drift and not a config hole: warn, stay green, but never
# close the issue on a partial sweep — an outage must not read as "clean".
sweep "API error, otherwise clean → green, no close"        0 none   CHECK_PLAN="FAKE/b=2"
sweep "API error + open issue → green, issue left open"     0 none   CHECK_PLAN="FAKE/b=2" EXISTING_ISSUE=42
sweep "API error + real drift → red, drift still reported"  1 create CHECK_PLAN="FAKE/a=2 FAKE/b=1"

echo "── permanent coverage holes (missing pat_secret) — issue #122 ──"
# The bug: this was exit 0 with a warning, so 8 repos sat unchecked behind a
# green daily run for months. A missing secret cannot fix itself; it is red.
sweep "missing secret, otherwise clean → RED"               3 none   NULLNET_RELEASE_PAT=
sweep "missing secret + open issue → red, no close"         3 none   NULLNET_RELEASE_PAT= EXISTING_ISSUE=42
sweep "missing secret + drift → drift wins (exit 1)"        1 create NULLNET_RELEASE_PAT= CHECK_PLAN="FAKE/b=1"
sweep "missing secret + API error → still red"              3 none   NULLNET_RELEASE_PAT= CHECK_PLAN="FAKE/a=2"

echo "── annotations and bookkeeping ──"
sweep "baseline for annotation checks"                      3 none   NULLNET_RELEASE_PAT=
if grep -q '^::error::.*NULL/c' "$LAST_DIR/log"; then
  ok "missing secret is an ::error::, naming the repo"
else
  bad "missing secret is an ::error::, naming the repo" "$(sed 's/^/     /' "$LAST_DIR/log")"
fi
if grep -q 'NULLNET_RELEASE_PAT' "$LAST_DIR/log"; then
  ok "the annotation names the secret to add"
else
  bad "the annotation names the secret to add" "$(sed 's/^/     /' "$LAST_DIR/log")"
fi

sweep "probe tokens" 0 none
# Bash indirection picks the credential per repo; getting this wrong reads back
# as MISSING stubs, i.e. false drift, not as an auth error.
if [ "$(sort "$LAST_DIR/probes")" = "$(printf 'FAKE/a rp\nFAKE/b rp\nNULL/c np')" ]; then
  ok "each repo is probed with its own pat_secret"
else
  bad "each repo is probed with its own pat_secret" "$(sed 's/^/     /' "$LAST_DIR/probes")"
fi

sweep "summary counts" 1 create CHECK_PLAN="FAKE/b=1 FAKE/a=2" NULLNET_RELEASE_PAT=
if grep -qE 'OK: 0 .*drifted: 1' "$LAST_DIR/summary" &&
   grep -qE 'unconfigured: 1' "$LAST_DIR/summary" &&
   grep -qE 'unchecked: 1' "$LAST_DIR/summary"; then
  ok "step summary counts all four buckets separately"
else
  bad "step summary counts all four buckets separately" "$(sed 's/^/     /' "$LAST_DIR/summary")"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

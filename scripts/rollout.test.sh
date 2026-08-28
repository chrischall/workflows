#!/usr/bin/env bash
# Unit tests for `rollout.sh --check`, the drift detector.
#
# --check is the one mode with a single external dependency (`gh`), so it can be
# tested hermetically: stub `gh` on PATH and run the REAL script against a fake
# fleet root. The fake root is a directory holding a fixture fleet.json, a
# symlink to the real templates/, and a symlink to the real scripts/rollout.sh —
# the script derives its own HERE from `dirname $0`, so this exercises the
# shipped file byte-for-byte with no test-only hooks in it.
#
# Usage: bash scripts/rollout.test.sh
set -uo pipefail   # deliberately no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# --- fake fleet root -------------------------------------------------------
ROOT="$TMP/root"
mkdir -p "$ROOT/scripts"
ln -s "$HERE/scripts/rollout.sh" "$ROOT/scripts/rollout.sh"
ln -s "$HERE/templates" "$ROOT/templates"
# Real defaults, one synthetic repo: a connector repo gets the widest stub set
# (auto-merge, ci, claude, deploy-connector, pr-auto-review, release-please),
# which is what makes "report EVERY drifted stub" testable at all.
# FAKE/y exists only to exercise the ci_dispatch opt-in: the render path that
# adds `workflow_dispatch:` to ci.yml is conditional, and both branches have to
# be pinned — an always-on trigger would silently drift all 60 standard-CI
# repos, and an always-off one would silently drop the escape hatch the repo
# that opted in is relying on.
jq '{defaults: .defaults,
     repos: [{repo: "FAKE/x", connector: "true"},
             {repo: "FAKE/y", ci_dispatch: "true"}]}' \
  "$HERE/fleet.json" > "$ROOT/fleet.json"
ROLLOUT="$ROOT/scripts/rollout.sh"

# --- fake gh ---------------------------------------------------------------
# Serves $GH_FIXTURES/<name> for `gh api repos/*/contents/.github/workflows/<name>`;
# a missing fixture is a 404, and GH_FAIL_MODE forces a non-404 API failure.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "fake gh: unsupported invocation: $*" >&2; exit 1; }
if [ -n "${GH_FAIL_MODE:-}" ]; then
  echo "gh: Internal Server Error (HTTP $GH_FAIL_MODE)" >&2
  exit 1
fi
name="${2##*/}"
if [ -f "$GH_FIXTURES/$name" ]; then
  # Line-wrapped, as the contents API returns it (and as `--jq .content`
  # hands it back) — the decode has to survive embedded newlines.
  base64 < "$GH_FIXTURES/$name" | tr -d '\n' | fold -w 60
  echo
else
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- helpers ---------------------------------------------------------------
# Canonical (drift-free) rendering of FAKE/x's stubs, produced by the script
# itself: fixtures that started as the real output make "drift" mean what it
# means in production instead of whatever a hand-written fixture happened to say.
CANON="$TMP/canon"
bash "$ROLLOUT" FAKE/x --render "$CANON" >/dev/null || {
  echo "setup failed: --render did not produce fixtures"; exit 1; }

# The opted-in repo's own canonical stubs. --check RENDERS and then diffs, so
# the ci_dispatch branch of render() is on the drift-detection path too, not
# just --render: a regression there reports every opted-in repo as drifted, or
# worse, stops noticing when one silently loses the escape hatch.
CANON_Y="$TMP/canon-y"
bash "$ROLLOUT" FAKE/y --render "$CANON_Y" >/dev/null || {
  echo "setup failed: --render did not produce FAKE/y fixtures"; exit 1; }

fixtures_y() { # fixtures_y <case> -> fresh copy of FAKE/y's canonical stubs
  local dir="$TMP/casey-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$CANON_Y"/* "$dir"/
  printf '%s' "$dir"
}

fixtures() { # fixtures <case> -> fresh copy of the canonical stubs, echoes dir
  local dir="$TMP/case-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$CANON"/* "$dir"/
  printf '%s' "$dir"
}

run_check() { # run_check <fixture-dir> -> writes $OUT and $ERR, sets $CODE
  # stdout and stderr are captured SEPARATELY on purpose. The report is stdout;
  # stderr is diagnostics. Merging them let a stray diagnostic land in the
  # middle of the report — which is exactly how the EPIPE bug below hid, since
  # every assertion here still matched with a broken-pipe line wedged between a
  # DRIFT header and its diff body.
  OUT="$TMP/out.txt"; ERR="$TMP/err.txt"
  GH_FIXTURES="$1" bash "$ROLLOUT" "${2:-FAKE/x}" --check > "$OUT" 2> "$ERR"
  CODE=$?
}

# --check talks to the network and reports what it found; anything on stderr is
# a bug in the script itself, and it corrupts the body pasted into the drift
# issue. Asserting emptiness is what catches a SIGPIPE/EPIPE regression: the
# stdout assertions alone all passed while the report was being polluted.
assert_clean_stderr() { # assert_clean_stderr <case>
  if [ ! -s "$ERR" ]; then ok "$1: nothing written to stderr"
  else bad "$1: expected clean stderr" "$(sed 's/^/       /' "$ERR")"; fi
}

assert_has() { # assert_has <test> <needle>
  if grep -qF -- "$2" "$OUT"; then ok "$1: reports '$2'"
  else bad "$1: expected '$2'" "got:$(printf '\n')$(sed 's/^/       /' "$OUT")"; fi
}
assert_lacks() {
  if grep -qF -- "$2" "$OUT"; then bad "$1: did not expect '$2'" "got:$(printf '\n')$(sed 's/^/       /' "$OUT")"
  else ok "$1: does not report '$2'"; fi
}
assert_code() {
  if [ "$CODE" = "$2" ]; then ok "$1: exit $2"
  else bad "$1: expected exit $2, got $CODE" "output:$(printf '\n')$(sed 's/^/       /' "$OUT")"; fi
}

# --- A: two drifted stubs are BOTH reported --------------------------------
# The regression this file exists for. `diff` exits 1 by design when files
# differ, so under `set -euo pipefail` the first drifting stub killed the loop
# and every later stub went unexamined — silent under-reporting, not a crash.
DIR=$(fixtures a)
printf '\n# hand-edited: ci\n' >> "$DIR/ci.yml"
printf '\n# hand-edited: release-please\n' >> "$DIR/release-please.yml"
run_check "$DIR"
assert_has  A "DRIFT    FAKE/x/ci.yml"
assert_has  A "DRIFT    FAKE/x/release-please.yml"
# The headers are not the report — the per-stub diff body IS the payload that
# fleet-drift.yml pastes into the issue. Assert it survives, or a change that
# stops printing it ships green through the CI step this suite backs.
assert_has  A "# hand-edited: ci"
assert_code A 1
assert_clean_stderr A

# --- B: drift does not hide a MISSING stub later in the set ----------------
DIR=$(fixtures b)
printf '\n# hand-edited: ci\n' >> "$DIR/ci.yml"
rm "$DIR/deploy-connector.yml"
run_check "$DIR"
assert_has  B "DRIFT    FAKE/x/ci.yml"
assert_has  B "MISSING  FAKE/x/deploy-connector.yml"
assert_code B 1

# --- C: clean repo is OK ---------------------------------------------------
DIR=$(fixtures c)
run_check "$DIR"
assert_has   C "OK       FAKE/x"
assert_lacks C "DRIFT"
assert_code  C 0

# --- D: a non-404 API failure is "unknown" (exit 2), not "missing" ---------
DIR=$(fixtures d)
OUT="$TMP/out.txt"; ERR="$TMP/err.txt"
GH_FIXTURES="$DIR" GH_FAIL_MODE=500 bash "$ROLLOUT" FAKE/x --check > "$OUT" 2> "$ERR"
CODE=$?
assert_has   D "ERROR    FAKE/x/"
assert_lacks D "MISSING"
assert_code  D 2
# The stub's 500 goes to rollout.sh's own gh.err buffer and comes back on
# stdout as `ERROR`; an API failure is reported, never leaked raw.
assert_clean_stderr D

# --- E: a diff LONGER than the pipe buffer still reports every later stub ----
# Case A covers the `diff` half of rollout.sh's `|| true`: diff exits 1 on any
# difference, so a 2-line edit is enough to catch a regression that drops it.
# It cannot catch the OTHER half — a reader that stops early while something
# upstream is still writing, which costs either the rest of the loop or the
# integrity of the report.
#
# rollout.sh now has no such reader: the comparison is a string test rather
# than `diff -q`, and the 20-line cap is `sed -n '1,20p'` (consumes the stream)
# rather than `| head -20` (exits at 20). This case is the regression test for
# both, and it needs a diff big enough to outlast a pipe buffer before any of
# it bites — not merely longer than the 20-line cap. macOS sizes that buffer up
# to 64KB, so a "21 line" fixture proves nothing. The 5000 lines below are
# 160KB of filler, ~190KB once diff framing and the 4-space prefix are added.
# Do not "simplify" them down.
#
# Note this has only ever FAILED on a CI runner, and did not reproduce locally
# across bash 3.2/5.3, BSD and GNU diff, or inputs up to 200k lines — it is a
# race on whether the reader exits before the writer finishes. A green local
# run therefore does not clear this case; the stderr assertion below is what
# reports it honestly if it ever comes back.
# (Note also the braces must enclose the `|| true`: `{ diff ...; } || true |
# sed ...` parses as `{ diff ...; } || (true | sed ...)` and is a different bug.)
#
# ci.yml is early in the stub glob and release-please.yml is last, so the
# assertion that BOTH are reported is what fails if the loop dies early.
DIR=$(fixtures e)
awk 'BEGIN{for(i=1;i<=5000;i++) printf "# hand-edited filler line %05d\n", i}' >> "$DIR/ci.yml"
printf '\n# hand-edited: release-please\n' >> "$DIR/release-please.yml"
run_check "$DIR"
assert_has  E "DRIFT    FAKE/x/ci.yml"
assert_has  E "DRIFT    FAKE/x/release-please.yml"
assert_code E 1
# ...and the cap itself still holds: the indented diff body printed under
# ci.yml's header is exactly 20 lines, not 5000 pasted into a GitHub issue.
BODY=$(awk '/^DRIFT    FAKE\/x\/ci\.yml$/{f=1;next} f&&/^    /{c++;next} f{exit} END{print c+0}' "$OUT")
if [ "$BODY" = 20 ]; then ok "E: ci.yml diff body capped at 20 lines"
else bad "E: expected a 20-line diff body for ci.yml, got $BODY" "head of output:$(printf '\n')$(head -5 "$OUT" | sed 's/^/       /')"; fi
# The assertion that actually catches EPIPE: a 190KB diff must not make the
# script say anything on stderr. This is the row that was red on CI.
assert_clean_stderr E

# --- F: the PR body carries --reason, and stays honest without it ----------
# The body is the ONLY thing a consumer repo's auto-review sees explaining why
# a stub changed. When the motive lives in chrischall/workflows, a body saying
# just "regenerated from fleet.json" reads as an unexplained removal — and the
# reviewer refuses, correctly (tock-mcp#73, failed twice on exactly that).
#
# This failure mode is silent: a PR that under-explains itself is structurally
# indistinguishable from one that doesn't, and no check downstream looks. So
# `--pr-body` renders the body with no network and no clone, and these pin it.
run_body() { # run_body <args...> -> writes $OUT, sets $CODE
  OUT="$TMP/body.txt"; ERR="$TMP/body-err.txt"
  bash "$ROLLOUT" FAKE/x --pr-body "$@" > "$OUT" 2> "$ERR"
  CODE=$?
}

run_body --only release-please --reason "The pin dodged a hard error #56 removed."
assert_code  F1 0
assert_has   F1 "## Why this change"
assert_has   F1 "The pin dodged a hard error #56 removed."
assert_has   F1 "Single-stub sync"
assert_clean_stderr F1

# No --reason: no empty heading. A "## Why this change" with nothing under it
# is worse than none — it reads as a section someone forgot to fill in.
run_body --only release-please
assert_code  F2 0
assert_lacks F2 "## Why this change"
assert_has   F2 "Single-stub sync"

# Full conversion body keeps its stub inventory AND takes a reason.
run_body --reason "Fleet-wide template correction."
assert_code  F3 0
assert_has   F3 "## Why this change"
assert_has   F3 "Fleet-wide template correction."
assert_has   F3 "- pr-auto-review: reusable"
assert_has   F3 "After this PR is open, run"

# --- G: ci_dispatch renders the manual trigger, and only when opted in -----
G="$TMP/g-off"; bash "$ROLLOUT" FAKE/x --render "$G" >/dev/null
if grep -q '^  workflow_dispatch:$' "$G/ci.yml"; then
  bad "G: unset ci_dispatch" "ci.yml gained workflow_dispatch without opting in"
else ok "G: unset ci_dispatch leaves ci.yml without workflow_dispatch"; fi
# The rationale comment must go with it — a stranded comment explaining a
# trigger that is not there is how the skill-path block drifted (issue #138).
if grep -q 'A manual gate, for when the automatic one' "$G/ci.yml"; then
  bad "G: unset ci_dispatch" "the rationale comment was left behind without its trigger"
else ok "G: unset ci_dispatch drops the rationale comment too"; fi

G2="$TMP/g-on"; bash "$ROLLOUT" FAKE/y --render "$G2" >/dev/null
if grep -q '^  workflow_dispatch:$' "$G2/ci.yml"; then
  ok "G: ci_dispatch=true renders workflow_dispatch"
else bad "G: ci_dispatch=true" "ci.yml has no workflow_dispatch:$(printf '\n')$(sed -n '10,20p' "$G2/ci.yml")"; fi
# It has to sit under `on:`, not merely appear somewhere in the file.
if ruby -ryaml -e 'y=YAML.load_file(ARGV[0]); exit(y[true].key?("workflow_dispatch") ? 0 : 1)' "$G2/ci.yml" 2>/dev/null; then
  ok "G: workflow_dispatch parses as a trigger under on:"
else bad "G: ci_dispatch=true" "workflow_dispatch is not a key under on:"; fi

# --- H: --check over an opted-in repo, both directions ---------------------
# CLAUDE.md: any change to what --check compares needs a case here, because its
# failure mode is a report that quietly says less than it should.
DIR=$(fixtures_y h1)
run_check "$DIR" FAKE/y
assert_has  H1 "OK       FAKE/y"
assert_code H1 0
assert_clean_stderr H1

# A repo that lost its dispatch trigger must be REPORTED, not shrugged off —
# that is the whole point of recording the opt-in in fleet.json rather than
# leaving it a hand-edit the next --execute deletes (issue #76).
DIR=$(fixtures_y h2)
grep -v '^  workflow_dispatch:$' "$DIR/ci.yml" > "$DIR/ci.yml.tmp" && mv "$DIR/ci.yml.tmp" "$DIR/ci.yml"
run_check "$DIR" FAKE/y
assert_has  H2 "DRIFT    FAKE/y/ci.yml"
assert_code H2 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

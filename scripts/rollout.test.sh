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
jq '{defaults: .defaults, repos: [{repo: "FAKE/x", connector: "true"}]}' \
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

fixtures() { # fixtures <case> -> fresh copy of the canonical stubs, echoes dir
  local dir="$TMP/case-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$CANON"/* "$dir"/
  printf '%s' "$dir"
}

run_check() { # run_check <fixture-dir> -> writes $OUT, sets $CODE
  OUT="$TMP/out.txt"
  GH_FIXTURES="$1" bash "$ROLLOUT" FAKE/x --check > "$OUT" 2>&1
  CODE=$?
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
OUT="$TMP/out.txt"
GH_FIXTURES="$DIR" GH_FAIL_MODE=500 bash "$ROLLOUT" FAKE/x --check > "$OUT" 2>&1
CODE=$?
assert_has   D "ERROR    FAKE/x/"
assert_lacks D "MISSING"
assert_code  D 2

# --- E: a diff LONGER than the pipe buffer still reports every later stub ----
# Case A covers the `diff` half of rollout.sh's `|| true`: diff exits 1 on any
# difference, so a 2-line edit is enough to catch a regression that drops it.
# It cannot catch the OTHER half. `head -20` exits after 20 lines and `sed`
# keeps writing into a closed pipe, so a half-fix that neutralises only diff's
# exit status (`{ diff ... || true; } | sed ... | head -20`) still dies of
# SIGPIPE mid-loop and silently under-reports every stub after this one.
# (Note the braces must enclose the `|| true`: `{ diff ...; } || true | sed ...`
# parses as `{ diff ...; } || (true | sed ...)` and is a different bug.)
#
# SIGPIPE needs sed to still be WRITING when head exits — i.e. enough output to
# outlast the pipe buffer, not merely more than the 20-line cap. macOS sizes
# that buffer up to 64KB, so a "21 line" fixture proves nothing: it truncates
# without ever signalling. Measured against the half-fix above, 21 / 50 / 200
# filler lines all leave the suite GREEN on a broken script; it only starts
# failing around 1000. The 5000 lines below are what `sed` actually writes:
# 160KB of filler, ~190KB once diff framing and the 4-space prefix are added —
# roughly 5x the observed trigger point, and the whole point of this case.
# Do not "simplify" them down.
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

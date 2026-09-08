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
# FAKE/z exists only to exercise the NEGATIVE render paths: with a non-standard
# ci mode neither ci.yml nor ci-fork-status.yml may be produced. Without it the
# "and never without it" half of case I was asserted by the case name and
# tested by nothing.
# FAKE/y exists only to exercise the ci_dispatch opt-in: the render path that
# adds `workflow_dispatch:` to ci.yml is conditional, and both branches have to
# be pinned — an always-on trigger would silently drift all 60 standard-CI
# repos, and an always-off one would silently drop the escape hatch the repo
# that opted in is relying on.
# FAKE/g is a gradle repo: its dependabot config must watch gradle, never npm.
# FAKE/n opts out of both repo-config templates, which is the only way to prove
# an opt-out renders NOTHING rather than an empty file.
jq '{defaults: .defaults,
     repos: [{repo: "FAKE/x", connector: "true", package_name: "fake-x",
              version_files: "src/version.ts"},
             {repo: "FAKE/y", ci_dispatch: "true", package_name: "fake-y"},
             {repo: "FAKE/z", ci: "none", package_name: "fake-z"},
             {repo: "FAKE/g", dependabot: "gradle", ci: "none", release: "none",
              package_name: "fake-g"},
             {repo: "FAKE/a", dependabot: "actions", ci: "none", release: "none",
              package_name: "fake-a"},
             {repo: "FAKE/i", dependabot_ignore: "agents-peer", ci: "none",
              release: "none", package_name: "fake-i"},
             {repo: "FAKE/bad", dependabot_ignore: "no-such-fragment",
              ci: "none", release: "none", package_name: "fake-bad"},
             {repo: "FAKE/n", dependabot: "none", release_config: "none",
              release_notes: "none"}]}' \
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
# `gh api repos/<owner>/<repo>/contents/<path>` -> fixture at <path>.
# Keyed on the full path so a --check that looks in the wrong directory 404s
# here exactly as it would against GitHub, instead of quietly matching a
# same-named file somewhere else.
name="${2#*/contents/}"
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
  cp -R "$CANON_Y"/. "$dir"/
  printf '%s' "$dir"
}

fixtures() { # fixtures <case> -> fresh copy of the canonical stubs, echoes dir
  local dir="$TMP/case-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp -R "$CANON"/. "$dir"/
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
printf '\n# hand-edited: ci\n' >> "$DIR/.github/workflows/ci.yml"
printf '\n# hand-edited: release-please\n' >> "$DIR/.github/workflows/release-please.yml"
run_check "$DIR"
assert_has  A "DRIFT    FAKE/x/.github/workflows/ci.yml"
assert_has  A "DRIFT    FAKE/x/.github/workflows/release-please.yml"
# The headers are not the report — the per-stub diff body IS the payload that
# fleet-drift.yml pastes into the issue. Assert it survives, or a change that
# stops printing it ships green through the CI step this suite backs.
assert_has  A "# hand-edited: ci"
assert_code A 1
assert_clean_stderr A

# --- B: drift does not hide a MISSING stub later in the set ----------------
DIR=$(fixtures b)
printf '\n# hand-edited: ci\n' >> "$DIR/.github/workflows/ci.yml"
rm "$DIR/.github/workflows/deploy-connector.yml"
run_check "$DIR"
assert_has  B "DRIFT    FAKE/x/.github/workflows/ci.yml"
assert_has  B "MISSING  FAKE/x/.github/workflows/deploy-connector.yml"
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
awk 'BEGIN{for(i=1;i<=5000;i++) printf "# hand-edited filler line %05d\n", i}' >> "$DIR/.github/workflows/ci.yml"
printf '\n# hand-edited: release-please\n' >> "$DIR/.github/workflows/release-please.yml"
run_check "$DIR"
assert_has  E "DRIFT    FAKE/x/.github/workflows/ci.yml"
assert_has  E "DRIFT    FAKE/x/.github/workflows/release-please.yml"
assert_code E 1
# ...and the cap itself still holds: the indented diff body printed under
# ci.yml's header is exactly 20 lines, not 5000 pasted into a GitHub issue.
BODY=$(awk '/^DRIFT    FAKE\/x\/\.github\/workflows\/ci\.yml$/{f=1;next} f&&/^    /{c++;next} f{exit} END{print c+0}' "$OUT")
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
if grep -q '^  workflow_dispatch:$' "$G/.github/workflows/ci.yml"; then
  bad "G: unset ci_dispatch" "ci.yml gained workflow_dispatch without opting in"
else ok "G: unset ci_dispatch leaves ci.yml without workflow_dispatch"; fi
# The rationale comment must go with it — a stranded comment explaining a
# trigger that is not there is how the skill-path block drifted (issue #138).
if grep -q 'A manual gate, for when the automatic one' "$G/.github/workflows/ci.yml"; then
  bad "G: unset ci_dispatch" "the rationale comment was left behind without its trigger"
else ok "G: unset ci_dispatch drops the rationale comment too"; fi

G2="$TMP/g-on"; bash "$ROLLOUT" FAKE/y --render "$G2" >/dev/null
if grep -q '^  workflow_dispatch:$' "$G2/.github/workflows/ci.yml"; then
  ok "G: ci_dispatch=true renders workflow_dispatch"
else bad "G: ci_dispatch=true" "ci.yml has no workflow_dispatch:$(printf '\n')$(sed -n '10,20p' "$G2/.github/workflows/ci.yml")"; fi
# It has to sit under `on:`, not merely appear somewhere in the file.
if ruby -ryaml -e 'y=YAML.load_file(ARGV[0]); exit(y[true].key?("workflow_dispatch") ? 0 : 1)' "$G2/.github/workflows/ci.yml" 2>/dev/null; then
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
grep -v '^  workflow_dispatch:$' "$DIR/.github/workflows/ci.yml" > "$DIR/.github/workflows/ci.yml.tmp" && mv "$DIR/.github/workflows/ci.yml.tmp" "$DIR/.github/workflows/ci.yml"
run_check "$DIR" FAKE/y
assert_has  H2 "DRIFT    FAKE/y/.github/workflows/ci.yml"
assert_code H2 1

# --- I: ci-fork-status renders with standard CI, and never without it ------
# Sequenced after H so the file keeps its A-H-I lettering; it was first added
# between G and H, which read as a renumbering rather than an addition.
# CLAUDE.md: a new stub needs a case here. This one has a sharper failure than
# most — the workflow triggers on the "CI" workflow BY NAME, so rendering it
# where ci.yml is absent produces a workflow that can never fire and silently
# never posts `ci-gated` for a fork.
I="$TMP/i-std"; bash "$ROLLOUT" FAKE/x --render "$I" >/dev/null
if [ -f "$I/.github/workflows/ci-fork-status.yml" ]; then
  ok "I: standard CI mode renders ci-fork-status.yml"
else bad "I: standard CI" "ci-fork-status.yml was not rendered alongside ci.yml"; fi

# It must trigger on the CI workflow's NAME, and only for completed runs.
if ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  wr = y[true]["workflow_run"]
  exit(wr["workflows"] == ["CI"] && wr["types"] == ["completed"] ? 0 : 1)' "$I/.github/workflows/ci-fork-status.yml" 2>/dev/null; then
  ok "I: triggers on workflow_run of \"CI\", completed only"
else bad "I: trigger shape" "workflow_run does not name the CI workflow on completion"; fi

# The pwn-request guard: it must never check out head-repo content.
# Match a USES line, not the security comment that warns against it — a bare
# grep for the string matches that comment and fails on a correct file.
if grep -qE "^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*actions/checkout" "$I/.github/workflows/ci-fork-status.yml"; then
  bad "I: security" "ci-fork-status.yml checks out code — it runs with a WRITE token on untrusted forks"
else ok "I: ci-fork-status.yml checks out nothing (pwn-request guard)"; fi

# And it must only act on forks; a same-repo PR posts its own status.
if grep -q "head_repository.full_name != github.repository" "$I/.github/workflows/ci-fork-status.yml"; then
  ok "I: guarded to fork PRs only"
else bad "I: fork guard" "missing the head_repository != repository condition"; fi

# The "never without it" half needs a repo whose ci mode is NOT standard —
# there was no such fixture, so that claim was asserted by the case NAME and
# tested by nothing. FAKE/z has `ci: "none"`.
IZ="$TMP/i-none"; bash "$ROLLOUT" FAKE/z --render "$IZ" >/dev/null
if [ -f "$IZ/.github/workflows/ci-fork-status.yml" ]; then
  bad "I: non-standard ci" "ci-fork-status.yml rendered without ci.yml — it triggers on the \"CI\" workflow by NAME, so it could never fire"
else ok "I: non-standard ci mode renders no ci-fork-status.yml"; fi
if [ -f "$IZ/.github/workflows/ci.yml" ]; then
  bad "I: non-standard ci" "ci.yml rendered for a repo with ci mode 'none'"
else ok "I: non-standard ci mode renders no ci.yml either"; fi

# --- J: the PR-creation path's labelling invariants ------------------------
# Static assertions, not behavioural: the suite never runs --execute (it would
# push branches and open PRs), so the label step cannot be exercised. These pin
# the two properties whose failure would be worst.
#
# The first is the serious one. rollout.sh opens PRs across the whole fleet in
# one sweep; if it ever applied an ARMING label, sixty PRs would auto-merge
# without a human or a review having seen them.
if grep -nE "add-label[[:space:]]+(ready-to-merge|release-ready)" "$ROLLOUT" >/dev/null; then
  bad "J: arming" "rollout.sh applies an ARMING label — a fleet sweep would auto-merge every PR it opens"
else ok "J: rollout.sh never applies an arming label"; fi

# Second: the label is best-effort. The sync is already pushed and the PR
# already open by then, so a labelling hiccup must not read as a failed
# rollout — the branch would look unsynced when it is not.
if grep -A2 'gh pr edit "$PR_URL"' "$ROLLOUT" | grep -q "2>/dev/null\|>/dev/null 2>&1"; then
  ok "J: the label step is best-effort (failure does not abort the rollout)"
else bad "J: best-effort" "the label step can abort a rollout that already pushed and opened its PR"; fi

# And it must be guarded on the label existing: a repo with no `ci` label has no
# such convention to satisfy, and erroring there would fail rollouts that are
# entirely correct.
if grep -q 'gh label list --repo "$REPO"' "$ROLLOUT"; then
  ok "J: label applied only where the repo has one"
else bad "J: guard" "the label is applied unconditionally"; fi


# --- K: stubs render to their REPO-RELATIVE paths, not a flat directory -----
# The whole point of the destination-path change: templates that do not live in
# .github/workflows/ (dependabot.yml, release-please-config.json,
# .github/release.yml) have to land where the consumer repo actually keeps
# them. A flat stage silently put every one of them in .github/workflows/,
# where dependabot and release-please would never look — a no-op rollout that
# reports success.
DIR="$TMP/paths"
bash "$ROLLOUT" FAKE/x --render "$DIR" >/dev/null 2>&1
for want in .github/workflows/ci.yml \
            .github/workflows/pr-auto-review.yml \
            .github/dependabot.yml \
            .github/release.yml \
            release-please-config.json; do
  if [ -f "$DIR/$want" ]; then ok "K: renders $want"
  else bad "K: $want" "not rendered; got:$(printf '\n')$(cd "$DIR" && find . -type f | sed 's|^\./|       |')"; fi
done

# --- L: the rendered config files are VALID, not merely present ------------
# A JSON template rendered through sed can lose its syntax to a value
# containing a quote or a backslash and still be written out happily; the
# failure then surfaces as release-please skipping the repo entirely.
if ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$DIR/release-please-config.json" 2>/dev/null; then
  ok "L: release-please-config.json is valid JSON"
else bad "L: JSON" "rendered release-please-config.json does not parse"; fi

if ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$DIR/.github/dependabot.yml" 2>/dev/null; then
  ok "L: dependabot.yml is valid YAML"
else bad "L: YAML" "rendered dependabot.yml does not parse"; fi

# The reason this whole change exists: @vitest/coverage-v8 must be pinned into
# the vitest group by EXACT name. Dependabot scores group patterns by
# specificity and hands the dependency to the highest scorer, so the wildcard
# "@vitest/*" (94) loses it to the pattern-less dev-dependencies group (500);
# the exact name scores 1000 and wins. Without this line the fleet goes back to
# two peer-conflicting PRs per vitest major that deadlock on ERESOLVE.
if grep -q '"@vitest/coverage-v8"' "$DIR/.github/dependabot.yml"; then
  ok "L: dependabot.yml pins @vitest/coverage-v8 by exact name"
else bad "L: vitest pin" "the vitest group does not list @vitest/coverage-v8 exactly"; fi

# release-please-config.json carries the RELEASE POLICY — which commit types
# bump and which stay hidden. It drifted into 78 unique copies, 8 of them with
# no changelog-sections at all, which is why it is templated now.
if ruby -rjson -e '
  c = JSON.parse(File.read(ARGV[0]))["packages"]["."]
  s = c["changelog-sections"].map { |x| x["type"] }
  hidden = c["changelog-sections"].select { |x| x["hidden"] }.map { |x| x["type"] }
  abort "missing types" unless (%w[feat fix perf ci chore test build] - s).empty?
  abort "ci/chore/test/build must be hidden" unless (%w[ci chore test build] - hidden).empty?
  abort "feat/fix must NOT be hidden" unless (%w[feat fix] & hidden).empty?
' "$DIR/release-please-config.json" 2>/dev/null; then
  ok "L: changelog-sections encode the fleet release policy"
else bad "L: policy" "rendered changelog-sections do not match the fleet release policy"; fi

# --- M: --only narrows to a stub OUTSIDE .github/workflows ------------------
# --only is how a single-template change reaches the fleet without regenerating
# everything (issue #76). It matched on a flat filename, so it could not name a
# file in another directory at all.
DIR="$TMP/only-dependabot"
bash "$ROLLOUT" FAKE/x --render "$DIR" --only dependabot >/dev/null 2>&1
if [ -f "$DIR/.github/dependabot.yml" ] && [ ! -f "$DIR/.github/workflows/ci.yml" ]; then
  ok "M: --only dependabot renders just .github/dependabot.yml"
else bad "M: --only" "expected only .github/dependabot.yml; got:$(printf '\n')$(cd "$DIR" && find . -type f | sed 's|^\./|       |')"; fi

DIR="$TMP/only-rpc"
bash "$ROLLOUT" FAKE/x --render "$DIR" --only release-please-config >/dev/null 2>&1
if [ -f "$DIR/release-please-config.json" ] && [ ! -f "$DIR/.github/workflows/release-please.yml" ]; then
  ok "M: --only release-please-config does not collide with the release-please workflow"
else bad "M: collision" "--only release-please-config did not select the config file alone"; fi

# The reverse direction of the same collision: the workflow stub and the config
# file share a name prefix, and `--only release-please` must still mean the
# workflow.
DIR="$TMP/only-rp"
bash "$ROLLOUT" FAKE/x --render "$DIR" --only release-please >/dev/null 2>&1
if [ -f "$DIR/.github/workflows/release-please.yml" ] && [ ! -f "$DIR/release-please-config.json" ]; then
  ok "M: --only release-please still means the workflow stub"
else bad "M: prefix" "--only release-please selected the wrong file(s)"; fi

# --- N: per-repo ecosystem selection ---------------------------------------
# A gradle repo must not be handed an npm dependabot config: it would open PRs
# against a package.json that does not exist, while its real dependencies go
# unwatched. FAKE/g is gradle, FAKE/z (ci: none) keeps the actions-only variant.
DIR="$TMP/gradle"
bash "$ROLLOUT" FAKE/g --render "$DIR" >/dev/null 2>&1
if grep -q "package-ecosystem: gradle" "$DIR/.github/dependabot.yml" 2>/dev/null &&
   ! grep -q "package-ecosystem: npm" "$DIR/.github/dependabot.yml" 2>/dev/null; then
  ok "N: a gradle repo renders the gradle ecosystem, not npm"
else bad "N: gradle" "gradle repo did not get the gradle dependabot config"; fi

# github-actions updates are wanted in EVERY repo, whatever the language —
# that block is the one thing all three variants share.
for v in npm gradle; do
  if grep -q "package-ecosystem: github-actions" "$TMP/${v/npm/paths}/.github/dependabot.yml" 2>/dev/null ||
     grep -q "package-ecosystem: github-actions" "$TMP/$v/.github/dependabot.yml" 2>/dev/null; then
    ok "N: $v variant still watches github-actions"
  else bad "N: $v actions" "the $v dependabot variant dropped the github-actions ecosystem"; fi
done

# --- O: opting out renders nothing rather than an empty file ---------------
# A repo with no npm/gradle manifest (or one deliberately excluded) must not
# receive a stub file at all — an empty or half-rendered dependabot.yml is a
# config error GitHub reports on the repo, not a no-op.
DIR="$TMP/optout"
bash "$ROLLOUT" FAKE/n --render "$DIR" >/dev/null 2>&1
if [ ! -e "$DIR/.github/dependabot.yml" ]; then ok "O: dependabot: none renders no file"
else bad "O: opt-out" "rendered a dependabot.yml for a repo that opted out"; fi
if [ ! -e "$DIR/release-please-config.json" ]; then ok "O: release_config: none renders no file"
else bad "O: opt-out" "rendered a release-please-config.json for a repo that opted out"; fi

# --- P: --check reports and fetches REPO-RELATIVE paths --------------------
# The report is what fleet-drift.yml pastes into the drift issue. With files in
# three directories a bare basename no longer identifies anything, and — worse
# — a --check that asks for .github/workflows/dependabot.yml gets a 404 and
# reports every repo in the fleet as MISSING a file it correctly does not have.
DIR=$(fixtures p)
printf '\n# hand-edited\n' >> "$DIR/.github/dependabot.yml"
run_check "$DIR"
assert_has  P "DRIFT    FAKE/x/.github/dependabot.yml"
assert_code P 1
assert_clean_stderr P

DIR=$(fixtures q)
rm "$DIR/release-please-config.json"
run_check "$DIR"
assert_has  P "MISSING  FAKE/x/release-please-config.json"
assert_code P 1

DIR=$(fixtures r)
run_check "$DIR"
assert_has   P "OK       FAKE/x"
assert_lacks P "MISSING"
assert_code  P 0


# --- Q: every --only a template recommends must actually resolve ------------
# The gap that let a broken instruction through review. --only names the
# DESTINATION basename, so templates/release-notes.yml -> .github/release.yml
# is `--only release`; the template's own header said `--only release-notes`,
# which exits 1. Nothing caught it because block M only exercised the two
# stubs whose template name happens to match their destination.
#
# Asserting the whole class rather than the one case: a template header is
# copied into every consumer repo, so a wrong command there is cheap to fix
# now and costs a second full fleet rollout once it has shipped to 81 repos.
# ci-gradle.yml is a starter template nothing renders, so it is exempt.
# Resolving is necessary but not sufficient: a header reading `--only claude`
# inside dependabot-npm.yml resolves perfectly and regenerates the WRONG file.
# So each template DECLARES its destination ("# Renders to: <path>") and this
# asserts the recommended name produces exactly that path — the two halves of
# the header have to agree with rollout.sh, and with each other.
#
# Content cannot be the fingerprint here: the three dependabot variants render
# to the same destination and share a byte-identical header, so a header match
# would pass whichever one happened to render.
#
# ci-gradle.yml is a starter template nothing renders, so it is exempt.
while IFS= read -r t; do
  tname=$(basename "$t")
  name=$(grep -oE -- '--only [a-z0-9-]+' "$t" | head -1 | awk '{print $2}')
  want=$(sed -n 's/^# Renders to: //p' "$t" | head -1)
  [ -n "$name" ] || continue
  if [ -z "$want" ]; then
    bad "Q: $tname" "recommends \`--only $name\` but declares no '# Renders to:' line, so nothing can check the two agree"
    continue
  fi
  # Render with a repo whose fleet.json config selects THIS template.
  case "$tname" in
    dependabot-gradle.yml)  repo=FAKE/g ;;
    dependabot-actions.yml) repo=FAKE/a ;;
    *)                      repo=FAKE/x ;;
  esac
  rm -rf "$TMP/only-q"
  if ! bash "$ROLLOUT" "$repo" --render "$TMP/only-q" --only "$name" >/dev/null 2>&1; then
    bad "Q: $tname" "its header recommends \`--only $name\`, which exits 1 — and that comment renders into every consumer repo"
    continue
  fi
  got=$(cd "$TMP/only-q" && find . -type f | sed 's|^\./||')
  if [ "$got" = "$want" ]; then
    ok "Q: $tname — --only $name renders $want"
  else
    bad "Q: $tname" "declares it renders $want, but \`--only $name\` produced $(printf '%s' "$got" | tr '\n' ' ') — the header would send an operator at the wrong file"
  fi
done < <(grep -lE -- '--only [a-z0-9-]+' "$HERE"/templates/*.yml "$HERE"/templates/*.json 2>/dev/null | grep -v ci-gradle)

# --- R: --only accepts a stub named WITH its extension ----------------------
# `--only ci.yml` worked because .yml was stripped; `--only
# release-please-config.json` did not, because only `.yml` was. Stub extensions
# vary now, so the strip has to be extension-agnostic.
for spelling in release-please-config release-please-config.json; do
  if bash "$ROLLOUT" FAKE/x --render "$TMP/only-r" --only "$spelling" >/dev/null 2>&1 &&
     [ -f "$TMP/only-r/release-please-config.json" ]; then
    ok "R: --only $spelling resolves"
  else bad "R: --only $spelling" "did not resolve to release-please-config.json"; fi
  rm -rf "$TMP/only-r"
done

# --- S: the single-stub commit body names the file it actually regenerated --
# It hardcoded templates/$ONLY.yml, which for the new stubs names templates
# that do not exist (templates/dependabot.yml, templates/release.yml). The
# commit message is the only record of what a sync touched.
if grep -q 'Regenerated \$ONLY_PATH from fleet.json' "$ROLLOUT"; then
  ok "S: single-stub commit body uses the resolved stub path"
else bad "S: commit body" "still names templates/\$ONLY.yml, which does not exist for stubs whose template and destination differ"; fi


# --- T: a repo-specific `ignore:` block survives templating -----------------
# gogcli-mcp and curtaincall were opted out of the dependabot template
# entirely, purely to protect one hand-written `ignore:` block each — which
# also cost them the vitest pin and every future fix. The block is a fragment
# now, so the config is templated AND the hold is kept. If this regresses, the
# hold disappears silently: dependabot simply starts proposing bumps that
# cannot install (gogcli's agents ceiling) or that break the build (curtaincall's
# javax-namespace JAXB pin).
DIR="$TMP/ign-on"
bash "$ROLLOUT" FAKE/i --render "$DIR" --only dependabot >/dev/null 2>&1
if ruby -ryaml -e '
    d = YAML.safe_load(File.read(ARGV[0]))
    ign = (d["updates"] || []).flat_map { |u| u["ignore"] || [] }
    abort "no ignore entries" if ign.empty?
    abort "wrong dep" unless ign.any? { |i| i["dependency-name"] == "agents" }
  ' "$DIR/.github/dependabot.yml" 2>/dev/null; then
  ok "T: dependabot_ignore splices the fragment into the rendered config"
else
  bad "T: fragment" "the ignore block did not survive rendering — the hold it protects is silently gone"
fi

# The comment marker must never survive into a consumer repo, spliced or not.
for case in ign-on paths; do
  if grep -q '__DEPENDABOT_IGNORE__' "$TMP/$case/.github/dependabot.yml" 2>/dev/null; then
    bad "T: marker ($case)" "the __DEPENDABOT_IGNORE__ marker rendered literally into the output"
  else
    ok "T: marker removed ($case)"
  fi
done

# And a repo with no fragment gets no `ignore:` key at all — an empty one is a
# config error GitHub reports on the repo.
if ruby -ryaml -e '
    d = YAML.safe_load(File.read(ARGV[0]))
    abort "ignore present" if (d["updates"] || []).any? { |u| u.key?("ignore") }
  ' "$TMP/paths/.github/dependabot.yml" 2>/dev/null; then
  ok "T: no fragment renders no ignore: key"
else
  bad "T: empty ignore" "a repo without dependabot_ignore rendered an ignore: key anyway"
fi

# --- U: a fragment name with no file is a hard error, not a silent drop -----
# Failing loudly matters more than usual here: the quiet failure is a rendered
# config that looks right and has simply lost the hold.
OUT="$TMP/badfrag.txt"
if bash "$ROLLOUT" FAKE/bad --render "$TMP/badfrag" --only dependabot >"$OUT" 2>&1; then
  bad "U: bad fragment" "an unknown dependabot_ignore name rendered successfully instead of failing"
else
  if grep -q "has no fragment" "$OUT"; then
    ok "U: an unknown dependabot_ignore name fails with a named error"
  else
    bad "U: bad fragment" "failed, but without naming the missing fragment: $(head -1 "$OUT")"
  fi
fi

# --- V: every shipped fragment is valid in the position it is spliced into --
# A fragment is indented YAML with no document of its own, so nothing else
# parses it until it is already inside 80 repos.
for f in "$HERE"/templates/fragments/dependabot-ignore-*.yml; do
  fname=$(basename "$f")
  if { echo "updates:"; echo "  - package-ecosystem: npm"; cat "$f"; } |
     ruby -ryaml -e 'd=YAML.safe_load(STDIN.read); abort "no entries" if (d["updates"][0]["ignore"]||[]).empty?' 2>/dev/null; then
    ok "V: $fname parses as an ignore block at its splice indentation"
  else
    bad "V: $fname" "does not parse as an ignore: block when spliced into an update entry"
  fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

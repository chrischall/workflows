#!/usr/bin/env bash
# The squash-message logic exists TWICE, and this is what keeps the copies honest.
#
# `reusable-pr-auto-review.yml` blocks a HUMAN PR whose squash message
# release-please cannot parse. `reusable-auto-merge.yml` replaces the body of a
# BOT one, because the review job is gated on `user_type == 'User'` and never
# runs on dependabot. Two different remedies for one defect, and both need the
# same two pieces of knowledge:
#
#   1. WHICH TEXT GitHub will actually commit. Not one thing across the fleet —
#      of the 81 repos in fleet.json, 42 squash with
#      COMMIT_OR_PR_TITLE/COMMIT_MESSAGES, 38 with PR_TITLE/PR_BODY and one
#      with a mixed PR_TITLE/COMMIT_MESSAGES — so "the PR title and body" is a
#      message most of the fleet never ships. Measuring it that way once
#      produced a wrong answer that survived two review rounds.
#   2. WHICH COMMITS MATTER. A type release-please acts on, or a `!` whatever
#      the type.
#
# Factoring them into a composite action would be the real fix. It was not done
# because the review copy is the one currently protecting the fleet and every
# consumer pins `@main`, so rewriting it is a fleet-wide production change to
# working code for a tidiness win. This test is the price of that choice: the
# copies may stay, but they may not DRIFT — and drift here is silent, because
# each file keeps working perfectly while disagreeing with the other about
# which commits are at risk.
#
# Compared after normalising whitespace and the variable name (`BLOCKING` in
# the review, `ACTS_ON` in the arm), so re-wrapping a long line is allowed and
# changing a condition, a type, or the jq program is not.
#
# Usage: bash scripts/relmsg-drift.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
ARM_WF="$HERE/.github/workflows/reusable-auto-merge.yml"
REVIEW_STEP='Check the squash message release-please will read'
ARM_STEP='Replace a dependabot squash message release-please would drop'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# Extracted from the shipped YAML, the technique relmsg.test.sh and
# verdict.test.sh use: the files are exercised as they ship, with no test-only
# hook in either of them.
extract() {
  ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
             .find { |s| s["name"] == ARGV[2] }
    abort("could not find step: #{ARGV[2]}") unless step
    File.write(ARGV[1], step["run"])
  ' "$1" "$2" "$3"
}

extract "$REVIEW_WF" "$TMP/review.sh" "$REVIEW_STEP" || { echo "FAIL: could not extract from $REVIEW_WF"; exit 1; }
extract "$ARM_WF"    "$TMP/arm.sh"    "$ARM_STEP"    || { echo "FAIL: could not extract from $ARM_WF"; exit 1; }

# Comments are stripped, line continuations dropped and whitespace collapsed,
# so the two may explain themselves differently and wrap differently; the variable name is normalised
# because the two steps legitimately name their own result.
norm() {
  # Slurped, so a line continuation is joined rather than left as a stray
  # backslash — that is formatting, and the two copies wrap differently.
  # Only `\\` immediately before a newline is removed, so jq's own escapes
  # (`split("\\n")`) survive and a change to one would still be caught.
  grep -v '^[[:space:]]*#' \
    | perl -0777 -pe 's/\\\n/ /g; s/\s+/ /g; s/^ //; s/ $//' \
    | sed 's/BLOCKING/CLASS/g; s/ACTS_ON/CLASS/g'
}

# ── 1. the reconstruction: which text GitHub will commit ──────────────────
for side in review arm; do
  awk '/MESSAGE=\$\(jq -rn/,/\$title \+ /' "$TMP/$side.sh" | norm > "$TMP/$side.jq"
done
if [ ! -s "$TMP/review.jq" ] || [ ! -s "$TMP/arm.jq" ]; then
  bad 'reconstruction is present in both files' \
      "one side yielded nothing — the jq block was renamed or removed; update this test with it"
elif diff -q "$TMP/review.jq" "$TMP/arm.jq" >/dev/null; then
  ok 'the squash-message reconstruction is identical in both workflows'
else
  bad 'the squash-message reconstruction has drifted' \
      "$(diff "$TMP/review.jq" "$TMP/arm.jq" | head -6)"
fi

# ── 2. the classification: which commits are worth acting on ──────────────
for side in review arm; do
  awk '/(BLOCKING|ACTS_ON)=0/,/^ *fi$/' "$TMP/$side.sh" | norm > "$TMP/$side.cls"
done
if [ ! -s "$TMP/review.cls" ] || [ ! -s "$TMP/arm.cls" ]; then
  bad 'type classification is present in both files' \
      "one side yielded nothing — the block was renamed; update this test with it"
elif diff -q "$TMP/review.cls" "$TMP/arm.cls" >/dev/null; then
  ok 'the conventional-type classification is identical in both workflows'
else
  bad 'the conventional-type classification has drifted' \
      "$(diff "$TMP/review.cls" "$TMP/arm.cls" | head -6)"
fi

# ── 3. the parser pin: one grammar, not two guessing at each other ────────
rev_pin=$(grep -o "@conventional-commits/parser@[0-9.]*" "$TMP/review.sh" | sort -u)
arm_pin=$(grep -o "@conventional-commits/parser@[0-9.]*" "$TMP/arm.sh" | sort -u)
if [ -n "$rev_pin" ] && [ "$rev_pin" = "$arm_pin" ]; then
  ok "both workflows pin the same parser ($rev_pin)"
else
  bad 'the parser pin has drifted' "review=[$rev_pin] arm=[$arm_pin] — a different grammar would give a different verdict"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

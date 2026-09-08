#!/usr/bin/env bash
# Unit tests for ensure-labels.sh and the labels.json contract.
#
# The failure mode this guards is quiet in both directions. A missing PIPELINE
# label does not error — the workflow that wanted it simply does not find it.
# A missing RELEASE-NOTES label leaves a .github/release.yml category that is
# valid, real, and matches nothing, so those PRs vanish into "Other Changes".
# Neither shows up as a red check anywhere.
#
# `gh` is stubbed, so this exercises the shipped script with no network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# --- A: labels.json is well-formed and the two families are disjoint -------
if jq -e . "$HERE/labels.json" >/dev/null 2>&1; then ok "A: labels.json is valid JSON"
else bad "A: json" "labels.json does not parse"; fi

dupes=$(jq -r '[.pipeline[],.["release-notes"][]]|group_by(.name)|map(select(length>1))|map(.[0].name)|join(", ")' "$HERE/labels.json")
if [ -z "$dupes" ]; then ok "A: no label is defined twice"
else bad "A: dupes" "defined more than once: $dupes"; fi

bad_color=$(jq -r '[.pipeline[],.["release-notes"][]][]|select(.color|test("^[0-9a-f]{6}$")|not)|.name' "$HERE/labels.json")
if [ -z "$bad_color" ]; then ok "A: every colour is lowercase 6-digit hex"
else bad "A: colour" "not lowercase 6-hex: $bad_color"; fi

nodesc=$(jq -r '[.pipeline[],.["release-notes"][]][]|select((.description//"")=="")|.name' "$HERE/labels.json")
if [ -z "$nodesc" ]; then ok "A: every label carries a description"
else bad "A: description" "missing description: $nodesc"; fi

# Every colour is unique ACROSS BOTH FAMILIES. Shared colours are not a
# cosmetic complaint: `fbca04` was worn by release-ready, auto-review-followup
# and ci at once, so on a PR list an automation state and a changelog category
# were the same swatch. The families are read together, so they have to be
# distinguishable together.
clash=$(jq -r '[.pipeline[],.["release-notes"][]]
  | group_by(.color) | map(select(length>1))
  | map("#" + .[0].color + " -> " + (map(.name)|join(", "))) | join("; ")' "$HERE/labels.json")
if [ -z "$clash" ]; then ok "A: every colour is unique across both families"
else bad "A: colour clash" "$clash"; fi

# --- B: every label .github/release.yml references is canonical ------------
# The contract that actually matters. release.yml names labels; labels.json
# creates them. If they drift apart the category matches nothing, and nothing
# else in the repo compares the two.
missing=$(ruby -ryaml -rjson -e '
  c = YAML.safe_load(File.read(ARGV[0]))["changelog"]
  used = (c["categories"].flat_map { |x| x["labels"] } + (c["exclude"]["labels"] || [])).uniq - ["*"]
  canon = JSON.parse(File.read(ARGV[1])).values_at("pipeline", "release-notes").compact.flatten.map { |l| l["name"] }
  puts (used - canon).join(", ")
' "$HERE/templates/release-notes.yml" "$HERE/labels.json")
if [ -z "$missing" ]; then ok "B: every label release.yml references is in labels.json"
else bad "B: contract" "release.yml categorises by labels nothing creates: $missing"; fi

# --- C: --check reports missing labels and wrong colours -------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# Serves a fixture label list; GH_OMIT drops one, GH_RECOLOR changes one.
if [ "${1:-}" = "api" ]; then
  jq -r --arg omit "${GH_OMIT:-}" --arg rc "${GH_RECOLOR:-}" '
    [.pipeline[], .["release-notes"][]][]
    | select(.name != $omit)
    | [.name, (if .name == $rc then "abcdef" else .color end)] | @tsv' "$LABELS_JSON"
  exit 0
fi
echo "fake gh: unexpected: $*" >&2; exit 1
SHIM
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"; export LABELS_JSON="$HERE/labels.json"

out=$(bash "$HERE/scripts/ensure-labels.sh" FAKE/x --check 2>&1); code=$?
if [ "$code" = 0 ] && printf '%s' "$out" | grep -q "^OK "; then ok "C: a fully-labelled repo reports OK"
else bad "C: clean" "expected OK/exit 0, got exit $code: $out"; fi

out=$(GH_OMIT=refactor bash "$HERE/scripts/ensure-labels.sh" FAKE/x --check 2>&1); code=$?
if [ "$code" = 1 ] && printf '%s' "$out" | grep -q "MISSING  FAKE/x/refactor"; then ok "C: a missing label is reported"
else bad "C: missing" "expected MISSING/exit 1, got exit $code: $out"; fi

out=$(GH_RECOLOR=ci bash "$HERE/scripts/ensure-labels.sh" FAKE/x --check 2>&1); code=$?
if [ "$code" = 1 ] && printf '%s' "$out" | grep -q "COLOUR   FAKE/x/ci"; then ok "C: a wrong colour is reported"
else bad "C: colour" "expected COLOUR/exit 1, got exit $code: $out"; fi

# --- D: colour comparison is case-insensitive ------------------------------
# The fleet has the same label as both FBCA04 and fbca04. Treating that as
# drift would rewrite 71 repos to change nothing.
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "fake gh: unexpected: $*" >&2; exit 1; }
jq -r '[.pipeline[], .["release-notes"][]][] | [.name, (.color|ascii_upcase)] | @tsv' "$LABELS_JSON"
SHIM
chmod +x "$TMP/bin/gh"
out=$(bash "$HERE/scripts/ensure-labels.sh" FAKE/x --check 2>&1); code=$?
if [ "$code" = 0 ]; then ok "D: an uppercase colour is not treated as drift"
else bad "D: case" "uppercase colours reported as drift: $out"; fi

# --- E: an unreadable repo is 'unknown' (exit 2), never 'missing' ----------
# Conflating an API failure with a missing label makes every auth blip look
# like 16 lost labels.
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh: Bad credentials (HTTP 401)" >&2; exit 1
SHIM
chmod +x "$TMP/bin/gh"
out=$(bash "$HERE/scripts/ensure-labels.sh" FAKE/x --check 2>&1); code=$?
if [ "$code" = 2 ] && ! printf '%s' "$out" | grep -q "MISSING"; then ok "E: an API failure is exit 2, not a pile of MISSING"
else bad "E: unknown" "expected exit 2 with no MISSING, got exit $code: $out"; fi

# --- F: rollout.sh has ONE label list ---------------------------------------
# It carried its own four-label loop and knew nothing about the release-notes
# vocabulary; that is how `refactor` went missing from 36 repos.
if grep -q 'ensure-labels.sh' "$HERE/scripts/rollout.sh"; then ok "F: rollout.sh delegates to ensure-labels.sh"
else bad "F: delegation" "rollout.sh does not call ensure-labels.sh"; fi
if grep -q 'gh label create "\${L%%:\*}"' "$HERE/scripts/rollout.sh"; then
  bad "F: second list" "rollout.sh still carries its own inline label list"
else ok "F: rollout.sh no longer carries a second list"; fi


# --- G: no workflow defines a label colour that labels.json also defines ---
# followup-orphan-sweep.yml creates `orphaned-followup` on demand, so the
# sweep keeps working against a repo that has never been rolled out. That is
# correct, but it is a SECOND definition of the same label: if the two colours
# drift, which one a repo gets depends on whether the sweep or the rollout
# reached it first. Same-colour is the contract; the inline create stays.
while IFS= read -r line; do
  name=$(printf '%s' "$line" | sed -n 's/.*gh label create \([a-z-]*\).*/\1/p')
  color=$(printf '%s' "$line" | sed -n 's/.*--color \([0-9A-Fa-f]\{6\}\).*/\1/p')
  [ -n "$name" ] && [ -n "$color" ] || continue
  want=$(jq -r --arg n "$name" '[.pipeline[],.["release-notes"][]][]|select(.name==$n)|.color' "$HERE/labels.json")
  [ -n "$want" ] || continue
  if [ "$(printf '%s' "$color" | tr 'A-Z' 'a-z')" = "$want" ]; then
    ok "G: $name inline colour agrees with labels.json"
  else
    bad "G: $name" "a workflow creates it as #$color, labels.json says #$want — which one a repo gets depends on who reached it first"
  fi
done < <(grep -rh 'gh label create' "$HERE/.github/workflows/" 2>/dev/null)

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# Unit tests for update-ruleset.sh, the gate-mode ruleset flipper.
#
# Its failure mode is silent: fleet-audit#280 found the --execute path rewrote
# the required_status_checks rule to the single new context, deleting every
# other required check (a CodeQL or platform build check) and its
# integration_id binding. The repo keeps merging, just without the check
# nobody noticed disappear. These stub `gh` on PATH, run the REAL script
# against a fixture ruleset, and assert exactly what would be PUT.
#
# Usage: bash scripts/update-ruleset.test.sh
set -uo pipefail   # deliberately no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

mkdir -p "$TMP/bin"
# gh stub: serves $TMP/ruleset.json for the ruleset, applies any --jq with the
# real jq, and records a PUT/POST body in $TMP/put.json.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "unexpected gh $*" >&2; exit 2; }
shift
method=GET path="" filter="" input=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -F|-f) shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
if [ "$method" != GET ]; then
  [ "$input" = - ] && cat > "$STUB_DIR/put.json"
  echo "$method $path" >> "$STUB_DIR/writes"
  echo '{}'; exit 0
fi
case "$path" in
  repos/*/rulesets)   body='[{"id":7,"target":"branch"}]' ;;
  repos/*/rulesets/7) body="$(cat "$STUB_DIR/ruleset.json")" ;;
  repos/*)            body='{"allow_auto_merge":true}' ;;
esac
if [ -n "$filter" ]; then printf '%s' "$body" | jq -r "$filter"; else printf '%s\n' "$body"; fi
STUB
chmod +x "$TMP/bin/gh"
export STUB_DIR="$TMP" PATH="$TMP/bin:$PATH"

ruleset() {  # ruleset <required_status_checks JSON array>
  jq -n --argjson checks "$1" '{
    id: 7, name: "ci", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [{type: "deletion"},
            {type: "required_status_checks",
             parameters: {strict_required_status_checks_policy: false,
                          required_status_checks: $checks}}]}' > "$TMP/ruleset.json"
  rm -f "$TMP/put.json" "$TMP/writes"
}
put_checks() { jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]]' "$TMP/put.json"; }

# --- A: flipping ci / ci -> ci-gated keeps every other required check ------
ruleset '[{"context":"ci / ci","integration_id":15368},
          {"context":"build-ios","integration_id":15368},
          {"context":"CodeQL"}]'
bash "$HERE/scripts/update-ruleset.sh" FAKE/r ci-gated --execute > "$TMP/out" 2>&1
got=$(put_checks)
want='[{"context":"build-ios","integration_id":15368},{"context":"CodeQL"},{"context":"ci-gated"}]'
[ "$got" = "$want" ] && ok "A: other required checks and their integration_id survive the flip" \
  || bad "A: other required checks and their integration_id survive the flip" "got $got want $want"

# --- B: the reverse flip replaces ci-gated, not the other checks ------------
ruleset '[{"context":"ci-gated"},{"context":"build-ios","integration_id":15368}]'
bash "$HERE/scripts/update-ruleset.sh" FAKE/r "ci / ci" --execute > "$TMP/out" 2>&1
got=$(put_checks)
want='[{"context":"build-ios","integration_id":15368},{"context":"ci / ci"}]'
[ "$got" = "$want" ] && ok "B: ci-gated -> ci / ci keeps build-ios" \
  || bad "B: ci-gated -> ci / ci keeps build-ios" "got $got want $want"

# --- C: re-running with the context already present is idempotent ----------
ruleset '[{"context":"ci-gated","integration_id":15368},{"context":"CodeQL"}]'
bash "$HERE/scripts/update-ruleset.sh" FAKE/r ci-gated --execute > "$TMP/out" 2>&1
got=$(put_checks)
want='[{"context":"ci-gated","integration_id":15368},{"context":"CodeQL"}]'
[ "$got" = "$want" ] && ok "C: re-run keeps the existing entry (and its binding), adds no duplicate" \
  || bad "C: re-run keeps the existing entry (and its binding), adds no duplicate" "got $got want $want"

# --- D: the rest of the rule and ruleset are carried through ----------------
got=$(jq -c '{name, target, enforcement, conditions,
              other: [.rules[] | select(.type!="required_status_checks")],
              strict: (.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy)}' "$TMP/put.json")
want='{"name":"ci","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"other":[{"type":"deletion"}],"strict":false}'
[ "$got" = "$want" ] && ok "D: non-check rules and ruleset metadata are preserved" \
  || bad "D: non-check rules and ruleset metadata are preserved" "got $got want $want"

# --- E: the dry run writes nothing and prints both lists --------------------
ruleset '[{"context":"ci / ci"},{"context":"build-ios"}]'
bash "$HERE/scripts/update-ruleset.sh" FAKE/r ci-gated > "$TMP/out" 2>&1
if [ ! -e "$TMP/writes" ] && grep -q 'before: ci / ci, build-ios' "$TMP/out" \
   && grep -q 'after:  build-ios, ci-gated' "$TMP/out" && grep -q '(dry run)' "$TMP/out"; then
  ok "E: dry run prints before/after and writes nothing"
else
  bad "E: dry run prints before/after and writes nothing" "$(cat "$TMP/out"; cat "$TMP/writes" 2>/dev/null)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

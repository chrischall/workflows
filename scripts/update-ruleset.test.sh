#!/usr/bin/env bash
# Unit tests for update-ruleset.sh, the fleet merge-protection converger.
#
# Its failure modes are silent. fleet-audit#280: the --execute path rewrote
# the required_status_checks rule to the single new context, deleting every
# other required check (a CodeQL or platform build check) and its
# integration_id binding; the repo kept merging without them. insync-mcp#8:
# the create path wrote only `deletion` + the status check and nothing
# required a pull request, so a repo with no ruleset merged every PR before
# its armed CI run finished — with CI red for the repo's whole history. These
# stub `gh` on PATH, run the REAL script against fixture rulesets and repo
# settings, and assert exactly what would be PUT/POST/PATCHed, or reported.
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
# gh stub. Fixtures live under $STUB_DIR/fx/<repo-name>/: repo.json (settings),
# rulesets.json (the list endpoint, ids only) and ruleset-<id>.json. A repo
# with no fixture directory gets the legacy single-ruleset shape the A–E cases
# were written against: ruleset 7 from $STUB_DIR/ruleset.json and fully
# converged settings. Any --jq is applied with the real jq. Writes are
# recorded in $STUB_DIR/writes (method, path, and -F fields) and a `--input -`
# body in $STUB_DIR/put.json.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "unexpected gh $*" >&2; exit 2; }
shift
method=GET path="" filter="" input="" fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -F|-f) fields="$fields $2"; shift 2 ;;
    -H) shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
# The CI stub, raw. A fixture repo without ci.yml is a 404 (no stub at all);
# a `ci.yml.error` marker makes the read fail some other way (rate limit,
# 5xx); the legacy no-fixture repo gets a status-mode stub.
case "$path" in
  repos/*/contents/.github/workflows/ci.yml)
    fx="$STUB_DIR/fx/$(printf '%s' "$path" | cut -d/ -f3)"
    if [ ! -d "$fx" ]; then echo "gate-mode: status"; exit 0; fi
    [ -f "$fx/ci.yml.error" ] && { echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1; }
    [ -f "$fx/ci.yml" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$fx/ci.yml"; exit 0 ;;
esac
if [ "$method" != GET ]; then
  [ "$input" = - ] && cat > "$STUB_DIR/put.json"
  echo "$method $path$fields" >> "$STUB_DIR/writes"
  echo '{}'; exit 0
fi
name="$(printf '%s' "$path" | cut -d/ -f3)"
fx="$STUB_DIR/fx/$name"
case "$path" in
  repos/*/rulesets/*)
    id="${path##*/}"
    if [ -d "$fx" ]; then body="$(cat "$fx/ruleset-$id.json")"; else body="$(cat "$STUB_DIR/ruleset.json")"; fi ;;
  repos/*/rulesets)
    if [ -d "$fx" ]; then body="$(cat "$fx/rulesets.json")"; else body='[{"id":7,"target":"branch"}]'; fi ;;
  repos/*)
    if [ -d "$fx" ]; then body="$(cat "$fx/repo.json")"; else
      body='{"allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true}'; fi ;;
  *) echo "unexpected gh api $path" >&2; exit 2 ;;
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

# --- D: the rest of the ruleset is carried through, and the rule types the ---
# --- fleet standard requires but this ruleset lacks are appended -----------
got=$(jq -c '{name, target, enforcement, conditions,
              other: [.rules[] | select(.type!="required_status_checks") | .type],
              approvals: (.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count),
              strict: (.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy)}' "$TMP/put.json")
want='{"name":"ci","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"other":["deletion","non_fast_forward","pull_request"],"approvals":0,"strict":false}'
[ "$got" = "$want" ] && ok "D: ruleset metadata is preserved; force-push and pull-request rules are added, zero approvals" \
  || bad "D: ruleset metadata is preserved; force-push and pull-request rules are added, zero approvals" "got $got want $want"

# --- E: the dry run writes nothing and prints both lists --------------------
ruleset '[{"context":"ci / ci"},{"context":"build-ios"}]'
bash "$HERE/scripts/update-ruleset.sh" FAKE/r ci-gated > "$TMP/out" 2>&1
if [ ! -e "$TMP/writes" ] && grep -q 'before: ci / ci, build-ios' "$TMP/out" \
   && grep -q 'after:  build-ios, ci-gated' "$TMP/out" && grep -q '(dry run)' "$TMP/out"; then
  ok "E: dry run prints before/after and writes nothing"
else
  bad "E: dry run prints before/after and writes nothing" "$(cat "$TMP/out"; cat "$TMP/writes" 2>/dev/null)"
fi

# --- fixture repos for the create, converge and audit cases ----------------
# `thin`: what `gh repo create` plus the OLD create path left behind — the
# insync-mcp shape. One ruleset with deletion + a legacy `ci / ci` check, no
# pull-request rule, auto-merge off, every merge method on.
# Every fixture repo gets a status-mode CI stub unless a case overwrites or
# removes ci.yml: that is the fleet norm, and what makes `ci-gated` the
# derived default context.
fixture() {  # fixture <name> <repo.json> <rulesets list> [<id> <ruleset json>]...
  local dir="$TMP/fx/$1"; shift
  mkdir -p "$dir"; printf '%s\n' "$1" > "$dir/repo.json"; printf '%s\n' "$2" > "$dir/rulesets.json"; shift 2
  printf 'jobs:\n  ci:\n    uses: chrischall/workflows/.github/workflows/reusable-mcp-ci.yml@main\n    with:\n      gate-mode: status\n' > "$dir/ci.yml"
  while [ $# -gt 0 ]; do printf '%s\n' "$2" > "$dir/ruleset-$1.json"; shift 2; done
}
THIN_SETTINGS='{"allow_auto_merge":false,"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true,"delete_branch_on_merge":false}'
GOOD_SETTINGS='{"allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true}'
rs() {  # rs <id> <name> <rules JSON array> [<enforcement>] [<include JSON array>]
  jq -nc --argjson id "$1" --arg name "$2" --argjson rules "$3" --arg enf "${4:-active}" --argjson inc "${5:-[\"~DEFAULT_BRANCH\"]}" \
    '{id: $id, name: $name, target: "branch", enforcement: $enf, conditions: {ref_name: {include: $inc, exclude: []}}, rules: $rules}'
}
CHECK_CI='{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"ci / ci"}]}}'
CHECK_GATED='{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"ci-gated"}]}}'
PR_RULE='{"type":"pull_request","parameters":{"required_approving_review_count":0}}'

fixture thin "$THIN_SETTINGS" '[{"id":7,"target":"branch"}]' \
  7 "$(rs 7 ci "[{\"type\":\"deletion\"},$CHECK_CI]")"
# `bare`: a brand-new repo. No rulesets at all, settings as `gh repo create` leaves them.
fixture bare "$THIN_SETTINGS" '[]'
# `good`: the live fleet shape (mcp-utils): TWO rulesets, protection split
# across them, plus a tag ruleset and an inactive draft that must not count.
fixture good "$GOOD_SETTINGS" '[{"id":1,"target":"branch"},{"id":2,"target":"branch"},{"id":3,"target":"tag"},{"id":4,"target":"branch"}]' \
  1 "$(rs 1 'Block force-push and deletion on main' '[{"type":"deletion"},{"type":"non_fast_forward"}]')" \
  2 "$(rs 2 'main protection (PR + ci)' "[$PR_RULE,$CHECK_GATED]")" \
  3 "$(rs 3 tags '[{"type":"deletion"}]')" \
  4 "$(rs 4 draft "[$PR_RULE]" disabled)"
# `split`: force-push/deletion in a separate ruleset (fleet shape), but the
# checks ruleset lacks the pull-request rule. Converging must add ONLY that —
# never a second deletion/non_fast_forward rule.
fixture split "$GOOD_SETTINGS" '[{"id":1,"target":"branch"},{"id":2,"target":"branch"}]' \
  1 "$(rs 1 protect '[{"type":"deletion"},{"type":"non_fast_forward"}]')" \
  2 "$(rs 2 ci "[$CHECK_GATED]")"

# --- F: no ruleset -> the full fleet ruleset, and the merge policy, in one --
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/bare --execute > "$TMP/out" 2>&1
got=$(jq -c '{types: [.rules[].type], ctx: [.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context],
              approvals: (.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count),
              methods: (.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods),
              enforcement, include: .conditions.ref_name.include}' "$TMP/put.json" 2>/dev/null)
want='{"types":["deletion","non_fast_forward","pull_request","required_status_checks"],"ctx":["ci-gated"],"approvals":0,"methods":["squash"],"enforcement":"active","include":["~DEFAULT_BRANCH"]}'
[ "$got" = "$want" ] && grep -q '^POST repos/FAKE/bare/rulesets$' "$TMP/writes" \
  && ok "F: a repo with no ruleset gets deletion + force-push + pull request + ci-gated, squash-only, active on the default branch" \
  || bad "F: a repo with no ruleset gets deletion + force-push + pull request + ci-gated, squash-only, active on the default branch" "got $got want $want; writes: $(cat "$TMP/writes" 2>/dev/null)"
patch=$(grep '^PATCH repos/FAKE/bare' "$TMP/writes" 2>/dev/null | tr ' ' '\n' | grep -F '=' | sort | tr '\n' ' ')
want='allow_auto_merge=true allow_merge_commit=false allow_rebase_merge=false delete_branch_on_merge=true '
[ "$patch" = "$want" ] && ok "F2: the merge policy PATCH sets exactly the settings that differ from the standard" \
  || bad "F2: the merge policy PATCH sets exactly the settings that differ from the standard" "got '$patch' want '$want'"

# --- G: --audit on the thin repo lists every gap, exits 1, writes nothing ---
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/thin --audit > "$TMP/out" 2>&1; rc=$?
missing=""
for needle in 'auto-merge' 'merge commits' 'rebase' 'not deleted' 'force-push' 'pull request' "'ci-gated'" "ci / ci"; do
  grep -q -- "$needle" "$TMP/out" || missing="$missing [$needle]"
done
if [ "$rc" = 1 ] && [ ! -e "$TMP/writes" ] && [ -z "$missing" ] && ! grep -q 'blocks deletion' "$TMP/out"; then
  ok "G: --audit names each gap (incl. the legacy ci / ci context), exits 1, writes nothing"
else
  bad "G: --audit names each gap (incl. the legacy ci / ci context), exits 1, writes nothing" "rc=$rc missing:$missing out: $(cat "$TMP/out"); writes: $(cat "$TMP/writes" 2>/dev/null)"
fi

# --- H: --audit accepts protection split across rulesets, ignores tag and --
# --- disabled rulesets, exits 0 -------------------------------------------
rm -f "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/good --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^FAKE/good: ok$' "$TMP/out" && [ ! -e "$TMP/writes" ] \
  && ok "H: --audit reports ok for the two-ruleset fleet shape and exits 0" \
  || bad "H: --audit reports ok for the two-ruleset fleet shape and exits 0" "rc=$rc out: $(cat "$TMP/out")"
# A draft ruleset must not satisfy the audit: make the pull-request ruleset disabled.
fixture gooddraft "$GOOD_SETTINGS" '[{"id":1,"target":"branch"},{"id":2,"target":"branch"}]' \
  1 "$(rs 1 protect '[{"type":"deletion"},{"type":"non_fast_forward"}]')" \
  2 "$(rs 2 ci "[$PR_RULE,$CHECK_GATED]" disabled)"
bash "$HERE/scripts/update-ruleset.sh" FAKE/gooddraft --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'pull request' "$TMP/out" && grep -q "'ci-gated'" "$TMP/out" \
  && ok "H2: a disabled ruleset does not count — its pull-request and ci-gated rules are reported missing" \
  || bad "H2: a disabled ruleset does not count — its pull-request and ci-gated rules are reported missing" "rc=$rc out: $(cat "$TMP/out")"

# --- I: converging the split shape adds only the pull-request rule ---------
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/split --execute > "$TMP/out" 2>&1
got=$(jq -c '[.rules[].type]' "$TMP/put.json" 2>/dev/null)
want='["required_status_checks","pull_request"]'
[ "$got" = "$want" ] && grep -q '^PUT repos/FAKE/split/rulesets/2$' "$TMP/writes" && ! grep -q '^PATCH' "$TMP/writes" \
  && ok "I: a checks ruleset beside a force-push ruleset gains only pull_request; converged settings are not PATCHed" \
  || bad "I: a checks ruleset beside a force-push ruleset gains only pull_request; converged settings are not PATCHed" "got $got want $want; writes: $(cat "$TMP/writes" 2>/dev/null)"

# --- J: --audit --all walks fleet.json from a fake root --------------------
ROOT="$TMP/root"; mkdir -p "$ROOT/scripts"
ln -s "$HERE/scripts/update-ruleset.sh" "$ROOT/scripts/update-ruleset.sh"
# `noci`: a fleet repo with `ci: none` (nullnet-app/nullnet) — no stub ever
# posts ci-gated, so requiring the status would block every PR. Deletion,
# force-push and the pull-request rule still apply.
fixture noci "$GOOD_SETTINGS" '[{"id":1,"target":"branch"},{"id":2,"target":"branch"}]' \
  1 "$(rs 1 protect '[{"type":"deletion"},{"type":"non_fast_forward"}]')" \
  2 "$(rs 2 'main protection (PR)' "[$PR_RULE]")"
jq -n '{defaults: {ci: "standard"}, repos: [{repo: "FAKE/good"}, {repo: "FAKE/thin"}, {repo: "FAKE/bare"}, {repo: "FAKE/noci", ci: "none"}]}' > "$ROOT/fleet.json"
rm -f "$TMP/writes"
bash "$ROOT/scripts/update-ruleset.sh" --audit --all > "$TMP/out" 2>&1; rc=$?
if [ "$rc" = 1 ] && [ ! -e "$TMP/writes" ] && grep -q '^FAKE/good: ok$' "$TMP/out" \
   && grep -q '^FAKE/thin$' "$TMP/out" && grep -q '^FAKE/bare$' "$TMP/out" \
   && grep -q '^FAKE/noci: ok (ci: none' "$TMP/out" \
   && grep -q 'no active default-branch ruleset' "$TMP/out"; then
  ok "J: --audit --all reports every fleet.json repo, ok or with its gaps, and exits 1 on any gap"
else
  bad "J: --audit --all reports every fleet.json repo, ok or with its gaps, and exits 1 on any gap" "rc=$rc out: $(cat "$TMP/out")"
fi
bash "$ROOT/scripts/update-ruleset.sh" --all > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$TMP/writes" ] \
  && ok "J2: --all without --audit is refused — there is no fleet-wide execute" \
  || bad "J2: --all without --audit is refused — there is no fleet-wide execute" "rc=$rc out: $(cat "$TMP/out")"
# Single-repo mode reads the same fleet.json: `ci: none` still waives the
# status check, and the waiver is spelled out so nobody reads ok as "gated".
bash "$ROOT/scripts/update-ruleset.sh" FAKE/noci --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^FAKE/noci: ok (ci: none' "$TMP/out" \
  && ok "J3: single-repo --audit also waives the status check for a ci: none fleet repo" \
  || bad "J3: single-repo --audit also waives the status check for a ci: none fleet repo" "rc=$rc out: $(cat "$TMP/out")"
# A ci: none repo missing the pull-request rule is still a gap.
fixture nocipr "$GOOD_SETTINGS" '[{"id":1,"target":"branch"}]' \
  1 "$(rs 1 protect '[{"type":"deletion"},{"type":"non_fast_forward"}]')"
jq '.repos += [{repo: "FAKE/nocipr", ci: "none"}]' "$ROOT/fleet.json" > "$ROOT/fleet.tmp" && mv "$ROOT/fleet.tmp" "$ROOT/fleet.json"
bash "$ROOT/scripts/update-ruleset.sh" FAKE/nocipr --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'pull request' "$TMP/out" && ! grep -q "'ci-gated'" "$TMP/out" \
  && ok "J4: ci: none waives only the status check — a missing pull-request rule is still reported" \
  || bad "J4: ci: none waives only the status check — a missing pull-request rule is still reported" "rc=$rc out: $(cat "$TMP/out")"

# --- K: converging a ci: none repo never requires a status nothing posts ---
rm -f "$TMP/put.json" "$TMP/writes"
bash "$ROOT/scripts/update-ruleset.sh" FAKE/nocipr --execute > "$TMP/out" 2>&1; rc=$?
got=$(jq -c '[.rules[].type]' "$TMP/put.json" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$got" = '["deletion","non_fast_forward","pull_request"]' ] \
   && grep -q '^PUT repos/FAKE/nocipr/rulesets/1$' "$TMP/writes" && ! grep -q '^POST' "$TMP/writes"; then
  ok "K: ci: none converge adds the pull-request rule to the existing ruleset and no status check"
else
  bad "K: ci: none converge adds the pull-request rule to the existing ruleset and no status check" "rc=$rc got $got; writes: $(cat "$TMP/writes" 2>/dev/null); out: $(cat "$TMP/out")"
fi
rm -f "$TMP/put.json" "$TMP/writes"
bash "$ROOT/scripts/update-ruleset.sh" FAKE/noci --execute > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/writes" ] && grep -q 'ci: none' "$TMP/out" \
  && ok "K2: a converged ci: none repo gets no write at all, and the waiver is printed" \
  || bad "K2: a converged ci: none repo gets no write at all, and the waiver is printed" "rc=$rc writes: $(cat "$TMP/writes" 2>/dev/null); out: $(cat "$TMP/out")"

# --- L: bypass actors survive the PUT ---------------------------------------
# The PUT replaces the whole ruleset; a projection that omits bypass_actors
# silently strips them on every run, including a no-op one.
BYPASS='[{"actor_id":5,"actor_type":"Integration","bypass_mode":"always"}]'
fixture bypass "$GOOD_SETTINGS" '[{"id":9,"target":"branch"}]' \
  9 "$(rs 9 ci "[{\"type\":\"deletion\"},$CHECK_CI]" | jq -c --argjson b "$BYPASS" '.bypass_actors = $b')"
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/bypass --execute > "$TMP/out" 2>&1
got=$(jq -c '.bypass_actors' "$TMP/put.json" 2>/dev/null)
[ "$got" = "$BYPASS" ] && grep -q '^PUT repos/FAKE/bypass/rulesets/9$' "$TMP/writes" \
  && ok "L: the ruleset PUT carries bypass_actors through unchanged" \
  || bad "L: the ruleset PUT carries bypass_actors through unchanged" "got $got want $BYPASS; writes: $(cat "$TMP/writes" 2>/dev/null)"
fixture nociprbp "$GOOD_SETTINGS" '[{"id":1,"target":"branch"}]' \
  1 "$(rs 1 protect '[{"type":"deletion"},{"type":"non_fast_forward"}]' | jq -c --argjson b "$BYPASS" '.bypass_actors = $b')"
jq '.repos += [{repo: "FAKE/nociprbp", ci: "none"}]' "$ROOT/fleet.json" > "$ROOT/fleet.tmp" && mv "$ROOT/fleet.tmp" "$ROOT/fleet.json"
rm -f "$TMP/put.json" "$TMP/writes"
bash "$ROOT/scripts/update-ruleset.sh" FAKE/nociprbp --execute > "$TMP/out" 2>&1
got=$(jq -c '.bypass_actors' "$TMP/put.json" 2>/dev/null)
[ "$got" = "$BYPASS" ] \
  && ok "L2: the ci: none PUT carries bypass_actors through unchanged" \
  || bad "L2: the ci: none PUT carries bypass_actors through unchanged" "got $got want $BYPASS; writes: $(cat "$TMP/writes" 2>/dev/null)"

# --- M: a converged repo gets no write at all ------------------------------
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/good --execute > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/writes" ] && grep -q 'nothing to change' "$TMP/out" \
  && ok "M: --execute on a converged repo neither PATCHes nor PUTs, and says so" \
  || bad "M: --execute on a converged repo neither PATCHes nor PUTs, and says so" "rc=$rc writes: $(cat "$TMP/writes" 2>/dev/null); out: $(cat "$TMP/out")"

# --- N: the default context follows the CI stub's gate mode ----------------
# A fail-mode stub posts no `ci-gated`; requiring it would block every PR
# (workflows#364). Bare --execute keeps `ci / ci`; an explicit context flips.
fixture legacy "$GOOD_SETTINGS" '[{"id":7,"target":"branch"}]' \
  7 "$(rs 7 ci "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECK_CI]")"
printf 'jobs:\n  ci:\n    uses: chrischall/workflows/.github/workflows/reusable-mcp-ci.yml@main\n    with:\n      gate-mode: fail\n' > "$TMP/fx/legacy/ci.yml"
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/legacy --execute > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/writes" ] && grep -q "gate context from the CI stub: 'ci / ci'" "$TMP/out" \
  && ok "N: bare --execute on a fail-mode stub keeps 'ci / ci' and writes nothing" \
  || bad "N: bare --execute on a fail-mode stub keeps 'ci / ci' and writes nothing" "rc=$rc writes: $(cat "$TMP/writes" 2>/dev/null); out: $(cat "$TMP/out")"
bash "$HERE/scripts/update-ruleset.sh" FAKE/legacy --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^FAKE/legacy: ok$' "$TMP/out" \
  && ok "N2: --audit holds a fail-mode repo to 'ci / ci', not 'ci-gated'" \
  || bad "N2: --audit holds a fail-mode repo to 'ci / ci', not 'ci-gated'" "rc=$rc out: $(cat "$TMP/out")"
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/legacy ci-gated --execute > "$TMP/out" 2>&1
got=$(put_checks 2>/dev/null)
[ "$got" = '[{"context":"ci-gated"}]' ] \
  && ok "N3: an explicit context still flips a fail-mode repo (the deliberate stub+ruleset migration)" \
  || bad "N3: an explicit context still flips a fail-mode repo (the deliberate stub+ruleset migration)" "got $got; out: $(cat "$TMP/out")"
# No ci.yml at all (404): nothing posts any status, so the legacy context is
# assumed and the audit says which, rather than demanding ci-gated.
fixture nostub "$GOOD_SETTINGS" '[{"id":7,"target":"branch"}]' \
  7 "$(rs 7 ci "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECK_CI]")"
rm -f "$TMP/fx/nostub/ci.yml"
bash "$HERE/scripts/update-ruleset.sh" FAKE/nostub --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^FAKE/nostub: ok$' "$TMP/out" \
  && ok "N4: a repo with no ci.yml is held to 'ci / ci', not to a status nothing would post" \
  || bad "N4: a repo with no ci.yml is held to 'ci / ci', not to a status nothing would post" "rc=$rc out: $(cat "$TMP/out")"

# --- O: rulesets scoped by ~ALL or the real default branch ref count -------
fixture allref "$GOOD_SETTINGS" '[{"id":1,"target":"branch"}]' \
  1 "$(rs 1 everything "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECK_GATED]" active '["~ALL"]')"
bash "$HERE/scripts/update-ruleset.sh" FAKE/allref --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^FAKE/allref: ok$' "$TMP/out" \
  && ok "O: a ~ALL ruleset covers the default branch" \
  || bad "O: a ~ALL ruleset covers the default branch" "rc=$rc out: $(cat "$TMP/out")"
DEVELOP_SETTINGS=$(jq -c '. + {default_branch: "develop"}' <<<"$GOOD_SETTINGS")
fixture develop "$DEVELOP_SETTINGS" '[{"id":1,"target":"branch"}]' \
  1 "$(rs 1 dev "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECK_GATED]" active '["refs/heads/develop"]')"
bash "$HERE/scripts/update-ruleset.sh" FAKE/develop --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^FAKE/develop: ok$' "$TMP/out" \
  && ok "O2: a ruleset on refs/heads/<default> counts when the default branch is not main" \
  || bad "O2: a ruleset on refs/heads/<default> counts when the default branch is not main" "rc=$rc out: $(cat "$TMP/out")"
fixture developmain "$DEVELOP_SETTINGS" '[{"id":1,"target":"branch"}]' \
  1 "$(rs 1 mainonly "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECK_GATED]" active '["refs/heads/main"]')"
bash "$HERE/scripts/update-ruleset.sh" FAKE/developmain --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'pull request' "$TMP/out" \
  && ok "O3: a ruleset on refs/heads/main protects nothing when the default branch is develop" \
  || bad "O3: a ruleset on refs/heads/main protects nothing when the default branch is develop" "rc=$rc out: $(cat "$TMP/out")"

# --- P: an unreadable stub is an error, never "ci / ci" ----------------------
# A rate limit or 5xx on ci.yml must not read as "no stub": on a ci-gated repo
# a bare --execute would migrate the required check backwards (workflows#366).
fixture flaky "$THIN_SETTINGS" '[{"id":1,"target":"branch"}]' \
  1 "$(rs 1 ci "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECK_GATED]")"
touch "$TMP/fx/flaky/ci.yml.error"
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/flaky --execute > "$TMP/out" 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -e "$TMP/writes" ] && grep -q 'could not read .github/workflows/ci.yml' "$TMP/out" \
  && ok "P: --execute aborts before ANY write (settings included) when the stub cannot be read" \
  || bad "P: --execute aborts before ANY write (settings included) when the stub cannot be read" "rc=$rc writes: $(cat "$TMP/writes" 2>/dev/null); out: $(cat "$TMP/out")"
bash "$HERE/scripts/update-ruleset.sh" FAKE/flaky --audit > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q '^FAKE/flaky: ERROR reading the CI stub' "$TMP/out" && ! grep -q "ci / ci" "$TMP/out" \
  && ok "P2: --audit reports the unreadable stub as an error and does not assume a context" \
  || bad "P2: --audit reports the unreadable stub as an error and does not assume a context" "rc=$rc out: $(cat "$TMP/out")"
rm -f "$TMP/put.json" "$TMP/writes"
bash "$HERE/scripts/update-ruleset.sh" FAKE/flaky ci-gated --execute > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^PATCH repos/FAKE/flaky' "$TMP/writes" \
  && ok "P3: an explicit context needs no stub read, so the flaky repo still converges" \
  || bad "P3: an explicit context needs no stub read, so the flaky repo still converges" "rc=$rc writes: $(cat "$TMP/writes" 2>/dev/null); out: $(cat "$TMP/out")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Unit tests for the `Confirm-gate lint (served tool schemas)` step in
# reusable-mcp-ci.yml (fleet-audit#945).
#
# That step fails a PR whose built MCP server publishes a tool with a boolean
# `confirm` input — the deprecated gate a model can satisfy on its first call.
# The fleet's confirmToken migration missed three repos that declared one by
# hand, because the grep that drove it looked for `schemaConfirm`. Every way
# this step can be wrong is quiet:
#
#   - it lints nothing (finds no server in a monorepo, or treats a missing
#     build as "nothing to do") and goes green;
#   - it swallows the audit's exit code and goes green;
#   - it reads the rule from a branch or a SHA, so the rule every fleet PR must
#     pass changes without a reviewed bump here;
#   - it hands the runner's environment to a server under test;
#   - or, the other way, it starts a library or a non-MCP CLI as a server and
#     turns a repo red that has nothing to lint.
#
# The step is extracted from the shipped YAML at run time (the gate.test.sh
# technique), `git` and `npm` are stubbed on PATH, and mcp-utils'
# audit-annotations.mjs is replaced by a fake that fails when the entry file
# says CONFIRM_BOOLEAN and records what it was started with. Node, timeout and
# the step's own server discovery are real.
#
# Usage: bash scripts/confirm-gate-lint.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-mcp-ci.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME='Confirm-gate lint (served tool schemas)'
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  steps = wf["jobs"]["ci"]["steps"]
  i = steps.index { |s| s["name"] == ARGV[1] } or abort("no #{ARGV[1]} step")
  s = steps[i]
  File.write(ARGV[2], s["run"])
  File.write(ARGV[3], s["if"].to_s)
  File.write(ARGV[4], (s["env"] || {})["MCP_UTILS_LINT_TAG"].to_s)
  t = steps.index { |x| x["run"].to_s.include?("inputs.test-command") } or abort("no test step")
  File.write(ARGV[5], "#{i} #{t}")
  inp = (wf["on"] || wf[true])["workflow_call"]["inputs"]["confirm-gate-lint"] or abort("no confirm-gate-lint input")
  File.write(ARGV[6], "#{inp["type"]} #{inp["default"]} #{inp["required"]}")
' "$WF" "$STEP_NAME" "$TMP/step.sh" "$TMP/if.txt" "$TMP/tag.txt" "$TMP/order.txt" "$TMP/input.txt" \
  || { echo "FAIL: could not extract the confirm-gate lint step from $WF"; exit 1; }

echo "── wiring ──"
if grep -qF "needs.gate.outputs.run == 'true'" "$TMP/if.txt" && grep -qF 'inputs.confirm-gate-lint' "$TMP/if.txt"; then
  ok "runs only when the gate armed CI, and only while the input is on"
else bad "runs only when the gate armed CI, and only while the input is on" "if: $(cat "$TMP/if.txt")"; fi
read -r lint_i test_i < "$TMP/order.txt"
if [ "$lint_i" -gt "$test_i" ]; then ok "runs after the build and the tests (it lints the built server)"
else bad "runs after the build and the tests (it lints the built server)" "lint step $lint_i, test step $test_i"; fi
if [ "$(cat "$TMP/input.txt")" = "boolean true false" ]; then
  ok "confirm-gate-lint is an optional boolean, on by default (no stub change needed)"
else bad "confirm-gate-lint is an optional boolean, on by default (no stub change needed)" "$(cat "$TMP/input.txt")"; fi

echo "── the rule is read from a release tag ──"
TAG="$(cat "$TMP/tag.txt")"
if printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then ok "MCP_UTILS_LINT_TAG is a vX.Y.Z tag ($TAG)"
else bad "MCP_UTILS_LINT_TAG is a vX.Y.Z tag" "'$TAG'"; fi

# ── stubs ────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
case "$1" in
  ls-remote) exit "${FAKE_LSREMOTE_RC:-0}" ;;
  -c|clone)
    dest="${@: -1}"
    mkdir -p "$dest/scripts/lib"
    cp "$FAKE_AUDIT" "$dest/scripts/audit-annotations.mjs"
    echo 'export {}' > "$dest/scripts/lib/confirm-gates.mjs"
    printf '{"packages":{"node_modules/@modelcontextprotocol/client":{"version":"2.0.7"}}}\n' > "$dest/package-lock.json"
    ;;
  *) echo "unexpected git $*" >&2; exit 1 ;;
esac
STUB
cat > "$TMP/bin/npm" <<'STUB'
#!/usr/bin/env bash
echo "npm $*" >> "$CALLS"
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/npm"
export FAKE_AUDIT="$TMP/fake-audit.mjs"
cat > "$FAKE_AUDIT" <<'JS'
import fs from 'node:fs';
const entry = process.argv[2];
fs.appendFileSync('.lint-calls', JSON.stringify({ entry, leaked: process.env.LEAK_ME ?? null, placeholder: process.env.X_BASE_URL ?? null }) + '\n');
const src = fs.readFileSync(entry, 'utf8');
// Mirrors the real script's per-tool lines ("  <class> <name>"), which the
// step reads to spot a server that served nothing but its healthcheck.
console.log('  read        x_healthcheck');
if (!src.includes('NEEDS_CONFIG') || process.env.X_BASE_URL) console.log('  read        x_get_thing');
if (src.includes('CONFIRM_BOOLEAN')) {
  console.log('  DESTRUCTIVE x_toggle  <- ERROR: `confirm` boolean');
  console.error('ERROR: x_toggle take a boolean `confirm` input.');
  process.exit(1);
}
console.log('confirm gates   confirm-boolean 0   ungated writes 0');
JS

# ── fixtures ─────────────────────────────────────────────────────────────────
# pkg <dir> <json>; server <file> [CONFIRM_BOOLEAN]
pkg()    { mkdir -p "$1"; printf '%s\n' "$2" > "$1/package.json"; }
server() { mkdir -p "$(dirname "$1")"; printf '// %s\n' "${2:-clean}" > "$1"; }
SDK='"dependencies":{"@modelcontextprotocol/server":"^2.0.0","@chrischall/mcp-utils":"^2.6.0"}'

N=0
# run_case <fixture-dir> [VAR=value ...]  → sets OUT, RC, CALLS_LOG, LINTED
run_case() {
  local dir="$1"; shift
  N=$((N+1))
  export CALLS="$TMP/calls.$N"; : > "$CALLS"
  rm -f "$dir/.lint-calls"
  OUT="$(cd "$dir" && env PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP/runner.$N" HOME="$TMP" \
          MCP_UTILS_LINT_TAG="$TAG" LEAK_ME=runner-secret "$@" bash -e "$TMP/step.sh" 2>&1)"
  RC=$?
  CALLS_LOG="$(cat "$CALLS")"
  LINTED="$( [ -f "$dir/.lint-calls" ] && node -e '
    const l = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
    console.log(l.map((c) => c.entry).join(" "))' "$dir/.lint-calls" )"
}
expect() { # expect <name> <want-rc> <want-linted>
  if [ "$RC" = "$2" ] && [ "$LINTED" = "$3" ]; then ok "$1"
  else bad "$1" "rc=$RC (want $2), linted='$LINTED' (want '$3')
$OUT"; fi
}

echo "── single-server repos ──"
F="$TMP/clean"; pkg "$F" "{\"name\":\"x-mcp\",\"bin\":{\"x-mcp\":\"dist/index.js\"},$SDK}"; server "$F/dist/index.js"
run_case "$F"
expect "clean server passes and is linted by its bin" 0 "dist/index.js"
if printf '%s\n' "$CALLS_LOG" | grep -qE -- "clone -q --depth 1 --branch $TAG https://github.com/chrischall/mcp-utils.git"; then
  ok "mcp-utils is cloned at the tag"
else bad "mcp-utils is cloned at the tag" "$CALLS_LOG"; fi
if printf '%s\n' "$CALLS_LOG" | grep -qE -- "ls-remote --exit-code --tags https://github.com/chrischall/mcp-utils.git refs/tags/$TAG"; then
  ok "the tag is checked to exist AS A TAG before cloning"
else bad "the tag is checked to exist AS A TAG before cloning" "$CALLS_LOG"; fi
if printf '%s\n' "$CALLS_LOG" | grep -E '^npm install' | grep -qF '@modelcontextprotocol/client@2.0.7'; then
  ok "installs the MCP client at the version the tag's lockfile pins"
else bad "installs the MCP client at the version the tag's lockfile pins" "$CALLS_LOG"; fi
if grep -qF '"leaked":null' "$F/.lint-calls"; then ok "the server under test gets none of the runner's environment"
else bad "the server under test gets none of the runner's environment" "$(cat "$F/.lint-calls")"; fi

F="$TMP/bundle"; pkg "$F" "{\"name\":\"b-mcp\",\"bin\":\"dist/bundle.js\",\"devDependencies\":{\"@modelcontextprotocol/sdk\":\"^1.0.0\"}}"; server "$F/dist/bundle.js"
run_case "$F"
expect "string bin + SDK as a devDependency (a bundled server) is linted" 0 "dist/bundle.js"

F="$TMP/confirm"; pkg "$F" "{\"name\":\"s-mcp\",\"bin\":{\"s-mcp\":\"dist/index.js\"},$SDK}"; server "$F/dist/index.js" CONFIRM_BOOLEAN
run_case "$F"
expect "a boolean confirm input fails the step" 1 "dist/index.js"
if printf '%s\n' "$OUT" | grep -qF '::error::dist/index.js failed the confirm-gate lint'; then
  ok "the failure is annotated with the entry and what to do"
else bad "the failure is annotated with the entry and what to do" "$OUT"; fi

F="$TMP/unbuilt"; pkg "$F" "{\"name\":\"u-mcp\",\"bin\":{\"u-mcp\":\"dist/index.js\"},$SDK}"
run_case "$F"
expect "a server bin the build did not produce fails (never a silent skip)" 1 ""

echo "── monorepos ──"
F="$TMP/mono"
pkg "$F" '{"name":"mono","private":true,"workspaces":["packages/*","tools/cli"]}'
pkg "$F/packages/a-mcp" "{\"name\":\"a-mcp\",\"bin\":{\"a-mcp\":\"dist/index.js\"},$SDK}"; server "$F/packages/a-mcp/dist/index.js"
pkg "$F/packages/b-mcp" "{\"name\":\"b-mcp\",\"bin\":{\"b-mcp\":\"dist/index.js\"},$SDK}"; server "$F/packages/b-mcp/dist/index.js" CONFIRM_BOOLEAN
pkg "$F/packages/core" "{\"name\":\"core\",$SDK}"
pkg "$F/tools/cli" '{"name":"cli","bin":{"cli":"./src/index.mjs"},"dependencies":{"commander":"^1"}}'; server "$F/tools/cli/src/index.mjs"
run_case "$F"
expect "every workspace server is linted, one bad one fails the step, the rest still run" 1 "packages/a-mcp/dist/index.js packages/b-mcp/dist/index.js"

F="$TMP/mono-ok"
pkg "$F" '{"name":"mono","private":true,"workspaces":{"packages":["packages/*"]}}'
pkg "$F/packages/a-mcp" "{\"name\":\"a-mcp\",\"bin\":{\"a-mcp\":\"dist/index.js\",\"a\":\"dist/index.js\"},$SDK}"; server "$F/packages/a-mcp/dist/index.js"
run_case "$F"
expect "object-form workspaces; two bin names for one file lint it once" 0 "packages/a-mcp/dist/index.js"

echo "── repos with nothing to lint pass without starting anything ──"
F="$TMP/library"; pkg "$F" "{\"name\":\"@x/connector\",\"main\":\"./dist/index.js\",$SDK}"; server "$F/dist/index.js" CONFIRM_BOOLEAN
run_case "$F"
expect "a library (main, no bin) is not started as a server" 0 ""
F="$TMP/fpx"; pkg "$F" '{"name":"fp","workspaces":["packages/*"]}'
pkg "$F/packages/cli" '{"name":"fpx","bin":{"fpx":"./dist/index.js"},"dependencies":{"commander":"^1"}}'; server "$F/packages/cli/dist/index.js" CONFIRM_BOOLEAN
run_case "$F"
expect "a CLI bin with no MCP server dependency is not started" 0 ""
if printf '%s\n' "$OUT" | grep -qF 'nothing to lint'; then ok "says so in the log"
else bad "says so in the log" "$OUT"; fi
if [ -z "$CALLS_LOG" ]; then ok "and never touches the network (no git, no npm)"
else bad "and never touches the network (no git, no npm)" "$CALLS_LOG"; fi

echo "── multi-bin packages: only the server bin is started ──"
# canvas-parent-mcp ships its server and an interactive QR-login CLI. Started
# as a server, the CLI never answers tools/list and the step times out red.
F="$TMP/multibin"
pkg "$F" "{\"name\":\"c-mcp\",\"bin\":{\"c-mcp\":\"dist/index.js\",\"c-mcp-qr-login\":\"dist/qr-login-cli.js\"},$SDK}"
server "$F/dist/index.js"; server "$F/dist/qr-login-cli.js" CONFIRM_BOOLEAN
run_case "$F"
expect "a server bin plus a non-server CLI bin: only the bin named after the package is linted" 0 "dist/index.js"
F="$TMP/multibin-scoped"
pkg "$F" "{\"name\":\"@x/d-mcp\",\"bin\":{\"d-mcp-setup\":\"dist/setup.js\",\"d-mcp\":\"dist/index.js\"},$SDK}"
server "$F/dist/index.js"; server "$F/dist/setup.js" CONFIRM_BOOLEAN
run_case "$F"
expect "a scoped package's server bin is the one named after its unscoped name" 0 "dist/index.js"
F="$TMP/multibin-ambiguous"
pkg "$F" "{\"name\":\"e-mcp\",\"bin\":{\"e-server\":\"dist/index.js\",\"e-login\":\"dist/login.js\"},$SDK}"
server "$F/dist/index.js"; server "$F/dist/login.js"
run_case "$F"
if [ "$RC" != 0 ] && [ -z "$LINTED" ] && printf '%s\n' "$OUT" | grep -qF 'none is named after the package' \
   && ! printf '%s\n' "$CALLS_LOG" | grep -q clone; then
  ok "several bins, none named after the package: fails and says why, never guesses"
else bad "several bins, none named after the package: fails and says why, never guesses" "rc=$RC linted='$LINTED'
$OUT"; fi

echo "── a server that registers tools only once configured ──"
F="$TMP/unconfigured"; pkg "$F" "{\"name\":\"g-mcp\",\"bin\":{\"g-mcp\":\"dist/index.js\"},$SDK}"; server "$F/dist/index.js" NEEDS_CONFIG
run_case "$F" X_BASE_URL=https://runner.example
expect "serving only a healthcheck fails (its real tools went unseen) — the runner's own env does not count" 1 "dist/index.js"
if printf '%s\n' "$OUT" | grep -qF 'served no tool beyond a healthcheck (x_healthcheck'; then
  ok "the failure names the tools it did see and points at .github/confirm-gate-lint.env"
else bad "the failure names the tools it did see and points at .github/confirm-gate-lint.env" "$OUT"; fi
mkdir -p "$F/.github"
printf '# placeholders only\n\nX_BASE_URL=https://g.example.invalid\nX_TOKEN=placeholder=with=equals\n' > "$F/.github/confirm-gate-lint.env"
run_case "$F"
expect "placeholder config from .github/confirm-gate-lint.env lets it register its tools" 0 "dist/index.js"
if grep -qF '"leaked":null,"placeholder":"https://g.example.invalid"' "$F/.lint-calls"; then
  ok "the server gets the placeholders and still none of the runner's environment"
else bad "the server gets the placeholders and still none of the runner's environment" "$(cat "$F/.lint-calls")"; fi
for badline in 'PATH=/evil' 'not a pair' '1X=y'; do
  printf '%s\n' "$badline" > "$F/.github/confirm-gate-lint.env"
  run_case "$F"
  if [ "$RC" = 1 ] && [ -z "$LINTED" ] && printf '%s\n' "$OUT" | grep -qF '::error file=.github/confirm-gate-lint.env,line=1::'; then
    ok "rejects '$badline' in the env file"
  else bad "rejects '$badline' in the env file" "rc=$RC linted='$LINTED'
$OUT"; fi
done

echo "── the ref policy holds at run time ──"
F="$TMP/clean"
for ref in main 5d445b8c4f1e2a3b4c5d6e7f8091a2b3c4d5e6f7 2.6.1; do
  run_case "$F" MCP_UTILS_LINT_TAG="$ref"
  if [ "$RC" = 1 ] && ! printf '%s\n' "$CALLS_LOG" | grep -q 'clone'; then ok "refuses '$ref' before cloning anything"
  else bad "refuses '$ref' before cloning anything" "rc=$RC calls: $CALLS_LOG"; fi
done
run_case "$F" FAKE_LSREMOTE_RC=2
if [ "$RC" = 1 ] && ! printf '%s\n' "$CALLS_LOG" | grep -q 'clone'; then ok "refuses a tag mcp-utils does not have (e.g. a branch of that name)"
else bad "refuses a tag mcp-utils does not have (e.g. a branch of that name)" "rc=$RC calls: $CALLS_LOG"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

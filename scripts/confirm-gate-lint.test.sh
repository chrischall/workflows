#!/usr/bin/env bash
# Unit tests for the `MCP lints (confirm gates, fs confinement)` step in
# reusable-mcp-ci.yml (fleet-audit#945).
#
# That step fails a PR whose built MCP server publishes a tool with a boolean
# `confirm` input — the deprecated gate a model can satisfy on its first call.
# The fleet's confirmToken migration missed three repos that declared one by
# hand, because the grep that drove it looked for `schemaConfirm`. It also
# fails a server whose source hands a path to mcp-utils' fileBlob /
# readFileHead / resolveOutputDir without `allowedRoots` (a model-chosen path
# with no confinement). Every way this step can be wrong is quiet:
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
# says CONFIRM_BOOLEAN and records what it was started with. Its
# audit-fs-confinement.mjs is replaced by a fake that fails on a src/ line
# calling fileBlob( without allowedRoots (the real rule is tested in
# mcp-utils' scripts/*.test.mjs). Node, timeout and the step's own server
# discovery are real.
#
# Usage: bash scripts/confirm-gate-lint.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-mcp-ci.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME='MCP lints (confirm gates, fs confinement)'
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
  inputs = (wf["on"] || wf[true])["workflow_call"]["inputs"]
  lines = %w[confirm-gate-lint fs-confinement-lint].map do |name|
    inp = inputs[name] or abort("no #{name} input")
    "#{name} #{inp["type"]} #{inp["default"]} #{inp["required"]}"
  end
  File.write(ARGV[6], lines.join("\n") + "\n")
  env = s["env"] || {}
  File.write(ARGV[7], "#{env["CONFIRM_GATE_LINT"]}\n#{env["FS_CONFINEMENT_LINT"]}\n")
' "$WF" "$STEP_NAME" "$TMP/step.sh" "$TMP/if.txt" "$TMP/tag.txt" "$TMP/order.txt" "$TMP/input.txt" "$TMP/env.txt" \
  || { echo "FAIL: could not extract the confirm-gate lint step from $WF"; exit 1; }

echo "── wiring ──"
if grep -qF "needs.gate.outputs.run == 'true'" "$TMP/if.txt" && grep -qF 'inputs.confirm-gate-lint' "$TMP/if.txt" \
   && grep -qF 'inputs.fs-confinement-lint' "$TMP/if.txt"; then
  ok "runs only when the gate armed CI, and only while one of the lint inputs is on"
else bad "runs only when the gate armed CI, and only while one of the lint inputs is on" "if: $(cat "$TMP/if.txt")"; fi
if [ "$(cat "$TMP/env.txt")" = '${{ inputs.confirm-gate-lint }}
${{ inputs.fs-confinement-lint }}' ]; then
  ok "each input reaches the script as its own switch"
else bad "each input reaches the script as its own switch" "$(cat "$TMP/env.txt")"; fi
read -r lint_i test_i < "$TMP/order.txt"
if [ "$lint_i" -gt "$test_i" ]; then ok "runs after the build and the tests (it lints the built server)"
else bad "runs after the build and the tests (it lints the built server)" "lint step $lint_i, test step $test_i"; fi
if [ "$(cat "$TMP/input.txt")" = "confirm-gate-lint boolean true false
fs-confinement-lint boolean true false" ]; then
  ok "confirm-gate-lint and fs-confinement-lint are optional booleans, on by default (no stub change needed)"
else bad "confirm-gate-lint and fs-confinement-lint are optional booleans, on by default (no stub change needed)" "$(cat "$TMP/input.txt")"; fi

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
    [ -n "${FAKE_NO_FS_SCRIPT:-}" ] || cp "$FAKE_FS_AUDIT" "$dest/scripts/audit-fs-confinement.mjs"
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
export FAKE_FS_AUDIT="$TMP/fake-fs-audit.mjs"
cat > "$FAKE_FS_AUDIT" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
fs.appendFileSync('.fs-calls', JSON.stringify({ args: process.argv.slice(2), cwd: process.cwd() }) + '\n');
let bad = 0;
const walk = (d) => {
  if (!fs.existsSync(d)) return;
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const f = path.join(d, e.name);
    if (e.isDirectory()) walk(f);
    else fs.readFileSync(f, 'utf8').split('\n').forEach((l, i) => {
      if (l.includes('fileBlob(') && !l.includes('allowedRoots')) {
        bad++;
        console.log(`::error file=${f},line=${i + 1},col=1::fileBlob(p) passes no allowedRoots`);
      }
    });
  }
};
walk('src');
console.log(`fs confinement: ${bad} unconfined.`);
process.exit(bad ? 1 : 0);
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
  rm -f "$dir/.lint-calls" "$dir/.fs-calls"
  OUT="$(cd "$dir" && env PATH="$TMP/bin:$PATH" RUNNER_TEMP="$TMP/runner.$N" HOME="$TMP" \
          MCP_UTILS_LINT_TAG="$TAG" CONFIRM_GATE_LINT=true FS_CONFINEMENT_LINT=true \
          LEAK_ME=runner-secret "$@" bash -e "$TMP/step.sh" 2>&1)"
  RC=$?
  CALLS_LOG="$(cat "$CALLS")"
  FS_RAN="$( [ -f "$dir/.fs-calls" ] && cat "$dir/.fs-calls" )"
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

echo "── fs confinement (source) ──"
# fsrepo <dir> <src line>: a built single-server repo with src/tool.ts.
fsrepo() {
  pkg "$1" "{\"name\":\"f-mcp\",\"bin\":{\"f-mcp\":\"dist/index.js\"},$SDK}"; server "$1/dist/index.js"
  mkdir -p "$1/src"; printf "import { fileBlob } from '@chrischall/mcp-utils';\n%s\n" "$2" > "$1/src/tool.ts"
}
F="$TMP/fs-ok"; fsrepo "$F" 'await fileBlob(p, { allowedRoots: roots });'
run_case "$F"
expect "a confined file-helper call passes, and the served lint still runs" 0 "dist/index.js"
if printf '%s\n' "$FS_RAN" | grep -qF '"args":[".","--github"]' && printf '%s\n' "$FS_RAN" | grep -qF "\"cwd\":\"$(cd "$F" && pwd -P)\""; then
  ok "the fs lint runs from the tagged clone over the whole repo, with GitHub annotations"
else bad "the fs lint runs from the tagged clone over the whole repo, with GitHub annotations" "$FS_RAN
$OUT"; fi
F="$TMP/fs-bad"; fsrepo "$F" 'await fileBlob(p);'
run_case "$F"
expect "an unconfined file-helper call fails the step — and the served lint still runs" 1 "dist/index.js"
if printf '%s\n' "$OUT" | grep -qF '::error file=src/tool.ts,line=2,col=1::' \
   && printf '%s\n' "$OUT" | grep -qF '::error::the fs-confinement lint failed'; then
  ok "the failure is annotated at the call and says what to do"
else bad "the failure is annotated at the call and says what to do" "$OUT"; fi
run_case "$F" FS_CONFINEMENT_LINT=false
expect "fs-confinement-lint: false turns only the source lint off" 0 "dist/index.js"
if [ -z "$FS_RAN" ]; then ok "and the fs script is not run"; else bad "and the fs script is not run" "$FS_RAN"; fi
run_case "$F" CONFIRM_GATE_LINT=false
expect "confirm-gate-lint: false still runs the fs lint (and fails), but starts no server" 1 ""
if ! printf '%s\n' "$CALLS_LOG" | grep -q '^npm install'; then ok "and installs no MCP client"
else bad "and installs no MCP client" "$CALLS_LOG"; fi
F="$TMP/fs-ok"
run_case "$F" CONFIRM_GATE_LINT=false
expect "confirm-gate-lint: false with a confined call passes" 0 ""
run_case "$F" FAKE_NO_FS_SCRIPT=1
if [ "$RC" = 1 ] && [ -z "$FS_RAN" ] && printf '%s\n' "$OUT" | grep -qF "has no scripts/audit-fs-confinement.mjs"; then
  ok "a tag that predates the fs lint fails loudly, never a silent pass"
else bad "a tag that predates the fs lint fails loudly, never a silent pass" "rc=$RC
$OUT"; fi
F="$TMP/fs-library"; pkg "$F" "{\"name\":\"@x/lib\",\"main\":\"./dist/index.js\",$SDK}"
mkdir -p "$F/src"; printf "import { fileBlob } from '@chrischall/mcp-utils';\nawait fileBlob(p);\n" > "$F/src/tool.ts"
run_case "$F"
if [ "$RC" = 0 ] && [ -z "$FS_RAN" ] && [ -z "$CALLS_LOG" ]; then ok "a repo with no MCP server bin is not fs-linted either"
else bad "a repo with no MCP server bin is not fs-linted either" "rc=$RC fs='$FS_RAN'
$OUT"; fi

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

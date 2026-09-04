#!/usr/bin/env bash
# Unit tests for .github/actions/mcp-publish/action.yml's
# `Wait for npm to index published versions` step.
#
# Extracted from the shipped YAML at run time (same technique as
# arm.test.sh / verdict.test.sh / dedupe.test.sh / gate.test.sh), so this
# exercises the file byte-for-byte with no test-only hooks in it.
#
# Why this exists: npm ACCEPTS a publish and indexes it asynchronously, so
# `+ pkg@version` in the log does not mean the version is readable. The MCP
# Registry refuses to register a version it cannot see on npm, and publishing
# to it in the next breath is a race the registry loses. gogcli-mcp v2.28.0
# lost it — eight packages indexed fast enough and gogcli-mcp-classroom did
# not, 40 seconds after its own successful publish:
#
#   registry validation failed for package 0 (gogcli-mcp-classroom): NPM
#   package 'gogcli-mcp-classroom' exists, but version '2.28.0' was not found
#   (status: 404)
#
# The step under test closes that window. The properties that matter are all
# failure-shaped, so they are what is asserted: it must NOT hang forever, must
# NOT fail the job when npm never catches up (the registry step owns that
# verdict), and must NOT wait on packages the registry will never submit.
#
# Usage: bash scripts/npm-index.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

# The extracted step runs under `bash -e`, the shell GitHub gives a `run:`
# block. Under a plain `bash` an unguarded non-zero completes the step here and
# aborts it in production — the failure class dedupe.test.sh documents.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$HERE/.github/actions/mcp-publish/action.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME="Wait for npm to index published versions"
ruby -ryaml -e '
  a = YAML.load_file(ARGV[0])
  step = (a["runs"]["steps"] || []).find { |s| s["name"] == ARGV[2] }
  abort("could not find `#{ARGV[2]}` step") unless step
  File.write(ARGV[1], step["run"])
' "$ACTION" "$TMP/wait.sh" "$STEP_NAME" \
  || { echo "FAIL: could not extract step from $ACTION"; exit 1; }

mkdir -p "$TMP/bin"

# curl stub. Serves a registry document whose `versions` map is whatever
# $REGISTRY_VERSIONS says, and counts calls so "did it actually poll?" is
# observable. ATTEMPTS_UNTIL_PRESENT models npm's indexing delay: the version
# is absent until that many calls have been made.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$CALLS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CALLS"
echo "$*" >> "$CALL_LOG"
if [ "$n" -ge "${ATTEMPTS_UNTIL_PRESENT:-1}" ]; then
  printf '{"versions":{"%s":{}}}' "$VERSION"
else
  printf '{"versions":{"0.0.1":{}}}'
fi
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"

# A workspace of publishable dirs. Only those with a server.json are ones the
# registry step will submit, so only those should be waited on.
mk_pkg() { # <dir> <name> <with-server-json>
  mkdir -p "$TMP/work/$1"
  printf '{"name":"%s","version":"9.9.9"}' "$2" > "$TMP/work/$1/package.json"
  [ "$3" = "yes" ] && printf '{}' > "$TMP/work/$1/server.json"
  echo "$1" >> "$TMP/work/dirs.txt"
}
mkdir -p "$TMP/work"; : > "$TMP/work/dirs.txt"
mk_pkg packages/with-server    with-server        yes
mk_pkg packages/no-server      no-server          no
mk_pkg "packages/scoped"       "@scope/pkg"       yes

# Runs the step and captures its output in $OUT. Deliberately not
# `out=$(run_step)`: command substitution forks a subshell, so the step's exit
# status would be lost with the assertions that depend on it.
run_step() {
  ( cd "$TMP/work" \
    && CALLS="$TMP/calls" CALL_LOG="$TMP/call.log" \
       VERSION=2.28.0 PUBLISH_DIRS_FILE="$TMP/work/dirs.txt" \
       NPM_INDEX_TIMEOUT_SECONDS="${TIMEOUT:-600}" NPM_INDEX_POLL_SECONDS=0 \
       ATTEMPTS_UNTIL_PRESENT="${ATTEMPTS_UNTIL_PRESENT:-1}" \
       bash -e "$TMP/wait.sh" ) > "$TMP/out" 2>&1
  STEP_RC=$?
  OUT="$(cat "$TMP/out")"
}
reset() { : > "$TMP/calls"; : > "$TMP/call.log"; unset ATTEMPTS_UNTIL_PRESENT TIMEOUT; }

# 1. The happy path: already indexed, so it returns without a warning.
reset
run_step
[ "$STEP_RC" -eq 0 ] \
  && ok "already-indexed version exits 0" \
  || bad "already-indexed version exits 0" "rc=$STEP_RC out=$OUT"
grep -q '::warning' <<<"$OUT" \
  && bad "already-indexed version warns about nothing" "$OUT" \
  || ok "already-indexed version warns about nothing"

# 2. THE BUG THIS STEP EXISTS FOR: npm is late, and the step waits it out
#    rather than handing the registry a 404.
reset; export ATTEMPTS_UNTIL_PRESENT=3
run_step
[ "$STEP_RC" -eq 0 ] \
  && ok "a late-indexing version is waited out, not failed" \
  || bad "a late-indexing version is waited out, not failed" "rc=$STEP_RC out=$OUT"
[ "$(cat "$TMP/calls")" -ge 3 ] \
  && ok "it actually re-polls until the version appears" \
  || bad "it actually re-polls until the version appears" "calls=$(cat "$TMP/calls")"

# 3. npm never catches up. The step must give up, and must NOT fail the job:
#    the registry step owns that verdict, and failing here would also have
#    skipped artifact attachment before that step gained `!cancelled()`.
reset; export ATTEMPTS_UNTIL_PRESENT=999999 TIMEOUT=0
run_step
[ "$STEP_RC" -eq 0 ] \
  && ok "an unindexed version does not fail the job" \
  || bad "an unindexed version does not fail the job" "rc=$STEP_RC out=$OUT"
grep -q '::warning title=npm indexing timed out' <<<"$OUT" \
  && ok "giving up is announced as a warning" \
  || bad "giving up is announced as a warning" "$OUT"

# 4. Only packages the registry will submit are waited on. A package with no
#    server.json is never validated, so blocking a release on it would be a
#    self-inflicted delay.
reset
run_step
grep -q 'no-server' "$TMP/call.log" \
  && bad "a package with no server.json is not waited on" "$(cat "$TMP/call.log")" \
  || ok "a package with no server.json is not waited on"

# 5. A scoped name's slash is percent-encoded; unencoded, the registry path is
#    a 404 for every scoped package in the fleet and the wait would always
#    time out.
reset
run_step
grep -q '@scope%2fpkg' "$TMP/call.log" \
  && ok "a scoped package name is percent-encoded in the registry URL" \
  || bad "a scoped package name is percent-encoded in the registry URL" "$(cat "$TMP/call.log")"
grep -q '@scope/pkg' "$TMP/call.log" \
  && bad "a scoped name is never sent unencoded" "$(cat "$TMP/call.log")" \
  || ok "a scoped name is never sent unencoded"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

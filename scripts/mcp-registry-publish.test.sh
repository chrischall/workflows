#!/usr/bin/env bash
# Unit tests for .github/actions/mcp-publish/action.yml's
# `Publish to MCP Registry` step.
#
# Extracted from the shipped YAML at run time (same technique as
# arm.test.sh / verdict.test.sh / dedupe.test.sh / npm-index.test.sh).
#
# Why this exists: a release that fails partway is recovered by re-running the
# workflow, so every step in it must tolerate the work it already did. The npm
# step has always been idempotent; this one was not, and that made the
# documented recovery unreachable. gogcli-mcp v2.28.0 lost one package to an
# npm indexing race; the re-run registered that package correctly and then
# failed on the five already registered:
#
#   Error: publish failed: server returned status 400: {"errors":[{"message":
#   "invalid version: cannot publish duplicate version"}]}
#
# The run went red with the registry fully correct — and because a red step
# skipped the artifact attachment that follows it, the release stayed at zero
# assets through two runs. A duplicate-version rejection is the registry
# agreeing with us, so it must not be an error.
#
# Usage: bash scripts/mcp-registry-publish.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$HERE/.github/actions/mcp-publish/action.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME="Publish to MCP Registry"
ruby -ryaml -e '
  a = YAML.load_file(ARGV[0])
  step = (a["runs"]["steps"] || []).find { |s| s["name"] == ARGV[2] }
  abort("could not find `#{ARGV[2]}` step") unless step
  File.write(ARGV[1], step["run"])
' "$ACTION" "$TMP/publish.sh" "$STEP_NAME" \
  || { echo "FAIL: could not extract step from $ACTION"; exit 1; }

mkdir -p "$TMP/bin"
# mcp-publisher stub. $OUTCOMES maps a package dir's basename to what the
# registry does: ok | duplicate | error. Reads the dir from the cwd, the way
# the real publisher reads server.json from it.
cat > "$TMP/bin/mcp-publisher" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$PWD")"
case " $OUTCOMES " in
  *" $name:duplicate "*)
    echo 'Error: publish failed: server returned status 400: {"title":"Bad Request","status":400,"detail":"Failed to publish server","errors":[{"message":"invalid version: cannot publish duplicate version"}]}'
    exit 1 ;;
  *" $name:error "*)
    echo 'Error: publish failed: server returned status 403: {"detail":"authentication failed"}'
    exit 1 ;;
  *)
    echo "✓ Server io.github.chrischall/$name version $VERSION"
    exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/mcp-publisher"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/work"; : > "$TMP/work/dirs.txt"
for d in alpha bravo charlie; do
  mkdir -p "$TMP/work/packages/$d"
  printf '{}' > "$TMP/work/packages/$d/server.json"
  echo "packages/$d" >> "$TMP/work/dirs.txt"
done
# A publishable dir with no server.json must be passed over untouched.
mkdir -p "$TMP/work/packages/delta"; echo "packages/delta" >> "$TMP/work/dirs.txt"

run_step() { # sets STEP_RC and OUT
  ( cd "$TMP/work" \
    && VERSION=2.28.0 PUBLISH_DIRS_FILE="$TMP/work/dirs.txt" OUTCOMES="$OUTCOMES" \
       bash -e "$TMP/publish.sh" ) > "$TMP/out" 2>&1
  STEP_RC=$?
  OUT="$(cat "$TMP/out")"
}

# 1. Everything publishes cleanly.
OUTCOMES=""; run_step
[ "$STEP_RC" -eq 0 ] \
  && ok "a clean run exits 0" \
  || bad "a clean run exits 0" "rc=$STEP_RC $OUT"

# 2. THE RECOVERY CASE: re-running after a partial failure. Every package the
#    first run registered comes back as a duplicate, and that must be green.
OUTCOMES="alpha:duplicate bravo:duplicate charlie:duplicate"; run_step
[ "$STEP_RC" -eq 0 ] \
  && ok "an all-duplicate re-run exits 0" \
  || bad "an all-duplicate re-run exits 0" "rc=$STEP_RC $OUT"
grep -q 'Registry already has this version' <<<"$OUT" \
  && ok "a duplicate is reported as already published" \
  || bad "a duplicate is reported as already published" "$OUT"

# 3. The exact v2.28.0 shape: the one package that was missing publishes, the
#    rest are duplicates. This is the run that has to go green.
OUTCOMES="alpha:duplicate charlie:duplicate"; run_step
[ "$STEP_RC" -eq 0 ] \
  && ok "the mixed re-run (one new, rest duplicate) exits 0" \
  || bad "the mixed re-run (one new, rest duplicate) exits 0" "rc=$STEP_RC $OUT"
grep -q '✓ Server io.github.chrischall/bravo' <<<"$OUT" \
  && ok "the genuinely-missing package is still published" \
  || bad "the genuinely-missing package is still published" "$OUT"

# 4. Idempotency must not swallow real failures — the whole point of the step.
OUTCOMES="alpha:error"; run_step
[ "$STEP_RC" -eq 1 ] \
  && ok "a real registry failure still fails the step" \
  || bad "a real registry failure still fails the step" "rc=$STEP_RC $OUT"

# 5. A real failure alongside duplicates still fails: a re-run must not go
#    green just because most of its work was already done.
OUTCOMES="alpha:duplicate bravo:error charlie:duplicate"; run_step
[ "$STEP_RC" -eq 1 ] \
  && ok "duplicates do not mask a real failure in the same run" \
  || bad "duplicates do not mask a real failure in the same run" "rc=$STEP_RC $OUT"

# 6. A failure must not stop the loop — the packages after it still get their
#    turn, or one bad package strands every package behind it.
OUTCOMES="alpha:error"; run_step
grep -q '✓ Server io.github.chrischall/charlie' <<<"$OUT" \
  && ok "a failure does not abandon the packages after it" \
  || bad "a failure does not abandon the packages after it" "$OUT"

# 7. The publisher's own output has to reach the log, or a real 400 becomes
#    invisible and the step's exit code is the only evidence left.
OUTCOMES="alpha:error"; run_step
grep -q 'authentication failed' <<<"$OUT" \
  && ok "the publisher's error text is still printed" \
  || bad "the publisher's error text is still printed" "$OUT"

# 8. No server.json means the registry never sees it.
OUTCOMES=""; run_step
grep -q 'packages/delta' <<<"$OUT" \
  && bad "a dir with no server.json is skipped" "$OUT" \
  || ok "a dir with no server.json is skipped"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

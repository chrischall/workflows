#!/usr/bin/env bash
# Unit tests for reusable-dependabot-lockfix.yml's isolation between the
# lockfix command and the release PAT.
#
# The lockfix command may run PR-controlled code (`./gradlew
# kotlinUpgradeYarnLock` evaluates build scripts and any bumped plugin). It
# used to run in the SAME job as the PAT-bearing push, so that code could
# plant .git/hooks the push step then ran with the PAT in its env, poison
# $GITHUB_ENV/$GITHUB_PATH, or leave a daemon reading the next step's environ
# (fleet-audit#281). The fix is two jobs: one runs the lockfix with no secret
# and hands over a patch; the other never runs PR code, accepts only a patch
# confined to the declared lockfile paths, and commits/pushes with hooks off.
#
# Structure is asserted from the parsed YAML; the two bash steps are extracted
# byte-for-byte (same technique as dedupe.test.sh) and run against a fixture
# repo with `git push` redirected to a local bare remote.
#
# Usage: bash scripts/lockfix.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-dependabot-lockfix.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# --- structure --------------------------------------------------------------
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  jobs = wf["jobs"]
  runner = jobs.select { |_, j| (j["steps"] || []).any? { |s| s["run"].to_s.include?("inputs.lockfix-command") } }
  pusher = jobs.select { |_, j| j.to_yaml.include?("secrets.release_pat") }
  fails = []
  fails << "exactly one job runs the lockfix command (got #{runner.size})" unless runner.size == 1
  fails << "exactly one job holds the PAT (got #{pusher.size})" unless pusher.size == 1
  if runner.size == 1 && pusher.size == 1
    rname, rjob = runner.first; pname, pjob = pusher.first
    fails << "the lockfix job must not be the PAT job" if rname == pname
    fails << "the lockfix job must reference no secret" if rjob.to_yaml.include?("secrets.")
    y = pjob.to_yaml
    %w[inputs.lockfix-command setup-node setup-java setup-gradle].each { |w|
      fails << "the PAT job must not run #{w}" if y.include?(w) }
    fails << "the PAT job must wait for the lockfix job" unless Array(pjob["needs"]).include?(rname)
    push = (pjob["steps"] || []).find { |s| s["name"] == "Commit and push drift" }
    fails << "the PAT job commits/pushes with hooks disabled" unless push && push["run"].scan("core.hooksPath=/dev/null").size >= 2
    pjob["steps"].select { |s| s["uses"].to_s.start_with?("actions/checkout") }.each { |s|
      fails << "the PAT job checkout must not persist credentials" unless (s["with"] || {})["persist-credentials"] == false }
  end
  pkg = jobs.values.flat_map { |j| j["steps"] || [] }.find { |s| s["name"] == "Package lockfile drift" }
  push = jobs.values.flat_map { |j| j["steps"] || [] }.find { |s| s["name"] == "Commit and push drift" }
  File.write(ARGV[1], pkg["run"]) if pkg
  File.write(ARGV[2], push["run"]) if push
  fails << "no `Package lockfile drift` step" unless pkg
  ao = (((wf["on"] || wf[true] || {})["workflow_call"] || {})["inputs"] || {})["append-only-paths"]
  if ao.nil?
    fails << "no `append-only-paths` workflow_call input"
  else
    fails << "`append-only-paths` must be an optional string" unless ao["type"] == "string" && ao["required"] == false
    fails << "`append-only-paths` must default to empty (no check)" unless ao["default"] == ""
  end
  fails << "the push step must receive append-only-paths as APPEND_ONLY" unless push && (push["env"] || {})["APPEND_ONLY"] == "${{ inputs.append-only-paths }}"
  ht = (((wf["on"] || wf[true] || {})["workflow_call"] || {})["inputs"] || {})["host-tool-checksums"]
  if ht.nil?
    fails << "no `host-tool-checksums` workflow_call input"
  else
    fails << "`host-tool-checksums` must be an optional boolean defaulting to false" unless ht["type"] == "boolean" && ht["required"] == false && ht["default"] == false
  end
  if runner.size == 1
    steps = runner.first[1]["steps"]
    names = steps.map { |s| s["name"] }
    i = names.index("Add host-tool checksums")
    if i.nil?
      fails << "no `Add host-tool checksums` step in the lockfix job"
    else
      hs = steps[i]
      File.write(ARGV[3], hs["run"].to_s)
      fails << "`Add host-tool checksums` must run only when host-tool-checksums is true" unless hs["if"] == "inputs.host-tool-checksums"
      fails << "`Add host-tool checksums` must come after `Regenerate lockfiles`" unless names.index("Regenerate lockfiles") && i > names.index("Regenerate lockfiles")
      fails << "`Add host-tool checksums` must come before `Package lockfile drift`" unless names.index("Package lockfile drift") && i < names.index("Package lockfile drift")
      fails << "`Add host-tool checksums` must not interpolate expressions into its script" if hs["run"].to_s.include?("${{")
    end
  end
  puts fails
' "$WF" "$TMP/package.sh" "$TMP/push.sh" "$TMP/hosttools.sh" > "$TMP/struct" 2>&1
if [ -s "$TMP/struct" ]; then bad "structure: lockfix and PAT live in separate jobs" "$(cat "$TMP/struct")"
else ok "structure: lockfix and PAT live in separate jobs"; fi
if [ ! -s "$TMP/package.sh" ] || [ ! -s "$TMP/push.sh" ]; then
  echo; echo "$PASS passed, $((FAIL+1)) failed (cannot extract steps)"; exit 1
fi

# --- fixtures ---------------------------------------------------------------
# git wrapper: `push <https url> <ref>` goes to the local bare remote instead.
mkdir -p "$TMP/bin"
REAL_GIT="$(command -v git)"
cat > "$TMP/bin/git" <<STUB
#!/usr/bin/env bash
args=()
for a in "\$@"; do case "\$a" in https://*) args+=("\$FAKE_REMOTE") ;; *) args+=("\$a") ;; esac; done
exec "$REAL_GIT" "\${args[@]}"
STUB
chmod +x "$TMP/bin/git"

new_origin() {  # fresh bare remote with a dependabot branch holding yarn.lock
  rm -rf "$TMP/origin.git" "$TMP/seed"
  git init -q --bare "$TMP/origin.git"
  git init -q -b main "$TMP/seed"
  mkdir -p "$TMP/seed/kotlin-js-store" "$TMP/seed/.github/workflows"
  echo "lock v1" > "$TMP/seed/kotlin-js-store/yarn.lock"
  echo "name: ci" > "$TMP/seed/.github/workflows/ci.yml"
  mkdir -p "$TMP/seed/gradle"
  printf '<components>\n<c a="1"/>\n<c b="2"/>\n</components>\n' > "$TMP/seed/gradle/verification-metadata.xml"
  git -C "$TMP/seed" add -A
  git -C "$TMP/seed" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$TMP/seed" push -q "$TMP/origin.git" main:dependabot/x
}
clone() { rm -rf "$1"; git clone -q -b dependabot/x "$TMP/origin.git" "$1"; }
origin_head() { git -C "$TMP/origin.git" rev-parse dependabot/x; }

# run_package <workdir>: the lockfix job's packaging step
run_package() {
  : > "$TMP/out"
  ( cd "$1" && PATHS="kotlin-js-store/yarn.lock package-lock.json" PATCH="$TMP/lockfix.patch" \
      GITHUB_OUTPUT="$TMP/out" bash -e "$TMP/package.sh" ) > "$TMP/log" 2>&1
}
# run_push <workdir> <patch>: the PAT job's step, with a trap hook planted.
# APPEND_ONLY (env, default empty) is passed through as the step's input.
run_push() {
  mkdir -p "$1/.git/hooks"
  for h in pre-commit commit-msg post-commit pre-push; do
    printf '#!/bin/sh\necho "%s saw PAT=$PAT" >> "%s"\n' "$h" "$TMP/hooked" > "$1/.git/hooks/$h"
    chmod +x "$1/.git/hooks/$h"
  done
  rm -f "$TMP/hooked"
  ( cd "$1" && PATH="$TMP/bin:$PATH" FAKE_REMOTE="$TMP/origin.git" PAT=secret \
      PATHS="kotlin-js-store/yarn.lock package-lock.json gradle/verification-metadata.xml" PATCH="$2" \
      APPEND_ONLY="${APPEND_ONLY:-}" MESSAGE="fix(deps): regen" BRANCH=dependabot/x REPO=o/r \
      bash -e "$TMP/push.sh" ) > "$TMP/log" 2>&1
}

# --- A: drift is packaged, then committed and pushed by the PAT job ---------
new_origin; clone "$TMP/j1"
echo "lock v2" > "$TMP/j1/kotlin-js-store/yarn.lock"
echo "{}" > "$TMP/j1/package-lock.json"          # a lockfile the lockfix CREATED
echo "junk" > "$TMP/j1/stray.txt"                # outside commit-paths: not shipped
run_package "$TMP/j1"
if grep -qx 'changed=true' "$TMP/out" && [ -s "$TMP/lockfix.patch" ] && ! grep -q stray.txt "$TMP/lockfix.patch"; then
  ok "A1: drift (incl. a new lockfile) is packaged as a patch of the commit-paths only"
else bad "A1: drift (incl. a new lockfile) is packaged as a patch of the commit-paths only" "$(cat "$TMP/out" "$TMP/log")"; fi
before=$(origin_head); clone "$TMP/j2"
run_push "$TMP/j2" "$TMP/lockfix.patch"; rc=$?
files=$(git -C "$TMP/origin.git" diff --name-only "$before" dependabot/x | sort | tr '\n' ' ')
if [ $rc -eq 0 ] && [ "$files" = "kotlin-js-store/yarn.lock package-lock.json " ]; then
  ok "A2: the PAT job commits exactly the lockfiles and pushes"
else bad "A2: the PAT job commits exactly the lockfiles and pushes" "rc=$rc files=[$files] $(cat "$TMP/log")"; fi
if [ ! -e "$TMP/hooked" ]; then ok "A3: no git hook runs in the PAT job (commit or push)"
else bad "A3: no git hook runs in the PAT job (commit or push)" "$(cat "$TMP/hooked")"; fi
[ "$(git -C "$TMP/origin.git" log -1 --format=%s dependabot/x)" = "fix(deps): regen" ] \
  && ok "A4: commit message is the configured one" \
  || bad "A4: commit message is the configured one" "$(git -C "$TMP/origin.git" log -1 --format=%s dependabot/x)"

# --- B: no drift -> nothing packaged ----------------------------------------
new_origin; clone "$TMP/j1"; rm -f "$TMP/lockfix.patch"
run_package "$TMP/j1"
if grep -qx 'changed=false' "$TMP/out" && [ ! -e "$TMP/lockfix.patch" ]; then ok "B: no drift packages nothing"
else bad "B: no drift packages nothing" "$(cat "$TMP/out" "$TMP/log")"; fi

# --- C: a patch reaching outside commit-paths is refused (it is attacker data)
new_origin; clone "$TMP/j1"
echo "lock v2" > "$TMP/j1/kotlin-js-store/yarn.lock"
echo "evil" >> "$TMP/j1/.github/workflows/ci.yml"
git -C "$TMP/j1" diff --binary > "$TMP/evil.patch"
before=$(origin_head); clone "$TMP/j2"
run_push "$TMP/j2" "$TMP/evil.patch"; rc=$?
if [ $rc -ne 0 ] && [ "$(origin_head)" = "$before" ]; then ok "C: a patch touching a workflow file is refused, nothing pushed"
else bad "C: a patch touching a workflow file is refused, nothing pushed" "rc=$rc $(cat "$TMP/log")"; fi

# --- D: a symlink at an allowed path is refused ------------------------------
new_origin; clone "$TMP/j1"
rm "$TMP/j1/kotlin-js-store/yarn.lock"; ln -s ../.github/workflows/ci.yml "$TMP/j1/kotlin-js-store/yarn.lock"
git -C "$TMP/j1" diff --binary > "$TMP/link.patch"
before=$(origin_head); clone "$TMP/j2"
run_push "$TMP/j2" "$TMP/link.patch"; rc=$?
if [ $rc -ne 0 ] && [ "$(origin_head)" = "$before" ]; then ok "D: a symlink in place of a lockfile is refused"
else bad "D: a symlink in place of a lockfile is refused" "rc=$rc $(cat "$TMP/log")"; fi

# --- E: an oversized patch is refused before it is applied -------------------
new_origin; clone "$TMP/j2"; before=$(origin_head)
head -c 60000000 /dev/zero | tr '\0' 'a' > "$TMP/big.patch"
run_push "$TMP/j2" "$TMP/big.patch"; rc=$?
if [ $rc -ne 0 ] && [ "$(origin_head)" = "$before" ] && grep -qi 'too large' "$TMP/log"; then ok "E: an oversized patch is refused"
else bad "E: an oversized patch is refused" "rc=$rc $(tail -3 "$TMP/log")"; fi

# --- F: append-only-paths refuses a patch that removes or changes a line ------
VM=gradle/verification-metadata.xml
# mkpatch <name> <cmd...>: run cmd in a fresh clone, write its worktree diff to
# $TMP/<name>.patch (a cmd that creates a file must `git add -N` it itself)
mkpatch() {
  local n=$1; shift
  new_origin; clone "$TMP/j1"
  ( cd "$TMP/j1" && "$@" )
  git -C "$TMP/j1" diff --binary > "$TMP/$n.patch"
}
add_line()    { sed -i.bak 's#</components>#<c d="4"/>\n</components>#' "$VM" && rm "$VM.bak"; }
change_line() { sed -i.bak 's#<c a="1"/>#<c a="9"/>#' "$VM" && rm "$VM.bak"; }
delete_line() { sed -i.bak '/<c b="2"\/>/d' "$VM" && rm "$VM.bak"; }

mkpatch add add_line
before=$(origin_head); clone "$TMP/j2"
APPEND_ONLY="$VM" run_push "$TMP/j2" "$TMP/add.patch"; rc=$?
if [ $rc -eq 0 ] && [ "$(origin_head)" != "$before" ] \
   && git -C "$TMP/origin.git" show "dependabot/x:$VM" | grep -q 'd="4"'; then
  ok "F1: pure additions to an append-only path are committed and pushed"
else bad "F1: pure additions to an append-only path are committed and pushed" "rc=$rc $(cat "$TMP/log")"; fi

mkpatch change change_line
before=$(origin_head); clone "$TMP/j2"
APPEND_ONLY="$VM" run_push "$TMP/j2" "$TMP/change.patch"; rc=$?
if [ $rc -ne 0 ] && [ "$(origin_head)" = "$before" ] \
   && grep -q "::error::.*$VM" "$TMP/log" && grep -q 'a="1"' "$TMP/log"; then
  ok "F2: changing an existing line of an append-only path is refused, naming the path and line"
else bad "F2: changing an existing line of an append-only path is refused, naming the path and line" "rc=$rc $(cat "$TMP/log")"; fi

mkpatch delete delete_line
before=$(origin_head); clone "$TMP/j2"
APPEND_ONLY="$VM" run_push "$TMP/j2" "$TMP/delete.patch"; rc=$?
if [ $rc -ne 0 ] && [ "$(origin_head)" = "$before" ] && grep -q "::error::.*$VM" "$TMP/log"; then
  ok "F3: deleting a line of an append-only path is refused"
else bad "F3: deleting a line of an append-only path is refused" "rc=$rc $(cat "$TMP/log")"; fi

mkpatch rmfile rm "$VM"
before=$(origin_head); clone "$TMP/j2"
APPEND_ONLY="$VM" run_push "$TMP/j2" "$TMP/rmfile.patch"; rc=$?
if [ $rc -ne 0 ] && [ "$(origin_head)" = "$before" ] && grep -q "::error::.*$VM" "$TMP/log"; then
  ok "F4: deleting an append-only file outright is refused"
else bad "F4: deleting an append-only file outright is refused" "rc=$rc $(cat "$TMP/log")"; fi

before=$(origin_head); clone "$TMP/j2"
APPEND_ONLY="" run_push "$TMP/j2" "$TMP/change.patch"; rc=$?
if [ $rc -eq 0 ] && [ "$(origin_head)" != "$before" ]; then
  ok "F5: with append-only-paths empty, a changing patch still pushes"
else bad "F5: with append-only-paths empty, a changing patch still pushes" "rc=$rc $(cat "$TMP/log")"; fi

both() { add_line && echo "lock v2" > kotlin-js-store/yarn.lock; }
mkpatch both both
before=$(origin_head); clone "$TMP/j2"
APPEND_ONLY="$VM" run_push "$TMP/j2" "$TMP/both.patch"; rc=$?
files=$(git -C "$TMP/origin.git" diff --name-only "$before" dependabot/x | sort | tr '\n' ' ')
if [ $rc -eq 0 ] && [ "$files" = "$VM kotlin-js-store/yarn.lock " ]; then
  ok "F6: a non-append-only path in the same patch may still change lines"
else bad "F6: a non-append-only path in the same patch may still change lines" "rc=$rc files=[$files] $(cat "$TMP/log")"; fi

newfile() { mkdir -p sub && printf '<a/>\n<b/>\n' > sub/verification-metadata.xml && git add -N sub; }
mkpatch newfile newfile
before=$(origin_head); clone "$TMP/j2"
( export APPEND_ONLY="sub/verification-metadata.xml"
  cd "$TMP/j2" && PATH="$TMP/bin:$PATH" FAKE_REMOTE="$TMP/origin.git" PAT=secret \
    PATHS="sub/verification-metadata.xml" PATCH="$TMP/newfile.patch" \
    MESSAGE="fix(deps): regen" BRANCH=dependabot/x REPO=o/r bash -e "$TMP/push.sh" ) > "$TMP/log" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ "$(origin_head)" != "$before" ]; then
  ok "F7: a newly created file at an append-only path is accepted"
else bad "F7: a newly created file at an append-only path is accepted" "rc=$rc $(cat "$TMP/log")"; fi

# --- G: host-tool-checksums adds the other-OS host-tool variants -------------
# The step runs in the lockfix job after the regen. curl is stubbed on PATH: it
# serves fixture bytes for URLs under $CURL_FIXTURES/<host>/<path> and fails
# for anything else, logging every call, so the suite is fully offline.
if [ ! -s "$TMP/hosttools.sh" ]; then
  bad "G: host-tool-checksums step" "cannot extract the \`Add host-tool checksums\` step"
else
mkdir -p "$TMP/curlbin"
cat > "$TMP/curlbin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
[ -n "$url" ] && [ -n "$out" ] || exit 2
f="$CURL_FIXTURES/${url#https://}"
[ -f "$f" ] || exit 22
cp "$f" "$out"
STUB
chmod +x "$TMP/curlbin/curl"

FX="$TMP/fx"; rm -rf "$FX"
fixture() {  # fixture <url> <bytes>: serve <bytes> at <url>
  local f="$FX/${1#https://}"; mkdir -p "$(dirname "$f")"; printf '%s' "$2" > "$f"
}
sha256_of() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
sha1_of()   { printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1; }
GM=https://dl.google.com/dl/android/maven2/com/android/tools/build/aapt2
MC=https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-native-prebuilt
ND=https://nodejs.org/dist
# aapt2 9.6.0-2: osx variant served with a matching .sha1
fixture "$GM/9.6.0-2/aapt2-9.6.0-2-osx.jar" "aapt2 osx bytes"
fixture "$GM/9.6.0-2/aapt2-9.6.0-2-osx.jar.sha1" "$(sha1_of "aapt2 osx bytes")"
# aapt2 9.4.0-1 (already in HEAD, missing osx): served, but must not be fetched
fixture "$GM/9.4.0-1/aapt2-9.4.0-1-osx.jar" "old osx bytes"
fixture "$GM/9.4.0-1/aapt2-9.4.0-1-osx.jar.sha1" "$(sha1_of "old osx bytes")"
# node 24.11.0: darwin-arm64 from SHASUMS256.txt (which sorts BEFORE linux-x64)
fixture "$ND/v24.11.0/node-v24.11.0-darwin-arm64.tar.gz" "node darwin bytes"
fixture "$ND/v24.11.0/SHASUMS256.txt" "$(printf '%s  node-v24.11.0-darwin-x64.tar.gz\n%s  node-v24.11.0-darwin-arm64.tar.gz\n' \
  "$(sha256_of other)" "$(sha256_of "node darwin bytes")")"
# kotlin-native-prebuilt 2.5.0: macos-aarch64 served with a WRONG .sha1
fixture "$MC/2.5.0/kotlin-native-prebuilt-2.5.0-macos-aarch64.tar.gz" "konan bytes"
fixture "$MC/2.5.0/kotlin-native-prebuilt-2.5.0-macos-aarch64.tar.gz.sha1" "$(sha1_of "tampered bytes")"
# aapt2 9.7.0-3: osx not served at all (download failure)

H=$(printf '1%.0s' {1..64})   # placeholder sha256 values for pre-existing entries
meta_head() { cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<verification-metadata>
   <configuration>
      <verify-metadata>false</verify-metadata>
   </configuration>
   <components>
      <component group="com.android.tools.build" name="aapt2" version="9.4.0-1">
         <artifact name="aapt2-9.4.0-1-linux.jar">
            <sha256 value="$H" origin="Generated by Gradle"/>
         </artifact>
      </component>
      <component group="com.example" name="lib" version="1.0">
         <artifact name="lib-1.0.jar">
            <sha256 value="$H" origin="Generated by Gradle"/>
         </artifact>
      </component>
XML
}
comp() {  # comp <group> <name> <version> <artifact>: a one-artifact component
  cat <<XML
      <component group="$1" name="$2" version="$3">
         <artifact name="$4">
            <sha256 value="$H" origin="Generated by Gradle"/>
         </artifact>
      </component>
XML
}
meta_tail() { printf '   </components>\n</verification-metadata>\n'; }
art() {  # art <name> <sha256> <host>: the entry the step is expected to write
  printf '         <artifact name="%s">\n            <sha256 value="%s" origin="Computed by dependabot lockfix from %s; matches the published %s"/>\n         </artifact>\n' \
    "$1" "$2" "$3" "$4"
}

# HEAD holds the old components; the regen (working tree) adds new ones that
# carry only their Linux variant, as an ubuntu --write-verification-metadata does.
rm -rf "$TMP/h"; git init -q "$TMP/h"; mkdir -p "$TMP/h/gradle"
{ meta_head; meta_tail; } > "$TMP/h/$VM"
git -C "$TMP/h" add -A; git -C "$TMP/h" -c user.name=t -c user.email=t@t commit -qm init
{ meta_head
  comp com.android.tools.build aapt2 9.6.0-2 aapt2-9.6.0-2-linux.jar
  comp com.android.tools.build aapt2 9.7.0-3 aapt2-9.7.0-3-linux.jar
  comp com.android.tools.build aapt2 '9.9/../../evil' 'aapt2-x-linux.jar'
  comp org.jetbrains.kotlin kotlin-native-prebuilt 2.5.0 kotlin-native-prebuilt-2.5.0-linux-x86_64.tar.gz
  comp org.nodejs node 24.11.0 node-24.11.0-linux-x64.tar.gz
  meta_tail; } > "$TMP/h/$VM"

run_hosttools() {
  : > "$TMP/curl.log"
  ( cd "$TMP/h" && PATH="$TMP/curlbin:$PATH" CURL_LOG="$TMP/curl.log" CURL_FIXTURES="$FX" \
      bash -e "$TMP/hosttools.sh" ) > "$TMP/log" 2>&1
}
run_hosttools; rc=$?
got="$TMP/h/$VM"
# The expected file: exactly the regen plus two inserted, sorted artifacts.
{ meta_head
  comp com.android.tools.build aapt2 9.6.0-2 aapt2-9.6.0-2-linux.jar | sed '$d'
  art aapt2-9.6.0-2-osx.jar "$(sha256_of "aapt2 osx bytes")" dl.google.com .sha1
  echo "      </component>"
  comp com.android.tools.build aapt2 9.7.0-3 aapt2-9.7.0-3-linux.jar
  comp com.android.tools.build aapt2 '9.9/../../evil' 'aapt2-x-linux.jar'
  comp org.jetbrains.kotlin kotlin-native-prebuilt 2.5.0 kotlin-native-prebuilt-2.5.0-linux-x86_64.tar.gz
  echo '      <component group="org.nodejs" name="node" version="24.11.0">'
  art node-24.11.0-darwin-arm64.tar.gz "$(sha256_of "node darwin bytes")" nodejs.org SHASUMS256.txt
  comp org.nodejs node 24.11.0 node-24.11.0-linux-x64.tar.gz | sed '1d'
  meta_tail; } > "$TMP/expected.xml"

if [ $rc -eq 0 ] && diff -u "$TMP/expected.xml" "$got" > "$TMP/d"; then
  ok "G1: new aapt2 + node components gain their other-OS variant, sorted, nothing else changes"
else bad "G1: new aapt2 + node components gain their other-OS variant, sorted, nothing else changes" "rc=$rc $(cat "$TMP/d" "$TMP/log")"; fi

removed=$(git -C "$TMP/h" diff --text -U0 -- "$VM" | awk '/^diff --git /{h=0} /^@@/{h=1; next} h && /^-/')
if [ -z "$removed" ]; then ok "G2: the result is pure additions vs HEAD (passes the append-only guard)"
else bad "G2: the result is pure additions vs HEAD (passes the append-only guard)" "$removed"; fi

if grep -q '::warning::.*kotlin-native-prebuilt-2.5.0-macos-aarch64.*does not match' "$TMP/log" \
   && ! grep -q 'kotlin-native-prebuilt-2.5.0-macos-aarch64' "$got"; then
  ok "G3: a published-hash mismatch writes nothing for that artifact and warns"
else bad "G3: a published-hash mismatch writes nothing for that artifact and warns" "$(cat "$TMP/log")"; fi

if grep -q '::warning::.*aapt2-9.7.0-3-osx' "$TMP/log" && ! grep -q 'aapt2-9.7.0-3-osx' "$got"; then
  ok "G4: a download failure writes nothing for that artifact and warns"
else bad "G4: a download failure writes nothing for that artifact and warns" "$(cat "$TMP/log")"; fi

if ! grep -q '9.4.0-1' "$TMP/curl.log" && ! grep -q 'aapt2-9.4.0-1-osx' "$got"; then
  ok "G5: a component unchanged since HEAD is not touched (no backfill)"
else bad "G5: a component unchanged since HEAD is not touched (no backfill)" "$(cat "$TMP/curl.log")"; fi

if ! grep -q 'evil' "$TMP/curl.log" && grep -q '::warning::.*9.9/../../evil' "$TMP/log"; then
  ok "G6: a version failing the regex is refused without any curl call"
else bad "G6: a version failing the regex is refused without any curl call" "$(cat "$TMP/curl.log" "$TMP/log")"; fi

if [ -s "$TMP/curl.log" ] && ! grep -v -- '-fsSL --proto =https ' "$TMP/curl.log" | grep -q . \
   && ! grep -vE ' https://(dl\.google\.com|repo1\.maven\.org|nodejs\.org)/' "$TMP/curl.log" | grep -q .; then
  ok "G7: every download is curl -fsSL --proto =https to a table host"
else bad "G7: every download is curl -fsSL --proto =https to a table host" "$(cat "$TMP/curl.log")"; fi

cp "$got" "$TMP/first.xml"; run_hosttools; rc=$?
if [ $rc -eq 0 ] && cmp -s "$TMP/first.xml" "$got" && ! grep -q 'aapt2-9.6.0-2-osx\|node-v24.11.0-darwin-arm64' "$TMP/curl.log"; then
  ok "G8: a second run is a no-op (present variants are not re-fetched)"
else bad "G8: a second run is a no-op (present variants are not re-fetched)" "rc=$rc $(cat "$TMP/log" "$TMP/curl.log")"; fi

rm -rf "$TMP/h2"; git init -q "$TMP/h2"
( cd "$TMP/h2" && PATH="$TMP/curlbin:$PATH" CURL_LOG="$TMP/curl.log" CURL_FIXTURES="$FX" \
    bash -e "$TMP/hosttools.sh" ) > "$TMP/log" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ ! -e "$TMP/h2/$VM" ]; then ok "G9: a repo without verification metadata is a no-op"
else bad "G9: a repo without verification metadata is a no-op" "rc=$rc $(cat "$TMP/log")"; fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

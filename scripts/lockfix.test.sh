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
  puts fails
' "$WF" "$TMP/package.sh" "$TMP/push.sh" > "$TMP/struct" 2>&1
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
# run_push <workdir> <patch>: the PAT job's step, with a trap hook planted
run_push() {
  mkdir -p "$1/.git/hooks"
  for h in pre-commit commit-msg post-commit pre-push; do
    printf '#!/bin/sh\necho "%s saw PAT=$PAT" >> "%s"\n' "$h" "$TMP/hooked" > "$1/.git/hooks/$h"
    chmod +x "$1/.git/hooks/$h"
  done
  rm -f "$TMP/hooked"
  ( cd "$1" && PATH="$TMP/bin:$PATH" FAKE_REMOTE="$TMP/origin.git" PAT=secret \
      PATHS="kotlin-js-store/yarn.lock package-lock.json" PATCH="$2" \
      MESSAGE="fix(deps): regen" BRANCH=dependabot/x REPO=o/r \
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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

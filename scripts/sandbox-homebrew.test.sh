#!/usr/bin/env bash
# Unit tests for the Homebrew fallback in the "Install the sandbox
# dependencies (bubblewrap, socat)" step the auto-review and @claude jobs
# share. sandbox-install.test.sh pins the apt retries; this pins what happens
# when they run out.
#
# On 2026-11-11 GitHub's hosted runners lost DNS for every Ubuntu mirror
# (azure.archive, archive and security.ubuntu.com; actions/runner-images#15296,
# #15297) for about three hours, far past the retries. Once apt gives up, the
# step now installs both tools from the runner image's Homebrew, whose bottles
# come from ghcr.io rather than an Ubuntu mirror. It still fails closed when
# neither source works: the review must never run without the sandbox.
#
# The step's script is extracted from the shipped YAML and run against fake
# sudo/apt-get/sleep/brew/bwrap/socat, so this exercises the file byte for
# byte. sandbox-install.test.sh already checks both jobs run the same step.
set -uo pipefail

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT

STEP='Install the sandbox dependencies (bubblewrap, socat)'
extract() { # workflow job out
  ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    job = wf["jobs"][ARGV[1]] or abort("no #{ARGV[1]} job")
    s = job["steps"].find { |x| x["name"] == ARGV[3] } or abort("no install step in #{ARGV[1]}")
    File.write(ARGV[2], s["run"])
  ' "$1" "$2" "$3" "$STEP"
}
extract "$ROOT/.github/workflows/reusable-pr-auto-review.yml" review "$TMP/review.sh" \
  || { echo "FAIL: could not extract the review job's install step"; exit 1; }

# One scenario: $1 = apt result (ok|fail), $2 = brew result (ok|fail).
# Prints the step's exit code; leaves calls.log and github_path in $TMP/$3.
run_case() {
  local apt="$1" brew="$2" d="$TMP/$3"
  mkdir -p "$d/bin" "$d/linuxbrew/bin" "$d/linuxbrew-installed"
  : > "$d/calls.log"; : > "$d/github_path"
  cat > "$d/bin/sudo" <<'EOF'
#!/bin/bash
"$@"
EOF
  cat > "$d/bin/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> "$d/calls.log"
case "\$1" in
  update) exit 0 ;;
  install) [ "$apt" = ok ] || exit 100
           printf '#!/bin/bash\nexit 0\n' > "$d/bin/bwrap"
           printf '#!/bin/bash\necho "socat version apt"\n' > "$d/bin/socat"
           chmod +x "$d/bin/bwrap" "$d/bin/socat" ;;
esac
EOF
  cat > "$d/bin/sysctl" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$d/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$d/linuxbrew/bin/brew" <<EOF
#!/bin/bash
echo "brew \$* auto_update_off=\${HOMEBREW_NO_AUTO_UPDATE:-}" >> "$d/calls.log"
[ "$brew" = ok ] || exit 1
printf '#!/bin/bash\nexit 0\n' > "$d/linuxbrew/bin/bwrap"
printf '#!/bin/bash\necho "socat version brew"\n' > "$d/linuxbrew/bin/socat"
chmod +x "$d/linuxbrew/bin/bwrap" "$d/linuxbrew/bin/socat"
EOF
  chmod +x "$d/bin/"* "$d/linuxbrew/bin/brew"
  env -i HOME="$d" PATH="$d/bin:/usr/bin:/bin" GITHUB_PATH="$d/github_path" \
    LINUXBREW="$d/linuxbrew" bash -e "$TMP/review.sh" > "$d/out.log" 2>&1
  echo $?
}

echo "── apt works ──"
rc="$(run_case ok ok aptok)"
[ "$rc" -eq 0 ] && ok "step exits 0" || bad "step exits 0" "rc=$rc $(cat "$TMP/aptok/out.log")"
if grep -qE '^apt-get install .*bubblewrap.*socat|^apt-get install .*socat.*bubblewrap' "$TMP/aptok/calls.log"; then
  ok "installs bubblewrap and socat with apt"
else bad "installs bubblewrap and socat with apt" "$(cat "$TMP/aptok/calls.log")"; fi
if grep -q '^brew' "$TMP/aptok/calls.log"; then bad "does not touch Homebrew" "$(cat "$TMP/aptok/calls.log")"
else ok "does not touch Homebrew"; fi
[ -s "$TMP/aptok/github_path" ] && bad "leaves PATH alone" "$(cat "$TMP/aptok/github_path")" || ok "leaves PATH alone"

echo "── apt cannot reach the Ubuntu mirrors ──"
rc="$(run_case fail ok aptfail)"
[ "$rc" -eq 0 ] && ok "step exits 0 on the Homebrew fallback" || bad "step exits 0 on the Homebrew fallback" "rc=$rc $(cat "$TMP/aptfail/out.log")"
if grep -qE '^brew install .*bubblewrap.*socat.* auto_update_off=1$' "$TMP/aptfail/calls.log"; then
  ok "installs both from Homebrew without an auto-update"
else bad "installs both from Homebrew without an auto-update" "$(cat "$TMP/aptfail/calls.log")"; fi
if grep -qxF "$TMP/aptfail/linuxbrew/bin" "$TMP/aptfail/github_path"; then
  ok "puts Homebrew's bin on PATH for the review step"
else bad "puts Homebrew's bin on PATH for the review step" "GITHUB_PATH: $(cat "$TMP/aptfail/github_path")"; fi
if grep -qF 'socat version brew' "$TMP/aptfail/out.log"; then ok "checks the Homebrew socat it installed"
else bad "checks the Homebrew socat it installed" "$(cat "$TMP/aptfail/out.log")"; fi
if grep -qF '::warning::' "$TMP/aptfail/out.log"; then ok "says it fell back"
else bad "says it fell back" "$(cat "$TMP/aptfail/out.log")"; fi

echo "── neither source works ──"
rc="$(run_case fail fail bothfail)"
[ "$rc" -ne 0 ] && ok "step fails closed" || bad "step fails closed" "rc=0 $(cat "$TMP/bothfail/out.log")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Unit tests for the "Install the sandbox dependencies (bubblewrap, socat)"
# step in reusable-pr-auto-review.yml and reusable-claude.yml.
#
# On 2026-11-11 GitHub runners could not resolve any Ubuntu mirror for over
# 20 minutes ("Temporary failure resolving 'security.ubuntu.com'"). The single
# apt-get install exited 100, the job never reached the model, and every PR in
# the fleet got "no verdict" (office-outlook-mcp#128, band-mcp, workflows).
# The step now retries before giving up. These pin that:
#
#   - an install that fails once or twice and then works lets the step pass;
#   - one that keeps failing stops after a bounded number of attempts, fails
#     the step, and says why in an ::error:: annotation;
#   - a failed `apt-get update` alone does not abort the step;
#   - both workflows run the same install logic.
#
# The step's `run:` is extracted from the shipped YAML (same technique as
# review-sandbox.test.sh) and run under `bash -e`, as Actions runs it, with
# sudo/apt-get/sleep/sysctl/bwrap/socat stubbed on PATH.
#
# Usage: bash scripts/sandbox-install.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

NAME='Install the sandbox dependencies (bubblewrap, socat)'
for wf in reusable-pr-auto-review reusable-claude; do
  ruby -ryaml -e '
    wf = YAML.load_file(ARGV[0])
    steps = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
    s = steps.find { |x| x["name"] == ARGV[1] } or abort("no install step")
    File.write(ARGV[2], s["run"])
  ' "$HERE/.github/workflows/$wf.yml" "$NAME" "$TMP/$wf.sh" \
    || { echo "FAIL: could not extract the install step from $wf.yml"; exit 1; }
done

# Stubs. apt-get install fails $INSTALL_FAILS times, then succeeds;
# apt-get update fails when UPDATE_FAILS=1. Every call is logged.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$LOG"
case " $* " in
  *" update "*) [ "${UPDATE_FAILS:-0}" = 1 ] && exit 100; exit 0 ;;
  *" install "*)
    n=$(grep -c ' install ' "$LOG")
    [ "$n" -le "${INSTALL_FAILS:-0}" ] && { echo "E: Temporary failure resolving 'security.ubuntu.com'" >&2; exit 100; }
    exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\n"$@"\n' > "$TMP/bin/sudo"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$LOG"\n' > "$TMP/bin/sleep"
for b in sysctl bwrap socat; do printf '#!/usr/bin/env bash\necho %s\n' "$b" > "$TMP/bin/$b"; done
# The step falls back to Homebrew once apt gives up (sandbox-homebrew.test.sh
# covers that path). Here it must fail, or "an install that never works" would
# depend on the machine: GitHub's ubuntu image has a real /home/linuxbrew.
mkdir -p "$TMP/linuxbrew/bin"
printf '#!/usr/bin/env bash\necho "brew $*" >> "$LOG"\nexit 1\n' > "$TMP/linuxbrew/bin/brew"
chmod +x "$TMP/bin"/* "$TMP/linuxbrew/bin/brew"

run_step() {  # $1 = workflow; env INSTALL_FAILS / UPDATE_FAILS
  : > "$TMP/log"
  LOG="$TMP/log" PATH="$TMP/bin:$PATH" LINUXBREW="$TMP/linuxbrew" GITHUB_PATH="$TMP/github_path" \
    bash -e "$TMP/$1.sh" > "$TMP/out" 2>&1
}
installs() { grep -c ' install ' "$TMP/log"; }

for wf in reusable-pr-auto-review reusable-claude; do
  if INSTALL_FAILS=0 run_step "$wf" && [ "$(installs)" = 1 ] && ! grep -q '^sleep' "$TMP/log"; then
    ok "$wf: a working install runs once, with no wait"
  else bad "$wf: a working install runs once, with no wait" "$(cat "$TMP/out" "$TMP/log")"; fi

  if INSTALL_FAILS=2 run_step "$wf" && [ "$(installs)" = 3 ]; then
    ok "$wf: an install that fails twice, then works, passes on the third attempt"
  else bad "$wf: an install that fails twice, then works, passes on the third attempt" "$(cat "$TMP/out" "$TMP/log")"; fi

  if INSTALL_FAILS=99 run_step "$wf"; then
    bad "$wf: an install that never works fails the step" "step exited 0"
  else
    n=$(installs)
    if [ "$n" -ge 2 ] && [ "$n" -le 5 ]; then ok "$wf: an install that never works stops after $n attempts"
    else bad "$wf: an install that never works stops after a bounded number of attempts" "$n attempts"; fi
    if grep -q '::error::' "$TMP/out" && grep -qi 'mirror' "$TMP/out"; then
      ok "$wf: the give-up says why in an ::error:: annotation"
    else bad "$wf: the give-up says why in an ::error:: annotation" "$(cat "$TMP/out")"; fi
  fi

  if INSTALL_FAILS=0 UPDATE_FAILS=1 run_step "$wf" && [ "$(installs)" = 1 ]; then
    ok "$wf: a failed apt-get update alone does not abort the step"
  else bad "$wf: a failed apt-get update alone does not abort the step" "$(cat "$TMP/out" "$TMP/log")"; fi
done

if diff -q "$TMP/reusable-pr-auto-review.sh" "$TMP/reusable-claude.sh" >/dev/null; then
  ok "both workflows run the same install step"
else bad "both workflows run the same install step" "$(diff "$TMP/reusable-pr-auto-review.sh" "$TMP/reusable-claude.sh")"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

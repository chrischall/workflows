#!/usr/bin/env bash
# Unit tests for reusable-release-please.yml's `Resolve the release to publish`
# step — the one place that decides WHETHER a release publishes, and WHICH tag
# and version it publishes as, on both paths into the publish job:
#
#   - release-please just cut a release (`release_created`), or
#   - a maintainer dispatched `republish_tag` for a tag whose publish never ran.
#
# The second path exists because of 2026-09-14 (chrischall/workflows#283): a
# transient API error hit release-please AFTER it had cut the tag and the
# GitHub Release in creditkarma-mcp, homes-mcp and onehome-mcp, the run lost
# `release_created`, publish skipped, and re-running could never set the flag
# again. Every failure mode of this step is quiet or dangerous:
#
#   - publishing `v1.2.3` as a VERSION string (the two paths disagree about
#     shape — caught in review on onehome-mcp#187 before any dispatch ran);
#   - a dispatch input written to $GITHUB_OUTPUT with a newline in it, which
#     defines a second output the publish job then trusts;
#   - a dispatch naming a tag that does not exist, failing later and vaguely.
#
# The script is extracted from the shipped YAML at run time (the gate.test.sh
# pattern), and run under `bash -e`, the flags GitHub gives a `run:` block.
#
# Usage: bash scripts/release-ref.test.sh
set -uo pipefail   # deliberately no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-release-please.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

[ -f "$WF" ] || { echo "FAIL: $WF does not exist"; exit 1; }

# --- extract the step, and pin the wiring around it --------------------------
ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  job = (wf["jobs"] || {}).values.find { |j| (j["steps"] || []).any? { |s| s["name"] == "Resolve the release to publish" } }
  abort("no job carries the `Resolve the release to publish` step") unless job
  step = job["steps"].find { |s| s["name"] == "Resolve the release to publish" }
  File.write(ARGV[1], step["run"])

  # The dispatch path must not run release-please at all: it is the escape
  # hatch for a release-please run that already failed, so making it depend on
  # the next release-please run succeeding would hand the outage its own fix.
  rp = job["steps"].find { |s| s["uses"].to_s.start_with?("googleapis/release-please-action") }
  abort("no release-please-action step") unless rp
  abort("release-please step is not skipped on a republish (if: #{rp["if"].inspect})") unless rp["if"].to_s.include?("inputs.republish_tag == \x27\x27")

  # Nothing caller-supplied may be interpolated into a script body: a workflow
  # expression is substituted BEFORE the shell parses it.
  wf["jobs"].each do |name, j|
    (j["steps"] || []).each do |s|
      next unless s["run"]
      abort("job #{name}: `${{` expression inside a run: body — pass it through env:") if s["run"].include?("${{")
    end
  end

  # The WIRING, not just the key names: a typo in any of these mappings
  # (`steps.resolv.outputs.publish`, RP_TAG fed from `version`) passes every
  # script case below while publish silently never runs — the exact quiet
  # failure this workflow exists to end.
  jname = wf["jobs"].key(job)
  outs = wf.dig("on", "workflow_call", "outputs") || wf.dig(true, "workflow_call", "outputs") || {}
  want_outs = {
    "publish" => "resolve.outputs.publish", "tag" => "resolve.outputs.tag",
    "version" => "resolve.outputs.version", "release_created" => "release.outputs.release_created",
    "tag_name" => "release.outputs.tag_name", "pr" => "release.outputs.pr",
  }
  want_outs.each do |o, src|
    abort("workflow_call does not declare output `#{o}`") unless outs.key?(o)
    abort("output #{o} maps to #{outs[o]["value"].inspect}") unless outs[o]["value"] == "${{ jobs.#{jname}.outputs.#{o} }}"
    abort("job output #{o} maps to #{job.dig("outputs", o).inspect}") unless job.dig("outputs", o) == "${{ steps.#{src} }}"
  end
  abort("release-please step id is #{rp["id"].inspect}") unless rp["id"] == "release"
  abort("resolve step id is #{step["id"].inspect}") unless step["id"] == "resolve"
  want_env = {
    "REPUBLISH_TAG" => "${{ inputs.republish_tag }}",
    "RELEASE_CREATED" => "${{ steps.release.outputs.release_created }}",
    "RP_TAG" => "${{ steps.release.outputs.tag_name }}",
    "RP_VERSION" => "${{ steps.release.outputs.version }}",
    "REPO" => "${{ github.repository }}",
  }
  want_env.each do |k, v|
    abort("resolve env #{k} is #{step.dig("env", k).inspect}, want #{v}") unless step.dig("env", k) == v
  end
  # The credit steps run only when release-please touched a PR — which also
  # makes them skip on a republish, where release-please never ran.
  job["steps"].each do |s|
    next unless s["uses"].to_s.start_with?("actions/checkout") || s["uses"].to_s.include?("credit-contributors")
    abort("#{s["uses"]} is not gated on a release PR (if: #{s["if"].inspect})") unless s["if"] == "steps.release.outputs.pr != \x27\x27"
  end
' "$WF" "$TMP/resolve.sh" 2>"$TMP/extract.err"
EXTRACT=$?
if [ "$EXTRACT" -eq 0 ]; then ok "wiring: step extracted, release-please skipped on republish, no \${{ in run:, outputs declared"
else echo "FAIL: $(cat "$TMP/extract.err")"; exit 1; fi

# --- fake gh: the dispatch path asks whether the tag exists ------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# gh api repos/<o>/<r>/git/ref/tags/<tag> [--silent]
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  api\ repos/*/git/ref/tags/*)
    tag="${2#*/git/ref/tags/}"
    if [ -n "${GH_FAIL:-}" ]; then echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; fi
    if printf '%s\n' $EXISTING_TAGS | grep -qxF -- "$tag"; then exit 0; fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
echo "fake gh: unsupported invocation: $*" >&2; exit 1
SHIM
chmod +x "$TMP/bin/gh"

# run <case> [VAR=value ...] -> sets $CODE, $OUTF (GITHUB_OUTPUT), $LOG (stdout+stderr)
run() {
  local name="$1"; shift
  OUTF="$TMP/$name.out"; LOG="$TMP/$name.log"; GH_LOG="$TMP/$name.gh"
  : > "$OUTF"; : > "$GH_LOG"
  env -i PATH="$TMP/bin:/usr/bin:/bin:/opt/homebrew/bin" HOME="$TMP" \
    GITHUB_OUTPUT="$OUTF" GH_LOG="$GH_LOG" REPO="chrischall/fake-mcp" GH_TOKEN="t" \
    EXISTING_TAGS="v2.8.3 1.4.4 fake-x-v0.3.0" \
    REPUBLISH_TAG="" RELEASE_CREATED="" RP_TAG="" RP_VERSION="" \
    "$@" bash -e "$TMP/resolve.sh" > "$LOG" 2>&1
  CODE=$?
}
out() { grep -E "^$1=" "$OUTF" | tail -1 | cut -d= -f2-; }
expect_out() { # expect_out <case> <key> <want>
  local got; got=$(out "$2")
  if [ "$got" = "$3" ]; then ok "$1: $2=$3"
  else bad "$1: expected $2=$3, got '$got'" "log: $(cat "$LOG")"; fi
}
expect_code() {
  if [ "$CODE" = "$2" ]; then ok "$1: exit $2"
  else bad "$1: expected exit $2, got $CODE" "log: $(cat "$LOG")"; fi
}
expect_failed() {
  if [ "$CODE" != 0 ]; then ok "$1: refused (exit $CODE)"
  else bad "$1: expected a refusal, got exit 0" "outputs: $(cat "$OUTF")"; fi
  if grep -qE '^publish=true$' "$OUTF"; then bad "$1: a refusal still wrote publish=true" "$(cat "$OUTF")"
  else ok "$1: no publish=true on a refusal"; fi
}

# --- A: a fresh release publishes at release-please's tag -------------------
run a RELEASE_CREATED=true RP_TAG=v1.2.3 RP_VERSION=1.2.3
expect_code a 0; expect_out a publish true; expect_out a tag v1.2.3; expect_out a version 1.2.3
if [ -s "$GH_LOG" ]; then bad "A: the release path asked GitHub about the tag" "$(cat "$GH_LOG")"
else ok "A: the release path makes no API call (release-please just made the tag)"; fi

# --- B: an ordinary push with no release publishes nothing ------------------
run b RELEASE_CREATED=false
expect_code b 0; expect_out b publish false
if [ -z "$(out tag)" ]; then ok "B: no tag output"
else bad "B: tag output without a release" "$(cat "$OUTF")"; fi

# --- C: a plain dispatch (blank republish_tag) is the ordinary path ---------
run c RELEASE_CREATED=""
expect_code c 0; expect_out c publish false

# --- D: republish an existing tag: version is derived from the TAG ----------
run d REPUBLISH_TAG=v2.8.3
expect_code d 0; expect_out d publish true; expect_out d tag v2.8.3; expect_out d version 2.8.3

# --- E: a tag without the v prefix (include_v_in_tag: "") -------------------
run e REPUBLISH_TAG=1.4.4
expect_code e 0; expect_out e version 1.4.4; expect_out e tag 1.4.4

# --- F: a component-prefixed tag (<name>-v<version>) ------------------------
run f REPUBLISH_TAG=fake-x-v0.3.0
expect_code f 0; expect_out f version 0.3.0; expect_out f tag fake-x-v0.3.0

# --- G: a prerelease survives intact ----------------------------------------
run g RELEASE_CREATED=true RP_TAG=v1.2.3-rc.1 RP_VERSION=1.2.3-rc.1
expect_code g 0; expect_out g version 1.2.3-rc.1

# --- H: a republish wins over a release flag (the dispatch skips release-please)
run h REPUBLISH_TAG=v2.8.3 RELEASE_CREATED=false
expect_out h publish true; expect_out h tag v2.8.3

# --- I: malformed tags are refused before anything is written ---------------
run i1 REPUBLISH_TAG=v1.2;             expect_failed I1
run i2 REPUBLISH_TAG=latest;           expect_failed I2
run i3 REPUBLISH_TAG='v1.2.3 ';        expect_failed I3

# --- J: a newline cannot define a second output ------------------------------
run j REPUBLISH_TAG="$(printf 'v2.8.3\nversion=6.6.6')"
expect_failed J
if grep -q '6.6.6' "$OUTF"; then bad "J: injected output landed in GITHUB_OUTPUT" "$(cat "$OUTF")"
else ok "J: injected line never reached GITHUB_OUTPUT"; fi

# --- K: shell metacharacters are data, never code ----------------------------
run k REPUBLISH_TAG='v1.2.3$(touch '"$TMP"'/pwned)'
expect_failed K
if [ -e "$TMP/pwned" ]; then bad "K: command substitution executed" ""
else ok "K: command substitution did not execute"; fi

# --- L: a dispatch naming a tag that does not exist fails, naming it ---------
run l REPUBLISH_TAG=v9.9.9
expect_failed L
if grep -q 'v9.9.9' "$LOG"; then ok "L: the error names the missing tag"
else bad "L: error does not name the tag" "$(cat "$LOG")"; fi

# --- M: release_created with no tag output is loud, not a silent skip --------
run m RELEASE_CREATED=true RP_TAG="" RP_VERSION=""
expect_failed M

# --- N: release-please's version disagreeing with its own tag is loud --------
run n RELEASE_CREATED=true RP_TAG=v1.2.3 RP_VERSION=1.2.4
expect_failed N

# --- P: prereleases whose suffix LOOKS like a version are not a component ----
# POSIX leftmost-longest: with one optional component group, `v2.0.0-0.3.7`
# parsed as component `v2.0.0-` + version `0.3.7`, and a republish of it would
# have published 0.3.7 with no error at all.
run p1 RELEASE_CREATED=true RP_TAG=v2.0.0-0.3.7 RP_VERSION=2.0.0-0.3.7
expect_code p1 0; expect_out p1 version 2.0.0-0.3.7
run p2 REPUBLISH_TAG=1.2.3-4.5.6 EXISTING_TAGS=1.2.3-4.5.6
expect_code p2 0; expect_out p2 version 1.2.3-4.5.6
# Build metadata after a prerelease — the old stub published it unchecked.
run p3 RELEASE_CREATED=true RP_TAG=v1.2.3-rc.1+b.2 RP_VERSION=1.2.3-rc.1+b.2
expect_code p3 0; expect_out p3 version 1.2.3-rc.1+b.2
# A component tag is `<component>-v<version>`, the shape release-please
# writes; without the `v` there is no telling component from prerelease.
run p4 REPUBLISH_TAG=name-1.2.3 EXISTING_TAGS=name-1.2.3
expect_failed P4

# --- O: a transient API failure is not reported as a missing tag -------------
run o REPUBLISH_TAG=v2.8.3 GH_FAIL=1
expect_failed O
if grep -q 'could not check' "$LOG" && ! grep -q 'does not exist' "$LOG"; then
  ok "O: a 5xx says it could not check, not that the tag is missing"
else bad "O: wrong diagnosis for a transient failure" "$(cat "$LOG")"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

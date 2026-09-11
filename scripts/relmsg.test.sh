#!/usr/bin/env bash
# Unit tests for reusable-pr-auto-review.yml's `Check the squash message
# release-please will read` step.
#
# What it guards, and why the guard is not obvious: release-please parses the
# merged commit message with `@conventional-commits/parser`, a strict PEG
# grammar, and it parses the BODY too — not just the subject. One unclosed
# "(" before a newline anywhere in the message makes the parse throw,
# release-please CATCHES the throw and silently skips the commit. No release,
# no changelog entry, and a green workflow. ofw-mcp#284 sat unreleased for two
# days on `grep "registerTool('ofw_"` in a PR body; a fleet scan then found 21
# such commits across 13 repos, ten of them feat/fix.
#
# The step therefore has to reconstruct the message GitHub will actually
# create, which is NOT one thing across this fleet: of the 82 repos in
# fleet.json, 43 squash with COMMIT_OR_PR_TITLE/COMMIT_MESSAGES, 38 with
# PR_TITLE/PR_BODY and one with a mixed PR_TITLE/COMMIT_MESSAGES — so the same
# PR yields a different commit depending on the repo. Most of these cases are
# about that reconstruction; the parse itself is one library call.
#
# Extracted from the shipped YAML at run time (same technique as
# verdict.test.sh), so this exercises the file byte-for-byte with no test-only
# hooks in it.
#
# Usage: bash scripts/relmsg.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == "Check the squash message release-please will read" }
  abort("could not find the squash-message step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/relmsg.sh" || { echo "FAIL: could not extract step from $WF"; exit 1; }

# One real install, reused by every case through RUNNER_TEMP — the step's own
# cache guard means it installs once and then finds the tree already there.
export RUNNER_TEMP="$TMP/runner"
mkdir -p "$RUNNER_TEMP"
PARSER_OK=1
npm install --silent --prefix "$RUNNER_TEMP/relmsg-parser" --no-audit --no-fund \
  --ignore-scripts --no-package-lock \
  @conventional-commits/parser@0.4.1 >/dev/null 2>&1 || PARSER_OK=0
if [ "$PARSER_OK" -eq 0 ]; then
  echo "FAIL: could not install @conventional-commits/parser (network?) — the"
  echo "      parse assertions below are the point of this suite, so this is a"
  echo "      failure rather than a skip."
  exit 1
fi

# `gh` stub. Serves the three reads the step makes, from the case's env.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"/pulls/"*"/commits"*) printf '%s' "$COMMITS_JSON"; exit 0 ;;
  *"/pulls/"*)            printf '%s' "$PR_JSON"; exit 0 ;;
  "api repos/"*)          printf '%s' "$REPO_JSON"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# run_case <name> <expect: ok|fail|warn> — asserts the `unparseable` output.
#   ok   -> empty (the commit parses, or its type is one release-please hides)
#   fail -> non-empty (a releasable commit release-please would silently drop)
#   warn -> empty, but a ::warning:: was emitted
run_case() {
  local name="$1" expect="$2"
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GITHUB_OUTPUT="$dir/out" GITHUB_STEP_SUMMARY="$dir/sum"
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
  local log; log="$dir/log"
  bash -e "$TMP/relmsg.sh" >"$log" 2>&1
  local got; got="$(sed -n 's/^unparseable=//p' "$GITHUB_OUTPUT")"
  case "$expect" in
    ok)   [ -z "$got" ] && ok "$name" || bad "$name" "expected no finding, got: $got" ;;
    fail) [ -n "$got" ] && ok "$name" || bad "$name" "expected a finding, got none. log: $(head -c 400 "$log")" ;;
    warn) if [ -n "$got" ]; then bad "$name" "expected a warning, not a blocking finding: $got"
          elif grep -q '::warning::' "$log"; then ok "$name"
          else bad "$name" "expected a ::warning::, saw none. log: $(head -c 400 "$log")"; fi ;;
  esac
  LAST_LOG="$log"; LAST_SUM="$dir/sum"; LAST_OUT="$got"
}

# Defaults every case starts from: PR_TITLE/PR_BODY squash, one commit.
setup() {
  export GH_TOKEN=x REPO=chrischall/example-mcp PR=53
  export REPO_JSON='{"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  export PR_JSON='{"title":"fix(manifest): three tools were missing","body":"A clean body."}'
  export COMMITS_JSON='[{"commit":{"message":"fix(manifest): three tools were missing\n\nA clean body."}}]'
}

# The unbalanced paren from ofw-mcp#284, verbatim in shape: a `(` that is never
# closed before the newline. This is the whole reason the suite exists, and it
# is written as REAL newlines rather than \n escapes — the escapes survive `jq
# --arg` as two literal characters, which parses fine and would have made every
# assertion below pass against a message that was never broken.
BROKEN_BODY='its name never appears as a literal in this repo and `grep
"registerTool('"'"'ofw_"` cannot see it. A name on a continuation line, and
a name that is a loop variable, are invisible the same way.'

# body <text> — a PR whose title is $1 and whose body is $2
pr_json() { PR_JSON="$(jq -nc --arg t "$1" --arg b "$2" '{title:$t, body:$b}')"; export PR_JSON; }
commits_json() { COMMITS_JSON="$(jq -nc --arg m "$1" '[{commit:{message:$m}}]')"; export COMMITS_JSON; }

echo "— the failure that started this —"
setup
run_case "a clean body parses" ok

setup
pr_json 'fix(manifest): three tools were missing' "$BROKEN_BODY"
run_case "an unclosed ( in the PR body is caught" fail

# The diagnosis is the deliverable: a maintainer who cannot see WHICH line has
# to bisect a 60-line body by hand.
if [ -n "${LAST_OUT:-}" ]; then
  if grep -qF 'registerTool(' "$LAST_SUM" 2>/dev/null; then ok "the summary quotes the offending line"
  else bad "the summary quotes the offending line" "summary: $(head -c 300 "$LAST_SUM" 2>/dev/null)"; fi
  if grep -qiE 'auto-review' "$LAST_SUM" 2>/dev/null; then ok "the summary names the route back (/auto-review)"
  else bad "the summary names the route back (/auto-review)" "summary had no recovery hint"; fi
fi

# The case the obvious version of this check gets wrong, and the one that
# actually shipped. Here the `(` sits mid-way through ONE long unwrapped line,
# so the grammar never meets a newline while waiting for `)` — the text parses
# exactly as typed. GitHub then hard-wraps the body at 72 columns when it
# builds the squash commit, the `(` lands at the end of a line, and the commit
# on `main` throws. ofw-mcp#283's body is this shape verbatim: it parses, and
# `fold -s -w 72` of it throws at line 30 — the same line release-please named.
LONG_LINE_BODY='writing the test found a third missing tool my grep had not. `ofw_healthcheck` registers through a shared `@chrischall/mcp-utils` helper, so its name never appears as a literal in this repo and `grep "registerTool('"'"'ofw_"` cannot see it. A name on a continuation line, and a name that is a loop variable, are invisible the same way.'

setup
pr_json 'fix(manifest): three registered tools were missing' "$LONG_LINE_BODY"
run_case "a long line that only breaks once GitHub wraps it is caught" fail
if [ -n "${LAST_OUT:-}" ]; then
  if grep -qF 'hard-wraps' "$LAST_SUM" 2>/dev/null; then
    ok "the summary says the wrap is what broke it, not the prose"
  else
    bad "the summary says the wrap is what broke it, not the prose" \
        "summary: $(head -c 300 "$LAST_SUM" 2>/dev/null)"
  fi
fi

echo
echo "— it must read the message THIS repo will actually build —"

# 38 repos: the PR body ships. A broken COMMIT body does not.
setup
commits_json "fix: x

$BROKEN_BODY"
run_case "PR_BODY repo: a broken COMMIT body is not the shipped message" ok

# 43 repos: the commit messages ship, so the PR body is the irrelevant one.
setup
export REPO_JSON='{"squash_merge_commit_title":"COMMIT_OR_PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES"}'
commits_json "fix: x

$BROKEN_BODY"
run_case "COMMIT_MESSAGES repo: a broken commit body IS caught" fail

setup
export REPO_JSON='{"squash_merge_commit_title":"COMMIT_OR_PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES"}'
pr_json 'fix: x' "$BROKEN_BODY"
run_case "COMMIT_MESSAGES repo: a broken PR body is not the shipped message" ok

# BLANK is the third setting GitHub offers, and no repo here uses it today —
# which is exactly why it needs a case: the jq `else "" end` branch is
# unreachable from the fleet's current config, so nothing else would notice it
# breaking. A blank body cannot contain a paren, so this must always be clean.
setup
export REPO_JSON='{"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"BLANK"}'
pr_json 'fix: x' "$BROKEN_BODY"
run_case "BLANK body: nothing ships, so nothing can fail" ok

# COMMIT_OR_PR_TITLE takes the sole commit's subject only when there IS one
# commit. With two it falls back to the PR title — the branch that decides
# whether `refactor!:` or `fix:` is the release decision on a multi-commit PR.
setup
export REPO_JSON='{"squash_merge_commit_title":"COMMIT_OR_PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES"}'
COMMITS_JSON="$(jq -nc --arg a "chore: wip" --arg b "chore: more wip

$BROKEN_BODY" '[{commit:{message:$a}},{commit:{message:$b}}]')"
export COMMITS_JSON
pr_json 'fix(manifest): three registered tools were missing' 'ignored'
run_case "multi-commit COMMIT_OR_PR_TITLE falls back to the PR title" fail

echo
echo "— only a commit release-please would have SHIPPED can block —"

# chore/ci/test/build are hidden types: release-please dropping one costs
# nothing, so failing the PR over it would be pure noise (and dependabot's
# release-note bodies are full of parens).
setup
pr_json 'chore(deps): bump foo from 1 to 2' "$BROKEN_BODY"
run_case "a hidden type (chore) warns rather than blocks" warn

setup
pr_json 'docs(skill): document the view parameter' "$BROKEN_BODY"
run_case "docs blocks — it is hidden from the BUMP, not from the changelog" fail

setup
pr_json 'refactor(engine)!: drop the legacy path' "$BROKEN_BODY"
run_case "a breaking ! blocks whatever the type" fail

# A subject with no conventional type is already invisible to release-please
# for reasons this check does not own, so it must not be reported here as if
# the paren were the problem.
setup
pr_json 'update the readme' "$BROKEN_BODY"
run_case "a non-conventional subject is not this check's finding" ok

echo
echo "— it must never be the reason a review job dies —"

setup
export REPO_JSON='' PR_JSON='' COMMITS_JSON=''
run_case "an empty API read fails open rather than aborting the job" ok

setup
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$TMP/bin/gh"
run_case "a failing gh fails open rather than aborting the job" ok
# restore the working stub for anything after this
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"/pulls/"*"/commits"*) printf '%s' "$COMMITS_JSON"; exit 0 ;;
  *"/pulls/"*)            printf '%s' "$PR_JSON"; exit 0 ;;
  "api repos/"*)          printf '%s' "$REPO_JSON"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/gh"

echo
echo "— the finding has to actually reach the verdict and the arming step —"
# A check nothing consumes is the most expensive kind of green. These pin the
# three wires: skip the model review, synthesize a `fail`, and let the existing
# arm step de-arm off that verdict.
wire() {
  local name="$1" pat="$2"
  if grep -qF "$pat" "$WF"; then ok "$name"; else bad "$name" "workflow did not contain: $pat"; fi
}
wire "an unparseable message skips the model review" \
     "steps.relmsg.outputs.unparseable == ''"
wire "the verdict step receives the finding" \
     "UNPARSEABLE: \${{ steps.relmsg.outputs.unparseable }}"
wire "it synthesizes a verdict rather than leaving the PR un-reviewed" \
     'if [ -n "$UNPARSEABLE" ]; then'

# The verdict must be `fail`. A `warn` would still ARM the PR — pass/warn both
# arm — and it would merge green and ship nothing, which is the exact outcome
# this check exists to prevent.
relmsg_verdict="$(ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == "Post verdict to PR" }
  run = step["run"]
  seg = run[/if \[ -n "\$UNPARSEABLE" \].*?(?=elif)/m].to_s
  puts seg
' "$WF")"
if printf '%s' "$relmsg_verdict" | grep -qF 'verdict: "fail"'; then
  ok "the synthesized verdict is fail, not warn (warn would still arm)"
else
  bad "the synthesized verdict is fail, not warn (warn would still arm)" \
      "branch did not set verdict fail"
fi

echo
echo "— the shell contract every guard in this file is written against —"
# The step's guards (`|| true` on each acceptable failure, no bare
# `cmd && VAR=…`) are correct for `-e`, and the reason has to stay accurate:
# GitHub runs a `run:` block as `bash -e {0}` UNLESS the file asks for
# `shell: bash`, which yields `bash -eo pipefail`. This file asks for neither,
# so no comment in it may claim pipefail is on — four did, describing the very
# constructs a reader would otherwise re-derive. A wrong rationale is worse
# than none: it is believed.
if grep -nE '^\s*(defaults:|shell:)' "$WF" >/dev/null 2>&1; then
  ok "SKIP: this file now sets shell:/defaults: — revisit the claims below"
else
  ok "the workflow sets no shell:/defaults:, so its blocks run as bash -e {0}"
  claims="$(grep -n 'pipefail' "$WF" | grep -v 'set -euo pipefail' \
    | grep -viE "no .?pipefail|not .?.pipefail|pipefail. is off|sets no|NOT \`pipefail\`" || true)"
  if [ -z "$claims" ]; then
    ok "no comment claims pipefail is on"
  else
    bad "no comment claims pipefail is on" "$claims"
  fi
fi

echo
# Same harness invariant verdict.test.sh pins: the extracted step must run
# under the aborting shell GitHub gives a `run:` block, or every "it keeps
# going" assertion above tests nothing.
if grep -nE 'bash +"\$TMP/relmsg\.sh"' "$0" | grep -qv -- '-e '; then
  bad "extracted step runs under an aborting shell" "add -e to the bash invocation"
else ok "extracted step runs under an aborting shell, as GitHub does"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Unit tests for what the ad-hoc `@claude` job in reusable-claude.yml lets the
# model do (fleet-audit#967).
#
# That job is the ONLY review path for a fork PR: a maintainer comments
# "@claude take a look" and the model runs on refs/pull/N/head — a stranger's
# code. The sandbox built for the auto-review job (fleet-audit#282, pinned by
# review-sandbox.test.sh) was never ported here, so this job ran with
# `contents: write`, the checkout's project settings and hooks, the fork's
# symlinks intact, and no subprocess env scrub — and it fired on any comment
# that merely CONTAINED "@claude" (the substring shape #284 fixed for
# /auto-review). These pin the port:
#
#   - `@claude` must be a whole-word mention (the gate step), matching the
#     action's own trigger regex, so "foo@claude.ai" or "@claudette" does not
#     check out a fork.
#   - fork PRs are detected, and on a fork the checkout does not persist the
#     workflow token and the model loses every write tool (edits, git
#     add/commit/rm/push and the action's push wrapper, API commits).
#   - the job token is read-only for contents; the action writes with its own
#     App token.
#   - CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 with bubblewrap + socat installed,
#     user-only settings, and symlinks removed after checkout, before the model.
#
# Extracted from the shipped YAML at run time (same technique as
# review-sandbox.test.sh), so this exercises the file byte-for-byte.
#
# Usage: bash scripts/claude-sandbox.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-claude.yml"
REVIEW_WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  job = wf["jobs"]["claude"] or abort("no claude job")
  steps = job["steps"]
  run = steps.find { |s| s["id"] == "claude" } or abort("no claude step")
  File.write(ARGV[1], run["with"]["claude_args"].to_s)
  File.write(ARGV[2], (job["env"] || {}).map { |k, v| "#{k}=#{v}" }.join("\n") + "\n")
  File.write(ARGV[3], steps.map { |s| s["name"].to_s }.join("\n") + "\n")
  neut = steps.find { |s| s["name"] == "Remove symlinks from the checkout" }
  File.write(ARGV[4], neut ? neut["run"] : "")
  gate = steps.find { |s| s["id"] == "gate" }
  File.write(ARGV[5], gate ? gate["run"] : "")
  File.write(ARGV[6], (job["permissions"] || {}).map { |k, v| "#{k}=#{v}" }.join("\n") + "\n")
  co = steps.find { |s| s["uses"].to_s.start_with?("actions/checkout@") } or abort("no checkout")
  File.write(ARGV[7], co["with"]["persist-credentials"].to_s)
  # Every step after the gate must be skipped when there is no real mention.
  gi = steps.index(gate) || -1
  ungated = steps.each_with_index.select { |s, i| i > gi && !s["if"].to_s.include?("steps.gate.outputs.mention == \x27true\x27") }
  File.write(ARGV[8], ungated.map { |s, _| s["name"].to_s }.join("\n"))
  File.write(ARGV[9], gi.to_s)
  File.write(ARGV[10], steps.map { |s| s["run"].to_s }.join("\n"))
' "$WF" "$TMP/args.txt" "$TMP/env.txt" "$TMP/steps.txt" "$TMP/neutralize.sh" \
    "$TMP/gate.sh" "$TMP/perms.txt" "$TMP/persist.txt" "$TMP/ungated.txt" \
    "$TMP/gate_index.txt" "$TMP/runs.txt" \
  || { echo "FAIL: could not extract the claude job from $WF"; exit 1; }

echo "── token scope ──"
if grep -qxF 'contents=read' "$TMP/perms.txt"; then ok "job token is contents: read (the action writes with its App token)"
else bad "job token is contents: read (the action writes with its App token)" "$(tr '\n' ' ' < "$TMP/perms.txt")"; fi
if grep -qxF 'id-token=write' "$TMP/perms.txt"; then ok "id-token: write kept (App token exchange)"
else bad "id-token: write kept (App token exchange)" "$(tr '\n' ' ' < "$TMP/perms.txt")"; fi
if grep -qF "steps.gate.outputs.fork" "$TMP/persist.txt" && grep -qF "!= 'true'" "$TMP/persist.txt"; then
  ok "checkout does not persist the workflow token on a fork PR"
else bad "checkout does not persist the workflow token on a fork PR" "persist-credentials: '$(cat "$TMP/persist.txt")'"; fi

echo "── settings and environment ──"
if grep -qE -- '--setting-sources user([[:space:]]|$)' "$TMP/args.txt"; then
  ok "loads user settings only (no project settings or hooks)"
else bad "loads user settings only (no project settings or hooks)" "$(cat "$TMP/args.txt")"; fi
if grep -qE -- '--model claude-opus-5-5' "$TMP/args.txt"; then ok "model pin kept"
else bad "model pin kept" "$(cat "$TMP/args.txt")"; fi
if grep -qxE "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB='?1'?" "$TMP/env.txt"; then
  ok "job sets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1"
else bad "job sets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1" "job env: $(tr '\n' ' ' < "$TMP/env.txt")"; fi
if grep -qE 'apt-get install [^#]*bubblewrap' "$TMP/runs.txt" && grep -qE 'apt-get install [^#]*socat' "$TMP/runs.txt"; then
  ok "job installs bubblewrap and socat for the env scrub"
else bad "job installs bubblewrap and socat for the env scrub" "no apt-get install bubblewrap socat"; fi
if grep -qF 'kernel.apparmor_restrict_unprivileged_userns=0' "$TMP/runs.txt"; then
  ok "job lets bwrap create its user namespace (ubuntu 24.04 AppArmor)"
else bad "job lets bwrap create its user namespace (ubuntu 24.04 AppArmor)" "no sysctl"; fi

echo "── write tools are denied on a fork PR ──"
fork_deny="$(grep -oE -- "steps\.gate\.outputs\.fork == 'true' && '--disallowedTools \"[^\"]*\"'" "$TMP/args.txt" \
  | sed -E "s/.*--disallowedTools \"//; s/\"'$//" | tr ',' '\n')"
for rule in 'Edit' 'MultiEdit' 'Write' 'NotebookEdit' 'Bash(git add:*)' 'Bash(git commit:*)' \
            'Bash(git rm:*)' 'Bash(git push:*)' 'Bash(*git-push.sh*)' \
            'mcp__github_file_ops__commit_files' 'mcp__github_file_ops__delete_files'; do
  if printf '%s\n' "$fork_deny" | grep -qxF -- "$rule"; then ok "fork deny list has $rule"
  else bad "fork deny list has $rule" "$(printf '%s' "$fork_deny" | tr '\n' ',')"; fi
done

echo "── step order ──"
pos() { grep -nxF -- "$1" "$TMP/steps.txt" | head -1 | cut -d: -f1; }
gt="$(pos 'Require a whole-word @claude mention and detect a fork PR')"
co="$(pos 'Checkout the PR under discussion (or the default branch)')"
nz="$(pos 'Remove symlinks from the checkout')"
rv="$(pos 'Run Claude Code')"
if [ -n "$gt" ] && [ -n "$co" ] && [ -n "$nz" ] && [ -n "$rv" ] && [ "$gt" -lt "$co" ] && [ "$co" -lt "$nz" ] && [ "$nz" -lt "$rv" ]; then
  ok "gate, then checkout, then symlink removal, then the model"
else bad "gate, then checkout, then symlink removal, then the model" "gate=${gt:-missing} checkout=${co:-missing} neutralize=${nz:-missing} run=${rv:-missing}"; fi
if [ "$(cat "$TMP/gate_index.txt")" = "0" ] && [ ! -s "$TMP/ungated.txt" ]; then
  ok "every step after the gate requires a real mention"
else bad "every step after the gate requires a real mention" "gate index $(cat "$TMP/gate_index.txt"); ungated: $(tr '\n' ',' < "$TMP/ungated.txt")"; fi

echo "── symlink removal matches the review job's ──"
review_nz="$(ruby -ryaml -e 'wf = YAML.load_file(ARGV[0]); s = wf["jobs"]["review"]["steps"].find { |x| x["name"] == "Remove symlinks from the checkout" }; print(s ? s["run"] : "")' "$REVIEW_WF")"
if [ -s "$TMP/neutralize.sh" ] && [ "$(cat "$TMP/neutralize.sh")" = "$review_nz" ]; then
  ok "same script as reusable-pr-auto-review.yml (behaviour pinned by review-sandbox.test.sh)"
else bad "same script as reusable-pr-auto-review.yml (behaviour pinned by review-sandbox.test.sh)" "missing or drifted"; fi
if [ -s "$TMP/neutralize.sh" ]; then
  R="$TMP/repo"; mkdir -p "$R/sub"; (
    cd "$R" && git init -q && git config user.email t@t && git config user.name t
    echo hi > a.txt; ln -s /proc sub/escape
    git add -A && git commit -qm init
  )
  (cd "$R" && bash -e "$TMP/neutralize.sh") >"$TMP/nz.log" 2>&1
  left="$(cd "$R" && find . -path ./.git -prune -o -type l -print)"
  [ -z "$left" ] && ok "no symlink left in the worktree" || bad "no symlink left in the worktree" "$left"
fi

echo "── gate: whole-word @claude mention ──"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.calls"
[ -n "${STUB_FAIL:-}" ] && exit 1
printf '%s\n' "$STUB_HEAD_REPO"
STUB
chmod +x "$TMP/bin/gh"

# gate <event> <body> [key=value env...]; leaves outputs in $TMP/out
gate() {
  local event="$1" body="$2"; shift 2
  rm -f "$TMP/gh.calls"; : > "$TMP/out"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP" STUB_DIR="$TMP" GITHUB_OUTPUT="$TMP/out" \
    REPO=o/r EVENT="$event" GH_TOKEN=x \
    COMMENT_BODY= REVIEW_BODY= ISSUE_BODY= ISSUE_TITLE= IS_PR_COMMENT= PR_NUMBER= PR_HEAD_REPO= \
    STUB_HEAD_REPO=o/r \
    "$@" \
    bash -e "$TMP/gate.sh" > "$TMP/log" 2>&1
}
out() { grep -E "^$1=" "$TMP/out" | tail -1 | cut -d= -f2-; }

mention_case() { # mention_case <want true|false> <event> <body> [env...]
  local want="$1" ev="$2" body="$3"; shift 3
  local var=COMMENT_BODY
  [ "$ev" = pull_request_review ] && var=REVIEW_BODY
  [ "$ev" = issues ] && var=ISSUE_BODY
  gate "$ev" "$body" "$var=$body" "$@"
  local got; got="$(out mention)"
  if [ "$got" = "$want" ]; then ok "mention=$want for $ev: $(printf '%s' "$body" | head -c 50 | tr '\n' '|')"
  else bad "mention=$want for $ev: $(printf '%s' "$body" | tr '\n' '|')" "got '$got'; $(cat "$TMP/log")"; fi
}

if [ -s "$TMP/gate.sh" ]; then
  mention_case true  issue_comment '@claude can you look at this?'
  mention_case true  issue_comment 'sure, @claude take a look'
  mention_case true  issue_comment "thanks.
@claude, please re-check"
  mention_case true  issue_comment 'what do you think @claude?'
  mention_case false issue_comment 'mail me at someone@claude.ai'
  mention_case false issue_comment 'ping @claudette about it'
  mention_case false issue_comment 'see chrischall/@claude-notes'
  mention_case false issue_comment 'no mention at all'
  mention_case true  pull_request_review_comment '@claude why?'
  mention_case true  pull_request_review 'LGTM but @claude check the lockfile'
  mention_case false pull_request_review 'x@claude'
  mention_case true  issues '@claude triage this'
  gate issues "" ISSUE_TITLE='@claude: flaky test' ISSUE_BODY='body'
  [ "$(out mention)" = true ] && ok "mention=true for an issue title mention" || bad "mention=true for an issue title mention" "$(cat "$TMP/out" "$TMP/log")"
  gate issues "" ISSUE_TITLE='foo@claude.ai bounce' ISSUE_BODY='body'
  [ "$(out mention)" = false ] && ok "mention=false for an email in an issue title" || bad "mention=false for an email in an issue title" "$(cat "$TMP/out" "$TMP/log")"
else
  bad "gate step exists" "no step with id: gate"
fi

echo "── gate: fork detection ──"
fork_case() { # fork_case <want> <label> <event> [env...]
  local want="$1" label="$2" ev="$3"; shift 3
  gate "$ev" "" "$@"
  local got; got="$(out fork)"
  if [ "$got" = "$want" ]; then ok "fork=$want: $label"
  else bad "fork=$want: $label" "got '$got'; $(cat "$TMP/out" "$TMP/log")"; fi
}
if [ -s "$TMP/gate.sh" ]; then
  fork_case false "same-repo PR comment" issue_comment COMMENT_BODY='@claude hi' IS_PR_COMMENT=true PR_NUMBER=7 STUB_HEAD_REPO=o/r
  if grep -qF 'repos/o/r/pulls/7' "$TMP/gh.calls" 2>/dev/null; then ok "PR comment looks the PR up by number"
  else bad "PR comment looks the PR up by number" "$(cat "$TMP/gh.calls" 2>/dev/null)"; fi
  fork_case false "same-repo PR comment, owner case differs" issue_comment COMMENT_BODY='@claude hi' IS_PR_COMMENT=true PR_NUMBER=7 STUB_HEAD_REPO=O/R
  fork_case true  "fork PR comment" issue_comment COMMENT_BODY='@claude hi' IS_PR_COMMENT=true PR_NUMBER=7 STUB_HEAD_REPO=stranger/r
  fork_case true  "deleted fork (head repo null)" issue_comment COMMENT_BODY='@claude hi' IS_PR_COMMENT=true PR_NUMBER=7 STUB_HEAD_REPO=null
  fork_case true  "PR lookup fails: fail closed" issue_comment COMMENT_BODY='@claude hi' IS_PR_COMMENT=true PR_NUMBER=7 STUB_FAIL=1
  fork_case false "comment on a plain issue" issue_comment COMMENT_BODY='@claude hi'
  [ ! -e "$TMP/gh.calls" ] && ok "plain issue comment makes no PR lookup" || bad "plain issue comment makes no PR lookup" "$(cat "$TMP/gh.calls")"
  fork_case false "new issue" issues ISSUE_BODY='@claude hi'
  fork_case false "same-repo review comment" pull_request_review_comment COMMENT_BODY='@claude hi' PR_NUMBER=7 PR_HEAD_REPO=o/r
  fork_case true  "fork review comment" pull_request_review_comment COMMENT_BODY='@claude hi' PR_NUMBER=7 PR_HEAD_REPO=stranger/r
  fork_case true  "fork review" pull_request_review REVIEW_BODY='@claude hi' PR_NUMBER=7 PR_HEAD_REPO=stranger/r
  fork_case true  "review on a deleted fork (no head repo)" pull_request_review REVIEW_BODY='@claude hi' PR_NUMBER=7 PR_HEAD_REPO=
  gate issue_comment "" COMMENT_BODY='mail someone@claude.ai' IS_PR_COMMENT=true PR_NUMBER=7
  [ ! -e "$TMP/gh.calls" ] && ok "no mention: no PR lookup" || bad "no mention: no PR lookup" "$(cat "$TMP/gh.calls")"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Unit tests for reusable-pr-auto-review.yml's `Post verdict to PR` step —
# specifically the NO-VERDICT paths, which are the ones a human has to act on.
#
# Extracted from the shipped YAML at run time (same technique as
# gate.test.sh), so this exercises the file byte-for-byte with no test-only
# hooks in it.
#
# Why the self-edit rows exist: a PR that edits the workflow reviewing it
# cannot be reviewed by its own `pull_request` run — claude-code-action
# refuses a workflow file that differs from the default branch's copy. The
# review emits nothing, and the step used to surface a bare "no verdict —
# treat as un-reviewed", which reads as a broken review and invites a re-run
# that reproduces it exactly. 78 sweep PRs sat idle on this at once. The
# comment must instead name the cause and the route out (`/auto-review`,
# which runs from the default branch).
#
# Usage: bash scripts/verdict.test.sh
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
           .find { |s| s["name"] == "Post verdict to PR" }
  abort("could not find `Post verdict to PR` step") unless step
  File.write(ARGV[1], step["run"])
' "$WF" "$TMP/verdict.sh" || { echo "FAIL: could not extract step from $WF"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${CALLS:-}" ] && echo "gh $*" >> "$CALLS"
# `gh pr diff <n> --repo <r> --name-only` -> the PR's changed files
case "$*" in
  "pr diff"*--name-only*) printf '%s\n' "$CHANGED_FILES"; exit 0 ;;
  "pr view"*comments*)    printf '%s' "$RECOVER_BODY"; exit 0 ;;
  # An earlier review's verdict comment, when the case sets one.
  *"issues/"*"/comments --paginate"*) [ -n "${EXISTING_ID:-}" ] && echo "$EXISTING_ID"; exit 0 ;;
esac
# The POST that carries the rendered comment body.
for a in "$@"; do case "$a" in body=*) printf '%s' "${a#body=}" > "$POSTED" ;; esac; done
# A POST asked for the new comment's id gets one.
case "$*" in *"-X POST"*"--jq .id"*) echo 4242 ;; esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# want: a grep -F pattern the posted comment body must contain ('' = must NOT
# contain the self-edit guidance)
run_case() {
  local name="$1" want="$2"; shift 2
  local dir; dir="$(mktemp -d "$TMP/case.XXXXXX")"
  export GITHUB_OUTPUT="$dir/out" POSTED="$dir/posted"; : > "$GITHUB_OUTPUT"; : > "$POSTED"
  export GH_TOKEN=x PR=53 REPO=chrischall/example-mcp OUT="" VIOLATIONS="" \
         RECOVER_BODY="" EXEC_FILE="" EVENT=pull_request \
         WORKFLOW_REF="chrischall/example-mcp/.github/workflows/pr-auto-review.yml@refs/pull/53/merge" \
         CHANGED_FILES="src/index.ts"
  local kv; for kv in "$@"; do export "${kv?}"; done
  bash -e "$TMP/verdict.sh" >"$dir/log" 2>&1
  local body; body="$(cat "$POSTED")"
  if [ -z "$want" ]; then
    if printf '%s' "$body" | grep -qF '/auto-review'; then
      bad "$name" "comment offered the /auto-review route when it should not have"
    else ok "$name"; fi
  elif printf '%s' "$body" | grep -qF "$want"; then ok "$name"
  else bad "$name" "posted body did not contain: $want"; fi
}

echo "── No-verdict diagnosis ──"
run_case "PR edits the reviewing workflow → names the cause" \
  'the very workflow this run executes' \
  CHANGED_FILES=".github/workflows/pr-auto-review.yml"
run_case "PR edits the reviewing workflow → names the route out" \
  '/auto-review' \
  CHANGED_FILES=".github/workflows/pr-auto-review.yml"
run_case "PR edits some OTHER workflow → hints at the same cause" \
  'files under' \
  CHANGED_FILES=".github/workflows/ci.yml"
run_case "ordinary PR, review fell over → no misleading workflow hint" \
  '' \
  CHANGED_FILES="src/index.ts"
run_case "already an /auto-review re-run → no hint (it IS the route out)" \
  '' \
  EVENT=issue_comment CHANGED_FILES=".github/workflows/pr-auto-review.yml"

echo "── The verdict contract is unchanged ──"
run_case "a real verdict still renders normally" \
  'Auto-review verdict' \
  OUT='{"verdict":"pass","summary":"looks good","important_findings":[],"nits":[]}'

# ONE comment per review. The model used to post its own summary comment and
# claude-code-action a progress comment, beside this verdict comment — three
# top-level comments saying the same thing (infinitecampus-mcp#257). The
# model's review text now arrives in structured output and renders HERE.
echo "── One comment: the review renders inside the verdict comment ──"
run_case "the model's review text renders in the verdict comment" \
  'Checked the timeout wiring in src/client.ts' \
  OUT='{"verdict":"pass","summary":"looks good","important_findings":[],"nits":[],"review":"### Review\n\nChecked the timeout wiring in src/client.ts."}'
run_case "the verdict line still leads the comment" \
  '✅ Auto-review verdict: **pass** — looks good' \
  OUT='{"verdict":"pass","summary":"looks good","important_findings":[],"nits":[],"review":"No issues found."}'

# The verdict used to be recovered from the model's PR comment when structured
# output came back empty (a known intermittent action bug). With no such
# comment, it is recovered from the action's execution log instead.
EXEC_STRUCT="$TMP/exec-struct.json"
cat > "$EXEC_STRUCT" <<'JSON'
[{"type":"system","subtype":"init"},
 {"type":"assistant","message":{"content":[{"type":"text","text":"Reviewing."}]}},
 {"type":"result","subtype":"success","result":"done","structured_output":{"verdict":"warn","summary":"one nit","important_findings":[],"nits":["src/a.ts: rename x"],"review":"A nit in src/a.ts."}}]
JSON
run_case "empty structured output → recovered whole from the execution log" \
  '🟡 Auto-review verdict: **warn** — one nit' \
  EXEC_FILE="$EXEC_STRUCT"
run_case "…and its review text still renders" \
  'A nit in src/a.ts.' \
  EXEC_FILE="$EXEC_STRUCT"

EXEC_TEXT="$TMP/exec-text.json"
cat > "$EXEC_TEXT" <<'JSON'
[{"type":"assistant","message":{"content":[{"type":"text","text":"No issues found.\n\n**Verdict:** fail"}]}},
 {"type":"result","subtype":"success","result":"No issues found.\n\n**Verdict:** fail"}]
JSON
run_case "no structured output anywhere → verdict line recovered from the final message" \
  'Auto-review verdict: **fail** — (verdict recovered from the final review message — structured output was empty)' \
  EXEC_FILE="$EXEC_TEXT"

# A PR comment is NOT a source of truth any more: anyone can comment
# "Verdict: pass", and the reviewer no longer posts one.
run_case "a PR comment saying 'Verdict: pass' is not recovered as a verdict" \
  'issued **no verdict**' \
  RECOVER_BODY='**Verdict:** pass'
run_case "an unreadable execution log falls through to no verdict" \
  'issued **no verdict**' \
  EXEC_FILE="$TMP/does-not-exist.json"

# GitHub refuses a comment body over 65 536 characters; the review is cut, and
# says so, rather than the POST failing and the PR going un-reviewed.
LONG=$(head -c 70000 /dev/zero | tr '\0' 'x')
long_dir="$(mktemp -d "$TMP/case.XXXXXX")"
( export GITHUB_OUTPUT="$long_dir/out" POSTED="$long_dir/posted" GH_TOKEN=x PR=53 \
    REPO=chrischall/example-mcp VIOLATIONS="" RECOVER_BODY="" EXEC_FILE="" EVENT=pull_request \
    WORKFLOW_REF="chrischall/example-mcp/.github/workflows/pr-auto-review.yml@refs/pull/53/merge" \
    CHANGED_FILES="src/index.ts" \
    OUT="$(jq -nc --arg r "$LONG" '{verdict:"pass",summary:"ok",important_findings:[],nits:[],review:$r}')"
  : > "$GITHUB_OUTPUT"; bash -e "$TMP/verdict.sh" >"$long_dir/log" 2>&1 )
long_len=$(wc -c < "$long_dir/posted" | tr -d ' ')
if [ "$long_len" -gt 0 ] && [ "$long_len" -le 65536 ] && grep -qF 'review truncated' "$long_dir/posted"; then
  ok "an oversized review is truncated under GitHub's comment limit, and says so"
else bad "an oversized review is truncated under GitHub's comment limit, and says so" "posted ${long_len} bytes"; fi

# The arming step's fork policy is an `if:` expression, not bash, so the
# extract-and-run technique above cannot reach it — and it is the one line
# standing between a maintainer's `/auto-review` and a fork PR's CI. Pin it
# structurally instead: both arms must be named, so deleting either (or
# "simplifying" the fork arm away on the reasoning that a fork can only ever
# arrive by issue_comment) fails here rather than in 79 repos.
echo "── The arm step's fork policy ──"
arm_if="$(ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  step = wf["jobs"].values.flat_map { |j| j["steps"] || [] }
           .find { |s| s["name"] == "Arm or de-arm auto-merge from the verdict" }
  abort("could not find `Arm or de-arm auto-merge from the verdict` step") unless step
  print step["if"].to_s
' "$WF")" || arm_if=""

arm_case() {
  local name="$1" want="$2"
  if printf '%s' "$arm_if" | grep -qF "$want"; then ok "$name"
  else bad "$name" "arm step if: did not contain: $want"; fi
}

arm_case "same-repo PRs still arm" "is_fork == 'false'"
arm_case "a fork arms down the /auto-review path" "github.event_name == 'issue_comment'"
arm_case "a failed verdict step still cannot arm" '!cancelled()'

# Each review gets its OWN comment. Editing one comment in place erased the
# previous verdict: a PR's history read as one review, re-dated, and a reader
# could not see what an earlier round said about an earlier commit
# (ofw-mcp#391 — a pass on d760647 overwrote the warn on 0559824).
echo "── A new comment per review ──"
pr_dir="$(mktemp -d "$TMP/case.XXXXXX")"
( export GITHUB_OUTPUT="$pr_dir/out" POSTED="$pr_dir/posted" CALLS="$pr_dir/calls" GH_TOKEN=x PR=53 \
    REPO=chrischall/example-mcp VIOLATIONS="" RECOVER_BODY="" EXEC_FILE="" EVENT=issue_comment \
    WORKFLOW_REF="chrischall/example-mcp/.github/workflows/pr-auto-review.yml@refs/heads/main" \
    CHANGED_FILES="src/index.ts" EXISTING_ID=1111 HEAD_SHA=d760647b939199f2bfb5fb309379d3498051d397 \
    OUT='{"verdict":"pass","summary":"ok","important_findings":[],"nits":[],"review":"No issues found."}'
  : > "$GITHUB_OUTPUT"; : > "$CALLS"; bash -e "$TMP/verdict.sh" >"$pr_dir/log" 2>&1 )
if grep -qF -- '-X PATCH' "$pr_dir/calls"; then
  bad "a re-review does not edit the earlier verdict comment" "$(grep -F -- '-X PATCH' "$pr_dir/calls")"
else ok "a re-review does not edit the earlier verdict comment"; fi
if grep -qF -- "-X POST repos/chrischall/example-mcp/issues/53/comments" "$pr_dir/calls"; then
  ok "a re-review posts a new verdict comment"
else bad "a re-review posts a new verdict comment" "calls: $(tr '\n' ' ' < "$pr_dir/calls")"; fi
if grep -qx 'comment_id=4242' "$pr_dir/out"; then ok "the new comment's id is a step output"
else bad "the new comment's id is a step output" "outputs: $(tr '\n' ' ' < "$pr_dir/out")"; fi
if grep -qF 'Reviewed commit `d760647`' "$pr_dir/posted"; then
  ok "each verdict comment names the commit it reviewed"
else bad "each verdict comment names the commit it reviewed" "body: $(head -c 300 "$pr_dir/posted")"; fi

echo
# The harness must run each extracted step under the flags GitHub gives it —
# `bash -e` for a workflow `run:` block, `bash -eo pipefail` for a composite
# action's `shell: bash`. Under a plain `bash` an unguarded non-zero continues
# here and ABORTS in production, so every "the step still does its second job"
# assertion above silently tests nothing. That is exactly how #213 shipped a
# de-arm that skipped `--disable-auto` whenever the label call failed.
if grep -nE 'bash +"\$(TMP|WORK)/' "$0" >/dev/null; then
  bad "extracted steps run under an aborting shell" \
      "$(grep -nE 'bash +"\$(TMP|WORK)/' "$0" | head -3) — add -e (or -eo pipefail for a composite step)"
else ok "extracted steps run under an aborting shell, as GitHub does"; fi
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

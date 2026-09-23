#!/usr/bin/env bash
# Unit tests for the `/auto-review` command match in reusable-pr-auto-review.yml
# — the one deliberate human act the whole fork trust model rests on.
#
# It used to be a SUBSTRING match, in both the `context` job's `if:` and its
# `pr` step, so any maintainer comment that merely mentioned the command —
# "please don't /auto-review this until the postinstall is gone", a quoted
# reply, pasted instructions — reviewed, armed and built a fork
# (fleet-audit#284). The command must now open the comment.
#
# Extracted from the shipped YAML at run time (same technique as
# dedupe.test.sh / arm.test.sh), so this exercises the file byte-for-byte.
#
# Usage: bash scripts/command.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WF="$HERE/.github/workflows/reusable-pr-auto-review.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

ruby -ryaml -e '
  wf = YAML.load_file(ARGV[0])
  job = wf["jobs"]["context"] or abort("no context job")
  step = job["steps"].find { |s| s["id"] == "pr" } or abort("no pr step")
  File.write(ARGV[1], step["run"])
  File.write(ARGV[2], job["if"])
' "$WF" "$TMP/pr.sh" "$TMP/if.txt" \
  || { echo "FAIL: could not extract the context job from $WF"; exit 1; }

# --- the job `if:` must not use a substring match on the comment body -------
if grep -q "contains(github.event.comment.body, '/auto-review')" "$TMP/if.txt"; then
  bad "job if: matches /auto-review as a whole command" "still a contains() substring match"
elif grep -q "startsWith(github.event.comment.body, '/auto-review')" "$TMP/if.txt"; then
  ok "job if: matches /auto-review as a whole command"
else
  bad "job if: matches /auto-review as a whole command" "no startsWith(github.event.comment.body, '/auto-review') found"
fi

# --- fake gh: any PR lookup means the step accepted the command -------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo called >> "$STUB_DIR/gh.calls"
echo '{"number":1,"title":"t","draft":false,"head_sha":"a","base_sha":"b","head_ref":"x","head_repo":"o/r","user_type":"User","labels":[]}'
STUB
chmod +x "$TMP/bin/gh"

# run_case <name> <want: accept|reject> <comment body> [assoc]
run_case() {
  local name="$1" want="$2" body="$3" assoc="${4:-OWNER}"
  rm -f "$TMP/gh.calls" "$TMP/out"; : > "$TMP/out"
  STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" GITHUB_OUTPUT="$TMP/out" \
    EVENT=issue_comment IS_PR_COMMENT=true PR_NUMBER=1 REPO=o/r GH_TOKEN=x \
    COMMENT_BODY="$body" COMMENT_ASSOC="$assoc" \
    bash -e "$TMP/pr.sh" > "$TMP/log" 2>&1
  local got=reject
  [ -e "$TMP/gh.calls" ] && got=accept
  if [ "$got" = "$want" ]; then ok "$name"
  else bad "$name" "wanted $want, got $got: $(cat "$TMP/log")"; fi
}

run_case "bare command"                         accept '/auto-review'
run_case "command with trailing text"           accept '/auto-review please, postinstall is gone now'
run_case "command then a second line"           accept $'/auto-review\nthanks!'
run_case "command with CRLF"                    accept $'/auto-review\r\n'
run_case "leading whitespace (job if: rejects it)" reject '  /auto-review'
run_case "mention mid-sentence"                 reject "please don't /auto-review this until the postinstall script is gone"
run_case "quoted reply"                         reject $'> /auto-review\n\nnot yet'
run_case "command on a later line"              reject $'looks close.\n/auto-review'
run_case "inline code"                          reject 'comment `/auto-review` when ready'
run_case "longer word"                          reject '/auto-reviewer'
run_case "non-maintainer still refused"         reject '/auto-review' CONTRIBUTOR

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

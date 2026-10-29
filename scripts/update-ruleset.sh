#!/usr/bin/env bash
# Converge a repo's merge protection on the fleet standard, or audit it.
#
# The standard, as every live fleet ruleset has it (mcp-fleet-builder
# SKILL.md, "Branch protection"): an ACTIVE ruleset on the default branch that
# blocks deletion and force-push, requires a pull request, and requires the
# `ci-gated` commit status; plus repo settings of allow auto-merge, squash-only
# merges, and delete branch on merge. Each piece fails silently when missing.
# insync-mcp#8 found a repo whose PRs had merged with CI red for its whole
# history: the create path here wrote only `deletion` + the status check,
# nothing required a pull request, and with no required check pending the
# pipeline's merge fallback squashed each PR before its armed CI run finished.
#
# Modes (dry-run unless --execute; --audit never writes):
#   scripts/update-ruleset.sh <owner/repo> [<context>] [--execute]
#       Enable auto-merge and the squash-only policy; flip the required gate
#       context (default `ci-gated`; `ci / ci` is the legacy fail-mode
#       context) keeping every other required check; append any rule type the
#       standard needs that no active default-branch ruleset carries; or
#       create the full ruleset when the repo has none with a status check.
#   scripts/update-ruleset.sh <owner/repo> [<context>] --audit
#   scripts/update-ruleset.sh --audit --all [<context>]
#       Report each gap, one line per gap; exit 1 when any repo has one.
#       --all walks every repo in fleet.json and is audit-only.
#
# Flip ruleset and stub together — requiring `ci-gated` while the stub still
# runs fail-mode blocks every merge (nothing ever posts the status), and a
# status-mode stub with a `ci / ci` ruleset leaves un-armed PRs mergeable by
# hand (the job is green). Protection split across several rulesets (one for
# deletion/force-push, one for PR + checks) is the live fleet shape and counts
# as converged; only what is missing from the UNION is added, to the ruleset
# that carries the status check.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$HERE/fleet.json"
USAGE='usage: update-ruleset.sh <owner/repo> [<context>] [--execute|--audit]  |  update-ruleset.sh --audit --all [<context>]'

EXECUTE="" AUDIT="" ALL="" POS=()
for arg in "$@"; do
  case "$arg" in
    --execute) EXECUTE=1 ;;
    --audit)   AUDIT=1 ;;
    --all)     ALL=1 ;;
    --*) echo "$USAGE" >&2; exit 2 ;;
    *) POS+=("$arg") ;;
  esac
done
if [ -n "$ALL" ]; then
  [ -n "$AUDIT" ] && [ -z "$EXECUTE" ] || { echo "--all is audit-only. $USAGE" >&2; exit 2; }
  REPOS=$(jq -r '.repos[].repo' "$FLEET")
  CONTEXT="${POS[0]:-ci-gated}"
else
  REPOS="${POS[0]:?$USAGE}"
  CONTEXT="${POS[1]:-ci-gated}"
fi

# Repo settings the pipeline depends on. Auto-merge must be ALLOWED or it
# stalls at the last step: arm-gate posts ci-gated, the review adds
# ready-to-merge, and then `gh pr merge --auto` fails with
#   GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)
# and the PR just sits there looking mergeable. `gh repo create` leaves it OFF
# and every merge method ON; the fleet squash-merges only (the PR title is the
# release decision) and deletes the branch on merge.
SETTINGS_WANT='{"allow_auto_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true}'
SETTINGS_GAPS='def settings_gaps($s; $want):
  (if $s.allow_auto_merge != $want.allow_auto_merge then "auto-merge disabled: the pipeline arms PRs that never merge" else empty end),
  (if $s.allow_squash_merge != $want.allow_squash_merge then "squash merge disabled" else empty end),
  (if $s.allow_merge_commit != $want.allow_merge_commit then "merge commits allowed (fleet is squash-only)" else empty end),
  (if $s.allow_rebase_merge != $want.allow_rebase_merge then "rebase merges allowed (fleet is squash-only)" else empty end),
  (if $s.delete_branch_on_merge != $want.delete_branch_on_merge then "merged branches are not deleted" else empty end);'

# The rules every repo needs beside the status check. Zero approvals: the
# auto-review pipeline is the reviewer, and a human approval requirement
# would hold every armed PR. Squash is the only merge method the policy
# above leaves on, so the rule says the same.
PR_RULE='{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false,"allowed_merge_methods":["squash"]}}'
STANDARD_RULES="[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE]"

# Only the GATE context is swapped. The two gate modes require `ci / ci` or
# `ci-gated`; every other required check (CodeQL, a platform build, ...) and
# its integration_id binding must survive the flip. Rewriting the list to the
# single new context silently dropped them (fleet-audit#280). An entry that
# already names the new context is kept as-is, binding included.
GATE_CONTEXTS='["ci / ci","ci-gated"]'
MIGRATE='def migrate($ctx; $gates):
  if any(.[]; .context == $ctx)
  then map(select(.context == $ctx or (.context | IN($gates[]) | not)))
  else map(select(.context | IN($gates[]) | not)) + [{context: $ctx}] end;'

# Every ACTIVE branch ruleset that applies to the default branch, rules
# included (the list endpoint omits them). Tag rulesets, disabled drafts and
# rulesets scoped to other branches protect nothing here and do not count.
default_branch_rulesets() {  # <owner/repo> -> JSON array
  local out='[]' id
  for id in $(gh api "repos/$1/rulesets" --jq '.[] | select(.target=="branch") | .id'); do
    out=$(gh api "repos/$1/rulesets/$id" | jq -c --argjson acc "$out" '
      if .enforcement == "active"
         and ((.conditions.ref_name.include // []) | index("~DEFAULT_BRANCH") != null or index("refs/heads/main") != null)
      then $acc + [.] else $acc end')
  done
  printf '%s' "$out"
}

# The repo's effective `ci` from fleet.json (`defaults` merged with its
# entry). A `ci: none` repo (nullnet-app/nullnet) has no CI stub, so nothing
# ever posts `ci-gated`; requiring the status there would block every PR, so
# the standard waives that one rule for it. A repo not in fleet.json, or no
# fleet.json beside this script, is held to the full standard.
ci_mode() {  # <owner/repo> -> standard | custom | none
  [ -f "$FLEET" ] || { echo standard; return; }
  jq -r --arg repo "$1" '
    ([.repos[] | select(.repo == $repo)][0]) as $r
    | if $r == null then "standard" else ($r.ci // .defaults.ci // "standard") end' "$FLEET"
}

# One line per gap between a repo and the standard; nothing when converged.
gaps() {  # <owner/repo> <context> <ci-mode>
  local settings rulesets
  settings=$(gh api "repos/$1")
  rulesets=$(default_branch_rulesets "$1")
  jq -rn --argjson s "$settings" --argjson rs "$rulesets" --arg ctx "$2" --arg ci "$3" --arg q "'" --argjson want "$SETTINGS_WANT" "$SETTINGS_GAPS"'
    settings_gaps($s; $want),
    ([$rs[].rules[].type] | unique) as $types
    | (if $types | index("deletion") != null then empty else "no active default-branch ruleset blocks deletion" end),
      (if $types | index("non_fast_forward") != null then empty else "no active default-branch ruleset blocks force-push" end),
      (if $types | index("pull_request") != null then empty else "no active default-branch ruleset requires a pull request" end),
      ([$rs[].rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context]) as $ctxs
      | if $ci == "none" or ($ctxs | index($ctx) != null) then empty
        else "no active default-branch ruleset requires the \($q)\($ctx)\($q) status"
             + (if ($ctxs | length) > 0 then " (requires: \($ctxs | join(", ")))" else "" end) end'
}

if [ -n "$AUDIT" ]; then
  rc=0
  for repo in $REPOS; do
    ci=$(ci_mode "$repo")
    if ! found=$(gaps "$repo" "$CONTEXT" "$ci"); then
      echo "$repo: ERROR reading settings or rulesets"; rc=1; continue
    fi
    if [ -z "$found" ] && [ "$ci" = none ]; then
      echo "$repo: ok (ci: none, no status check expected)"
    elif [ -z "$found" ]; then
      echo "$repo: ok"
    else
      rc=1; echo "$repo"; printf '%s\n' "$found" | sed 's/^/  - /'
    fi
  done
  exit $rc
fi

REPO="$REPOS"

# --- repo settings ---------------------------------------------------------
SETTINGS=$(gh api "repos/$REPO")
MISSING=$(jq -rn --argjson s "$SETTINGS" --argjson want "$SETTINGS_WANT" \
  '$want | to_entries[] | select($s[.key] != .value) | "\(.key)=\(.value)"')
if [ -z "$MISSING" ]; then
  echo "$REPO merge settings already converged (auto-merge on, squash-only, delete branch on merge)."
else
  echo "$REPO merge settings to set: $(echo "$MISSING" | tr '\n' ' ')"
  if [ -n "$EXECUTE" ]; then
    FIELDS=()
    for kv in $MISSING; do FIELDS+=(-F "$kv"); done
    gh api -X PATCH "repos/$REPO" "${FIELDS[@]}" >/dev/null
    echo "  set."
  fi
fi

# --- ruleset -----------------------------------------------------------------
RULESETS=$(default_branch_rulesets "$REPO")
# The ruleset that carries the status check is the one edited; the standard
# rules missing from the UNION of active rulesets are appended to it.
RID=$(jq -r '[.[] | select(any(.rules[]; .type=="required_status_checks"))][0].id // empty' <<<"$RULESETS")
ADD_RULES=$(jq -c --argjson have "$(jq -c '[.[].rules[].type] | unique' <<<"$RULESETS")" \
  'map(select(.type as $t | ($have | index($t)) == null))' <<<"$STANDARD_RULES")
ADD_TYPES=$(jq -r 'map(.type) | join(", ") | if . == "" then "none" else . end' <<<"$ADD_RULES")

if [ "$(ci_mode "$REPO")" = none ]; then
  # No CI stub, so no status is ever posted: never require one here. Only the
  # standard rules are converged, into the first active default-branch
  # ruleset, or a new one when there is none.
  echo "$REPO is ci: none in fleet.json — no status check required; rules to add: $ADD_TYPES"
  [ "$ADD_TYPES" != none ] || exit 0
  [ -n "$EXECUTE" ] || { echo "(dry run)"; exit 0; }
  RID=$(jq -r '.[0].id // empty' <<<"$RULESETS")
  if [ -n "$RID" ]; then
    jq -c --argjson add "$ADD_RULES" '.[0] | .rules += $add | {name, target, enforcement, bypass_actors: (.bypass_actors // []), conditions, rules}' <<<"$RULESETS" \
    | gh api -X PUT "repos/$REPO/rulesets/$RID" --input - >/dev/null
    echo "Updated."
  else
    jq -n --argjson add "$ADD_RULES" '{name: "protect-default-branch", target: "branch", enforcement: "active",
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}}, rules: $add}' \
    | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
    echo "Created."
  fi
  exit 0
fi

if [ -n "$RID" ]; then
  FULL=$(jq -c --arg id "$RID" '.[] | select((.id|tostring) == $id)' <<<"$RULESETS")
  CHECKS=$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]]' <<<"$FULL")
  AFTER=$(jq -c --arg ctx "$CONTEXT" --argjson gates "$GATE_CONTEXTS" "$MIGRATE migrate(\$ctx; \$gates)" <<<"$CHECKS")
  echo "$REPO ruleset $RID required checks:"
  echo "  before: $(jq -r 'map(.context) | join(", ") | if . == "" then "<none>" else . end' <<<"$CHECKS")"
  echo "  after:  $(jq -r 'map(.context) | join(", ")' <<<"$AFTER")"
  echo "  rules to add: $ADD_TYPES"
  # A PUT replaces the whole ruleset, so it only happens when something
  # differs, and it carries bypass_actors through — a projection without them
  # would strip every bypass on every run.
  if [ "$AFTER" = "$CHECKS" ] && [ "$ADD_TYPES" = none ]; then
    echo "  nothing to change."; exit 0
  fi
  [ -n "$EXECUTE" ] || { echo "(dry run)"; exit 0; }
  jq --arg ctx "$CONTEXT" --argjson gates "$GATE_CONTEXTS" --argjson add "$ADD_RULES" "$MIGRATE"'
    .rules = [.rules[] | if .type=="required_status_checks"
      then .parameters.required_status_checks |= migrate($ctx; $gates) else . end] + $add
    | {name, target, enforcement, bypass_actors: (.bypass_actors // []), conditions, rules}' <<<"$FULL" \
  | gh api -X PUT "repos/$REPO/rulesets/$RID" --input - >/dev/null
  echo "Updated."
else
  echo "$REPO has no active default-branch ruleset with a status check — creating one requiring '$CONTEXT' plus: $ADD_TYPES."
  [ -n "$EXECUTE" ] || { echo "(dry run)"; exit 0; }
  jq -n --arg ctx "$CONTEXT" --argjson add "$ADD_RULES" '{
    name: "ci",
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: ($add + [
      {type: "required_status_checks",
       parameters: {strict_required_status_checks_policy: false,
                    required_status_checks: [{context: $ctx}]}}])
    }' | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
  echo "Created."
fi

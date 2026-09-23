#!/usr/bin/env bash
# Set a repo's gate required-status-check context (default `ci / ci`), or
# create the ruleset if the repo has none (nullnet-app, now on Team plan).
# Only the gate context (`ci / ci` / `ci-gated`) is replaced; any other
# required check on the ruleset is kept.
#
# Status-mode gate migration: after a repo's CI stub switches to
# `gate-mode: status` (node) / `mode: status` (arm-gate), flip its required
# check to the commit-status context the gate posts:
#   scripts/update-ruleset.sh <owner/repo> ci-gated --execute
# Flip ruleset and stub together — requiring `ci-gated` while the stub still
# runs fail-mode blocks every merge (nothing ever posts the status), and a
# status-mode stub with a `ci / ci` ruleset leaves un-armed PRs mergeable by
# hand (the job is green).
#
# Usage: scripts/update-ruleset.sh <owner/repo> [<new-context>] [--execute]
set -euo pipefail

REPO="${1:?usage: update-ruleset.sh <owner/repo> [<new-context>] [--execute]}"
NEW_CONTEXT="${2:-ci / ci}"
EXECUTE="${3:-}"

# Auto-merge must be ALLOWED on the repo, or the whole pipeline stalls at the
# last step: arm-gate posts ci-gated, the review adds ready-to-merge, and then
# `gh pr merge --auto` fails with
#   GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)
# The PR just sits there looking mergeable. `gh repo create` leaves this OFF, so
# every new fleet repo needs it set once — checked here because this is already
# the "make merging work" script.
AUTO_MERGE=$(gh api "repos/$REPO" --jq '.allow_auto_merge')
if [ "$AUTO_MERGE" = "true" ]; then
  echo "$REPO already allows auto-merge."
elif [ "$EXECUTE" = "--execute" ]; then
  gh api -X PATCH "repos/$REPO" -F allow_auto_merge=true >/dev/null
  echo "$REPO: enabled allow_auto_merge."
else
  echo "$REPO does NOT allow auto-merge — the pipeline will arm PRs that never merge. Re-run with --execute to enable. (dry run)"
fi

# The list endpoint omits rules; find the branch ruleset that actually
# carries a required_status_checks rule (repos also have a separate
# force-push/deletion ruleset).
RID=""
for id in $(gh api "repos/$REPO/rulesets" --jq '.[] | select(.target=="branch") | .id'); do
  if gh api "repos/$REPO/rulesets/$id" \
       --jq '[.rules[] | select(.type=="required_status_checks")] | length' \
     | grep -qx '[1-9][0-9]*'; then
    RID="$id"
    break
  fi
done

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

if [ -n "$RID" ]; then
  FULL=$(gh api "repos/$REPO/rulesets/$RID")
  CHECKS=$(echo "$FULL" | jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[]]')
  AFTER=$(echo "$CHECKS" | jq -c --arg ctx "$NEW_CONTEXT" --argjson gates "$GATE_CONTEXTS" "$MIGRATE migrate(\$ctx; \$gates)")
  echo "$REPO ruleset $RID required checks:"
  echo "  before: $(echo "$CHECKS" | jq -r 'map(.context) | join(", ") | if . == "" then "<none>" else . end')"
  echo "  after:  $(echo "$AFTER" | jq -r 'map(.context) | join(", ")')"
  [ "$EXECUTE" = "--execute" ] || { echo "(dry run)"; exit 0; }
  echo "$FULL" | jq --arg ctx "$NEW_CONTEXT" --argjson gates "$GATE_CONTEXTS" "$MIGRATE"'
    .rules = [.rules[] | if .type=="required_status_checks"
      then .parameters.required_status_checks |= migrate($ctx; $gates) else . end]
    | {name, target, enforcement, conditions, rules}' \
  | gh api -X PUT "repos/$REPO/rulesets/$RID" --input - >/dev/null
  echo "Updated."
else
  echo "$REPO has no branch ruleset — creating one requiring '$NEW_CONTEXT' on the default branch."
  [ "$EXECUTE" = "--execute" ] || { echo "(dry run)"; exit 0; }
  jq -n --arg ctx "$NEW_CONTEXT" '{
    name: "ci",
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"},
      {type: "required_status_checks",
       parameters: {strict_required_status_checks_policy: false,
                    required_status_checks: [{context: $ctx}]}}
    ]}' | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
  echo "Created."
fi


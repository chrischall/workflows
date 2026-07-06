#!/usr/bin/env bash
# Set a repo's required-status-check context (default `ci / ci`), or create
# the ruleset if the repo has none (nullnet-app, now on Team plan).
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

if [ -n "$RID" ]; then
  CURRENT=$(gh api "repos/$REPO/rulesets/$RID" --jq \
    '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | join(",")')
  echo "$REPO ruleset $RID currently requires: ${CURRENT:-<none>} -> $NEW_CONTEXT"
  [ "$EXECUTE" = "--execute" ] || { echo "(dry run)"; exit 0; }
  FULL=$(gh api "repos/$REPO/rulesets/$RID")
  echo "$FULL" | jq --arg ctx "$NEW_CONTEXT" '
    .rules = [.rules[] | if .type=="required_status_checks"
      then .parameters.required_status_checks = [{context: $ctx}] else . end]
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

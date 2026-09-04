#!/usr/bin/env bash
# Unit tests for .github/actions/mcp-publish/action.yml's
# `Resolve skill path` step.
#
# Extracted from the shipped YAML at run time (same technique as
# arm.test.sh / verdict.test.sh / npm-index.test.sh).
#
# Why this exists: this step decides what gets packaged as a .skill, attached
# to the release, and published to ClawHub. When it under-counts, nothing
# fails — the release is green and the skills are simply absent, which is the
# hardest kind of bug to notice. gogcli-mcp shipped nine per-package SKILL.md
# files and published exactly one for months: the resolver knew a root
# SKILL.md and a plugin-shaped skills/*/ tree, and nothing else, so a workspace
# monorepo's packages/*/SKILL.md were invisible to it.
#
# The precedence rules are what these lock down. A repo that resolves skills
# today must resolve exactly the same ones tomorrow — changing an existing
# repo's slug silently orphans its ClawHub listing and renames its release
# artifact.
#
# Usage: bash scripts/skill-resolve.test.sh
set -uo pipefail   # no -e: assertions need to observe failures

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="$HERE/.github/actions/mcp-publish/action.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STEP_NAME="Resolve skill path"
ruby -ryaml -e '
  a = YAML.load_file(ARGV[0])
  step = (a["runs"]["steps"] || []).find { |s| s["name"] == ARGV[2] }
  abort("could not find `#{ARGV[2]}` step") unless step
  File.write(ARGV[1], step["run"])
' "$ACTION" "$TMP/resolve.sh" "$STEP_NAME" \
  || { echo "FAIL: could not extract step from $ACTION"; exit 1; }

# Runs the step against a fresh fixture repo. $LAYOUT is a space-separated list
# of SKILL.md paths to create; $IN_SKILL_PATH is the action's explicit override.
run_step() { # sets STEP_RC, RESOLVED (the "path<TAB>slug" manifest) and OUT
  rm -rf "$TMP/repo" "$TMP/env" "$TMP/runner"; mkdir -p "$TMP/repo" "$TMP/runner"; : > "$TMP/env"
  for f in $LAYOUT; do mkdir -p "$TMP/repo/$(dirname "$f")"; printf -- '---\nname: x\n---\n' > "$TMP/repo/$f"; done
  ( cd "$TMP/repo" \
    && MCP_PUBLISH_NAME=my-repo IN_SKILL_PATH="${IN_SKILL_PATH:-}" \
       RUNNER_TEMP="$TMP/runner" GITHUB_ENV="$TMP/env" \
       bash -e "$TMP/resolve.sh" ) > "$TMP/out" 2>&1
  STEP_RC=$?
  OUT="$(cat "$TMP/out")"
  RESOLVED="$(cat "$TMP/runner/skills.tsv" 2>/dev/null || true)"
  COUNT="$(grep -c . <<<"${RESOLVED:-}" 2>/dev/null || echo 0)"
  [ -z "$RESOLVED" ] && COUNT=0
}
reset() { unset IN_SKILL_PATH; LAYOUT=""; }

# --- Existing behaviour. These must not move: a changed slug orphans a live
# --- ClawHub listing and renames the release artifact.

reset; LAYOUT="SKILL.md"; run_step
[ "$COUNT" = "1" ] && grep -q "^SKILL.md	my-repo$" <<<"$RESOLVED" \
  && ok "a root SKILL.md resolves to one skill under the repo slug" \
  || bad "a root SKILL.md resolves to one skill under the repo slug" "$RESOLVED"

reset; LAYOUT="skills/alpha/SKILL.md"; run_step
[ "$COUNT" = "1" ] && grep -q "	my-repo$" <<<"$RESOLVED" \
  && ok "a lone skills/*/ skill keeps the repo slug" \
  || bad "a lone skills/*/ skill keeps the repo slug" "$RESOLVED"

reset; LAYOUT="skills/alpha/SKILL.md skills/bravo/SKILL.md"; run_step
[ "$COUNT" = "2" ] && grep -q "	alpha$" <<<"$RESOLVED" && grep -q "	bravo$" <<<"$RESOLVED" \
  && ok "several skills/*/ skills each get their directory slug" \
  || bad "several skills/*/ skills each get their directory slug" "$RESOLVED"

reset; LAYOUT="SKILL.md skills/alpha/SKILL.md"; IN_SKILL_PATH="skills/alpha/SKILL.md"; run_step
[ "$COUNT" = "1" ] && grep -q "^skills/alpha/SKILL.md	my-repo$" <<<"$RESOLVED" \
  && ok "an explicit skill-path wins and stays single" \
  || bad "an explicit skill-path wins and stays single" "$RESOLVED"

reset; LAYOUT=""; IN_SKILL_PATH="nope/SKILL.md"; run_step
[ "$STEP_RC" -ne 0 ] \
  && ok "a skill-path that does not exist fails loudly" \
  || bad "a skill-path that does not exist fails loudly" "rc=$STEP_RC $OUT"

reset; LAYOUT=""; run_step
[ "$COUNT" = "0" ] && [ "$STEP_RC" -eq 0 ] \
  && ok "a repo with no skill resolves zero without failing" \
  || bad "a repo with no skill resolves zero without failing" "rc=$STEP_RC count=$COUNT"

# --- The bug: a workspace monorepo's per-package skills.

reset; LAYOUT="packages/a-mcp/SKILL.md packages/b-mcp/SKILL.md packages/c-mcp/SKILL.md"; run_step
[ "$COUNT" = "3" ] \
  && ok "a monorepo's packages/*/ skills are all resolved" \
  || bad "a monorepo's packages/*/ skills are all resolved" "count=$COUNT $RESOLVED"
grep -q "	a-mcp$" <<<"$RESOLVED" && grep -q "	b-mcp$" <<<"$RESOLVED" && grep -q "	c-mcp$" <<<"$RESOLVED" \
  && ok "each package skill gets its package-directory slug" \
  || bad "each package skill gets its package-directory slug" "$RESOLVED"

reset; LAYOUT="packages/only-mcp/SKILL.md"; run_step
[ "$COUNT" = "1" ] && grep -q "	my-repo$" <<<"$RESOLVED" \
  && ok "a lone packages/*/ skill keeps the repo slug, as skills/*/ does" \
  || bad "a lone packages/*/ skill keeps the repo slug, as skills/*/ does" "$RESOLVED"

# --- Precedence. Adding a layout must not change what any existing repo
# --- already resolves, which is what keeps this change zero-blast-radius.

reset; LAYOUT="SKILL.md packages/a-mcp/SKILL.md packages/b-mcp/SKILL.md"; run_step
[ "$COUNT" = "1" ] && grep -q "^SKILL.md	my-repo$" <<<"$RESOLVED" \
  && ok "a root SKILL.md still wins over packages/*/" \
  || bad "a root SKILL.md still wins over packages/*/" "$RESOLVED"

reset; LAYOUT="skills/alpha/SKILL.md skills/bravo/SKILL.md packages/a-mcp/SKILL.md"; run_step
[ "$COUNT" = "2" ] && ! grep -q "packages/" <<<"$RESOLVED" \
  && ok "a skills/*/ tree still wins over packages/*/" \
  || bad "a skills/*/ tree still wins over packages/*/" "$RESOLVED"

# --- Nested workspaces must not be swept in: packages/*/node_modules/<dep>/
# --- can contain a dependency's own SKILL.md, and publishing someone else's
# --- skill under our slug would be worse than publishing none.
reset; LAYOUT="packages/a-mcp/SKILL.md packages/a-mcp/node_modules/dep/SKILL.md"; run_step
! grep -q "node_modules" <<<"$RESOLVED" \
  && ok "a dependency's SKILL.md under node_modules is never resolved" \
  || bad "a dependency's SKILL.md under node_modules is never resolved" "$RESOLVED"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

# Fleet Reusable Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate the fleet's PR auto-review, auto-merge, CI, and MCP release pipelines into `chrischall/workflows` (reusable workflows + composite actions), then convert all 39 repos to thin stubs.

**Architecture:** Reusable workflows (`workflow_call`) for review/auto-merge/CI (job-level guards consolidate); a composite action for the MCP publish steps because npm trusted publishing and mcp-publisher OIDC bind to the caller repo's workflow identity — a reusable workflow would change `job_workflow_ref` and break publish auth. Consumers reference `@main`. Per-repo data (PAT secret name, node version, test command, conventions hint) lives in `fleet.json`; `scripts/rollout.sh` generates stub-conversion PRs and `scripts/update-ruleset.sh` flips the required-check context.

**Tech Stack:** GitHub Actions (reusable workflows, composite actions), `gh` CLI, `jq`, `actionlint`, bash.

**Spec deviation (approved rationale, update spec in Task 12):** `reusable-mcp-release.yml` from the spec becomes the `mcp-publish` composite action + a per-repo `release-please.yml` stub, for the OIDC reason above. Consolidation value is identical; the stub is ~45 lines.

**Working directory:** `/Users/chris/git/workflows` (local repo already initialized, spec committed).

**Verification command used throughout:** `actionlint` validates workflow YAML and shellchecks `run:` blocks. There is no unit-test harness for YAML; actionlint + the zola-mcp canary (Task 9) are the test suite. Composite action files (`action.yml`) are NOT covered by actionlint — validate them with the canary.

**Hard rules:**
- NEVER run `gh pr merge` and NEVER add the `ready-to-merge` label to any PR. The pipeline being built does the merging. Release PRs additionally gate on the owner adding `release-ready` — never add that either.
- All fleet source files referenced below were fetched to `/tmp/wf-audit/` during the audit. If that directory is gone, re-fetch with:
  `gh api repos/<owner>/<repo>/contents/.github/workflows/<file> --jq .content | base64 -d`

---

### Task 1: Publish the repo skeleton

**Files:**
- Create: `README.md`, `.gitignore`

- [ ] **Step 1: Create the public GitHub repo and push** (owner approved public creation at implement-time)

```bash
cd /Users/chris/git/workflows
gh repo create chrischall/workflows --public \
  --description "Reusable GitHub Actions workflows for the fleet: auto-review, auto-merge, CI, release" \
  --source . --push
```

Expected: repo created, `main` pushed with the spec commit.

- [ ] **Step 2: Write `README.md`**

```markdown
# workflows

Reusable GitHub Actions workflows and composite actions for the fleet
(33 chrischall repos + 6 nullnet-app repos). Consumers reference `@main`.

| Component | Kind | Consumers |
|---|---|---|
| `.github/workflows/reusable-pr-auto-review.yml` | reusable workflow | all |
| `.github/workflows/reusable-auto-merge.yml` | reusable workflow | all |
| `.github/workflows/reusable-mcp-ci.yml` | reusable workflow | node repos |
| `.github/actions/mcp-publish` | composite action | MCP publishers |
| `.github/actions/install-mcp-publisher` | composite action | via mcp-publish |

The pipeline contract: non-release PR → auto-review emits a mandatory
`pass|warn|fail` verdict → `pass` adds `ready-to-merge` → label arms native
auto-merge and fires deferred CI (the required check) → merge on green.
`warn`/`fail` keep a human in the loop. Release-please PRs gate on
`release-ready` instead.

`mcp-publish` is a composite action (not a reusable workflow) on purpose:
npm trusted publishing and mcp-publisher validate the OIDC token's workflow
identity, which must remain the consuming repo's own `release-please.yml`.

Rollout tooling: `fleet.json` (per-repo parameters), `scripts/rollout.sh`
(stub-conversion PRs), `scripts/update-ruleset.sh` (required-check rename).
Design: `docs/superpowers/specs/2026-06-12-fleet-reusable-workflows-design.md`.
```

- [ ] **Step 3: Write `.gitignore`**

```
.DS_Store
```

- [ ] **Step 4: Install actionlint if missing, commit**

```bash
which actionlint || brew install actionlint
git add README.md .gitignore
git commit -m "docs: README and gitignore"
git push
```

---

### Task 2: `reusable-pr-auto-review.yml`

**Files:**
- Create: `.github/workflows/reusable-pr-auto-review.yml`

Canonical sources: `/tmp/wf-audit/chrischall__zola-mcp/pr-auto-review.yml` (fleet canonical) + the enhanced verdict/arm steps from curtaincall PR #128 (commit `bf9e298`). Changes: `workflow_call` trigger with `conventions_hint` input and `claude_code_oauth_token`/`release_pat` secrets; verdict step is the single source of truth for arming.

- [ ] **Step 1: Write the file**

```yaml
name: Reusable PR auto-review

# Fleet-canonical PR review. Call from a stub on `pull_request`
# (types: [opened, reopened, ready_for_review, synchronize, labeled]).
# The stub owns workflow-level concurrency (a called workflow cannot).
#
# Contract:
#  1. Applies the `auto-review` label; requests Copilot (best-effort).
#  2. Runs claude-code-action with a JSON-schema-bound verdict
#     pass | warn | fail.
#  3. ALWAYS surfaces the verdict as a marker-tagged PR comment and a step
#     output; FAILS the job if no verdict can be determined.
#  4. On `pass`, adds `ready-to-merge` via the caller's PAT (GITHUB_TOKEN
#     would not fire the auto-merge workflow). warn/fail never auto-arm.
#
# Why `pull_request` (not `pull_request_target`): Anthropic's OIDC backend
# rejects `pull_request_target` (anthropics/claude-code-action#713). Fork
# PRs therefore can't be auto-reviewed; `@claude review this` via claude.yml
# is the manual fallback.
#
# Bot PRs (dependabot etc.) skip review entirely (user.type filter) and go
# straight to CI + auto-merge. PRs already labeled `ready-to-merge` skip
# re-review. Release-please PRs review only once `release-ready` is added.

on:
  workflow_call:
    inputs:
      conventions_hint:
        description: >-
          Repo-specific conventions appended to the review prompt
          (e.g. "TDD project; Envers auditing rules apply").
        type: string
        required: false
        default: ""
    secrets:
      claude_code_oauth_token:
        description: OAuth token from `claude setup-token` (Max plan quota)
        required: true
      release_pat:
        description: PAT used to add ready-to-merge so auto-merge fires
        required: true

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write       # Claude App OIDC token exchange
    if: |
      github.event.pull_request.draft == false &&
      github.event.pull_request.user.type == 'User' &&
      github.event.pull_request.head.repo.full_name == github.repository &&
      (!startsWith(github.event.pull_request.head.ref, 'release-please--') || contains(github.event.pull_request.labels.*.name, 'release-ready')) &&
      (!contains(github.event.pull_request.labels.*.name, 'autorelease: pending') || contains(github.event.pull_request.labels.*.name, 'release-ready')) &&
      !contains(github.event.pull_request.labels.*.name, 'ready-to-merge') &&
      (github.event.action != 'labeled' || github.event.label.name == 'review-with-opus' || github.event.label.name == 'release-ready')
    steps:
      - name: Apply auto-review label
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
        run: gh pr edit "$PR" --repo "$REPO" --add-label auto-review

      - name: Request Copilot reviewer
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
        run: |
          # 422 if Copilot review isn't enabled for the repo — swallow it.
          if gh api --method POST \
              "/repos/${REPO}/pulls/${PR}/requested_reviewers" \
              -f 'reviewers[]=Copilot' 2>/tmp/copilot.err; then
            echo "Requested Copilot as reviewer."
          else
            echo "Could not request Copilot reviewer (likely not enabled):"
            cat /tmp/copilot.err
          fi

      - name: Checkout PR
        uses: actions/checkout@v6
        with:
          fetch-depth: 1

      - name: Pick model by PR size (or label override)
        id: model
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
          HAS_OPUS_LABEL: ${{ contains(github.event.pull_request.labels.*.name, 'review-with-opus') }}
        run: |
          # Three-tier ladder by additions+deletions; `review-with-opus`
          # label forces Opus. Never the [1m] context variant.
          CHANGED=$(gh api "/repos/${REPO}/pulls/${PR}" --jq '.additions + .deletions')
          if [ "$HAS_OPUS_LABEL" = "true" ]; then
            MODEL="claude-opus-4-7"
            REASON="\`review-with-opus\` label (forced)"
          elif [ "$CHANGED" -le 50 ]; then
            MODEL="claude-haiku-4-5"
            REASON="${CHANGED} lines (≤50, trivial)"
          elif [ "$CHANGED" -le 500 ]; then
            MODEL="claude-sonnet-4-6"
            REASON="${CHANGED} lines (51-500)"
          else
            MODEL="claude-opus-4-7"
            REASON="${CHANGED} lines (>500, complex)"
          fi
          echo "model=$MODEL" >> "$GITHUB_OUTPUT"
          echo "Selected ${MODEL} — ${REASON}"
          echo "**Model:** \`${MODEL}\` — ${REASON}" >> "$GITHUB_STEP_SUMMARY"

      - name: Claude review with structured verdict
        id: review
        uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.claude_code_oauth_token }}
          # No `github_token:` — the installed Claude App authors comments
          # as claude[bot] via OIDC.
          # track_progress hard-errors on `labeled` events (the action only
          # supports it for opened/synchronize/ready_for_review/reopened).
          track_progress: ${{ github.event.action != 'labeled' }}
          claude_args: |
            --model ${{ steps.model.outputs.model }}
            --json-schema '{"type":"object","required":["verdict","summary","important_findings"],"properties":{"verdict":{"enum":["pass","warn","fail"]},"summary":{"type":"string"},"important_findings":{"type":"array","items":{"type":"string"}}}}'
            --allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(cat:*),Bash(rg:*),Bash(jq:*),Bash(ls:*),Bash(find:*)"
          prompt: |
            You are reviewing pull request #${{ github.event.pull_request.number }} in ${{ github.repository }}.

            STEPS:
            1. Read CLAUDE.md (and README.md if CLAUDE.md is absent) to learn the project's conventions.
            2. Read the PR diff: `gh pr diff ${{ github.event.pull_request.number }}` (or read files in the working tree, which is checked out).
            3. Review the changes for:
               - Correctness and edge cases
               - Adherence to documented conventions
               - Test coverage of new code paths
               - Security or data-integrity concerns

            REPO-SPECIFIC NOTES:
            ${{ inputs.conventions_hint }}

            CONVENTIONS ARE GROUNDED, NOT INVENTED:
            A "convention" exists only if it is (a) written in CLAUDE.md/README.md, (b) enforced by a repo config (linter/formatter/compiler config), or (c) consistently followed by the surrounding code. Before citing a documented rule you MUST be able to quote its exact text. Never infer an unwritten style rule.

            SEVERITY MODEL (matches the official code-review plugin):
              🔴 Important — bug, broken behavior, security/data risk, or violation of a convention you can QUOTE from the docs. Confidence ≥80 to count.
              🟡 Nit       — a concrete, actionable minor issue grounded in the docs, a linter/formatter config, or a clear inconsistency with adjacent code. Confidence ≥80.
              🟣 Pre-existing — issue already in the codebase, not introduced by this PR. Never blocking.

            OUT OF SCOPE — never a finding, never affects the verdict:
              - Formatting taste a formatter would own: comment length, single- vs multi-line comments, blank lines, line breaks, import order not enforced by a config.
              - Rephrasing comments/identifiers that are already clear.
              - Anything you cannot ground in the docs, a repo config, or adjacent-code style.
            If your only findings are out-of-scope, the verdict is `pass`.

            OUTPUT:
            - For line-specific findings, prefer the inline-comment tool (`mcp__github_inline_comment__create_inline_comment`).
            - Post ONE top-level summary comment with overall judgment (use `gh pr comment`). If there are no findings worth surfacing, post a short "No issues found" comment.
            - ALWAYS end that summary comment with a final line `**Verdict:** pass` / `**Verdict:** warn` / `**Verdict:** fail` — every review, findings or not.
            - Then emit your structured verdict per the JSON schema:
              • `pass` — no 🔴 Important findings.
              • `warn` — no 🔴 Important findings but at least one 🟡 Nit worth surfacing.
              • `fail` — at least one 🔴 Important finding.
              Set `summary` to a 1-2 sentence overall judgment.
              Set `important_findings` to the list of 🔴 Important finding titles (empty array if none).

            DO NOT modify files, push commits, approve the PR formally, or call `gh pr review` / `gh pr edit`. Posting comments and emitting the verdict is the entire job. The workflow will gate auto-merge based on your verdict.

      - name: Surface verdict in run summary
        if: always() && steps.review.outputs.structured_output != ''
        env:
          OUT: ${{ steps.review.outputs.structured_output }}
        run: |
          {
            echo "## Claude review verdict"
            echo ""
            echo "**Verdict:** \`$(echo "$OUT" | jq -r .verdict)\`"
            echo ""
            echo "**Summary:** $(echo "$OUT" | jq -r .summary)"
            echo ""
            COUNT=$(echo "$OUT" | jq -r '.important_findings | length')
            echo "**Important findings:** ${COUNT}"
            if [ "$COUNT" -gt 0 ]; then
              echo ""
              echo "$OUT" | jq -r '.important_findings[] | "- " + .'
            fi
          } >> "$GITHUB_STEP_SUMMARY"

      # Deterministic verdict surfacing: one marker-tagged PR comment, verdict
      # recovered from the review comment when structured_output is empty
      # (known intermittent action bug), loud failure when no verdict exists.
      # Single source of truth: exports `verdict` consumed by the arm step.
      - name: Post verdict to PR
        id: verdict
        if: ${{ !cancelled() }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
          OUT: ${{ steps.review.outputs.structured_output }}
        run: |
          verdict=""; summary=""
          if [ -n "$OUT" ]; then
            verdict=$(echo "$OUT" | jq -r '.verdict // empty')
            summary=$(echo "$OUT" | jq -r '.summary // empty')
          fi
          if [ -z "$verdict" ]; then
            body=$(gh pr view "$PR" --repo "$REPO" --json comments --jq '[.comments[]|select(.author.login=="claude")]|last|.body' 2>/dev/null || echo "")
            vline=$(printf '%s' "$body" | grep -ioE 'verdict[^a-z]{0,6}(pass|warn|fail)' | tail -1 || true)
            case "$vline" in
              *[Pp]ass*) verdict="pass";;
              *[Ww]arn*) verdict="warn";;
              *[Ff]ail*) verdict="fail";;
            esac
            [ -n "$verdict" ] && summary="(verdict recovered from the review comment — structured output was empty)"
          fi

          # Export before any later command can fail: an empty value reads as
          # "no verdict" downstream, which fails safe (never arms).
          echo "verdict=$verdict" >> "$GITHUB_OUTPUT"

          MARKER="<!-- auto-review-verdict -->"
          if [ -n "$verdict" ]; then
            case "$verdict" in pass) ICON="✅";; warn) ICON="🟡";; fail) ICON="🔴";; esac
            NEW_BODY="$MARKER
          $ICON Auto-review verdict: **$verdict**${summary:+ — $summary}"
          else
            NEW_BODY="$MARKER
          ⚠️ Auto-review issued **no verdict** — structured output was empty and no verdict line was found in the review comment. Treat this PR as un-reviewed."
          fi

          # One comment per PR, updated in place on re-reviews (marker-matched).
          # Marker is inlined in the jq program: gh --jq has no --arg support.
          # head -n1 because --paginate runs the jq filter per page.
          EXISTING=$(gh api "repos/$REPO/issues/$PR/comments" --paginate \
            --jq '[.[] | select(.body | startswith("<!-- auto-review-verdict -->"))][0].id // empty' \
            | grep . | head -n1 || true)
          if [ -n "$EXISTING" ]; then
            gh api -X PATCH "repos/$REPO/issues/comments/$EXISTING" -f body="$NEW_BODY" >/dev/null
          else
            gh api -X POST "repos/$REPO/issues/$PR/comments" -f body="$NEW_BODY" >/dev/null
          fi

          if [ -z "$verdict" ]; then
            echo "::error::auto-review completed without emitting a verdict"
            exit 1
          fi

      - name: Arm auto-merge on pass
        # `ready-to-merge` MUST be added with the PAT: GitHub suppresses
        # workflow runs for GITHUB_TOKEN-triggered events, so a label added
        # that way would not fire the auto-merge workflow.
        if: ${{ !cancelled() && github.event.pull_request.head.repo.full_name == github.repository }}
        env:
          GH_TOKEN: ${{ secrets.release_pat }}
          PR: ${{ github.event.pull_request.number }}
          REPO: ${{ github.repository }}
          # Empty if the verdict step failed before exporting — never arms.
          VERDICT: ${{ steps.verdict.outputs.verdict }}
        run: |
          if [ "$VERDICT" = "pass" ]; then
            gh pr edit "$PR" --repo "$REPO" --add-label ready-to-merge
            echo "Verdict=pass — added ready-to-merge to arm auto-merge."
          else
            echo "Verdict=${VERDICT:-unknown} — not arming (human-in-the-loop preserved)."
          fi
```

- [ ] **Step 2: Validate**

Run: `actionlint .github/workflows/reusable-pr-auto-review.yml`
Expected: no output (pass). If it flags the `secrets.claude_code_oauth_token` names, they are lowercase by design (workflow_call secret identifiers).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-pr-auto-review.yml
git commit -m "feat: reusable PR auto-review workflow"
```

---

### Task 3: `reusable-auto-merge.yml`

**Files:**
- Create: `.github/workflows/reusable-auto-merge.yml`

Source: `/tmp/wf-audit/chrischall__mcp-utils/auto-merge.yml` (canonical), parameterized on the PAT secret.

- [ ] **Step 1: Write the file**

```yaml
name: Reusable auto-merge

# Source-aware auto-merge. Call from a stub on `pull_request_target`
# (types: [opened, reopened, ready_for_review, synchronize, labeled]).
#
#  - dependabot[bot] PRs: arm `--auto --squash` as soon as non-draft.
#  - Same-repo PRs with `ready-to-merge`: arm on the labeled event. The label
#    comes from the review workflow (verdict=pass), release tooling, or the
#    owner overriding a warn/fail.
#  - Fork PRs: never auto-armed.
#
# The merge waits on branch protection's required status check, so this is
# "merge when CI is green", not "merge without CI". Repos without a required
# check would merge immediately — the rollout creates rulesets first.
#
# pull_request_target (in the stub) because dependabot's pull_request token
# is restricted. Safe: PR code is never checked out or executed here.
#
# The PAT (not GITHUB_TOKEN) arms the merge so the eventual push to main
# fires `push` workflows (release-please).

on:
  workflow_call:
    secrets:
      release_pat:
        description: PAT that arms `gh pr merge --auto`
        required: true

jobs:
  arm-dependabot:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    # Lifecycle events only — `labeled` is the owner-PR path.
    if: |
      github.event.action != 'labeled' &&
      github.event.pull_request.draft == false &&
      github.event.pull_request.user.login == 'dependabot[bot]'
    steps:
      - name: Arm auto-merge for dependabot
        env:
          GH_TOKEN: ${{ secrets.release_pat }}
          PR_URL: ${{ github.event.pull_request.html_url }}
        run: |
          if gh pr merge --auto --squash "$PR_URL"; then exit 0; fi
          state="$(gh pr view "$PR_URL" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
          if [ "$state" = "MERGED" ]; then
            echo "PR already merged (instant-merge race) — treating as success."
            exit 0
          fi
          echo "::error::auto-merge arm failed (PR state=$state)"
          exit 1

  arm-on-ready-label:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    # Same-repo PRs only (excludes forks).
    if: |
      github.event.action == 'labeled' &&
      github.event.label.name == 'ready-to-merge' &&
      github.event.pull_request.draft == false &&
      github.event.pull_request.head.repo.full_name == github.repository
    steps:
      - name: Arm auto-merge on ready-to-merge label
        env:
          GH_TOKEN: ${{ secrets.release_pat }}
          PR_URL: ${{ github.event.pull_request.html_url }}
        run: |
          if gh pr merge --auto --squash "$PR_URL"; then exit 0; fi
          state="$(gh pr view "$PR_URL" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
          if [ "$state" = "MERGED" ]; then
            echo "PR already merged (instant-merge race) — treating as success."
            exit 0
          fi
          echo "::error::auto-merge arm failed (PR state=$state)"
          exit 1
```

- [ ] **Step 2: Validate**

Run: `actionlint .github/workflows/reusable-auto-merge.yml`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-auto-merge.yml
git commit -m "feat: reusable auto-merge workflow"
```

---

### Task 4: `reusable-mcp-ci.yml`

**Files:**
- Create: `.github/workflows/reusable-mcp-ci.yml`

Source: `/tmp/wf-audit/chrischall__zola-mcp/ci.yml`, parameterized on node version and build/test commands.

- [ ] **Step 1: Write the file**

```yaml
name: Reusable node CI

# Standard node CI for the fleet. Call from a stub on `pull_request`
# (types: [opened, synchronize, reopened, labeled]) and optionally
# `push: branches: [main]`.
#
# CI is the LAST gate, not a parallel cost:
#   - human PRs: CI runs only once auto-review passes and arms
#     `ready-to-merge` (the labeled event fires the deferred run; later
#     pushes re-run via synchronize while the label is present).
#   - release-please PRs: deferred to the `release-ready` ship signal.
#   - BOT PRs (dependabot): CI on EVERY event, unconditionally — bots never
#     receive auto-review, and native auto-merge treats a skipped required
#     check as satisfied, so gating them on a label would merge them with
#     CI skipped.
#   - non-pull_request events (push) fall through and always run.

on:
  workflow_call:
    inputs:
      node-version:
        type: string
        required: false
        default: "26"
      build-command:
        type: string
        required: false
        default: npm run build
      test-command:
        type: string
        required: false
        default: npm test

jobs:
  ci:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    if: |
      github.event_name != 'pull_request' ||
      github.event.pull_request.user.type != 'User' ||
      (
        (github.event.action != 'labeled' || github.event.label.name == 'release-ready' || github.event.label.name == 'ready-to-merge') &&
        (
          (startsWith(github.event.pull_request.head.ref, 'release-please--') && contains(github.event.pull_request.labels.*.name, 'release-ready')) ||
          (!startsWith(github.event.pull_request.head.ref, 'release-please--') && contains(github.event.pull_request.labels.*.name, 'ready-to-merge'))
        )
      )
    steps:
      - uses: actions/checkout@v6

      - uses: actions/setup-node@v6
        with:
          node-version: ${{ inputs.node-version }}
          cache: npm

      - run: npm ci
      - run: ${{ inputs.build-command }}
      - run: ${{ inputs.test-command }}
```

- [ ] **Step 2: Validate**

Run: `actionlint .github/workflows/reusable-mcp-ci.yml`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-mcp-ci.yml
git commit -m "feat: reusable node CI workflow with deferred gate"
```

---

### Task 5: Migrate `install-mcp-publisher`; add `mcp-publish` composite action

**Files:**
- Create: `.github/actions/install-mcp-publisher/action.yml` (+ README.md if upstream has one)
- Create: `.github/actions/mcp-publish/action.yml`

- [ ] **Step 1: Copy install-mcp-publisher verbatim from mcp-utils**

```bash
mkdir -p .github/actions/install-mcp-publisher
for f in $(gh api repos/chrischall/mcp-utils/contents/.github/actions/install-mcp-publisher --jq '.[].name'); do
  gh api "repos/chrischall/mcp-utils/contents/.github/actions/install-mcp-publisher/$f" \
    --jq .content | base64 -d > ".github/actions/install-mcp-publisher/$f"
done
ls .github/actions/install-mcp-publisher/
```

Expected: at least `action.yml` (plus `README.md`). Do not edit the contents.

- [ ] **Step 2: Write `.github/actions/mcp-publish/action.yml`**

The publish steps from the canonical `release-please.yml` (`/tmp/wf-audit/chrischall__zola-mcp/release-please.yml` lines 67–158), parameterized. This is a composite action — NOT a reusable workflow — so the caller's OIDC identity (`job_workflow_ref` = the repo's own release-please.yml) is preserved for npm trusted publishing and mcp-publisher.

```yaml
name: MCP publish
description: >-
  Publish a released MCP server: npm (trusted publishing/provenance),
  .skill + .mcpb artifacts, MCP Registry, ClawHub. Run inside the repo's
  own release-please.yml publish job AFTER checking out the release tag.
  The job needs `contents: write` and `id-token: write`.

inputs:
  version:
    description: Release version (from release-please outputs)
    required: true
  tag-name:
    description: Release tag (from release-please outputs)
    required: true
  package-name:
    description: Artifact/skill base name; defaults to the repository name
    required: false
    default: ""
  node-version:
    description: Node version for the publish toolchain
    required: false
    default: "26"
  publish-npm:
    required: false
    default: "true"
  publish-skill:
    required: false
    default: "true"
  publish-mcpb:
    required: false
    default: "true"
  publish-registry:
    required: false
    default: "true"
  publish-clawhub:
    required: false
    default: "true"
  clawhub-token:
    description: ClawHub token; skipped when empty
    required: false
    default: ""
  github-token:
    description: Token for `gh release upload`
    required: true

runs:
  using: composite
  steps:
    - uses: actions/setup-node@v6
      with:
        node-version: ${{ inputs.node-version }}
        cache: npm
        registry-url: https://registry.npmjs.org

    # Strip always-auth from .npmrc (set by setup-node, deprecated in npm 11)
    - shell: bash
      run: sed -i '/always-auth/d' "$NPM_CONFIG_USERCONFIG"

    - shell: bash
      run: npm ci
    - shell: bash
      run: npm run build

    - name: Resolve names
      shell: bash
      env:
        IN_NAME: ${{ inputs.package-name }}
        VERSION: ${{ inputs.version }}
      run: |
        NAME="${IN_NAME:-${GITHUB_REPOSITORY##*/}}"
        echo "MCP_PUBLISH_NAME=$NAME" >> "$GITHUB_ENV"
        echo "VERSION=$VERSION" >> "$GITHUB_ENV"

    - name: Package skill
      if: inputs.publish-skill == 'true'
      shell: bash
      run: |
        python3 - <<'EOF'
        import zipfile, pathlib, os

        version = os.environ["VERSION"]
        skill_name = os.environ["MCP_PUBLISH_NAME"]
        out = pathlib.Path(f"{skill_name}-{version}.skill")

        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(pathlib.Path("SKILL.md"), f"{skill_name}/SKILL.md")

        print(f"Packaged {out} ({out.stat().st_size} bytes)")
        EOF

    - name: Build .mcpb bundle
      if: inputs.publish-mcpb == 'true'
      shell: bash
      run: |
        npx @anthropic-ai/mcpb pack
        mv "${MCP_PUBLISH_NAME}.mcpb" "${MCP_PUBLISH_NAME}-${VERSION}.mcpb"

    # Idempotent: skip if this version is already on the registry.
    - name: Publish to npm
      if: inputs.publish-npm == 'true'
      shell: bash
      run: |
        PKG=$(node -p "require('./package.json').name")
        PUBLISHED=$(npm view "${PKG}@${VERSION}" version 2>/dev/null || true)
        if [ "$PUBLISHED" = "$VERSION" ]; then
          echo "npm already has ${PKG}@${VERSION} — skipping publish."
          exit 0
        fi
        npm publish --access public --provenance

    - name: Install mcp-publisher
      if: inputs.publish-registry == 'true'
      uses: chrischall/workflows/.github/actions/install-mcp-publisher@main

    - name: Authenticate to MCP Registry (OIDC)
      if: inputs.publish-registry == 'true'
      shell: bash
      run: mcp-publisher login github-oidc

    - name: Publish to MCP Registry
      if: inputs.publish-registry == 'true'
      shell: bash
      run: mcp-publisher publish

    # `secrets.*` is not addressable in composite steps; token arrives as an
    # input and the emptiness check happens in the run block.
    - name: Publish skill to ClawHub
      if: inputs.publish-clawhub == 'true'
      continue-on-error: true
      shell: bash
      env:
        CLAWHUB_TOKEN: ${{ inputs.clawhub-token }}
      run: |
        if [ -z "$CLAWHUB_TOKEN" ]; then
          echo "clawhub-token not set — skipping ClawHub publish."
          exit 0
        fi
        if [ ! -f SKILL.md ]; then
          echo "SKILL.md not present — skipping ClawHub publish."
          exit 0
        fi
        npx --yes clawhub login --token "$CLAWHUB_TOKEN" --no-browser
        # ClawHub `publish` rejects plugin-shaped folders; publish SKILL.md
        # from a clean temp dir as a standalone skill.
        SKILL_DIR=$(mktemp -d)
        cp SKILL.md "$SKILL_DIR/"
        npx --yes clawhub publish "$SKILL_DIR" --version "${VERSION}" --slug "${MCP_PUBLISH_NAME}"

    # release-please already created the GitHub Release; attach artifacts.
    - name: Attach artifacts to release
      shell: bash
      env:
        GH_TOKEN: ${{ inputs.github-token }}
        TAG: ${{ inputs.tag-name }}
      run: |
        ARGS=()
        [ -f "${MCP_PUBLISH_NAME}-${VERSION}.skill" ] && ARGS+=("${MCP_PUBLISH_NAME}-${VERSION}.skill")
        [ -f "${MCP_PUBLISH_NAME}-${VERSION}.mcpb" ] && ARGS+=("${MCP_PUBLISH_NAME}-${VERSION}.mcpb")
        if [ "${#ARGS[@]}" -eq 0 ]; then
          echo "No artifacts to attach."
          exit 0
        fi
        gh release upload "$TAG" "${ARGS[@]}" --clobber
```

- [ ] **Step 3: Validate and commit**

`actionlint` does not check action.yml files; spot-check YAML parses:

```bash
ruby -ryaml -e 'YAML.load_file(".github/actions/mcp-publish/action.yml"); puts "OK"'
ruby -ryaml -e 'YAML.load_file(".github/actions/install-mcp-publisher/action.yml"); puts "OK"'
git add .github/actions
git commit -m "feat: mcp-publish composite action; migrate install-mcp-publisher from mcp-utils"
```

Expected: `OK` twice.

---

### Task 6: Stub templates

**Files:**
- Create: `templates/pr-auto-review.yml`, `templates/auto-merge.yml`, `templates/ci.yml`, `templates/release-please.yml`

Placeholders `__UPPERCASE__` are substituted by `scripts/rollout.sh` from `fleet.json`.

- [ ] **Step 1: Write `templates/pr-auto-review.yml`**

```yaml
name: PR auto-review

# Thin stub — the pipeline lives in chrischall/workflows.

on:
  pull_request:
    types: [opened, reopened, ready_for_review, synchronize, labeled]

permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write

# `labeled` events get their own group keyed by label name: opening a PR
# with --label fires `opened`+`labeled` back-to-back, and a shared group
# would let the labeled event displace the queued review, leaving the PR
# with no verdict and no label.
concurrency:
  group: |
    pr-auto-review-${{ github.event.pull_request.number }}${{
      github.event.action == 'labeled'
        && format('-labeled-{0}', github.event.label.name)
        || ''
    }}
  cancel-in-progress: false

jobs:
  review:
    uses: chrischall/workflows/.github/workflows/reusable-pr-auto-review.yml@main
    with:
      conventions_hint: __CONVENTIONS_HINT__
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      release_pat: ${{ secrets.__PAT_SECRET__ }}
```

- [ ] **Step 2: Write `templates/auto-merge.yml`**

```yaml
name: Auto-merge PRs

# Thin stub — the pipeline lives in chrischall/workflows.
# pull_request_target so dependabot PRs can arm; PR code is never executed.

on:
  pull_request_target:
    types: [opened, reopened, ready_for_review, synchronize, labeled]

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: auto-merge-${{ github.event.pull_request.number }}
  cancel-in-progress: false

jobs:
  arm:
    uses: chrischall/workflows/.github/workflows/reusable-auto-merge.yml@main
    secrets:
      release_pat: ${{ secrets.__PAT_SECRET__ }}
```

- [ ] **Step 3: Write `templates/ci.yml`**

```yaml
name: CI

# Thin stub — the gate and steps live in chrischall/workflows.
# NOTE: converting to a reusable workflow renames the required check from
# `ci` to `ci / ci`; scripts/update-ruleset.sh flips the ruleset.

on:
  pull_request:
    types: [opened, synchronize, reopened, labeled]

jobs:
  ci:
    uses: chrischall/workflows/.github/workflows/reusable-mcp-ci.yml@main
    with:
      node-version: "__NODE_VERSION__"
      build-command: __BUILD_COMMAND__
      test-command: __TEST_COMMAND__
```

- [ ] **Step 4: Write `templates/release-please.yml`**

```yaml
name: release-please

# Thin stub: release-please runs here; the publish steps are the
# chrischall/workflows mcp-publish composite action. The publish job stays
# in THIS file (not a reusable workflow) because npm trusted publishing and
# mcp-publisher bind to this repo's workflow identity via OIDC.
#
# The release PR is the human review gate: add `release-ready` to ship it.
# RELEASE-pat so the release PR's events trigger CI/review workflows.

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: release-please-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release-please:
    runs-on: ubuntu-latest
    outputs:
      release_created: ${{ steps.release.outputs.release_created }}
      tag_name: ${{ steps.release.outputs.tag_name }}
      version: ${{ steps.release.outputs.version }}
    steps:
      - uses: googleapis/release-please-action@v5
        id: release
        with:
          token: ${{ secrets.__PAT_SECRET__ }}
          config-file: release-please-config.json
          manifest-file: .release-please-manifest.json

  publish:
    needs: release-please
    if: needs.release-please.outputs.release_created == 'true'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write    # npm provenance + mcp-publisher OIDC
    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ needs.release-please.outputs.tag_name }}

      - uses: chrischall/workflows/.github/actions/mcp-publish@main
        with:
          version: ${{ needs.release-please.outputs.version }}
          tag-name: ${{ needs.release-please.outputs.tag_name }}
          clawhub-token: ${{ secrets.CLAWHUB_TOKEN }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 5: Commit**

Templates contain `__PLACEHOLDERS__`, so don't actionlint them.

```bash
git add templates/
git commit -m "feat: per-repo stub templates"
```

---

### Task 7: `fleet.json` + rollout scripts

**Files:**
- Create: `fleet.json`, `scripts/rollout.sh`, `scripts/update-ruleset.sh`

- [ ] **Step 1: Write `fleet.json`**

Fields: `repo`; `pat_secret`; `ci` = `standard` (use ci stub) / `custom` (keep repo's ci.yml) / `none`; `node_version`/`build_command`/`test_command` (standard ci only); `release` = `mcp` (use release stub) / `custom` / `none`; `conventions_hint` (single line; empty = generic prompt only); `verify: true` = diff the repo's current files before converting and fall back to `custom` if they differ beyond these parameters.

```json
{
  "defaults": {
    "pat_secret": "RELEASE_PAT",
    "ci": "standard",
    "node_version": "26",
    "build_command": "npm run build",
    "test_command": "npm test",
    "release": "mcp",
    "conventions_hint": ""
  },
  "repos": [
    {"repo": "chrischall/zola-mcp"},
    {"repo": "chrischall/artsonia-mcp"},
    {"repo": "chrischall/canvas-parent-mcp"},
    {"repo": "chrischall/compass-mcp"},
    {"repo": "chrischall/creditkarma-mcp"},
    {"repo": "chrischall/gemini-mcp"},
    {"repo": "chrischall/gogcli-mcp"},
    {"repo": "chrischall/homes-mcp"},
    {"repo": "chrischall/honeybook-mcp"},
    {"repo": "chrischall/infinitecampus-mcp"},
    {"repo": "chrischall/musescore-mcp"},
    {"repo": "chrischall/onehome-mcp"},
    {"repo": "chrischall/opentable-mcp"},
    {"repo": "chrischall/redfin-mcp"},
    {"repo": "chrischall/resy-mcp"},
    {"repo": "chrischall/setlist-mcp"},
    {"repo": "chrischall/signupgenius-mcp"},
    {"repo": "chrischall/splitwise-mcp"},
    {"repo": "chrischall/tempo-api-mcp"},
    {"repo": "chrischall/zillow-mcp"},
    {"repo": "chrischall/musicbrainz-mcp"},
    {"repo": "chrischall/app-store-connect-mcp",
     "conventions_hint": "The version appears in several files and must stay in sync; JWT/auth handling and stdio logging rules are in CLAUDE.md."},
    {"repo": "chrischall/skylight-mcp", "test_command": "npm run test:coverage"},
    {"repo": "chrischall/evite-mcp", "test_command": "npm run test:coverage"},
    {"repo": "chrischall/ofw-mcp", "test_command": "npm run test:coverage"},
    {"repo": "chrischall/ioffice-mcp", "node_version": "22"},
    {"repo": "chrischall/mcp-utils", "verify": true,
     "conventions_hint": "Shared library: README.md documents the core-vs-optional-subpath module boundary; this package handles bearer tokens — error messages must never echo a credential; public API changes need tests."},
    {"repo": "chrischall/realty-mcp", "node_version": "24",
     "build_command": "npm run build --workspace=@chrischall/realty-core", "verify": true},
    {"repo": "chrischall/fetchproxy", "ci": "custom", "release": "custom"},
    {"repo": "chrischall/apple-swift-mcp", "ci": "custom", "release": "custom"},
    {"repo": "chrischall/outlook-to-pdf", "ci": "custom", "release": "custom"},
    {"repo": "chrischall/swift-mail-automation", "ci": "custom", "release": "mcp", "verify": true},
    {"repo": "chrischall/swift-notes-automation", "ci": "custom", "release": "mcp", "verify": true},

    {"repo": "nullnet-app/curtaincall", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "custom", "release": "custom",
     "conventions_hint": "TDD project (behavior changes ship with tests; never weaken assertions); Hibernate Envers auditing rules; one shared test context; Flyway owns the schema. All in CLAUDE.md."},
    {"repo": "nullnet-app/encore-ios", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "custom", "release": "custom",
     "conventions_hint": "TDD project; XcodeGen-generated project rules; setlist.fm API-terms constraints; secrets handling. All in CLAUDE.md."},
    {"repo": "nullnet-app/PassMint", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "custom", "release": "custom",
     "conventions_hint": "PR labeling, testing expectations, and security posture are in CLAUDE.md."},
    {"repo": "nullnet-app/StoryMint", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "custom", "release": "custom"},
    {"repo": "nullnet-app/aikidsbook-backend", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "custom", "release": "none", "verify": true},
    {"repo": "nullnet-app/nullnet", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "none", "release": "none"},
    {"repo": "nullnet-app/aikidsbook", "pat_secret": "NULLNET_RELEASE_PAT",
     "ci": "none", "release": "none"}
  ]
}
```

- [ ] **Step 2: Write `scripts/rollout.sh`**

```bash
#!/usr/bin/env bash
# Convert one fleet repo to chrischall/workflows stubs via PR.
#
# Usage: scripts/rollout.sh <owner/repo> [--execute]
# Dry-run by default: prints generated stubs and planned actions.
#
# Does NOT merge the PR and does NOT add ready-to-merge — the pipeline does.
# Run scripts/update-ruleset.sh after the PR is open (see Task 9).
set -euo pipefail

REPO="${1:?usage: rollout.sh <owner/repo> [--execute]}"
EXECUTE="${2:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$HERE/fleet.json"
BRANCH="ci/reusable-workflows"

cfg() { # cfg <key> -> value with defaults applied
  jq -r --arg repo "$REPO" --arg key "$1" '
    (.repos[] | select(.repo == $repo)) as $r
    | ($r[$key] // .defaults[$key] // "")' "$FLEET"
}

FOUND=$(jq -r --arg repo "$REPO" '[.repos[] | select(.repo == $repo)] | length' "$FLEET")
[ "$FOUND" = "1" ] || { echo "::error::$REPO not in fleet.json"; exit 1; }

PAT_SECRET=$(cfg pat_secret)
CI_MODE=$(cfg ci)
RELEASE_MODE=$(cfg release)
NODE_VERSION=$(cfg node_version)
BUILD_COMMAND=$(cfg build_command)
TEST_COMMAND=$(cfg test_command)
HINT=$(cfg conventions_hint)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

render() { # render <template> <dest>
  sed -e "s|__PAT_SECRET__|$PAT_SECRET|g" \
      -e "s|__NODE_VERSION__|$NODE_VERSION|g" \
      -e "s|__BUILD_COMMAND__|$BUILD_COMMAND|g" \
      -e "s|__TEST_COMMAND__|$TEST_COMMAND|g" \
      -e "s|__CONVENTIONS_HINT__|${HINT//|/\\|}|g" \
      "$HERE/templates/$1" > "$2"
}

STAGE="$WORK/stage"; mkdir -p "$STAGE"
render pr-auto-review.yml "$STAGE/pr-auto-review.yml"
render auto-merge.yml "$STAGE/auto-merge.yml"
[ "$CI_MODE" = "standard" ] && render ci.yml "$STAGE/ci.yml"
[ "$RELEASE_MODE" = "mcp" ] && render release-please.yml "$STAGE/release-please.yml"

echo "=== $REPO  (pat=$PAT_SECRET ci=$CI_MODE release=$RELEASE_MODE) ==="
for f in "$STAGE"/*; do echo "--- $(basename "$f")"; cat "$f"; done

if [ "$EXECUTE" != "--execute" ]; then
  echo "(dry run — pass --execute to open the conversion PR)"
  exit 0
fi

# Labels the pipeline depends on (idempotent).
for L in "auto-review:bfdadc" "ready-to-merge:0e8a16" "review-with-opus:5319e7" "release-ready:fbca04"; do
  gh label create "${L%%:*}" --repo "$REPO" --color "${L##*:}" --force >/dev/null
done

gh repo clone "$REPO" "$WORK/clone" -- --depth 1 --quiet
cd "$WORK/clone"
git checkout -b "$BRANCH"
mkdir -p .github/workflows
cp "$STAGE"/* .github/workflows/
# StoryMint/PassMint poll-merge and any old copies are replaced by the
# stubs above; files not in the stub set are intentionally left untouched
# (custom ci.yml, claude.yml, deploy workflows, release for custom repos).
git add .github/workflows
if git diff --cached --quiet; then
  echo "$REPO already converted — nothing to do."
  exit 0
fi
git commit -m "ci: convert to chrischall/workflows reusable pipeline

Thin stubs replace the vendored auto-review/auto-merge$( [ "$CI_MODE" = "standard" ] && echo "/CI" )$( [ "$RELEASE_MODE" = "mcp" ] && echo "/release" ) workflows.
Pipeline source: https://github.com/chrischall/workflows"
git push -u origin "$BRANCH"
gh pr create --repo "$REPO" --title "ci: convert to chrischall/workflows reusable pipeline" --body \
"Replaces vendored pipeline workflows with thin stubs calling chrischall/workflows@main.

- pr-auto-review: reusable (forced verdict + fail-loud + pass-only arming)
- auto-merge: reusable (dependabot + ready-to-merge label arms)
$( [ "$CI_MODE" = "standard" ] && echo "- ci: reusable node CI (deferred gate) — required check becomes \`ci / ci\`" )
$( [ "$RELEASE_MODE" = "mcp" ] && echo "- release-please: thin stub + mcp-publish composite action (OIDC identity preserved)" )

After this PR is open, run \`scripts/update-ruleset.sh $REPO\` in chrischall/workflows.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
echo "PR opened for $REPO."
```

- [ ] **Step 3: Write `scripts/update-ruleset.sh`**

```bash
#!/usr/bin/env bash
# Flip a repo's required-status-check context from `ci` to the reusable
# name (default `ci / ci`), or create the ruleset if the repo has none
# (nullnet-app, now on Team plan).
#
# Usage: scripts/update-ruleset.sh <owner/repo> [<new-context>] [--execute]
set -euo pipefail

REPO="${1:?usage: update-ruleset.sh <owner/repo> [<new-context>] [--execute]}"
NEW_CONTEXT="${2:-ci / ci}"
EXECUTE="${3:-}"

RULESET=$(gh api "repos/$REPO/rulesets" --jq \
  '[.[] | select(.target=="branch")][0] // empty')

if [ -n "$RULESET" ]; then
  RID=$(echo "$RULESET" | jq -r .id)
  CURRENT=$(gh api "repos/$REPO/rulesets/$RID" --jq \
    '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | join(",")')
  echo "$REPO ruleset $RID currently requires: ${CURRENT:-<none>} -> $NEW_CONTEXT"
  [ "$EXECUTE" = "--execute" ] || { echo "(dry run)"; exit 0; }
  FULL=$(gh api "repos/$REPO/rulesets/$RID")
  echo "$FULL" | jq --arg ctx "$NEW_CONTEXT" '
    .rules = [.rules[] | if .type=="required_status_checks"
      then .parameters.required_status_checks = [{context: $ctx}] else . end]
    | {name, target, enforcement, conditions, rules}' \
  | gh api -X PUT "repos/$REPO/rulesets/$RID" --input -
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
    ]}' | gh api -X POST "repos/$REPO/rulesets" --input -
  echo "Created."
fi
```

- [ ] **Step 4: Make executable; dry-run against zola-mcp; commit**

```bash
chmod +x scripts/rollout.sh scripts/update-ruleset.sh
scripts/rollout.sh chrischall/zola-mcp          # dry run: prints 4 stubs
scripts/update-ruleset.sh chrischall/zola-mcp   # dry run: prints current ci context
git add fleet.json scripts/
git commit -m "feat: fleet config and rollout scripts"
git push
```

Expected: dry-run output shows rendered stubs with `RELEASE_PAT`, node 26, `npm test`; ruleset dry-run shows `currently requires: ci`.

---

### Task 8: Dogfood — this repo's own pipeline

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/pr-auto-review.yml`, `.github/workflows/auto-merge.yml`

- [ ] **Step 1: Write `.github/workflows/ci.yml`** (actionlint as the check; same deferred-gate semantics don't apply here — lint every PR event so reusable-workflow changes are validated immediately)

```yaml
name: CI

on:
  pull_request:
    types: [opened, synchronize, reopened, labeled]
  push:
    branches: [main]

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: actionlint
        run: |
          bash <(curl -s https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) 1.7.7
          ./actionlint -color
      - name: validate composite actions parse
        run: |
          ruby -ryaml -e 'Dir.glob(".github/actions/*/action.yml").each { |f| YAML.load_file(f) }; puts "actions OK"'
          ruby -ryaml -e 'Dir.glob("templates/*.yml").each { |f| YAML.load_file(f.gsub(/__[A-Z_]+__/) { "x" }) rescue (puts f; raise) }; puts "templates OK"' || true
```

Note: this job is a plain job named `ci` (not a reusable call), so this repo's required check context is `ci`.

- [ ] **Step 2: Write the dogfood stubs** — copy `templates/pr-auto-review.yml` and `templates/auto-merge.yml` with substitutions applied (`__PAT_SECRET__` → `RELEASE_PAT`, `__CONVENTIONS_HINT__` → `"This repo hosts the fleet's reusable workflows; changes here affect 39 repos. Comments encode load-bearing constraints (OIDC, token-suppression, concurrency races) — flag any change that weakens them."`) and the `uses:` lines switched to local refs (`./.github/workflows/reusable-pr-auto-review.yml`, `./.github/workflows/reusable-auto-merge.yml` — local refs track the PR's own branch, which is exactly what dogfooding wants).

- [ ] **Step 3: Validate, create labels + ruleset, secrets check**

```bash
actionlint
for L in "auto-review:bfdadc" "ready-to-merge:0e8a16" "review-with-opus:5319e7" "release-ready:fbca04"; do
  gh label create "${L%%:*}" --repo chrischall/workflows --color "${L##*:}" --force
done
gh api repos/chrischall/workflows --jq .allow_auto_merge   # must be true; if false:
gh api -X PATCH repos/chrischall/workflows -f allow_auto_merge=true --jq .allow_auto_merge
scripts/update-ruleset.sh chrischall/workflows "ci" --execute
# CLAUDE_CODE_OAUTH_TOKEN and RELEASE_PAT must be visible to this repo —
# both exist (user-level/org pattern used by 33 sibling repos); verify:
gh secret list --repo chrischall/workflows
```

If `gh secret list` lacks `CLAUDE_CODE_OAUTH_TOKEN`/`RELEASE_PAT`, STOP and ask the owner to add them (values are not retrievable from other repos).

- [ ] **Step 4: Commit, push, prove the pipeline on a real PR**

```bash
git add .github/workflows
git commit -m "ci: dogfood the reusable pipeline"
git push
# Trivial test PR:
git checkout -b test/dogfood-pipeline
printf '\n' >> README.md
git commit -am "docs: trailing newline (pipeline dogfood test)"
git push -u origin test/dogfood-pipeline
gh pr create --repo chrischall/workflows --title "docs: pipeline dogfood test" \
  --body "Exercises the dogfooded reusable pipeline end-to-end. 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Watch (do not intervene): auto-review runs → verdict comment appears → `ready-to-merge` label added by the workflow → CI runs → auto-merge merges. Check with `gh pr view <n> --json labels,state,statusCheckRollup` and `gh run list --repo chrischall/workflows`. If the verdict comment is missing or the job didn't fail loudly on a missing verdict, debug before proceeding — this is the gate for the whole rollout.

---

### Task 9: Canary — zola-mcp

- [ ] **Step 1: Convert**

```bash
scripts/rollout.sh chrischall/zola-mcp --execute
```

Expected: labels ensured, branch pushed, PR opened. The PR's head carries the new stubs, so the new pipeline reviews its own conversion PR.

- [ ] **Step 2: Verify OIDC + verdict on the conversion PR**

```bash
PR=$(gh pr list --repo chrischall/zola-mcp --head ci/reusable-workflows --json number --jq '.[0].number')
gh run list --repo chrischall/zola-mcp --limit 10
gh pr view "$PR" --repo chrischall/zola-mcp --json comments --jq '[.comments[].body] | last'
```

Checks: (a) the review job ran the reusable workflow and claude[bot] commented — proves Anthropic OIDC works cross-repo; (b) the marker verdict comment exists; (c) on `pass` the `ready-to-merge` label was added by `chrischall` (the PAT identity), firing CI.
If OIDC fails (auth error in the review run): fallback per spec — restructure review as a composite action called from a per-repo job (same trick as mcp-publish). Stop and report before doing this.

- [ ] **Step 3: Capture the exact new check context**

```bash
gh pr view "$PR" --repo chrischall/zola-mcp --json statusCheckRollup --jq '.statusCheckRollup[].name'
```

Expected to include `ci / ci` (caller job `ci` / called job `ci`). Whatever the exact string is, use it for every subsequent `update-ruleset.sh` call — and if it is NOT `ci / ci`, update the default in `scripts/update-ruleset.sh` and the note in `templates/ci.yml`, then commit.

- [ ] **Step 4: Flip the ruleset, let the pipeline merge**

```bash
scripts/update-ruleset.sh chrischall/zola-mcp "ci / ci" --execute
gh pr view "$PR" --repo chrischall/zola-mcp --json state,labels
```

The PR merges on its own once CI is green (the label predates the flip; auto-merge waits on the new required context). Do not merge manually. If the PR sits with CI green but unmerged, the required context doesn't match the reported check name — recheck Step 3.

- [ ] **Step 5: Verify release path (gated on owner)**

The next `fix:`/`feat:` merge to zola-mcp opens a release PR; the owner ships it by adding `release-ready` (never add it yourself). When that happens, verify the publish job: npm version published with provenance, registry publish OK, `.skill`/`.mcpb` attached. If npm trusted publishing rejects (composite action changed nothing about OIDC identity, so it should not), stop and report. This step may be deferred — note it as pending in the final report rather than blocking the waves, but verify before converting the last 10 repos so a publish regression can't hit the whole fleet.

---

### Task 10: chrischall wave (32 repos)

- [ ] **Step 1: Convert in batches of ~8, oldest-simplest first**

```bash
for r in artsonia-mcp canvas-parent-mcp compass-mcp creditkarma-mcp gemini-mcp gogcli-mcp homes-mcp honeybook-mcp; do
  scripts/rollout.sh "chrischall/$r" --execute
  scripts/update-ruleset.sh "chrischall/$r" "ci / ci" --execute
done
```

Then batches 2–4: `infinitecampus-mcp musescore-mcp onehome-mcp opentable-mcp redfin-mcp resy-mcp setlist-mcp signupgenius-mcp`, `splitwise-mcp tempo-api-mcp zillow-mcp musicbrainz-mcp app-store-connect-mcp skylight-mcp evite-mcp ofw-mcp`, `ioffice-mcp mcp-utils realty-mcp fetchproxy apple-swift-mcp outlook-to-pdf swift-mail-automation swift-notes-automation`.

For `verify: true` repos (mcp-utils, realty-mcp, swift-*-automation), before `--execute`: fetch the repo's current `ci.yml`/`release-please.yml`, diff against what the stub replaces, and if there is logic beyond node-version/build/test parameters, flip that repo to `ci: custom`/`release: custom` in fleet.json (commit the change) so the file is kept.
For `ci: custom` repos do NOT flip the ruleset context (their check stays `ci`).
NOTE for fetchproxy/realty-mcp: their custom/old configs armed on `warn` — converting the review workflow alone fixes that (pass-only is in the reusable).

- [ ] **Step 2: Monitor each batch to completion**

```bash
for r in <batch>; do
  gh pr list --repo "chrischall/$r" --head ci/reusable-workflows --json number,state,labels --jq '.[0] | [.number, .state, ([.labels[].name]|join(","))] | @tsv'
done
```

Healthy: state MERGED (pipeline did it). A PR stuck OPEN with `ready-to-merge` but no merge = check-context mismatch (rerun ruleset dry-run). A PR with verdict `warn`/`fail` = read the findings, fix in the conversion branch, push (re-review fires on synchronize). Never label or merge manually.

---

### Task 11: nullnet-app wave (6 repos)

- [ ] **Step 1: Preflight — org secret visibility + curtaincall #128**

```bash
# NULLNET_RELEASE_PAT must be visible to aikidsbook-backend, nullnet, aikidsbook:
gh api orgs/nullnet-app/actions/secrets/NULLNET_RELEASE_PAT --jq '{visibility}'
# If visibility=="selected", add the three repos:
gh api orgs/nullnet-app/actions/secrets/NULLNET_RELEASE_PAT/repositories --jq '.repositories[].name'
# curtaincall PR #128 (verdict surfacing) — the conversion supersedes it:
gh pr view 128 --repo nullnet-app/curtaincall --json state
```

If #128 is still OPEN, the conversion PR will conflict on pr-auto-review.yml; close #128 with a comment pointing at the conversion PR (closing is fine — merging is what's restricted). If MERGED, nothing to do.

- [ ] **Step 2: nullnet repo CI discovery**

`nullnet-app/nullnet` has no ci.yml (deploy.yml only). Inspect: `gh api repos/nullnet-app/nullnet/contents/package.json --jq .content | base64 -d | jq '{scripts}'`. If it has `build`/`test` scripts, set `ci: standard` (+ node version from `.nvmrc`/engines if present) in fleet.json and commit; if not, leave `ci: none` and skip its ruleset (label-armed merges wait on nothing — accepted in spec).

- [ ] **Step 3: Convert all six + rulesets**

```bash
for r in curtaincall encore-ios PassMint StoryMint aikidsbook-backend nullnet aikidsbook; do
  scripts/rollout.sh "nullnet-app/$r" --execute
done
# Required-check rulesets (Team plan now permits them). Custom-CI repos keep
# their existing `ci` job name; verify per repo before flipping:
for r in curtaincall encore-ios PassMint StoryMint aikidsbook-backend; do
  gh api "repos/nullnet-app/$r/commits/$(gh api repos/nullnet-app/$r --jq .default_branch)/check-runs" --jq '[.check_runs[].name] | unique'
  scripts/update-ruleset.sh "nullnet-app/$r" "<observed ci context>" --execute
done
# nullnet: only if Step 2 gave it CI. aikidsbook: no ruleset (no CI).
```

This wave also fixes by construction: aikidsbook-backend/nullnet dead `RELEASE_PAT` (stubs use `NULLNET_RELEASE_PAT`), StoryMint/PassMint poll-merge (replaced by native arm + new required checks — ruleset MUST be active before their conversion PR merges, same ordering as Task 9 Step 4), the five `track_progress: true` crashes, and curtaincall/encore-ios merge-before-CI.

- [ ] **Step 4: Monitor to completion** — same loop as Task 10 Step 2 against `nullnet-app/*`.

---

### Task 12: Cleanup + docs

- [ ] **Step 1: Deprecate mcp-utils' install-mcp-publisher** — once every `release: mcp` repo is converted (check: `gh search code "mcp-utils/.github/actions/install-mcp-publisher" --owner chrischall --json repository --jq '[.[].repository.nameWithOwner] | unique'` returns only mcp-utils docs), open a PR to mcp-utils replacing the action directory with a README pointing at `chrischall/workflows`, and updating README.md/CHANGELOG mentions plus the `mcp-fleet-builder` skill (`skills/mcp-fleet-builder/SKILL.md`) to reference the new home. Let the pipeline merge it.

- [ ] **Step 2: Update the spec** — amend `docs/superpowers/specs/2026-06-12-fleet-reusable-workflows-design.md`: replace the `reusable-mcp-release.yml` section with the `mcp-publish` composite action + stub design and the OIDC rationale; commit.

- [ ] **Step 3: Memory + final report** — update auto-memory (fleet now on chrischall/workflows@main; rollout script location; check context `ci / ci`), then report: repos converted, divergences eliminated, anything deferred (e.g. Task 9 Step 5 release verification).

---

## Self-review notes

- **Spec coverage:** repo+home (T1), 4 consolidated pipelines (T2–T6: release as composite per deviation note), stubs/templates (T6), fleet config+scripts (T7), dogfood (T8), canary incl. OIDC + check-context risks (T9), waves (T10–11), nullnet fixes — rulesets, poll-merge retirement, PAT, nullnet CI, aikidsbook partial pipeline (T11), install-mcp-publisher migration + deprecation (T5, T12), spec amendment (T12).
- **Check-name consistency:** `ci / ci` is provisional until T9 Step 3 captures the real string; T9 explicitly updates the script default and template note if it differs. Custom-CI repos keep context `ci`.
- **No placeholder scan:** templates intentionally contain `__X__` tokens (that's their format); all other code blocks are complete.

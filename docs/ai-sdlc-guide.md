# AI-SDLC Operations Guide

A practical guide for running projects with AI agents (Claude, Codex, etc.) using GitHub Issue-based lifecycle tracking.

---

## 1. Lifecycle Overview

Every task follows this flow. Each step is recorded in GitHub Issues for full traceability.

```
Task request → Issue created → START logged
    → Research/PRD → PRD/PLAN logged
        → Branch created → Implement → PROGRESS logged
            → Verify → RESULT logged → Commit → (PR → Merge → Issue auto-closed)
```

### Automatic Status Transitions

`issue-status-sync.yml` auto-transitions labels:

| Event | Label Transition |
|-------|-----------------|
| Issue assigned | `status:todo` → `status:in-progress` |
| PR opened (referencing issue) | → `status:review` |
| PR merged | → `status:done` |
| Issue closed | → `status:done` |
| Issue reopened | → `status:in-progress` |

---

## 2. Step-by-Step Execution

### 2.1 Create Issue

```bash
gh issue create \
  --title "[PREFIX] Task title" \
  --label "area:aipm,type:task,status:todo,priority:p1" \
  --body "## Summary\n...\n## Done Criteria\n..."
```

Or use the **AIPM Major Request** template from GitHub UI.

**Label rules:** Always specify `area:*` + `type:*` + `status:todo` + `priority:*`.

### 2.2 Log START

```bash
./scripts/issue-log.sh <issue-number> start - <<'EOF'
## Scope
- What this task covers

## Done Criteria
- Verifiable conditions for completion
EOF
```

A START comment should include:
- **Scope**: What is and isn't covered
- **Assumptions**: Preconditions
- **Done criteria**: Verifiable conditions

### 2.3 Research / PRD / Plan

Record research, PRDs, and execution plans as issue comments.

```bash
# Attach a PRD file to the issue
./scripts/issue-log.sh <issue-number> prd docs/prd-feature-x.md

# Log an execution plan
./scripts/issue-log.sh <issue-number> plan - <<'EOF'
1. Step A → verify: ...
2. Step B → verify: ...
EOF
```

### 2.4 Branch and Implement

```bash
git checkout -b feat/PREFIX-42-feature-name
```

**Branch naming:** `<type>/<PREFIX>-<n>-<slug>`

| Type | Purpose |
|------|---------|
| `feat` | New feature |
| `fix` | Bug fix |
| `chore` | Maintenance, config |
| `refactor` | Refactoring |
| `research` | Research, investigation |
| `docs` | Documentation |

Log progress during development:

```bash
./scripts/issue-log.sh <issue-number> progress - <<'EOF'
## Progress
- Completed items
- Next steps
- Blockers (if any)
EOF
```

### 2.5 Commit

```
[PREFIX-42] feat(auth): add OAuth2 token refresh

Implement automatic token refresh before expiry.

Closes #42
```

**Commit format:**
```
[PREFIX-n] type(scope): summary

Description (optional)

Refs #n    ← work in progress
Closes #n  ← completed
Fixes #n   ← bug fix completed
```

- `prepare-commit-msg` hook auto-extracts the issue number from branch name
- `commit-msg` hook validates issue key and link keyword presence
- CI (`aipm-governance.yml`) re-validates on push/PR

### 2.6 Log RESULT and Close

```bash
./scripts/issue-log.sh <issue-number> result - <<'EOF'
## Result
- Implementation summary
- Verification results

## Lessons Learned
- Key takeaways (if any)
EOF
```

To close the issue, add `--close`:

```bash
./scripts/issue-log.sh <issue-number> result - --close <<'EOF'
...
EOF
```

Or include `Closes #n` in your commit — the issue auto-closes when the PR is merged.

---

## 3. PR Rules

The `.github/pull_request_template.md` is auto-applied on PR creation.

**PR governance CI checks:**
1. PR title/body contains `Refs/Closes/Fixes #n`
2. Referenced issues have START + (PLAN|PRD|PROGRESS) + (RESULT|END) comments

If lifecycle logs are incomplete, **the PR cannot merge**.

---

## 4. AI Agent Usage

### 4.1 Local CLI

When using Claude CLI or Codex CLI, agents automatically follow rules defined in `CLAUDE.md` and `AGENTS.md`:
- Issue creation → lifecycle logging → commit with issue key

### 4.2 GitHub Actions Dispatch

Apply a label to an issue and an AI agent picks up the work automatically:

| Label | Action |
|-------|--------|
| `agent:claude` | Runs Claude Code Action |
| `agent:codex` | Runs Codex Action |
| `agent:auto` | Runs default agent (configurable via repo variable) |

Trigger via issue comment:
- `@ai-agent` → default agent
- `@ai-agent claude` → Claude
- `@ai-agent codex` → Codex

### 4.3 Agent Instruction Files

| File | Target | Purpose |
|------|--------|---------|
| `CLAUDE.md` | Claude Code | Commit format, branch rules, issue-log commands |
| `AGENTS.md` | Codex / general | Same rules + trigger phrases + comment log format |

Both files contain `<!-- AIPM-ISSUE-OPS:BEGIN/END -->` managed blocks, auto-injected by `aipm-bootstrap-repo.sh`.

---

## 5. Applying to a New Project

### 5.1 Single Repo

```bash
./scripts/aipm-bootstrap-repo.sh --repo ~/projects/my-app

# Preview changes first
./scripts/aipm-bootstrap-repo.sh --repo ~/projects/my-app --dry-run
```

This installs:
- `scripts/issue-log.sh`, `scripts/setup-labels.sh`
- `.aipm/ops.env` (auto-inferred `ISSUE_KEY_PREFIX`)
- `.githooks/prepare-commit-msg`, `.githooks/commit-msg`
- `.github/ISSUE_TEMPLATE/aipm-major.md`
- `.github/workflows/aipm-governance.yml`
- Managed blocks appended to `AGENTS.md` and `CLAUDE.md`
- `git config core.hooksPath .githooks`

### 5.2 All Repos at Once

```bash
./scripts/aipm-bootstrap-all.sh --root ~/projects
```

### 5.3 Audit Compliance

```bash
./scripts/aipm-audit-repos.sh --root ~/projects --format table
```

### 5.4 Initialize Labels

Run once per new repo:

```bash
cd ~/projects/my-app
./scripts/setup-labels.sh
```

---

## 6. 3-Layer Enforcement

Issue keys and lifecycle logs are enforced at three layers:

```
Layer 1: Local Git Hook (commit-msg)
  → Blocks commits immediately: missing issue key, missing link keyword

Layer 2: CI (aipm-governance.yml, on push)
  → Re-validates all commit subjects/bodies

Layer 3: PR Governance (aipm-governance.yml, on PR)
  → Validates issue references in PR
  → Verifies lifecycle log completeness (START + PLAN/PRD + RESULT)
```

Even if one layer is bypassed, the next layer catches it.

---

## 7. Release Automation

`release-please.yml` analyzes conventional commits on push to main:
1. Auto-generates CHANGELOG.md
2. Creates a Release PR
3. When the Release PR is merged → GitHub Release + tag

Commit type to version bump mapping:

| Type | Version Bump |
|------|-------------|
| `fix` | PATCH (0.0.x) |
| `feat` | MINOR (0.x.0) |
| `feat!` / `BREAKING CHANGE` | MAJOR (x.0.0) |
| `chore`, `docs`, `refactor` | No release |

---

## 8. `[PM]` Trigger — Project Management Mode

`[PM]` acts as a state machine. The agent auto-detects the current phase and advances to the next step.

**Start a new task:**
```
[PM] Add OAuth token refresh
```
→ Phase 1 (Intake): Create issue + log START

**Then repeat `[PM]` to advance:**
```
[PM]    → Phase 2: PRD/Plan
[PM]    → Phase 3: Implement
[PM]    → Phase 4: Verify
[PM]    → Phase 5: RESULT + Commit
[PM]    → Phase 6: Push
```

You can also give specific instructions mid-flow:
```
[PM] Add test cases        ← specific instruction during implementation
[PM] Done. Commit please   ← jump to close phase
```

Without `[PM]`, prompts execute directly — no issue tracking.

---

## 9. Quick Reference

```bash
# Create issue
gh issue create --title "[PREFIX] title" --label "area:aipm,type:task,status:todo,priority:p1"

# Lifecycle logging
./scripts/issue-log.sh <n> start
./scripts/issue-log.sh <n> progress
./scripts/issue-log.sh <n> prd docs/prd.md
./scripts/issue-log.sh <n> plan docs/plan.md
./scripts/issue-log.sh <n> result - --close

# Branch
git checkout -b feat/PREFIX-<n>-slug

# Initialize labels
./scripts/setup-labels.sh

# Bootstrap a new repo
./scripts/aipm-bootstrap-repo.sh --repo ~/projects/<name>

# Audit all repos
./scripts/aipm-audit-repos.sh --root ~/projects --format table
```

---

## 10. Related Documents

| Document | Contents |
|----------|----------|
| [issue-workflow.md](issue-workflow.md) | Label taxonomy, lifecycle rules |
| [README.md](../README.md) | Quick start and overview |

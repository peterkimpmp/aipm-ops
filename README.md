# aipm-ops

Issue-driven lifecycle governance for AI-native development teams.

One bootstrap command installs structured traceability, agent-agnostic dispatch, and PR merge gates across any GitHub repo.

## What It Does

```
Issue created → START logged → Plan/PRD → Implement → PROGRESS logged → Verify → RESULT logged → Commit → PR → Merge
```

Every step is recorded in GitHub Issues. Every commit links to an issue. Every PR is gated on lifecycle completeness.

## Why

AI coding agents (Claude Code, Codex, Copilot) generate code fast. But without governance rails, you get:
- Commits with no context on *why*
- PRs that can't be traced back to a requirement
- No audit trail from intent to implementation

**aipm-ops** connects the dots: issue creation, lifecycle logging, commit enforcement, agent dispatch, and PR governance — in one toolkit.

## Quick Start

### 1. Clone this repo

```bash
git clone https://github.com/peterkimpmp/aipm-ops.git
cd aipm-ops
```

### 2. Bootstrap a target repo

```bash
./scripts/aipm-bootstrap-repo.sh --repo ~/projects/my-app
```

This installs:

| Component | Description |
|-----------|-------------|
| `scripts/issue-log.sh` | Post lifecycle logs (START/PROGRESS/RESULT) to GitHub Issues |
| `scripts/setup-labels.sh` | Create label taxonomy (type, status, priority, agent) |
| `.githooks/commit-msg` | Block commits without issue key |
| `.githooks/prepare-commit-msg` | Auto-insert issue key from branch name |
| `.github/workflows/aipm-governance.yml` | CI: validate commits + issue lifecycle completeness |
| `.github/workflows/issue-status-sync.yml` | Auto-transition status labels on events |
| `.github/workflows/ai-agent-dispatch.yml` | Route work to Claude/Codex via labels |
| `.github/workflows/release-please.yml` | Automated CHANGELOG and releases |
| `.github/pull_request_template.md` | PR checklist with lifecycle verification |
| `.github/ISSUE_TEMPLATE/aipm-major.md` | Structured issue template |
| `CLAUDE.md` / `AGENTS.md` | AI agent instruction blocks |
| `.aipm/ops.env` | Per-repo issue key prefix |

### 3. Bootstrap all repos at once

```bash
./scripts/aipm-bootstrap-all.sh --root ~/projects
```

### 4. Audit compliance

```bash
./scripts/aipm-audit-repos.sh --root ~/projects --format table
```

```
| Repo      | AgentRules | IssueLog | Labels | Template | GovernanceCI | Hooks     | OpsEnv | Prefix |
|-----------|-----------|---------|--------|----------|-------------|-----------|--------|--------|
| my-app    | yes       | yes     | yes    | yes      | yes         | yes/yes   | yes    | MA     |
| my-service| yes       | yes     | yes    | yes      | yes         | yes/yes   | yes    | MS     |
```

## How It Works

### 3-Layer Enforcement

```
Layer 1: Local Git Hook (commit-msg)
  → Blocks commits without issue key [PREFIX-n] and Refs/Closes/Fixes #n

Layer 2: CI (aipm-governance.yml)
  → Validates all commits on push and PR

Layer 3: PR Governance
  → Verifies referenced issues have START + PLAN/PRD + RESULT logs
  → PR cannot merge until lifecycle is complete
```

### `[PM]` Trigger (AI Agents)

Add `[PM]` to your prompt in Claude Code or Codex CLI. The agent auto-detects the current phase and executes the next step:

```
[PM] Add OAuth token refresh    → Creates issue + START log
[PM]                            → Plans/PRD
[PM]                            → Implements + PROGRESS log
[PM]                            → Verifies
[PM]                            → RESULT log + Commit
[PM]                            → Push
```

Without `[PM]`, the agent executes directly with no issue tracking.

### Agent-Agnostic Dispatch

Apply a label to any issue to dispatch work to an AI agent:

| Label | Agent |
|-------|-------|
| `agent:claude` | Claude Code |
| `agent:codex` | OpenAI Codex |
| `agent:auto` | Default (configurable) |

Or mention `@ai-agent` in an issue comment.

### Commit Format

```
[PREFIX-42] feat(auth): add OAuth2 token refresh

Implement automatic token refresh before expiry.

Closes #42
```

The prefix is per-repo, configured in `.aipm/ops.env`.

### Branch Naming

```
feat/PREFIX-42-oauth-refresh
fix/PREFIX-17-login-timeout
```

## Issue Lifecycle Logging

```bash
# Log start of work
./scripts/issue-log.sh 42 start

# Log progress
./scripts/issue-log.sh 42 progress

# Log PRD or plan
./scripts/issue-log.sh 42 prd docs/prd.md

# Log result and close
./scripts/issue-log.sh 42 result - --close
```

Each command posts a structured comment to the GitHub issue:

```markdown
### START | PREFIX-42
- Timestamp: 2026-02-18 12:26 KST
- Commit: `abc1234`

<your content>
```

## Label Taxonomy

| Group | Labels |
|-------|--------|
| Area | `area:aipm` |
| Type | `type:prd`, `type:plan`, `type:task`, `type:bug`, `type:chore`, `type:result` |
| Status | `status:todo`, `status:in-progress`, `status:blocked`, `status:review`, `status:done` |
| Priority | `priority:p0` ... `priority:p3` |
| Agent | `agent:claude`, `agent:codex`, `agent:auto` |

Status labels transition automatically via `issue-status-sync.yml`.

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) — installed and authenticated
- Git 2.9+ (for `core.hooksPath` support)
- Bash 4+

## Configuration

### Issue Key Prefix

Each repo gets a unique prefix in `.aipm/ops.env`:

```bash
ISSUE_KEY_PREFIX=MA
```

The bootstrap script infers the prefix from:
1. Existing `.aipm/ops.env`
2. Existing issue key patterns in the repo
3. Repo name initials (e.g., `my-app` → `MA`)

### AI Agent Dispatch

Set the `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` as GitHub repository secrets. Optionally set `AI_AGENT_DEFAULT_MODEL` as a repository variable.

## Security Considerations

- **API key exposure**: The `ai-agent-dispatch.yml` workflow uses repository secrets. Anyone who can apply labels or comment on issues can trigger agent runs that consume API credits. Consider adding an actor allowlist for production use.
- **Lifecycle log bypass**: The governance CI checks for phase markers via regex. A collaborator could satisfy checks by posting comments manually. This is a workflow aid, not a tamper-proof audit system.
- **Git config mutation**: The bootstrap script sets `core.hooksPath=.githooks` in local git config. This is logged but does not prompt for confirmation.

## Repository Structure

```
aipm-ops/
├── scripts/
│   ├── aipm-bootstrap-repo.sh    # Bootstrap one repo
│   ├── aipm-bootstrap-all.sh     # Bootstrap all repos under a root
│   └── aipm-audit-repos.sh       # Audit compliance across repos
├── templates/aipm-ops/           # Source templates (with __PLACEHOLDER__)
│   ├── scripts/
│   │   ├── issue-log.sh
│   │   └── setup-labels.sh
│   ├── .aipm/ops.env
│   ├── .githooks/
│   │   ├── commit-msg
│   │   └── prepare-commit-msg
│   └── .github/
│       ├── pull_request_template.md
│       ├── ISSUE_TEMPLATE/aipm-major.md
│       └── workflows/
│           ├── aipm-governance.yml
│           ├── issue-status-sync.yml
│           ├── ai-agent-dispatch.yml
│           └── release-please.yml
├── examples/                     # Standalone workflow examples
├── docs/
│   ├── ai-sdlc-guide.md         # Full operations guide
│   └── issue-workflow.md         # Label taxonomy and lifecycle rules
├── LICENSE
├── CONTRIBUTING.md
└── README.md
```

## License

[MIT](LICENSE)

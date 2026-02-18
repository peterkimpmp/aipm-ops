# Issue Workflow

## Purpose

Use GitHub Issues as the single source of truth for task start, progress, and completion.

## Label Taxonomy

| Group | Labels |
|-------|--------|
| Area | `area:aipm` |
| Type | `type:prd`, `type:plan`, `type:task`, `type:bug`, `type:chore`, `type:result` |
| Status | `status:todo`, `status:in-progress`, `status:blocked`, `status:review`, `status:done` |
| Priority | `priority:p0`, `priority:p1`, `priority:p2`, `priority:p3` |
| Agent | `agent:claude`, `agent:codex`, `agent:auto` |

## Lifecycle

1. Create issue with `area:*`, one `type:*`, one `priority:*`, and `status:todo`.
2. When work starts, switch to `status:in-progress` and add `START` log.
3. During execution, post `PROGRESS` logs as needed.
4. On completion, add `RESULT` log, switch to `status:done`, and close the issue.

## Required Logs Per Issue

For PR governance to pass, referenced issues must have:

- `START` log — marks work initiation
- `PLAN` or `PRD` or `PROGRESS` log — marks planning or progress
- `RESULT` or `END` log — marks completion

## Branch Naming

- Format: `<type>/<PREFIX>-<n>-<slug>`
- Examples: `feat/MA-17-oauth-refresh`, `fix/MS-5-login-timeout`
- The `prepare-commit-msg` hook extracts the issue number from branch name automatically.

## Commit Format

```
[PREFIX-n] type(scope): summary

Description (optional)

Refs #n | Closes #n | Fixes #n
```

- **Subject**: `[PREFIX-n] type(scope): summary`
- **Scope** is optional: `[PREFIX-n] type: summary` is also valid
- **Body** must include one of: `Refs #n`, `Closes #n`, `Fixes #n`

## Status Auto-Transitions

The `issue-status-sync.yml` workflow automatically transitions status labels:

| Event | Transition |
|-------|-----------|
| Issue assigned | `status:todo` → `status:in-progress` |
| PR opened (referencing issue) | → `status:review` |
| PR merged | → `status:done` |
| Issue closed | → `status:done` |
| Issue reopened | → `status:in-progress` |

## `[PM]` Trigger

Add `[PM]` to the beginning of your prompt to activate project management mode. The agent auto-detects the current phase and advances:

| Input | Phase |
|-------|-------|
| `[PM] <new topic>` | Intake: create issue + START |
| `[PM]` | PRD/Plan |
| `[PM]` | Implement + PROGRESS |
| `[PM]` | Verify |
| `[PM]` | Close: RESULT + commit |
| `[PM]` | Deploy: push |

Case-insensitive: `[PM]`, `[pm]`, `[Pm]` all work.

Without `[PM]`, the agent executes directly with no issue tracking.

# Issue Workflow

## Purpose

Use GitHub Issues as the single source of truth for task start, progress, and completion.

## Label Taxonomy

| Group | Labels |
|-------|--------|
| Type | `type:epic`, `type:feature`, `type:story`, `type:task`, `type:bug`, `type:chore`, `type:docs`, `type:refactor` |
| Status | `status:todo`, `status:in-progress`, `status:blocked`, `status:review`, `status:done`, `status:wont-fix`, `status:duplicate` |
| Priority | `priority:p0`, `priority:p1`, `priority:p2`, `priority:p3` |
| Area | `area:backend`, `area:frontend`, `area:infra`, `area:database`, `area:api`, `area:ai-agent`, `area:security`, `area:ux`, `area:docs`, `area:aipm` |
| Agent | `agent:claude`, `agent:codex`, `agent:auto` |

## Issue Hierarchy

```
Initiative  (strategic goal, quarterly~annual)
  └── Epic       (large feature bundle, weeks~months)
        └── Feature    (single feature, 1–3 sprints)
              └── Story      (user requirement, 1 sprint)
                    └── Task / Bug  (concrete work, 1–3 days)
```

Issue title prefix must match type: `[Epic]`, `[Feature]`, `[Story]`, `[Task]`, `[Bug]`.

## Lifecycle

```
[Created] status:todo
  → [Started]   status:in-progress  +  issue-log start
  → [Progress]  issue-log progress  (repeat as needed)
  → [Done]      status:done  +  issue-log result  +  close
```

```bash
./scripts/issue-log.sh <n> start
./scripts/issue-log.sh <n> progress
./scripts/issue-log.sh <n> result docs/result.md --close
```

## Required Logs Per Issue

For PR governance to pass, referenced issues must have:

- `START` log — marks work initiation
- `PLAN` or `PRD` or `PROGRESS` log — marks planning or progress
- `RESULT` or `END` log — marks completion

## Branch Naming

- Format: `<type>/<PREFIX>-<n>-<slug>`
- Examples: `feat/AO-5-oauth-refresh`, `fix/AO-12-login-timeout`
- The `prepare-commit-msg` hook extracts the issue number from branch name automatically.

## Commit Format

```
[AO-n] type(scope): summary

Description (optional)

Refs #n | Closes #n | Fixes #n
```

- **Subject**: `[AO-n] type(scope): summary`
- **Scope** is optional: `[AO-n] type: summary` is also valid
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

Add `[PM]` to your prompt to activate issue-driven lifecycle mode.

### MODE 1 — Start (New Task)

`[pm] <task description>` — Fully automated from issue creation to commit/push.

```
① Create issue → ② Write plan doc → ③ Implement → ④ Verify → ⑤ Document result → ⑥ Commit → ⑦ Push + Close
```

Steps run continuously without stopping. Pauses only when user confirmation is required.

### MODE 2 — Closeout (Retrospective)

`[pm]` alone — Infers completed work from conversation context and processes retroactive documentation in bulk.

```
① Confirm/create issue → ② Reconstruct plan doc → ③ Write result/retrospective doc → ④ Update related docs → ⑤ issue-log result+close → ⑥ Commit + Push
```

### Mode Auto-Detection

| Condition | Mode |
|-----------|------|
| `[pm] <description>` + no active issue | MODE 1 (Start) |
| `[pm]` alone + work completed in conversation | MODE 2 (Closeout) |
| `[pm]` alone + work in progress | MODE 1 (Continue) |

Without `[PM]`, the agent executes directly with no issue tracking.

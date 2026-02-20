# Agent Rules

<!-- AIPM-ISSUE-OPS:BEGIN -->
## AIPM Issue Ops (Managed)

### `[PM]` Trigger

When `[PM]` (case-insensitive) is included in a prompt, the issue-based lifecycle is activated.
**Without `[PM]`, tasks are executed directly without issue tracking.**

#### MODE 1 — Start (New Task)
`[pm] <task description>` — Fully automated from issue creation to commit/push.
① Create issue → ② Write plan doc → ③ Implement → ④ Verify → ⑤ Document result → ⑥ Commit → ⑦ Push + Close
Each step runs continuously without stopping. Pause only when user confirmation is required.

#### MODE 2 — Closeout (Retrospective)
`[pm]` alone — Infers completed work from conversation context and processes retroactive documentation in bulk.
① Confirm/create issue → ② Reconstruct plan doc → ③ Write result/retrospective doc → ④ Update related docs → ⑤ issue-log result+close → ⑥ Commit + Push

#### Mode Auto-Detection
| Condition | Mode |
|-----------|------|
| `[pm] <description>` + no active issue | MODE 1 (Start) |
| `[pm]` alone + work completed in conversation | MODE 2 (Closeout) |
| `[pm]` alone + work in progress | MODE 1 (Continue) |

### Commit Format
- Subject: `[AO-<n>] <type>(<scope>): <summary>`
- Body: `Refs #<n>` or `Closes #<n>` or `Fixes #<n>`

### Quick Commands
- `./scripts/setup-labels.sh`
- `./scripts/issue-log.sh <issue> start`
- `./scripts/issue-log.sh <issue> progress`
- `./scripts/issue-log.sh <issue> result docs/result.md --close`
<!-- AIPM-ISSUE-OPS:END -->

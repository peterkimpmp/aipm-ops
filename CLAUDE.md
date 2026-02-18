# CLAUDE Rules

<!-- AIPM-ISSUE-OPS:BEGIN -->
## AIPM Issue Ops (Managed)

### `[PM]` Trigger
When a user prompt contains `[PM]` (case-insensitive), activate issue-driven lifecycle.
Auto-detect the current phase from context and execute the next step.
- `[PM] <description>` — Start or continue work on the described task.
- `[PM]` alone — Auto-advance to the next phase.
- Without `[PM]` — Execute directly, no issue tracking.

### Commit Format
- Subject: `[AOPS-<n>] <type>(<scope>): <summary>`
- Body: `Refs #<n>` or `Closes #<n>` or `Fixes #<n>`

### Branch Naming
- `<type>/<AOPS>-<n>-<slug>`

### Quick Commands
- `./scripts/setup-labels.sh`
- `./scripts/issue-log.sh <issue> start`
- `./scripts/issue-log.sh <issue> progress`
- `./scripts/issue-log.sh <issue> result docs/result.md --close`
<!-- AIPM-ISSUE-OPS:END -->


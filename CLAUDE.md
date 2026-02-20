# CLAUDE Rules

<!-- AIPM-ISSUE-OPS:BEGIN -->
## AIPM Issue Ops (Managed)

### `[PM]` Trigger

When `[PM]` (case-insensitive) is included in a prompt, the issue-based lifecycle is activated.
**Without `[PM]`, tasks are executed directly without issue tracking.**

#### MODE 1 — Work Initiation (START)
`[pm] <task description>` — Automatically complete the entire workflow from issue creation to commit/push **in one continuous run**.
① Issue creation + `issue-log start`
② Plan document + `issue-log plan`
③ Implementation/Execution + `issue-log progress`
④ Verification
⑤ Result documentation + `issue-log result`
⑥ Commit
⑦ Push + Close
Each stage runs continuously without stopping. **Calls to issue-log in ②③⑤ are mandatory** (for PR governance validation).

#### MODE 2 — Work Completion/Retrospective (CLOSEOUT)
`[pm]` alone — Identify completed work from the conversation and **batch process post-execution documentation**.
① Issue confirmation/creation → ② Plan document restructuring → ③ Result and retrospective documentation → ④ Update related docs → ⑤ issue-log result+close → ⑥ Commit + Push

#### Explicit Termination
`[pm] done` or `[pm] close` — Explicitly trigger MODE 2. Use instead of ambiguous auto-detection.

#### Mode Auto-Detection
| Condition | Mode |
|-----------|------|
| `[pm] <description>` + no active issue | MODE 1 (initiation) |
| `[pm] done` / `[pm] close` | MODE 2 (completion) |
| `[pm]` alone + completed work in conversation | MODE 2 (completion) |
| `[pm]` alone + work in progress | MODE 1 (continue) |

#### Status Check
`[AIPM-CHECK] #<issue-number>` — Report the current state, progress summary, and next action for the issue.

### Commit Format
- Subject: `[AO-<n>] <type>(<scope>): <summary>`
- Body: `Refs #<n>` or `Closes #<n>` or `Fixes #<n>`

### Quick Commands
- `./scripts/setup-labels.sh`
- `./scripts/issue-log.sh <issue> start`
- `./scripts/issue-log.sh <issue> plan`
- `./scripts/issue-log.sh <issue> progress`
- `./scripts/issue-log.sh <issue> result docs/result.md --close`
<!-- AIPM-ISSUE-OPS:END -->

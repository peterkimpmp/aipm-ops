# PM Mode Canonical

> Last updated: 2026-02-27
> Source of truth for `[pm]` operation in this repository.

## Trigger Semantics

- `[pm] <title>`: START
  - Create issue (`pm-start`)
  - Record required logs (`start`, `plan`, `progress`)
  - Create dedicated branch/worktree by default
- `[pm]`: SYNC checkpoint
  - If active issue exists: append `progress` and run sync check
  - If active issue does not exist: status/sync only (no new issue)
- `[pm] done` or `[pm] close`: CLOSEOUT
  - Require modernization evidence in the result document
  - Require merged PR linked to the issue by default
  - Close issue with `result` log
- `[pm] release [patch|minor|major]`: RELEASE
  - Standard release/milestone parity flow

Without `[pm]`, run in direct execution mode (no issue lifecycle automation).

## Script Mapping

- START:
  - `./scripts/pm-start.sh --title "<title>"`
  - Optional structured logs:
    - `--start-file <path>`
    - `--plan-file <path>`
    - `--progress-file <path>`
- CLOSEOUT:
  - `./scripts/pm-close.sh <issue> <result-file>`
  - Guard defaults:
    - merged PR required (`AIPM_PM_CLOSE_REQUIRE_MERGED_PR=1`)
    - worktree cleanup required (`AIPM_PM_CLOSE_CLEANUP_WORKTREE=1`)
    - modernization guard required (modernization marker + modernization flag)
  - Override only when explicitly needed:
    - `--no-require-merged-pr`
    - `--no-cleanup-worktree`
- SYNC/Audit:
  - `./scripts/pm-sync.sh`
- Audit:
  - `./scripts/check-pm-integrity.sh --state open --strict`

## Required Evidence

- START: non-placeholder body for `start/plan/progress`
- CLOSEOUT: `result` document includes modernization evidence
- Governance health: issue has exactly one `type:*` and one `status:*`

## Branch/Worktree Convention

- Branch format: `<type>/<PREFIX>-<issue>-<slug>`
  - Example: `feat/AIPM-117-pm-integrity-audit`
- Default worktree root: `.aipm/worktrees/`

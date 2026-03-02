# CLAUDE Rules

<!-- AIPM-ISSUE-OPS:BEGIN -->
## AIPM Issue Ops (Managed)

### `[PM]` Trigger

When a prompt contains `[PM]` (case-insensitive), enable issue-driven lifecycle automation.
**Without `[PM]`, execute directly without issue tracking.**

#### MODE 1 — START
`[pm] <work description>` starts the lifecycle automatically. (**no milestone/release creation**)
1. Create issue via `pm-start`
2. Record required logs: `issue-log start/plan/progress` (**placeholder bodies are not allowed**)
3. Create default branch/worktree (`<type>/<PREFIX>-<n>-<slug>`)

#### MODE 2 — CLOSEOUT
`[pm] done` or `[pm] close` runs explicit closeout.
1. Prepare result/retrospective document and update related docs
2. Verify linked PR is merged (required by default)
3. Run `pm-close` (modernization guard + `issue-log result --close`)

#### SYNC CHECKPOINT
`[pm]` alone runs sync checks for the current lifecycle state.
- If an active issue exists: run progress/sync checks
- If no active issue exists: run status/sync checks only (no new issue creation)

#### MODE 3 — RELEASE
`[pm] release [patch|minor|major]` runs standard tag/release automation (default: `patch`).
1. Compute latest version + bump (`patch`/`minor`/`major`)
2. Ensure matching milestone exists (create when missing)
3. Create/push tag
4. Generate release notes from the standard template
5. Run `gh release create/edit`
6. Assign release-range issues to the matching milestone
7. Verify release version == milestone version (1:1) + assignment parity
8. Optionally backfill historical releases (`./scripts/pm-release.sh --backfill-all`)

#### EXPLICIT CLOSE
`[pm] done` or `[pm] close` explicitly triggers MODE 2.

#### AUTO MODE DETECTION
| Condition | Mode |
|------|------|
| `[pm] <description>` + no active issue | MODE 1 (START) |
| `[pm] release [patch\|minor\|major]` | MODE 3 (RELEASE) |
| `[pm] done` / `[pm] close` | MODE 2 (CLOSEOUT) |
| `[pm]` alone + active issue exists | SYNC CHECKPOINT |
| `[pm]` alone + no active issue | status/sync check |

#### PM TRIGGER STANDARD MAPPING
- `[pm] <title>` → `./scripts/pm-start.sh --title "<title>"`
- `[pm]` → active-issue progress/sync checkpoint (`./scripts/pm-sync.sh` for manual audit)
- `[pm] done|close` → `./scripts/pm-close.sh <issue> <result-file>` (defaults: merged PR + worktree cleanup required)
- `[pm] release [patch|minor|major]` → `./scripts/pm-release.sh [patch|minor|major]`

#### ISSUE LABEL RULES (REQUIRED)
- `[PM]` issue creation must use `./scripts/issue-create.sh`.
- Forbidden: passing bare labels (`feature`, `epic`, `story`, `task`, `bug`, `chore`, `docs`, `refactor`) directly via `--label`.
- Standard label taxonomy: `type:*`, `status:*`, `priority:*`, `area:*`, `agent:*`.
- Defaults: `type:task` when type is omitted, `status:todo` when status is omitted.
- Multi-line bodies should use `--body-file` by default (`AIPM_ISSUE_BODY_MODE=file` in `.aipm/ops.env`).

| Title Prefix | Canonical Label |
|------|------|
| `[Epic]` | `type:epic` |
| `[Feature]` | `type:feature` |
| `[Story]` | `type:story` |
| `[Task]` | `type:task` |
| `[Bug]` | `type:bug` |
| `[Chore]` | `type:chore` |
| `[Docs]` | `type:docs` |
| `[Refactor]` | `type:refactor` |
| `[PRD]` | `type:prd` |
| `[Plan]` | `type:plan` |
| `[Result]` | `type:result` |

#### RELEASE NOTE STANDARD (REQUIRED)
- Release notes must include these fixed sections:
  - `## Highlights`
  - `## Changed by Type` (`Added/Changed/Fixed/Removed/Deprecated/Security`)
  - `## Compatibility`
  - `## Validation`
  - `## Links`
- Inferred statements for historical backfills must be marked explicitly.
- Parity scope is SemVer only (`vX.Y.Z`).
- Release version and milestone version must be 1:1.
- Any milestone with a release must have at least one assigned issue.
- Track progress through issue assignments (do not encode issue numbers in milestone description).
- Automation commands: `./scripts/pm-release.sh` (default patch), `./scripts/pm-release.sh patch|minor|major`.

#### STATUS CHECK
`[AIPM-CHECK] #<issue-number>` reports current state, progress summary, and next action.

### Commit Format
- Subject: `[AIPMOPS-<n>] <type>(<scope>): <summary>`
- Body: `Refs #<n>` or `Closes #<n>` or `Fixes #<n>`

### Quick Commands
- `./scripts/setup-labels.sh`
- `./scripts/issue-create.sh --title "[Task] ..." --body "..."`
- `./scripts/pm-start.sh --title "[Task] ..." --start-file docs/start.md --plan-file docs/plan.md --progress-file docs/progress.md`
- `./scripts/issue-log.sh <issue> start`
- `./scripts/issue-log.sh <issue> plan`
- `./scripts/issue-log.sh <issue> progress`
- `./scripts/pm-sync.sh`
- `./scripts/pm-modernize.sh --issue <issue> --result-file docs/result.md`
- `./scripts/pm-close.sh <issue> docs/result.md`
- `./scripts/check-pm-integrity.sh --state open --strict`
- `./scripts/pm-release.sh`
- `./scripts/pm-release.sh patch|minor|major`
- `./scripts/pm-release.sh --backfill-all --bootstrap-if-missing`
- `./scripts/check-release-milestone-parity.sh --strict`
<!-- AIPM-ISSUE-OPS:END -->

<!-- AIPM-RESEARCH-OPS:BEGIN -->
## AIPM Research Ops (Managed)

### `[research]` Trigger

When a prompt contains `[research]` (case-insensitive), enable research automation.
**Without `[research]`, handle it as normal conversation.**
`[research]` mode can optionally integrate issue/label/git operations.

#### URL Research
`[research] <URL1>, <URL2>, ...` or `[research] <URL1> <URL2> ...`
1. Detect URLs
2. Collect in parallel via sub-agents (4-step fallback)
3. Summarize each source
4. Produce cross-source insights
5. Generate an executive summary
6. Save `research/yyyymmdd-daily-<slug>.md`

#### Topic Research
`[research] <topic>` (topic only, no URL)
1. Detect topic intent
2. Run 3-5 WebSearch queries
3. Select top 3-5 source URLs
4. Join the URL research pipeline
-> Saves `research/yyyymmdd-daily-<slug>.md`

#### YouTube Research
`[research] youtube <topics>` or `[research] youtube <YouTube links>`
1. Auto-classify inputs (URL = link, non-URL = topic)
2. Topic mode: search YouTube Top 5 per topic and backfill with transcript-success videos to keep Top 5
3. Link mode: preserve original input links and record transcript failure reasons (no automatic replacement)
4. Save `research/yyyymmdd-youtube-<slug>.md` and create artifacts under `research/youtube/YYYY-MM-DD/<slug>/`

#### NotebookLM Research
`[research] notebooklm <topic>` runs NotebookLM deep research integrated into the daily report format.
-> Saves `research/yyyymmdd-nlm-<slug>.md` (with artifact appendix)

#### Spike Research
`[research] spike <topic>` performs web-search-based background research and creates a spike template document.
-> Saves `research/yyyymmdd-spike-<slug>.md`

#### Conversation Wrap-up
`[research] done` summarizes and saves the conversation as a research document.

#### 4-Step URL Collection Fallback
1. WebFetch → 2. `curl -sL -A '<browser-UA>'` → 3. Playwright MCP (`mcp__playwright`) → 4. WebSearch
Automatically advances to the next step on failure. Final WebSearch collects search snippets.

#### File Naming Rules
- Daily (URL/Topic): `research/yyyymmdd-daily-<slug>.md`
- YouTube: `research/yyyymmdd-youtube-<slug>.md`
- NotebookLM: `research/yyyymmdd-nlm-<slug>.md`
- Spike: `research/yyyymmdd-spike-<slug>.md`

#### Issue/Git Integration (`[research]` mode)
For `[research]` outputs, you can run these together:
1. Apply the `research` label to an issue
2. Add the research document link as an issue comment
3. Commit research artifacts (and push when needed)

#### Quick Commands
- `/research` — run research via slash command
- `./scripts/research-log.sh daily <slug>` — create a daily research file
- `./scripts/research-log.sh youtube <slug> --youtube-input "<topic or youtube-url>"` — create a YouTube research file
- `./scripts/research-log.sh spike <slug>` — create a spike research file
- `./scripts/research-log.sh nlm-flatten all` — flatten the `nlm` directory into single markdown files
- `./scripts/research-log.sh daily <slug> --issue <n> --push` — run `[research]` with issue/git integration
- `./scripts/research-log.sh daily <slug> --create-issue --issue-title "AI Agent Routing" --push` — auto-create an issue and integrate
<!-- AIPM-RESEARCH-OPS:END -->

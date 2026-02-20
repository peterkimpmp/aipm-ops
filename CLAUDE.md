# CLAUDE Rules

<!-- AIPM-ISSUE-OPS:BEGIN -->
## AIPM Issue Ops (Managed)

### `[PM]` Trigger

프롬프트에 `[PM]` (대소문자 무관)이 포함되면 이슈 기반 라이프사이클을 활성화한다.
**`[PM]` 없이 실행한 경우 이슈 추적 없이 직접 실행.**

#### MODE 1 — 작업 착수 (START)
`[pm] <작업 설명>` — 이슈 등록부터 commit/push까지 **전 과정을 한 번에 자동 완료**.
① 이슈 생성 → ② 계획 문서 작성 → ③ 구현/실행 → ④ 검증 → ⑤ 결과 문서화 → ⑥ 커밋 → ⑦ Push+Close
각 단계는 멈추지 않고 연속 실행. 사용자 확인이 필요한 경우에만 중단.

#### MODE 2 — 작업 종료/회고 (CLOSEOUT)
`[pm]` 단독 — 대화에서 완료된 작업을 파악해 **사후 문서화를 일괄 처리**.
① 이슈 확인/등록 → ② 계획 문서 재구성 → ③ 결과·회고 문서 작성 → ④ 관련 문서 현행화 → ⑤ issue-log result+close → ⑥ 커밋+Push

#### 모드 자동 판별
| 조건 | 모드 |
|------|------|
| `[pm] <설명>` + 활성 이슈 없음 | MODE 1 (착수) |
| `[pm]` 단독 + 작업 완료된 대화 | MODE 2 (종료) |
| `[pm]` 단독 + 작업 진행 중 | MODE 1 계속 |

### Commit Format
- Subject: `[AO-<n>] <type>(<scope>): <summary>`
- Body: `Refs #<n>` or `Closes #<n>` or `Fixes #<n>`

### Quick Commands
- `./scripts/setup-labels.sh`
- `./scripts/issue-log.sh <issue> start`
- `./scripts/issue-log.sh <issue> progress`
- `./scripts/issue-log.sh <issue> result docs/result.md --close`
<!-- AIPM-ISSUE-OPS:END -->


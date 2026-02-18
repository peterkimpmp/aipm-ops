#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

ensure_label() {
  local name="$1"
  local color="$2"
  local description="$3"

  if gh label create "$name" --repo "$repo" --color "$color" --description "$description" >/dev/null 2>&1; then
    echo "created: $name"
  else
    gh label edit "$name" --repo "$repo" --color "$color" --description "$description" >/dev/null
    echo "updated: $name"
  fi
}

ensure_label "area:aipm" "0e8a16" "AIPM project management scope"

ensure_label "type:prd" "5319e7" "PRD and requirements definition"
ensure_label "type:plan" "1d76db" "Execution planning"
ensure_label "type:task" "0052cc" "Normal execution task"
ensure_label "type:bug" "d73a4a" "Bug fix work"
ensure_label "type:chore" "6f42c1" "Maintenance work"
ensure_label "type:result" "fbca04" "Result and closure documentation"

ensure_label "status:todo" "cfd3d7" "Not started"
ensure_label "status:in-progress" "fbca04" "In progress"
ensure_label "status:blocked" "b60205" "Blocked"
ensure_label "status:review" "0e8a16" "In review"
ensure_label "status:done" "1d76db" "Completed"

ensure_label "priority:p0" "b60205" "Critical and urgent"
ensure_label "priority:p1" "d93f0b" "High priority"
ensure_label "priority:p2" "fbca04" "Medium priority"
ensure_label "priority:p3" "0e8a16" "Low priority"

ensure_label "agent:claude" "7c4dff" "Assign to Claude agent"
ensure_label "agent:codex" "00a67e" "Assign to Codex agent"
ensure_label "agent:auto" "ededed" "Auto-select agent backend"

echo "label setup complete for $repo"

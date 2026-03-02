#!/usr/bin/env bash
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

# ── type (hierarchical issue type) ───────────────────────────────────
ensure_label "type:epic"    "0075ca" "Large initiative bundle (multi-week to multi-month)"
ensure_label "type:feature" "a2eeef" "Single feature / PRD scope (1-3 sprints)"
ensure_label "type:story"   "d4edda" "User requirement slice (within one sprint)"
ensure_label "type:task"    "0052cc" "Concrete technical task (1-3 days)"
ensure_label "type:bug"     "d73a4a" "Bug fix"
ensure_label "type:chore"   "6f42c1" "Maintenance / configuration"
ensure_label "type:docs"    "0075ca" "Documentation work"
ensure_label "type:research" "5319e7" "Research and investigation"
ensure_label "type:refactor" "fbca04" "Refactoring"
# research shortcut label
ensure_label "research" "5319e7" "Research output tracking"
# legacy aliases (backward compatibility)
ensure_label "type:prd"    "5319e7" "PRD and requirements definition"
ensure_label "type:plan"   "1d76db" "Execution planning"
ensure_label "type:result" "fbca04" "Result and closure documentation"

# ── status ───────────────────────────────────────────────────────────
ensure_label "status:todo"        "cfd3d7" "Not started"
ensure_label "status:in-progress" "fbca04" "In progress"
ensure_label "status:blocked"     "b60205" "Blocked"
ensure_label "status:review"      "0e8a16" "In review"
ensure_label "status:done"        "1d76db" "Completed"
ensure_label "status:wont-fix"    "eeeeee" "Will not fix"
ensure_label "status:duplicate"   "cfd3d7" "Duplicate issue"

# ── priority ─────────────────────────────────────────────────────────
ensure_label "priority:p0" "b60205" "Critical — address immediately"
ensure_label "priority:p1" "d93f0b" "High — target current sprint"
ensure_label "priority:p2" "fbca04" "Medium — target next sprint"
ensure_label "priority:p3" "0e8a16" "Low — when capacity allows"

# ── area (work domain) ────────────────────────────────────────────────
ensure_label "area:backend"   "0e8a16" "Backend"
ensure_label "area:frontend"  "0e8a16" "Frontend"
ensure_label "area:infra"     "0e8a16" "Infrastructure / DevOps"
ensure_label "area:database"  "0e8a16" "Database"
ensure_label "area:api"       "0e8a16" "API design"
ensure_label "area:ai-agent"  "0e8a16" "AI agent / LLM"
ensure_label "area:security"  "0e8a16" "Security"
ensure_label "area:ux"        "0e8a16" "UX / Design"
ensure_label "area:docs"      "0e8a16" "Documentation"
ensure_label "area:aipm"      "0e8a16" "AIPM project management scope"

# ── agent ─────────────────────────────────────────────────────────────
ensure_label "agent:claude" "7c4dff" "Assign to Claude agent"
ensure_label "agent:codex"  "00a67e" "Assign to Codex agent"
ensure_label "agent:auto"   "ededed" "Auto-select agent backend"

echo "label setup complete for $repo"

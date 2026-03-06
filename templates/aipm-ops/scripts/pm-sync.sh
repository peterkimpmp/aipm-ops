#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-sync.sh [--repo <owner/repo>] [--issue <n>] [--json]

Description:
  Reports PM lifecycle sync state for the active issue or the most recent open issue
  that already has START/PLAN/PROGRESS comments.
USAGE
}

repo=""
issue_number=""
json_output=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --issue)
      issue_number="$2"
      shift 2
      ;;
    --json)
      json_output=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pm-state.sh
source "$script_dir/pm-state.sh"

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

active_json=""
issue_json=""
source_mode="none"

if [[ -n "$issue_number" ]]; then
  issue_json="$(gh issue view "$issue_number" --repo "$repo" --json number,title,state,url,labels,comments)"
  source_mode="explicit"
elif active_json="$(pm_read_active_json 2>/dev/null || true)"; [[ -n "$active_json" ]]; then
  issue_number="$(jq -r '.issue' <<<"$active_json")"
  issue_json="$(gh issue view "$issue_number" --repo "$repo" --json number,title,state,url,labels,comments)"
  source_mode="active"
else
  issue_json="$(pm_find_recent_issue_from_comments "$repo" 30 || true)"
  if [[ -n "$issue_json" ]]; then
    issue_number="$(jq -r '.number' <<<"$issue_json")"
    source_mode="discovered"
  fi
fi

if [[ -z "$issue_json" ]]; then
  if [[ "$json_output" -eq 1 ]]; then
    jq -n --arg repo "$repo" '{
      repo: $repo,
      source: "none",
      state: "attention",
      next_action: "Start with [pm] <title>.",
      checks: { active_issue: false }
    }'
  else
    echo "state=attention"
    echo "source=none"
    echo "next_action=Start with [pm] <title>."
  fi
  exit 0
fi

issue_state="$(jq -r '.state | ascii_downcase' <<<"$issue_json")"
title="$(jq -r '.title' <<<"$issue_json")"
issue_url="$(jq -r '.url' <<<"$issue_json")"
status_labels="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("status:"))] | join(",")' <<<"$issue_json")"
type_labels="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("type:"))] | join(",")' <<<"$issue_json")"
status_count="$(jq '[.labels[].name | ascii_downcase | select(startswith("status:"))] | length' <<<"$issue_json")"
type_count="$(jq '[.labels[].name | ascii_downcase | select(startswith("type:"))] | length' <<<"$issue_json")"
has_start="$(jq '[.comments[].body | select(test("^### START \\| "; "m"))] | length > 0' <<<"$issue_json")"
has_plan="$(jq '[.comments[].body | select(test("^### PLAN \\| "; "m"))] | length > 0' <<<"$issue_json")"
has_progress="$(jq '[.comments[].body | select(test("^### PROGRESS \\| "; "m"))] | length > 0' <<<"$issue_json")"

branch_name=""
worktree_path=""
result_file=""
active_present=0
if [[ -n "$active_json" ]]; then
  active_present=1
  branch_name="$(jq -r '.branch // ""' <<<"$active_json")"
  worktree_path="$(jq -r '.worktree // ""' <<<"$active_json")"
  result_file="$(jq -r '.result_file // ""' <<<"$active_json")"
fi
if [[ -z "$result_file" ]]; then
  result_file="$(pm_default_result_file "$issue_number" "$title")"
fi

branch_exists=0
worktree_exists=0
result_exists=0
merged_pr=0
modernized=0
if [[ -n "$branch_name" ]] && git show-ref --verify --quiet "refs/heads/$branch_name"; then
  branch_exists=1
fi
if [[ -n "$worktree_path" ]] && [[ -d "$worktree_path" ]]; then
  worktree_exists=1
fi
if [[ -f "$result_file" ]]; then
  result_exists=1
fi
if gh pr list --repo "$repo" --state merged --search "#$issue_number" --limit 30 --json number | jq -e 'length > 0' >/dev/null; then
  merged_pr=1
fi
if [[ -f "$(pm_state_dir)/modernized-${issue_number}.flag" ]]; then
  modernized=1
fi

summary_state="healthy"
next_action="Continue implementation."
blockers=()

if [[ "$issue_state" != "open" ]]; then
  summary_state="blocked"
  blockers+=("issue_not_open")
  next_action="Clear stale active issue state or start a new PM task."
fi
if [[ "$status_count" -ne 1 || "$type_count" -ne 1 ]]; then
  if [[ "$summary_state" == "healthy" ]]; then
    summary_state="attention"
  fi
  blockers+=("label_integrity")
  next_action="Run ./scripts/check-pm-integrity.sh --fix-active or repair labels."
fi
if [[ "$has_start" != "true" || "$has_plan" != "true" || "$has_progress" != "true" ]]; then
  if [[ "$summary_state" == "healthy" ]]; then
    summary_state="attention"
  fi
  blockers+=("phase_logs_missing")
  next_action="Post missing START/PLAN/PROGRESS logs."
fi
if [[ "$active_present" -eq 1 && ( "$branch_exists" -ne 1 || "$worktree_exists" -ne 1 ) ]]; then
  summary_state="blocked"
  blockers+=("branch_or_worktree_missing")
  next_action="Restore the tracked worktree/branch or refresh active state."
fi
if [[ "$result_exists" -eq 1 && "$merged_pr" -ne 1 ]]; then
  if [[ "$summary_state" == "healthy" ]]; then
    summary_state="attention"
  fi
  blockers+=("pr_not_merged")
  next_action="Run [pm] close to land the branch and close the issue."
fi
if [[ "$result_exists" -eq 1 && "$merged_pr" -eq 1 && "$modernized" -ne 1 ]]; then
  if [[ "$summary_state" == "healthy" ]]; then
    summary_state="attention"
  fi
  blockers+=("ready_to_close")
  next_action="Run [pm] done or ./scripts/pm-close.sh --from-active --yes."
fi

if [[ "$json_output" -eq 1 ]]; then
  jq -n \
    --arg repo "$repo" \
    --arg source "$source_mode" \
    --arg state "$summary_state" \
    --arg next_action "$next_action" \
    --argjson issue "$issue_number" \
    --arg title "$title" \
    --arg url "$issue_url" \
    --arg issue_state "$issue_state" \
    --arg status_labels "$status_labels" \
    --arg type_labels "$type_labels" \
    --arg branch "$branch_name" \
    --arg worktree "$worktree_path" \
    --arg result_file "$result_file" \
    --argjson active_issue "$( [[ "$active_present" -eq 1 ]] && echo true || echo false )" \
    --argjson branch_exists "$( [[ "$branch_exists" -eq 1 ]] && echo true || echo false )" \
    --argjson worktree_exists "$( [[ "$worktree_exists" -eq 1 ]] && echo true || echo false )" \
    --argjson result_exists "$( [[ "$result_exists" -eq 1 ]] && echo true || echo false )" \
    --argjson merged_pr "$( [[ "$merged_pr" -eq 1 ]] && echo true || echo false )" \
    --argjson modernized "$( [[ "$modernized" -eq 1 ]] && echo true || echo false )" \
    --argjson has_start "$has_start" \
    --argjson has_plan "$has_plan" \
    --argjson has_progress "$has_progress" \
    --argjson blockers "$(printf '%s\n' "${blockers[@]-}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
    '{
      repo: $repo,
      source: $source,
      state: $state,
      next_action: $next_action,
      issue: {
        number: $issue,
        title: $title,
        state: $issue_state,
        url: $url
      },
      checks: {
        active_issue: $active_issue,
        status_labels: $status_labels,
        type_labels: $type_labels,
        has_start: $has_start,
        has_plan: $has_plan,
        has_progress: $has_progress,
        branch: $branch,
        branch_exists: $branch_exists,
        worktree: $worktree,
        worktree_exists: $worktree_exists,
        result_file: $result_file,
        result_exists: $result_exists,
        merged_pr: $merged_pr,
        modernized: $modernized
      },
      blockers: $blockers
    }'
else
  echo "state=$summary_state"
  echo "source=$source_mode"
  echo "issue=$issue_number"
  echo "title=$title"
  echo "next_action=$next_action"
  echo "checks:"
  echo "- status_labels=${status_labels:-<none>}"
  echo "- type_labels=${type_labels:-<none>}"
  echo "- start=$has_start plan=$has_plan progress=$has_progress"
  echo "- branch=${branch_name:-<none>} exists=$branch_exists"
  echo "- worktree=${worktree_path:-<none>} exists=$worktree_exists"
  echo "- result_file=$result_file exists=$result_exists"
  echo "- merged_pr=$merged_pr modernized=$modernized"
  if [[ "${#blockers[@]}" -gt 0 ]]; then
    echo "blockers=${blockers[*]}"
  else
    echo "blockers=none"
  fi
fi

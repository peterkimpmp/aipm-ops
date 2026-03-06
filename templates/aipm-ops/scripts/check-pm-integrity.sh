#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/check-pm-integrity.sh [--repo <owner/repo>] [--state <open|closed|all>] [--limit <n>] [--json] [--strict] [--fix-active]

Description:
  Audits issue label integrity for PM lifecycle governance.
  - exactly one type:* label per issue
  - exactly one status:* label per issue
  - status/type labels must be canonical labels
  - open issue must not use terminal status (done/wont-fix/duplicate)
  - closed issue should use terminal status

Options:
  --repo <owner/repo>     Target repository (default: current gh repo)
  --state <value>         open | closed | all (default: open)
  --limit <n>             Max issues to fetch via gh issue list (default: 500)
  --json                  Print machine-readable JSON
  --strict                Exit 2 when violations are found

Examples:
  ./scripts/check-pm-integrity.sh
  ./scripts/check-pm-integrity.sh --state all --strict
  ./scripts/check-pm-integrity.sh --repo owner/repo --json
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

contains() {
  local needle="$1"
  shift || true
  local item=""
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

repo=""
state="open"
limit="500"
json=0
strict=0
fix_active=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -lt 2 ]] && { echo "error: --repo requires a value" >&2; exit 1; }
      repo="$2"
      shift 2
      ;;
    --state)
      [[ $# -lt 2 ]] && { echo "error: --state requires a value" >&2; exit 1; }
      state="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    --limit)
      [[ $# -lt 2 ]] && { echo "error: --limit requires a value" >&2; exit 1; }
      limit="$2"
      shift 2
      ;;
    --json)
      json=1
      shift
      ;;
    --strict)
      strict=1
      shift
      ;;
    --fix-active)
      fix_active=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$state" in
  open|closed|all) ;;
  *)
    echo "error: --state must be one of: open, closed, all" >&2
    exit 1
    ;;
esac

if [[ ! "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]]; then
  echo "error: --limit must be a positive integer" >&2
  exit 1
fi

require_cmd gh
require_cmd jq

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pm-state.sh
source "$script_dir/pm-state.sh"

if [[ "$fix_active" -eq 1 ]]; then
  active_issue="$(pm_read_active_field issue 2>/dev/null || true)"
  if [[ -n "$active_issue" ]]; then
    active_json="$(gh issue view "$active_issue" --repo "$repo" --json number,title,state,labels)"
    active_title="$(jq -r '.title' <<<"$active_json")"
    active_state="$(jq -r '.state | ascii_downcase' <<<"$active_json")"
    active_status_count="$(jq '[.labels[].name | ascii_downcase | select(startswith("status:"))] | length' <<<"$active_json")"
    active_type_count="$(jq '[.labels[].name | ascii_downcase | select(startswith("type:"))] | length' <<<"$active_json")"
    if [[ "$active_type_count" -eq 0 ]]; then
      pm_add_type_label_if_missing "$repo" "$active_issue" "$active_title"
    fi
    if [[ "$active_state" == "open" && "$active_status_count" -eq 0 ]]; then
      pm_set_issue_status_label "$repo" "$active_issue" "status:in-progress"
    fi
    if [[ "$active_state" == "closed" && "$active_status_count" -eq 0 ]]; then
      pm_set_issue_status_label "$repo" "$active_issue" "status:done"
    fi
  fi
fi

issues_json="$(gh issue list --repo "$repo" --state "$state" --limit "$limit" --json number,title,state,url,labels)"
issue_count="$(jq 'length' <<<"$issues_json")"

allowed_statuses=(
  "status:todo"
  "status:in-progress"
  "status:blocked"
  "status:review"
  "status:done"
  "status:wont-fix"
  "status:duplicate"
)
terminal_statuses=(
  "status:done"
  "status:wont-fix"
  "status:duplicate"
)
allowed_types=(
  "type:epic"
  "type:feature"
  "type:story"
  "type:task"
  "type:bug"
  "type:chore"
  "type:docs"
  "type:research"
  "type:refactor"
  "type:prd"
  "type:plan"
  "type:result"
)

violation_count=0
violations_json='[]'

add_violation() {
  local issue_number="$1"
  local issue_state="$2"
  local issue_url="$3"
  local code="$4"
  local message="$5"
  violation_count=$((violation_count + 1))
  violations_json="$(jq -c \
    --argjson issue "$issue_number" \
    --arg state "$issue_state" \
    --arg url "$issue_url" \
    --arg code "$code" \
    --arg message "$message" \
    '. + [{issue:$issue, state:$state, code:$code, message:$message, url:$url}]' \
    <<<"$violations_json")"
}

while IFS= read -r issue; do
  [[ -z "$issue" ]] && continue

  issue_number="$(jq -r '.number' <<<"$issue")"
  issue_state="$(jq -r '.state | ascii_downcase' <<<"$issue")"
  issue_url="$(jq -r '.url' <<<"$issue")"

  status_count="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("status:"))] | length' <<<"$issue")"
  type_count="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("type:"))] | length' <<<"$issue")"
  status_join="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("status:"))] | join(",")' <<<"$issue")"
  type_join="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("type:"))] | join(",")' <<<"$issue")"
  single_status="$(jq -r '[.labels[].name | ascii_downcase | select(startswith("status:"))] | if length==1 then .[0] else "" end' <<<"$issue")"

  if [[ "$status_count" -eq 0 ]]; then
    add_violation "$issue_number" "$issue_state" "$issue_url" "missing_status_label" "missing status:* label"
  elif [[ "$status_count" -gt 1 ]]; then
    add_violation "$issue_number" "$issue_state" "$issue_url" "multiple_status_labels" "multiple status labels: $status_join"
  fi

  if [[ "$type_count" -eq 0 ]]; then
    add_violation "$issue_number" "$issue_state" "$issue_url" "missing_type_label" "missing type:* label"
  elif [[ "$type_count" -gt 1 ]]; then
    add_violation "$issue_number" "$issue_state" "$issue_url" "multiple_type_labels" "multiple type labels: $type_join"
  fi

  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    if ! contains "$label" "${allowed_statuses[@]}"; then
      add_violation "$issue_number" "$issue_state" "$issue_url" "unknown_status_label" "unknown status label: $label"
    fi
  done <<EOF
$(printf '%s' "$status_join" | tr ',' '\n')
EOF

  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    if ! contains "$label" "${allowed_types[@]}"; then
      add_violation "$issue_number" "$issue_state" "$issue_url" "unknown_type_label" "unknown type label: $label"
    fi
  done <<EOF
$(printf '%s' "$type_join" | tr ',' '\n')
EOF

  if [[ -n "$single_status" ]]; then
    if [[ "$issue_state" == "open" ]] && contains "$single_status" "${terminal_statuses[@]}"; then
      add_violation "$issue_number" "$issue_state" "$issue_url" "open_with_terminal_status" "open issue has terminal status: $single_status"
    fi
    if [[ "$issue_state" == "closed" ]] && ! contains "$single_status" "${terminal_statuses[@]}"; then
      add_violation "$issue_number" "$issue_state" "$issue_url" "closed_with_non_terminal_status" "closed issue should use terminal status: $single_status"
    fi
  fi
done < <(jq -c '.[]' <<<"$issues_json")

if [[ "$json" -eq 1 ]]; then
  jq -n \
    --arg repo "$repo" \
    --arg state "$state" \
    --argjson issues_checked "$issue_count" \
    --argjson violations "$violations_json" \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      repo: $repo,
      state: $state,
      issues_checked: $issues_checked,
      violation_count: ($violations | length),
      violations: $violations,
      generated_at: $generated_at
    }'
else
  echo "repo=$repo"
  echo "state=$state"
  echo "issues_checked=$issue_count"
  echo "violations=$violation_count"
  if [[ "$violation_count" -gt 0 ]]; then
    jq -r '.[] | "- #\(.issue) [\(.code)] \(.message) (\(.url))"' <<<"$violations_json"
  else
    echo "details=none"
  fi
fi

if [[ "$strict" -eq 1 && "$violation_count" -gt 0 ]]; then
  exit 2
fi

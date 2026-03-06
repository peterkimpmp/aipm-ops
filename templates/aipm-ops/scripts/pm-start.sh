#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-start.sh --title "<title>" [--body "<text>" | --body-file <path>] [--label <name>]... [--repo <owner/repo>] [--start-file <path>] [--plan-file <path>] [--progress-file <path>] [--branch <name>] [--worktree <path>] [--base <branch>] [--no-worktree] [--budget-mode <warn|enforce|off>] [--budget-threshold <n>] [--force-budget] [--dry-run]

Description:
  Standardized MODE 1 start flow for [pm] <title>.
  - Creates issue via issue-create.sh
  - Writes required logs: start -> plan -> progress
  - Creates a dedicated branch/worktree by default
  - Does not create milestone/release

Examples:
  ./scripts/pm-start.sh --title "[Task] Normalize PM mode docs" --label area:aipm --body "Goal and done criteria"
  ./scripts/pm-start.sh --title "[Feature] Add PM start wrapper" --start-file docs/start.md --plan-file docs/plan.md --progress-file docs/progress.md
  ./scripts/pm-start.sh --title "[Bug] Fix release note parser" --no-worktree
  ./scripts/pm-start.sh --title "[Feature] Full pipeline automation" --budget-mode enforce
  ./scripts/pm-start.sh --title "[Task] Full pipeline automation" --budget-mode enforce --force-budget
USAGE
}

slugify() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*\[[^]]+\][[:space:]]*//')"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$value" ]]; then
    value="work"
  fi
  printf '%s' "$value"
}

infer_branch_type_from_title() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    "[bug]"*) echo "fix" ;;
    "[task]"*|"[test]"*) echo "task" ;;
    "[docs]"*) echo "docs" ;;
    "[chore]"*) echo "chore" ;;
    "[refactor]"*) echo "refactor" ;;
    *) echo "feat" ;;
  esac
}

normalize_path() {
  local value="$1"
  local root="$2"
  if [[ "$value" = /* ]]; then
    printf '%s' "$value"
  else
    printf '%s/%s' "$root" "$value"
  fi
}

compute_scope_score() {
  local text="$1"
  local score=0
  local chars=${#text}

  if [[ "$chars" -ge 1200 ]]; then
    score=$((score + 3))
  elif [[ "$chars" -ge 700 ]]; then
    score=$((score + 2))
  elif [[ "$chars" -ge 350 ]]; then
    score=$((score + 1))
  fi

  if printf '%s' "$text" | grep -Eqi '\b(parallel|pipeline|orchestr|multi[- ]?phase|end[- ]to[- ]end|full)\b'; then
    score=$((score + 3))
  fi
  if printf '%s' "$text" | grep -Eqi '(병렬|파이프라인|오케스트|멀티|전 단계|전체 실행|엔드투엔드|풀런)'; then
    score=$((score + 2))
  fi
  if printf '%s' "$text" | grep -Eqi '\b(phase|stage|agent|subagent|sub-agent|swarm)\b'; then
    score=$((score + 2))
  fi
  if printf '%s' "$text" | grep -Eqi '(phase|stage|에이전트|서브에이전트|스웜)'; then
    score=$((score + 1))
  fi

  printf '%s' "$score"
}

run_budget_preflight() {
  local title_val="$1"
  local body_val="$2"
  local mode_val="$3"
  local threshold_val="$4"
  local force_val="$5"
  local combined=""
  local scope_score=0

  if [[ "$mode_val" == "off" ]]; then
    return 0
  fi

  combined="$title_val"$'\n'"$body_val"
  scope_score="$(compute_scope_score "$combined")"

  if [[ "$scope_score" -lt "$threshold_val" ]]; then
    return 0
  fi

  echo "[budget] scope-score=$scope_score (threshold=$threshold_val, mode=$mode_val)"
  echo "[budget] large-scope work detected. Prefer a split session or explicit checkpointing."

  if [[ "$mode_val" == "enforce" && "$force_val" -ne 1 ]]; then
    echo "error: budget preflight blocked this start request." >&2
    echo "hint: reduce scope or bypass explicitly with --force-budget." >&2
    exit 2
  fi
}

resolve_start_point() {
  local base="$1"
  if git show-ref --verify --quiet "refs/remotes/origin/$base"; then
    printf '%s' "origin/$base"
    return 0
  fi
  if git show-ref --verify --quiet "refs/heads/$base"; then
    printf '%s' "$base"
    return 0
  fi
  if git rev-parse --verify --quiet "$base" >/dev/null; then
    printf '%s' "$base"
    return 0
  fi
  return 1
}

find_worktree_for_branch() {
  local target_branch="$1"
  local current_path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      branch\ refs/heads/*)
        local branch_name="${line#branch refs/heads/}"
        if [[ "$branch_name" == "$target_branch" ]]; then
          printf '%s' "$current_path"
          return 0
        fi
        ;;
      "")
        current_path=""
        ;;
    esac
  done < <(git worktree list --porcelain)
  return 1
}

title=""
body=""
body_file=""
repo=""
dry_run=0
create_worktree=1
branch_name=""
worktree_path=""
base_branch="${AIPM_PM_BASE_BRANCH:-main}"
start_file=""
plan_file=""
progress_file=""
budget_mode="${AIPM_PM_BUDGET_MODE:-warn}"
budget_threshold="${AIPM_PM_BUDGET_THRESHOLD:-7}"
force_budget=0
labels=()
tmp_files=()

cleanup_tmp_files() {
  local file
  for file in "${tmp_files[@]-}"; do
    if [[ -n "$file" && -f "$file" ]]; then
      rm -f "$file"
    fi
  done
  return 0
}

trap cleanup_tmp_files EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ $# -lt 2 ]] && { echo "error: --title requires a value" >&2; exit 1; }
      title="$2"
      shift 2
      ;;
    --body)
      [[ $# -lt 2 ]] && { echo "error: --body requires a value" >&2; exit 1; }
      body="$2"
      shift 2
      ;;
    --body-file)
      [[ $# -lt 2 ]] && { echo "error: --body-file requires a value" >&2; exit 1; }
      body_file="$2"
      shift 2
      ;;
    --label)
      [[ $# -lt 2 ]] && { echo "error: --label requires a value" >&2; exit 1; }
      labels+=("$2")
      shift 2
      ;;
    --repo)
      [[ $# -lt 2 ]] && { echo "error: --repo requires a value" >&2; exit 1; }
      repo="$2"
      shift 2
      ;;
    --start-file)
      [[ $# -lt 2 ]] && { echo "error: --start-file requires a value" >&2; exit 1; }
      start_file="$2"
      shift 2
      ;;
    --plan-file)
      [[ $# -lt 2 ]] && { echo "error: --plan-file requires a value" >&2; exit 1; }
      plan_file="$2"
      shift 2
      ;;
    --progress-file)
      [[ $# -lt 2 ]] && { echo "error: --progress-file requires a value" >&2; exit 1; }
      progress_file="$2"
      shift 2
      ;;
    --branch)
      [[ $# -lt 2 ]] && { echo "error: --branch requires a value" >&2; exit 1; }
      branch_name="$2"
      shift 2
      ;;
    --worktree)
      [[ $# -lt 2 ]] && { echo "error: --worktree requires a value" >&2; exit 1; }
      worktree_path="$2"
      shift 2
      ;;
    --base)
      [[ $# -lt 2 ]] && { echo "error: --base requires a value" >&2; exit 1; }
      base_branch="$2"
      shift 2
      ;;
    --no-worktree)
      create_worktree=0
      shift
      ;;
    --budget-mode)
      [[ $# -lt 2 ]] && { echo "error: --budget-mode requires a value" >&2; exit 1; }
      budget_mode="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    --budget-threshold)
      [[ $# -lt 2 ]] && { echo "error: --budget-threshold requires a value" >&2; exit 1; }
      budget_threshold="$2"
      shift 2
      ;;
    --force-budget)
      force_budget=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$title" ]]; then
        title="$1"
        shift
      else
        echo "error: unknown argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$title" ]]; then
  echo "error: --title is required" >&2
  usage
  exit 1
fi

if [[ -n "$body" && -n "$body_file" ]]; then
  echo "error: use either --body or --body-file, not both" >&2
  exit 1
fi

if [[ -n "$body_file" && "$body_file" != "-" && ! -f "$body_file" ]]; then
  echo "error: body file not found: $body_file" >&2
  exit 1
fi

case "$budget_mode" in
  warn|enforce|off) ;;
  *)
    echo "error: --budget-mode must be one of: warn, enforce, off" >&2
    exit 1
    ;;
esac

if [[ ! "$budget_threshold" =~ ^[0-9]+$ ]] || [[ "$budget_threshold" -lt 1 ]]; then
  echo "error: --budget-threshold must be a positive integer" >&2
  exit 1
fi

for phase_file in "$start_file" "$plan_file" "$progress_file"; do
  if [[ -n "$phase_file" && "$phase_file" != "-" && ! -f "$phase_file" ]]; then
    echo "error: phase file not found: $phase_file" >&2
    exit 1
  fi
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pm-state.sh
source "$script_dir/pm-state.sh"

preflight_body=""
if [[ -n "$body" ]]; then
  preflight_body="$body"
elif [[ -n "$body_file" ]]; then
  if [[ "$body_file" == "-" ]]; then
    preflight_body=""
  else
    preflight_body="$(cat "$body_file")"
  fi
fi

run_budget_preflight "$title" "$preflight_body" "$budget_mode" "$budget_threshold" "$force_budget"

create_cmd=("$script_dir/issue-create.sh" --title "$title")
if [[ -n "$body" ]]; then
  create_cmd+=(--body "$body")
fi
if [[ -n "$body_file" ]]; then
  create_cmd+=(--body-file "$body_file")
fi
for label in "${labels[@]-}"; do
  if [[ "$label" != status:* ]]; then
    create_cmd+=(--label "$label")
  fi
done
create_cmd+=(--label "status:in-progress")
if [[ -n "$repo" ]]; then
  create_cmd+=(--repo "$repo")
fi
if [[ "$dry_run" -eq 1 ]]; then
  create_cmd+=(--dry-run)
  "${create_cmd[@]}"
  echo "[dry-run] issue-log start/plan/progress skipped (issue not created)."
  if [[ "$create_worktree" -eq 1 ]]; then
    echo "[dry-run] branch/worktree setup skipped (issue number unavailable in dry-run)."
  fi
  exit 0
fi

issue_output="$("${create_cmd[@]}")"
printf '%s\n' "$issue_output"

issue_url="$(printf '%s\n' "$issue_output" | rg -o 'https://github\.com/[^ ]+/issues/[0-9]+' | tail -n 1 || true)"
if [[ -z "$issue_url" ]]; then
  echo "error: failed to parse issue URL from issue-create output." >&2
  exit 1
fi

issue_number="${issue_url##*/}"
if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
  echo "error: failed to parse issue number from URL: $issue_url" >&2
  exit 1
fi

issue_key_prefix="AIPM"
if [[ -f ".aipm/ops.env" ]]; then
  # shellcheck disable=SC1091
  source ".aipm/ops.env"
fi
issue_key_prefix="${ISSUE_KEY_PREFIX:-$issue_key_prefix}"
issue_key="${issue_key_prefix}-${issue_number}"
issue_repo="$repo"
if [[ -z "$issue_repo" ]]; then
  issue_repo="${issue_url#https://github.com/}"
  issue_repo="${issue_repo%/issues/*}"
fi
pm_set_issue_status_label "$issue_repo" "$issue_number" "status:in-progress"

create_default_phase_file() {
  local phase="$1"
  local file
  file="$(mktemp)"
  tmp_files+=("$file")
  case "$phase" in
    start)
      cat > "$file" <<EOF
- Scope:
  - $title
- Intent Contract:
  - Execution Mode: implement-now
  - Deliverable Interpretation: rendered artifacts (PDF/ePub/build outputs) unless explicitly stated otherwise
- Assumptions:
  - TBD
- Done Criteria:
  - TBD
EOF
      ;;
    plan)
      cat > "$file" <<'EOF'
- Requirements:
  - TBD
- Execution Plan:
  - TBD
- Verification:
  - TBD
EOF
      ;;
    progress)
      cat > "$file" <<'EOF'
- Changed:
  - TBD
- Blockers:
  - none
- Next Step:
  - TBD
EOF
      ;;
    *)
      echo "error: unsupported phase for default body: $phase" >&2
      exit 1
      ;;
  esac
  printf '%s' "$file"
}

run_issue_log_phase() {
  local phase="$1"
  local phase_file="$2"
  if [[ -z "$phase_file" ]]; then
    phase_file="$(create_default_phase_file "$phase")"
  fi
  if [[ -n "$repo" ]]; then
    AIPM_REPO="$repo" "$script_dir/issue-log.sh" "$issue_number" "$phase" "$phase_file"
  else
    "$script_dir/issue-log.sh" "$issue_number" "$phase" "$phase_file"
  fi
}

run_issue_log_phase start "$start_file"
run_issue_log_phase plan "$plan_file"
run_issue_log_phase progress "$progress_file"

if [[ "$create_worktree" -eq 1 ]]; then
  if [[ -z "$branch_name" ]]; then
    branch_type="$(infer_branch_type_from_title "$title")"
    branch_slug="$(slugify "$title")"
    branch_name="${branch_type}/${issue_key}-${branch_slug}"
  fi

  if [[ -z "$worktree_path" ]]; then
    worktree_root="${AIPM_WORKTREE_ROOT:-$repo_root/.aipm/worktrees}"
    mkdir -p "$worktree_root"
    worktree_path="${worktree_root}/${branch_name//\//-}"
  fi
  worktree_path="$(normalize_path "$worktree_path" "$repo_root")"

  existing_worktree_path="$(find_worktree_for_branch "$branch_name" || true)"
  if [[ -n "$existing_worktree_path" ]]; then
    worktree_path="$existing_worktree_path"
    echo "[info] branch already has worktree: $worktree_path"
  else
    if [[ -e "$worktree_path" ]]; then
      echo "error: worktree path already exists: $worktree_path" >&2
      exit 1
    fi

    if ! start_point="$(resolve_start_point "$base_branch")"; then
      echo "error: base branch not found: $base_branch" >&2
      exit 1
    fi

    if ! git show-ref --verify --quiet "refs/heads/$branch_name" && git show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
      git branch --track "$branch_name" "origin/$branch_name" >/dev/null 2>&1 || true
    fi

    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      git worktree add "$worktree_path" "$branch_name"
    else
      git worktree add -b "$branch_name" "$worktree_path" "$start_point"
    fi
  fi
fi

result_file="$(pm_default_result_file "$issue_number" "$title")"
started_at="$(pm_iso_now)"
pm_write_active_issue_state \
  "$issue_number" \
  "$title" \
  "$branch_name" \
  "$worktree_path" \
  "$issue_repo" \
  "${start_file:-}" \
  "${plan_file:-}" \
  "${progress_file:-}" \
  "$result_file" \
  "in_progress" \
  "$started_at"

echo "[ok] PM start completed for issue #$issue_number"
echo "issue_url=$issue_url"
echo "active_state=$(pm_active_issue_file)"
echo "result_file=$result_file"
if [[ "$create_worktree" -eq 1 ]]; then
  echo "branch=$branch_name"
  echo "worktree_path=$worktree_path"
  echo "next=cd \"$worktree_path\""
fi

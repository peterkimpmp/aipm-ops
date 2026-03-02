#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-start.sh --title "<title>" [--body "<text>" | --body-file <path>] [--label <name>]... [--repo <owner/repo>] [--start-file <path>] [--plan-file <path>] [--progress-file <path>] [--branch <name>] [--worktree <path>] [--base <branch>] [--no-worktree] [--dry-run]

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

write_pm_state() {
  local state_dir="$1"
  local issue_number_val="$2"
  local issue_key_val="$3"
  local branch_val="$4"
  local worktree_val="$5"
  local create_worktree_val="$6"
  local base_branch_val="$7"
  local repo_root_val="$8"
  local repo_val="$9"
  local timestamp

  mkdir -p "$state_dir"
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  cat > "${state_dir}/pm-issue-${issue_number_val}.env" <<EOF
# Managed by AIPM PM Start
issue_number=${issue_number_val}
issue_key=${issue_key_val}
branch=${branch_val}
worktree_path=${worktree_val}
create_worktree=${create_worktree_val}
base_branch=${base_branch_val}
repo_root=${repo_root_val}
repo=${repo_val}
created_at=${timestamp}
EOF

  cp "${state_dir}/pm-issue-${issue_number_val}.env" "${state_dir}/pm-active.env"
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

for phase_file in "$start_file" "$plan_file" "$progress_file"; do
  if [[ -n "$phase_file" && "$phase_file" != "-" && ! -f "$phase_file" ]]; then
    echo "error: phase file not found: $phase_file" >&2
    exit 1
  fi
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

create_cmd=("$script_dir/issue-create.sh" --title "$title")
if [[ -n "$body" ]]; then
  create_cmd+=(--body "$body")
fi
if [[ -n "$body_file" ]]; then
  create_cmd+=(--body-file "$body_file")
fi
for label in "${labels[@]-}"; do
  create_cmd+=(--label "$label")
done
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
state_dir="${AIPM_STATE_DIR:-.aipm/state}"

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

write_pm_state "$state_dir" "$issue_number" "$issue_key" "${branch_name:-}" "${worktree_path:-}" "$create_worktree" "$base_branch" "$repo_root" "${repo:-}"

echo "[ok] PM start completed for issue #$issue_number"
echo "issue_url=$issue_url"
if [[ "$create_worktree" -eq 1 ]]; then
  echo "branch=$branch_name"
  echo "worktree_path=$worktree_path"
  echo "next=cd \"$worktree_path\""
fi
echo "state_file=${state_dir}/pm-issue-${issue_number}.env"

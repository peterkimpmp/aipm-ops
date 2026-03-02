#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-sync.sh [--issue <issue-number>] [--state-dir <path>] [--worktree-root <path>] [--strict]

Description:
  Audits PM issue state files against actual git worktree registrations.
  - checks issue->branch->worktree mapping recorded by pm-start
  - detects mapping mismatches and missing worktrees
  - detects orphaned managed worktrees under .aipm/worktrees

Options:
  --issue <n>           Check only one issue
  --state-dir <path>    State directory (default: .aipm/state)
  --worktree-root <p>   Managed worktree root (default: .aipm/worktrees)
  --strict              Exit 2 when violations are found

Examples:
  ./scripts/pm-sync.sh
  ./scripts/pm-sync.sh --issue 218
  ./scripts/pm-sync.sh --strict
USAGE
}

get_state_value() {
  local file="$1"
  local key="$2"
  awk -F= -v target="$key" '$1 == target { print substr($0, index($0, "=") + 1); exit }' "$file"
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

normalize_path() {
  local value="$1"
  local root="$2"
  if [[ "$value" = /* ]]; then
    printf '%s' "$value"
  else
    printf '%s/%s' "$root" "$value"
  fi
}

add_violation() {
  local code="$1"
  local message="$2"
  violation_count=$((violation_count + 1))
  printf '%s|%s\n' "$code" "$message" >>"$violations_file"
}

issue_filter=""
strict=0
state_dir=""
worktree_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      [[ $# -lt 2 ]] && { echo "error: --issue requires a value" >&2; exit 1; }
      issue_filter="$2"
      shift 2
      ;;
    --state-dir)
      [[ $# -lt 2 ]] && { echo "error: --state-dir requires a value" >&2; exit 1; }
      state_dir="$2"
      shift 2
      ;;
    --worktree-root)
      [[ $# -lt 2 ]] && { echo "error: --worktree-root requires a value" >&2; exit 1; }
      worktree_root="$2"
      shift 2
      ;;
    --strict)
      strict=1
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

if [[ -n "$issue_filter" && ! "$issue_filter" =~ ^[0-9]+$ ]]; then
  echo "error: --issue must be numeric: $issue_filter" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

state_dir="${state_dir:-${AIPM_STATE_DIR:-.aipm/state}}"
worktree_root="${worktree_root:-${AIPM_WORKTREE_ROOT:-$repo_root/.aipm/worktrees}}"
worktree_root="$(normalize_path "$worktree_root" "$repo_root")"

violations_file="$(mktemp)"
tracked_paths_file="$(mktemp)"
trap 'rm -f "$violations_file" "$tracked_paths_file"' EXIT

violation_count=0
state_count=0
checked_count=0

shopt -s nullglob
state_files=("$state_dir"/pm-issue-*.env)
shopt -u nullglob

if [[ "${#state_files[@]}" -eq 0 ]]; then
  echo "repo_root=$repo_root"
  echo "state_dir=$state_dir"
  echo "worktree_root=$worktree_root"
  echo "state_files=0"
  echo "issues_checked=0"
  echo "violations=0"
  echo "details=none"
  exit 0
fi

for state_file in "${state_files[@]}"; do
  state_count=$((state_count + 1))

  state_issue="$(get_state_value "$state_file" "issue_number")"
  if [[ -z "$state_issue" ]]; then
    state_issue="$(basename "$state_file" | sed -E 's/^pm-issue-([0-9]+)\.env$/\1/')"
  fi

  if [[ -n "$issue_filter" && "$state_issue" != "$issue_filter" ]]; then
    continue
  fi

  checked_count=$((checked_count + 1))

  state_branch="$(get_state_value "$state_file" "branch")"
  state_worktree="$(get_state_value "$state_file" "worktree_path")"
  state_create_worktree="$(get_state_value "$state_file" "create_worktree")"

  if [[ "${state_create_worktree:-0}" != "1" ]]; then
    continue
  fi

  if [[ -z "$state_branch" ]]; then
    add_violation "missing_branch" "issue #$state_issue has empty branch in state ($state_file)"
    continue
  fi

  if [[ -z "$state_worktree" ]]; then
    add_violation "missing_worktree_path" "issue #$state_issue has empty worktree_path in state ($state_file)"
    continue
  fi

  registered_worktree="$(find_worktree_for_branch "$state_branch" || true)"
  if [[ -z "$registered_worktree" ]]; then
    add_violation "branch_without_worktree" "issue #$state_issue branch '$state_branch' has no registered worktree"
    continue
  fi

  printf '%s\n' "$registered_worktree" >>"$tracked_paths_file"

  if [[ "$registered_worktree" != "$state_worktree" ]]; then
    add_violation "state_path_mismatch" "issue #$state_issue branch '$state_branch' state='$state_worktree' actual='$registered_worktree'"
  fi

done

if [[ -z "$issue_filter" ]]; then
  current_path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      "")
        if [[ -n "$current_path" && "$current_path" == "$worktree_root"/* ]]; then
          if ! grep -Fxq "$current_path" "$tracked_paths_file"; then
            add_violation "orphan_worktree" "managed worktree without active PM state: $current_path"
          fi
        fi
        current_path=""
        ;;
    esac
  done < <(git worktree list --porcelain)
fi

echo "repo_root=$repo_root"
echo "state_dir=$state_dir"
echo "worktree_root=$worktree_root"
echo "state_files=$state_count"
echo "issues_checked=$checked_count"
echo "violations=$violation_count"

if [[ "$violation_count" -gt 0 ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    code="${line%%|*}"
    message="${line#*|}"
    echo "- [$code] $message"
  done <"$violations_file"
else
  echo "details=none"
fi

if [[ "$strict" -eq 1 && "$violation_count" -gt 0 ]]; then
  exit 2
fi

#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-close.sh [--from-active] [--yes] <issue-number> <result-file> [--repo <owner/repo>] [--require-merged-pr|--no-require-merged-pr] [--close-only|--land-only] [--skip-commit] [--skip-push] [--skip-pr-create] [--skip-pr-merge] [--skip-worktree-cleanup]

Examples:
  ./scripts/pm-close.sh --from-active --yes
  ./scripts/pm-close.sh 218 docs/results/result-218-pm-done-label-normalization.md
  ./scripts/pm-close.sh 218 docs/results/result-218.md --no-require-merged-pr
USAGE
}

normalize_bool() {
  local raw="$1"
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) echo "1" ;;
    0|false|no|off) echo "0" ;;
    *)
      echo "error: invalid boolean value: $raw" >&2
      exit 1
      ;;
  esac
}

find_linked_pr() {
  local repo="$1"
  local issue_number="$2"
  local pr_state="$3"
  gh pr list --repo "$repo" --state "$pr_state" --search "#$issue_number" --limit 100 \
    --json number,title,url,mergedAt,body \
    | jq -c --arg issue "$issue_number" '
      [ .[]
        | select((((.title // "") + "\n" + (.body // "")) | test("(Refs|Closes|Fixes)[[:space:]]*(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#" + $issue + "\\b"; "i")))
      ]
      | sort_by(.mergedAt // "")
      | last
    '
}

worktree_is_dirty() {
  local path="$1"
  [[ -n "$(git -C "$path" status --short 2>/dev/null)" ]]
}

path_tracked_in_worktree() {
  local worktree_path="$1"
  local repo_relative_path="$2"
  git -C "$worktree_path" ls-files --error-unmatch -- "$repo_relative_path" >/dev/null 2>&1
}

safe_commit_all_changes() {
  local path="$1"
  local message="$2"
  local body="$3"
  git -C "$path" add -A
  if [[ -n "$(git -C "$path" diff --cached --name-only)" ]]; then
    git -C "$path" commit -m "$message" -m "$body"
  fi
}

current_git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

current_git_dir() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

main_worktree_path() {
  local current_branch current_dir main_worktree
  current_branch="$(current_git_branch)"
  current_dir="$(current_git_dir)"
  main_worktree="$(pm_find_worktree_for_branch main || true)"
  if [[ -n "$main_worktree" ]]; then
    printf '%s' "$main_worktree"
    return 0
  fi
  if [[ "$current_branch" == "main" ]]; then
    printf '%s' "$current_dir"
    return 0
  fi
  return 1
}

ensure_main_worktree() {
  local existing
  existing="$(main_worktree_path || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  local temp_main
  temp_main="${repo_root}/.aipm/worktrees/pm-close-main-sync"
  mkdir -p "${repo_root}/.aipm/worktrees"
  if [[ -e "$temp_main" ]]; then
    rm -rf "$temp_main"
  fi
  git worktree add "$temp_main" main >/dev/null 2>&1
  printf '%s' "$temp_main"
}

merge_branch_into_main_worktree() {
  local main_worktree="$1"
  local branch_name="$2"
  git -C "$main_worktree" checkout main >/dev/null 2>&1
  if git -C "$main_worktree" merge-base --is-ancestor "$branch_name" main >/dev/null 2>&1; then
    return 0
  fi
  git -C "$main_worktree" merge --no-ff --no-edit "$branch_name"
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

issue_number=""
result_file=""
from_active=0
yes_mode=0
close_only=0
land_only=0
skip_commit=0
skip_push=0
skip_pr_create=0
skip_pr_merge=0
skip_worktree_cleanup=0

repo=""
require_merged_pr="$(normalize_bool "${AIPM_PM_CLOSE_REQUIRE_MERGED_PR:-1}")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-active)
      from_active=1
      shift
      ;;
    --yes)
      yes_mode=1
      shift
      ;;
    --repo)
      [[ $# -lt 2 ]] && { echo "error: --repo requires a value" >&2; exit 1; }
      repo="$2"
      shift 2
      ;;
    --require-merged-pr)
      require_merged_pr=1
      shift
      ;;
    --no-require-merged-pr)
      require_merged_pr=0
      shift
      ;;
    --close-only)
      close_only=1
      shift
      ;;
    --land-only)
      land_only=1
      shift
      ;;
    --skip-commit)
      skip_commit=1
      shift
      ;;
    --skip-push)
      skip_push=1
      shift
      ;;
    --skip-pr-create)
      skip_pr_create=1
      shift
      ;;
    --skip-pr-merge)
      skip_pr_merge=1
      shift
      ;;
    --skip-worktree-cleanup)
      skip_worktree_cleanup=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$issue_number" ]]; then
        issue_number="$1"
        shift
      elif [[ -z "$result_file" ]]; then
        result_file="$1"
        shift
      else
        echo "error: unknown argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ "$close_only" -eq 1 && "$land_only" -eq 1 ]]; then
  echo "error: --close-only and --land-only are mutually exclusive" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/pm-state.sh
source "$script_dir/pm-state.sh"

if [[ "$from_active" -eq 1 ]]; then
  if [[ -z "$issue_number" ]]; then
    issue_number="$(pm_read_active_field issue 2>/dev/null || true)"
  fi
  if [[ -z "$result_file" ]]; then
    result_file="$(pm_read_active_field result_file 2>/dev/null || true)"
  fi
  if [[ -z "$repo" ]]; then
    repo="$(pm_read_active_field repo 2>/dev/null || true)"
  fi
fi

if [[ -z "$issue_number" || -z "$result_file" ]]; then
  usage
  exit 1
fi

if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
  echo "error: issue-number must be numeric: $issue_number" >&2
  exit 1
fi

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

active_branch="$(pm_read_active_field branch 2>/dev/null || true)"
active_worktree="$(pm_read_active_field worktree 2>/dev/null || true)"
if [[ -z "$active_branch" ]]; then
  active_branch="$(current_git_branch)"
fi
if [[ -z "$active_worktree" ]]; then
  active_worktree="$(current_git_dir)"
fi

result_file_in_active_worktree=""
if [[ -n "$active_worktree" && -n "$result_file" ]]; then
  result_file_in_active_worktree="$(pm_resolve_path_in_worktree "$active_worktree" "$result_file")"
fi

blockers=()
warnings=()
temp_main_worktree=""

if [[ ! -f "$result_file" ]]; then
  blockers+=("result_file_missing:$result_file")
fi
if [[ -n "$active_branch" ]]; then
  if ! git show-ref --verify --quiet "refs/heads/$active_branch"; then
    blockers+=("active_branch_missing")
  fi
fi
if [[ -n "$active_worktree" && ! -d "$active_worktree" ]]; then
  blockers+=("active_worktree_missing")
fi
if [[ -f "$result_file" && -n "$result_file_in_active_worktree" && ! -f "$result_file_in_active_worktree" ]]; then
  blockers+=("result_file_not_in_active_worktree:$result_file")
fi
if [[ -f "$result_file" && -n "$result_file_in_active_worktree" && -f "$result_file_in_active_worktree" ]]; then
  result_abs="$(pm_abs_path "$result_file")"
  result_in_worktree_abs="$(pm_abs_path "$result_file_in_active_worktree")"
  if [[ "$result_abs" != "$result_in_worktree_abs" ]]; then
    blockers+=("result_file_untracked_outside_active_branch:$result_file")
  fi
fi

issue_state="$(gh issue view "$issue_number" --repo "$repo" --json state,title --jq '.state | ascii_downcase')"
issue_title="$(gh issue view "$issue_number" --repo "$repo" --json state,title --jq '.title')"
if [[ "$issue_state" != "open" ]]; then
  blockers+=("issue_already_closed")
fi

if [[ -f "$result_file" ]] && ! grep -Eqi "modernization|modernized|현행화" "$result_file"; then
  blockers+=("result_missing_modernization_section")
fi
if [[ -f "$result_file" && -n "$result_file_in_active_worktree" && -f "$result_file_in_active_worktree" ]]; then
  if ! path_tracked_in_worktree "$active_worktree" "$result_file"; then
    status_output="$(git -C "$active_worktree" status --short -- "$result_file" 2>/dev/null || true)"
    if [[ -z "$status_output" ]]; then
      blockers+=("result_file_untracked_outside_active_branch:$result_file")
    fi
  fi
fi

merged_pr_json="null"
open_pr_json="null"
if [[ "$require_merged_pr" -eq 1 ]]; then
  merged_pr_json="$(find_linked_pr "$repo" "$issue_number" merged)"
  open_pr_json="$(find_linked_pr "$repo" "$issue_number" open)"
fi
needs_land=0
if [[ "$close_only" -ne 1 && "$require_merged_pr" -eq 1 ]]; then
  if [[ -z "$merged_pr_json" || "$merged_pr_json" == "null" ]]; then
    needs_land=1
  fi
fi

if [[ "$needs_land" -eq 1 ]]; then
  if [[ -z "$active_branch" ]]; then
    blockers+=("active_branch_missing")
  fi
  if [[ "$active_branch" == "main" && -d "$active_worktree" ]]; then
    if worktree_is_dirty "$active_worktree"; then
      blockers+=("branch_is_main_with_changes")
    fi
  fi
fi

if [[ "${#blockers[@]}" -gt 0 ]]; then
  echo "error: pm-close preflight failed for issue #$issue_number" >&2
  printf 'blocker=%s\n' "${blockers[@]}" >&2
  exit 2
fi

if [[ "$needs_land" -eq 1 ]]; then
  commit_message="[PP-${issue_number}] chore(pm): land closeout branch"
  commit_body="Refs #${issue_number}"

  if [[ -d "$active_worktree" ]]; then
    if worktree_is_dirty "$active_worktree"; then
      if [[ "$skip_commit" -eq 1 ]]; then
        echo "error: pm-close land failed for issue #$issue_number" >&2
        echo "blocker=dirty_worktree_uncommitted" >&2
        exit 2
      fi
      safe_commit_all_changes "$active_worktree" "$commit_message" "$commit_body"
    fi
  fi

  if [[ "$skip_push" -eq 0 ]]; then
    if ! git -C "$active_worktree" push -u origin "$active_branch"; then
      echo "error: pm-close land failed for issue #$issue_number" >&2
      echo "blocker=push_failed" >&2
      exit 2
    fi
  fi

  if [[ -z "$open_pr_json" || "$open_pr_json" == "null" ]]; then
    if [[ "$skip_pr_create" -eq 1 ]]; then
      echo "error: pm-close land failed for issue #$issue_number" >&2
      echo "blocker=pr_create_failed" >&2
      exit 2
    fi
    pr_body="$(mktemp)"
    cat > "$pr_body" <<EOF
## Summary
- automated closeout land for issue #$issue_number

## Notes
- generated by pm-close

Refs #$issue_number
EOF
    if ! gh pr create --repo "$repo" --base main --head "$active_branch" --title "$issue_title" --body-file "$pr_body" >/dev/null; then
      rm -f "$pr_body"
      echo "error: pm-close land failed for issue #$issue_number" >&2
      echo "blocker=pr_create_failed" >&2
      exit 2
    fi
    rm -f "$pr_body"
    open_pr_json="$(find_linked_pr "$repo" "$issue_number" open)"
  fi

  if [[ "$skip_pr_merge" -eq 0 ]]; then
    pr_number="$(jq -r '.number // ""' <<<"$open_pr_json")"
    if [[ -z "$pr_number" ]]; then
      echo "error: pm-close land failed for issue #$issue_number" >&2
      echo "blocker=pr_create_failed" >&2
      exit 2
    fi
    if ! gh pr merge "$pr_number" --repo "$repo" --squash --delete-branch >/dev/null; then
      echo "error: pm-close land failed for issue #$issue_number" >&2
      echo "blocker=pr_merge_failed" >&2
      exit 2
    fi

    main_worktree="$(ensure_main_worktree || true)"
    if [[ -z "$main_worktree" ]]; then
      warnings+=("main_sync_failed")
    else
      if [[ "$main_worktree" == "${repo_root}/.aipm/worktrees/pm-close-main-sync" ]]; then
        temp_main_worktree="$main_worktree"
      fi
      if ! merge_branch_into_main_worktree "$main_worktree" "$active_branch"; then
        warnings+=("main_sync_failed")
      else
        if [[ "$skip_push" -eq 0 ]]; then
          git -C "$main_worktree" push origin main >/dev/null 2>&1 || warnings+=("main_push_failed")
        fi
        if [[ "$skip_worktree_cleanup" -eq 0 && -n "$active_worktree" && -d "$active_worktree" ]]; then
          current_abs="$(cd "$(pwd)" && pwd)"
          active_abs="$(cd "$active_worktree" && pwd)"
          if [[ "$current_abs" == "$active_abs" ]]; then
            warnings+=("worktree_cleanup_skipped_current_shell")
          else
            git -C "$main_worktree" worktree remove "$active_worktree" --force >/dev/null 2>&1 || warnings+=("worktree_cleanup_failed")
          fi
        fi
        git -C "$main_worktree" branch -D "$active_branch" >/dev/null 2>&1 || true
      fi
    fi

    merged_pr_json="$(find_linked_pr "$repo" "$issue_number" merged)"
  fi
fi

if [[ "$require_merged_pr" -eq 1 ]]; then
  if [[ -z "$merged_pr_json" || "$merged_pr_json" == "null" ]]; then
    echo "error: pm-close preflight failed for issue #$issue_number" >&2
    echo "blocker=missing_merged_pr" >&2
    exit 2
  fi
  merged_pr_number="$(jq -r '.number' <<<"$merged_pr_json")"
  merged_pr_url="$(jq -r '.url' <<<"$merged_pr_json")"
  echo "[ok] merged PR linked: #$merged_pr_number ($merged_pr_url)"
fi

if [[ "$land_only" -eq 0 ]]; then
  modernize_cmd=("$script_dir/pm-modernize.sh" --issue "$issue_number" --result-file "$result_file")
  if [[ "$yes_mode" -eq 1 ]]; then
    modernize_cmd+=(--yes)
  fi
  "${modernize_cmd[@]}"
  if [[ ! -f "$(pm_state_dir)/modernized-${issue_number}.flag" ]]; then
    echo "error: pm-close preflight failed for issue #$issue_number" >&2
    echo "blocker=missing_modernization_flag" >&2
    exit 2
  fi
  AIPM_REPO="$repo" AIPM_MODERNIZED=1 "$script_dir/issue-log.sh" "$issue_number" result "$result_file" --close
  AIPM_REPO="$repo"
  pm_set_issue_status_label "$repo" "$issue_number" "status:done"
  if pm_active_issue_matches "$issue_number"; then
    pm_update_active_issue_status "closed"
    pm_archive_active_issue
  fi
fi

if [[ -n "$temp_main_worktree" && -d "$temp_main_worktree" ]]; then
  git worktree remove "$temp_main_worktree" --force >/dev/null 2>&1 || true
fi

echo "[ok] PM close completed for issue #$issue_number"
if [[ "${#warnings[@]}" -gt 0 ]]; then
  printf 'warning=%s\n' "${warnings[@]}"
fi

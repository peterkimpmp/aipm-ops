#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-close.sh <issue-number> <result-file> [--repo <owner/repo>] [--require-merged-pr|--no-require-merged-pr] [--cleanup-worktree|--no-cleanup-worktree]

Examples:
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

find_worktree_for_issue_pattern() {
  local pattern="$1"
  local current_path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        current_path="${line#worktree }"
        ;;
      branch\ refs/heads/*)
        local branch_name="${line#branch refs/heads/}"
        if [[ "$branch_name" == *"$pattern"* ]]; then
          printf '%s\n%s' "$branch_name" "$current_path"
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

cleanup_issue_worktree() {
  local issue_number_val="$1"
  local repo_root_val="$2"
  local state_dir_val="$3"
  local state_file="${state_dir_val}/pm-issue-${issue_number_val}.env"
  local issue_key_prefix_val="$4"

  local tracked_branch=""
  local tracked_worktree=""
  local discovered_branch=""
  local discovered_worktree=""
  local issue_pattern=""
  local issue_match=""

  if [[ -f "$state_file" ]]; then
    tracked_branch="$(get_state_value "$state_file" "branch")"
    tracked_worktree="$(get_state_value "$state_file" "worktree_path")"
  fi

  if [[ -n "$tracked_branch" ]]; then
    discovered_worktree="$(find_worktree_for_branch "$tracked_branch" || true)"
    discovered_branch="$tracked_branch"
  fi

  if [[ -z "$discovered_worktree" ]]; then
    issue_pattern="${issue_key_prefix_val}-${issue_number_val}-"
    issue_match="$(find_worktree_for_issue_pattern "$issue_pattern" || true)"
    if [[ -n "$issue_match" ]]; then
      discovered_branch="$(printf '%s\n' "$issue_match" | sed -n '1p')"
      discovered_worktree="$(printf '%s\n' "$issue_match" | sed -n '2p')"
    fi
  fi

  if [[ -z "$discovered_worktree" && -n "$tracked_worktree" ]]; then
    if git worktree list --porcelain | rg -Fq "worktree $tracked_worktree"; then
      discovered_worktree="$tracked_worktree"
      discovered_branch="${discovered_branch:-$tracked_branch}"
    fi
  fi

  if [[ -z "$discovered_worktree" ]]; then
    echo "[info] no registered worktree found for issue #$issue_number_val; cleanup skipped."
    return 0
  fi

  if [[ "$discovered_worktree" == "$repo_root_val" ]]; then
    echo "[info] skip cleanup for primary worktree: $discovered_worktree"
    return 0
  fi

  if [[ ! -d "$discovered_worktree" ]]; then
    echo "[warn] worktree path missing on disk: $discovered_worktree"
    git worktree prune >/dev/null 2>&1 || true
    echo "[ok] pruned stale worktree metadata."
    return 0
  fi

  if [[ -n "$(git -C "$discovered_worktree" status --porcelain)" ]]; then
    echo "error: dirty worktree detected for issue #$issue_number_val: $discovered_worktree" >&2
    echo "hint: commit/stash/discard in that worktree, then rerun close; or bypass with --no-cleanup-worktree." >&2
    return 1
  fi

  git worktree remove "$discovered_worktree"
  git worktree prune >/dev/null 2>&1 || true
  echo "[ok] cleaned worktree for issue #$issue_number_val: $discovered_worktree (${discovered_branch:-n/a})"
  return 0
}

cleanup_state_artifacts() {
  local issue_number_val="$1"
  local state_dir_val="$2"
  local issue_file="${state_dir_val}/pm-issue-${issue_number_val}.env"
  local active_file="${state_dir_val}/pm-active.env"
  local modernized_file="${state_dir_val}/modernized-${issue_number_val}.flag"
  local active_issue=""

  rm -f "$issue_file" "$modernized_file"

  if [[ -f "$active_file" ]]; then
    active_issue="$(get_state_value "$active_file" "issue_number")"
    if [[ "$active_issue" == "$issue_number_val" ]]; then
      rm -f "$active_file"
    fi
  fi
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

issue_number="$1"
result_file="$2"
shift 2

repo=""
require_merged_pr="$(normalize_bool "${AIPM_PM_CLOSE_REQUIRE_MERGED_PR:-1}")"
cleanup_worktree="$(normalize_bool "${AIPM_PM_CLOSE_CLEANUP_WORKTREE:-1}")"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --cleanup-worktree)
      cleanup_worktree=1
      shift
      ;;
    --no-cleanup-worktree)
      cleanup_worktree=0
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

if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
  echo "error: issue-number must be numeric: $issue_number" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ ! -f "$result_file" ]]; then
  echo "error: result file not found: $result_file" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="${AIPM_STATE_DIR:-.aipm/state}"
issue_key_prefix="AIPM"
if [[ -f ".aipm/ops.env" ]]; then
  # shellcheck disable=SC1091
  source ".aipm/ops.env"
fi
issue_key_prefix="${ISSUE_KEY_PREFIX:-$issue_key_prefix}"

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

if [[ "$require_merged_pr" -eq 1 ]]; then
  merged_pr_json="$(
    gh pr list --repo "$repo" --state merged --search "#$issue_number" --limit 100 \
      --json number,title,url,mergedAt,body \
      | jq -c --arg issue "$issue_number" '
        [ .[]
          | select((((.title // "") + "\n" + (.body // "")) | test("(Refs|Closes|Fixes)[[:space:]]*(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#" + $issue + "\\b"; "i")))
        ]
        | sort_by(.mergedAt)
        | last
      '
  )"

  if [[ -z "$merged_pr_json" || "$merged_pr_json" == "null" ]]; then
    echo "error: no merged PR found for issue #$issue_number in $repo" >&2
    echo "hint: merge a PR that references this issue with Refs/Closes/Fixes #$issue_number, or run with --no-require-merged-pr." >&2
    exit 1
  fi

  merged_pr_number="$(jq -r '.number' <<<"$merged_pr_json")"
  merged_pr_url="$(jq -r '.url' <<<"$merged_pr_json")"
  echo "[ok] merged PR linked: #$merged_pr_number ($merged_pr_url)"
fi

"$script_dir/pm-modernize.sh" --issue "$issue_number" --result-file "$result_file"

if [[ "$cleanup_worktree" -eq 1 ]]; then
  cleanup_issue_worktree "$issue_number" "$repo_root" "$state_dir" "$issue_key_prefix"
fi

AIPM_REPO="$repo" AIPM_MODERNIZED=1 "$script_dir/issue-log.sh" "$issue_number" result "$result_file" --close
cleanup_state_artifacts "$issue_number" "$state_dir"

echo "[ok] PM close completed for issue #$issue_number"

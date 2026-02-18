#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/aipm-bootstrap-all.sh [--root <path>] [--dry-run] [--force] [--exclude <repo-name>]...

Examples:
  ./scripts/aipm-bootstrap-all.sh --root ~/GitHub --dry-run
  ./scripts/aipm-bootstrap-all.sh --root ~/GitHub --exclude aipm
USAGE
}

root="${HOME}/GitHub"
dry_run=0
force=0
excludes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    --exclude)
      excludes+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_bootstrap="$script_dir/aipm-bootstrap-repo.sh"

if [[ ! -x "$repo_bootstrap" ]]; then
  echo "missing executable: $repo_bootstrap"
  exit 1
fi

is_excluded() {
  local name="$1"
  local item
  for item in "${excludes[@]-}"; do
    [[ -z "$item" ]] && continue
    if [[ "$item" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

ok_count=0
fail_count=0

for repo_path in "$root"/*; do
  [[ -d "$repo_path/.git" ]] || continue
  repo_name="$(basename "$repo_path")"

  if is_excluded "$repo_name"; then
    echo "SKIP-EXCLUDE $repo_name"
    continue
  fi

  args=(--repo "$repo_path")
  [[ "$dry_run" -eq 1 ]] && args+=(--dry-run)
  [[ "$force" -eq 1 ]] && args+=(--force)

  if "$repo_bootstrap" "${args[@]}"; then
    ok_count=$((ok_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi

done

echo "=== Bootstrap All Summary ==="
echo "root=$root"
echo "ok=$ok_count"
echo "fail=$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

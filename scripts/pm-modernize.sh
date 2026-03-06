#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-modernize.sh --issue <issue-number> [--result-file <path>] [--yes]

Examples:
  ./scripts/pm-modernize.sh --issue 218 --result-file docs/results/result-218.md
USAGE
}

issue_number=""
result_file=""
yes_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      if [[ $# -lt 2 ]]; then
        echo "error: --issue requires a value." >&2
        usage
        exit 1
      fi
      issue_number="$2"
      shift 2
      ;;
    --result-file)
      if [[ $# -lt 2 ]]; then
        echo "error: --result-file requires a value." >&2
        usage
        exit 1
      fi
      result_file="$2"
      shift 2
      ;;
    --yes)
      yes_mode=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "invalid argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$issue_number" ]]; then
  echo "error: --issue is required." >&2
  usage
  exit 1
fi

if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
  echo "error: issue-number must be numeric: $issue_number" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ -n "$result_file" && ! -f "$result_file" ]]; then
  echo "error: result file not found: $result_file" >&2
  exit 1
fi

echo "[modernize] Preparing closeout modernization check for issue #$issue_number"
if [[ -n "$result_file" ]]; then
  if grep -Eqi "modernization|modernized|현행화" "$result_file"; then
    echo "[ok] Result file includes modernization keyword: $result_file"
  else
    echo "[warn] Result file does not include modernization evidence yet: $result_file"
    echo "       issue-log close guard will fail until you update the result file."
  fi
fi

cat <<'CHECKLIST'
[checklist] closeout modernization
- Result/retrospective documentation updated
- README/ops guides/backlog documentation updated
- Worktree cleanup and main integration status verified
CHECKLIST

if [[ "$yes_mode" -eq 1 ]]; then
  :
elif [[ -t 0 ]]; then
  echo "[confirm] If modernization is complete, type: MODERNIZED"
  printf "> "
  read -r ack
  if [[ "$ack" != "MODERNIZED" && "$ack" != "현행화완료" ]]; then
    echo "aborted: modernization confirmation not provided." >&2
    exit 1
  fi
elif [[ "${AIPM_MODERNIZED:-0}" != "1" ]]; then
  echo "error: non-interactive modernization requires explicit confirmation." >&2
  echo "hint: rerun with --yes or set AIPM_MODERNIZED=1 for automation." >&2
  exit 1
fi

state_dir="${AIPM_STATE_DIR:-.aipm/state}"
mkdir -p "$state_dir"
flag_file="${state_dir}/modernized-${issue_number}.flag"

timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
commit_ref="$(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
branch_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)"
operator="${USER:-unknown}"

cat > "$flag_file" <<EOF
issue=${issue_number}
timestamp=${timestamp}
commit=${commit_ref}
branch=${branch_ref}
operator=${operator}
result_file=${result_file}
EOF

echo "[ok] Modernization flag recorded: $flag_file"

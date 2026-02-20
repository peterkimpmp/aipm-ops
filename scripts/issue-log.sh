#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/issue-log.sh <issue-number> <phase> [body-file] [--close]

Phase:
  start | progress | end | prd | plan | result

Examples:
  ./scripts/issue-log.sh 12 start
  ./scripts/issue-log.sh 12 prd docs/prd.md
  ./scripts/issue-log.sh 12 result docs/result.md --close
USAGE
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

issue_number="$1"
phase="$2"
shift 2

body_file=""
close_flag=""
for arg in "$@"; do
  case "$arg" in
    --close) close_flag="--close" ;;
    *) [[ -z "$body_file" ]] && body_file="$arg" ;;
  esac
done

case "$phase" in
  start|progress|end|prd|plan|result) ;;
  *)
    echo "invalid phase: $phase"
    usage
    exit 1
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

issue_key_prefix="AIPM"
if [[ -f ".aipm/ops.env" ]]; then
  # shellcheck disable=SC1091
  source ".aipm/ops.env"
fi
issue_key_prefix="${ISSUE_KEY_PREFIX:-$issue_key_prefix}"

repo="${AIPM_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
issue_key="${issue_key_prefix}-${issue_number}"
phase_upper="$(echo "$phase" | tr '[:lower:]' '[:upper:]')"
timestamp="$(date '+%Y-%m-%d %H:%M %Z')"
commit_ref="$(git rev-parse --short HEAD 2>/dev/null || echo n/a)"

if [[ -n "$body_file" ]]; then
  body_content="$(cat "$body_file")"
elif [[ ! -t 0 ]]; then
  body_content="$(cat)"
else
  body_content="-"
fi

comment_body="$(cat <<MSG
### ${phase_upper} | ${issue_key}
- Timestamp: ${timestamp}
- Commit: \`${commit_ref}\`

${body_content}
MSG
)"

gh issue comment "$issue_number" --repo "$repo" --body "$comment_body"
echo "comment posted to #$issue_number ($repo)"

if [[ "$close_flag" == "--close" ]]; then
  gh issue close "$issue_number" --repo "$repo"
  echo "issue #$issue_number closed"
fi

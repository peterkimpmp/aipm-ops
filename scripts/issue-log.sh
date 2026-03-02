#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/issue-log.sh <issue-number> <phase> [body-file] [--close] [--allow-placeholder-body]

Phase:
  start | progress | end | prd | plan | debate | result

Examples:
  ./scripts/issue-log.sh 12 start
  ./scripts/issue-log.sh 12 prd docs/prd.md
  ./scripts/issue-log.sh 12 result docs/result.md --close
USAGE
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
phase="$2"
shift 2

body_file=""
close_flag=""
allow_placeholder_body=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --close)
      close_flag="--close"
      shift
      ;;
    --allow-placeholder-body)
      allow_placeholder_body=1
      shift
      ;;
    *)
      if [[ -z "$body_file" ]]; then
        body_file="$1"
        shift
      else
        echo "error: unknown argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

is_placeholder_body() {
  local body_value="$1"
  local normalized=""
  normalized="$(printf '%s' "$body_value" | tr -d '\r')"
  normalized="$(printf '%s' "$normalized" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  normalized="$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    ""|"-"|"tbd"|"todo"|"n/a"|"na")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

enforce_phase_body_quality() {
  local phase_val="$1"
  local body_val="$2"
  local allow_placeholder="$3"

  case "$phase_val" in
    start|plan|progress|prd|result) ;;
    *) return 0 ;;
  esac

  if [[ "$allow_placeholder" == "1" || "${AIPM_ALLOW_PLACEHOLDER_BODY:-0}" == "1" ]]; then
    return 0
  fi

  if is_placeholder_body "$body_val"; then
    echo "error: phase '$phase_val' requires a non-placeholder body." >&2
    echo "hint: provide a body-file or stdin content, or use --allow-placeholder-body for explicit bypass." >&2
    exit 1
  fi
}

enforce_modernization_before_close() {
  local issue_val="$1"
  local phase_val="$2"
  local close_val="$3"
  local body_val="${4:-}"
  local state_dir="${AIPM_STATE_DIR:-.aipm/state}"
  local modernized_flag="${state_dir}/modernized-${issue_val}.flag"
  local lower_body=""

  if [[ "$phase_val" != "result" || "$close_val" != "--close" ]]; then
    return 0
  fi

  # Guard 1: result closeout note must explicitly mention modernization.
  lower_body="$(printf '%s' "$body_val" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$body_val" || ( "$lower_body" != *"modernization"* && "$lower_body" != *"modernized"* && "$body_val" != *"현행화"* ) ]]; then
    echo "error: closeout requires modernization evidence in result body (missing modernization marker)." >&2
    echo "hint: add a dedicated 'modernization' section to the result document, then retry." >&2
    exit 1
  fi

  # Guard 2: explicit operator confirmation before closing issue.
  # pm-close.sh sets AIPM_MODERNIZED=1 to avoid duplicate prompts.
  if [[ -t 0 && "${AIPM_MODERNIZED:-0}" != "1" ]]; then
    echo "[guard] '[pm] close' requires modernization first."
    echo "        if modernization is complete, type: MODERNIZED"
    printf "> "
    read -r ack
    if [[ "$ack" != "MODERNIZED" && "$ack" != "현행화완료" ]]; then
      echo "aborted: modernization confirmation not provided." >&2
      exit 1
    fi
  elif [[ "${AIPM_MODERNIZED:-0}" != "1" ]]; then
    echo "error: non-interactive close requires AIPM_MODERNIZED=1." >&2
    echo "hint: run modernization first, then retry with AIPM_MODERNIZED=1." >&2
    exit 1
  fi

  # Guard 3: close requires modernization state artifact.
  if [[ ! -f "$modernized_flag" ]]; then
    echo "error: closeout requires modernization flag: $modernized_flag" >&2
    echo "hint: run ./scripts/pm-modernize.sh --issue $issue_val before close." >&2
    exit 1
  fi

  if ! grep -q "^issue=${issue_val}$" "$modernized_flag"; then
    echo "error: invalid modernization flag for issue #$issue_val: $modernized_flag" >&2
    echo "hint: rerun ./scripts/pm-modernize.sh --issue $issue_val." >&2
    exit 1
  fi
}

case "$phase" in
  start|progress|end|prd|plan|debate|result) ;;
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

issue_key="${issue_key_prefix}-${issue_number}"
phase_upper="$(echo "$phase" | tr '[:lower:]' '[:upper:]')"
timestamp="$(date '+%Y-%m-%d %H:%M %Z')"
commit_ref="$(git rev-parse --short HEAD 2>/dev/null || echo n/a)"

if [[ -n "$body_file" ]]; then
  if [[ "$body_file" == "-" ]]; then
    body_content="$(cat)"
  else
    body_content="$(cat "$body_file")"
  fi
elif [[ ! -t 0 ]]; then
  body_content="$(cat)"
else
  body_content="-"
fi

enforce_phase_body_quality "$phase" "$body_content" "$allow_placeholder_body"
enforce_modernization_before_close "$issue_number" "$phase" "$close_flag" "$body_content"

comment_body="$(cat <<MSG
### ${phase_upper} | ${issue_key}
- Timestamp: ${timestamp}
- Commit: \`${commit_ref}\`

${body_content}
MSG
)"

repo="${AIPM_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
gh issue comment "$issue_number" --repo "$repo" --body "$comment_body"
echo "comment posted to #$issue_number ($repo)"

if [[ "$close_flag" == "--close" ]]; then
  gh issue close "$issue_number" --repo "$repo"
  echo "issue #$issue_number closed"
fi

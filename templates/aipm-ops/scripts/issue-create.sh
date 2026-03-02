#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/issue-create.sh --title "<title>" [--body "<text>" | --body-file <path>] [--label <name>]... [--repo <owner/repo>] [--dry-run]

Examples:
  ./scripts/issue-create.sh --title "[Feature] Multi-AI Editor Review Module" --label feature --body "Summary"
  ./scripts/issue-create.sh --title "[Task] Fix CI flake" --label priority:p1 --label area:backend --dry-run
USAGE
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

array_contains() {
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

normalize_label_alias() {
  local raw="$1"
  local lower=""
  lower="$(to_lower "$raw")"
  case "$lower" in
    epic) echo "type:epic" ;;
    feature) echo "type:feature" ;;
    story) echo "type:story" ;;
    task) echo "type:task" ;;
    bug) echo "type:bug" ;;
    chore) echo "type:chore" ;;
    docs) echo "type:docs" ;;
    refactor) echo "type:refactor" ;;
    *) echo "$lower" ;;
  esac
}

infer_type_from_title() {
  local title="$1"
  local lower=""
  lower="$(to_lower "$title")"
  if printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[epic\]'; then
    echo "type:epic"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[feature\]'; then
    echo "type:feature"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[story\]'; then
    echo "type:story"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[task\]'; then
    echo "type:task"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[bug\]'; then
    echo "type:bug"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[chore\]'; then
    echo "type:chore"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[docs\]'; then
    echo "type:docs"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[refactor\]'; then
    echo "type:refactor"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[prd\]'; then
    echo "type:prd"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[plan\]'; then
    echo "type:plan"
  elif printf '%s' "$lower" | grep -Eq '^[[:space:]]*\[result\]'; then
    echo "type:result"
  else
    echo ""
  fi
}

add_unique_label() {
  local label="$1"
  if [[ -z "$label" ]]; then
    return
  fi
  if [[ "${#labels[@]}" -eq 0 ]]; then
    labels+=("$label")
    return
  fi
  if ! array_contains "$label" "${labels[@]}"; then
    labels+=("$label")
  fi
}

load_repo_labels() {
  repo_labels=()
  local raw_lines=""
  local label=""

  if raw_lines="$(gh label list --repo "$repo" --limit 200 --json name --jq '.[].name' 2>/dev/null)"; then
    :
  else
    raw_lines="$(gh label list --repo "$repo" --limit 200 | awk -F '\t' '{print $1}')"
  fi

  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    repo_labels+=("$(to_lower "$label")")
  done <<EOF
$raw_lines
EOF
}

title=""
body=""
body_file=""
repo=""
dry_run=0
issue_body_mode=""
temp_body_file=""
input_labels=()
labels=()
repo_labels=()
canonical_labels=()
missing_labels=()

cleanup_temp_body_file() {
  if [[ -n "${temp_body_file:-}" && -f "${temp_body_file:-}" ]]; then
    rm -f "$temp_body_file"
  fi
}

trap cleanup_temp_body_file EXIT

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ops_env_file="$repo_root/.aipm/ops.env"
if [[ -f "$ops_env_file" ]]; then
  # shellcheck disable=SC1090
  source "$ops_env_file"
fi
issue_body_mode="${AIPM_ISSUE_BODY_MODE:-auto}"
case "$issue_body_mode" in
  auto|file|inline) ;;
  *)
    echo "error: AIPM_ISSUE_BODY_MODE must be one of: auto, file, inline" >&2
    exit 1
    ;;
esac

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
      input_labels+=("$2")
      shift 2
      ;;
    --repo)
      [[ $# -lt 2 ]] && { echo "error: --repo requires a value" >&2; exit 1; }
      repo="$2"
      shift 2
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
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
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

if [[ -n "$body" && -z "$body_file" ]]; then
  # Common shell pitfall: "--body \"line1\\nline2\"" sends literal "\n".
  if [[ "$body" != *$'\n'* && "$body" == *\\n* ]]; then
    body="${body//\\n/$'\n'}"
  fi
fi

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_script="$script_dir/setup-labels.sh"
if [[ ! -f "$setup_script" ]]; then
  echo "error: setup script not found: $setup_script" >&2
  exit 1
fi

while IFS= read -r label; do
  [[ -z "$label" ]] && continue
  canonical_labels+=("$(to_lower "$label")")
done <<EOF
$(sed -n 's/^[[:space:]]*ensure_label "\([^"]*\)".*/\1/p' "$setup_script")
EOF

if [[ "${#canonical_labels[@]}" -eq 0 ]]; then
  echo "error: no canonical labels were found in setup-labels.sh" >&2
  exit 1
fi

if [[ "${#input_labels[@]}" -gt 0 ]]; then
  for raw_label in "${input_labels[@]}"; do
    while IFS= read -r part; do
      part="$(trim "$part")"
      [[ -z "$part" ]] && continue
      add_unique_label "$(normalize_label_alias "$part")"
    done <<EOF
$(printf '%s' "$raw_label" | tr ',' '\n')
EOF
  done
fi

has_type=0
if [[ "${#labels[@]}" -gt 0 ]]; then
  for label in "${labels[@]}"; do
    if [[ "$label" == type:* ]]; then
      has_type=1
      break
    fi
  done
fi

if [[ "$has_type" -eq 0 ]]; then
  inferred_type="$(infer_type_from_title "$title")"
  if [[ -n "$inferred_type" ]]; then
    add_unique_label "$inferred_type"
  else
    add_unique_label "type:task"
  fi
fi

has_status=0
if [[ "${#labels[@]}" -gt 0 ]]; then
  for label in "${labels[@]}"; do
    if [[ "$label" == status:* ]]; then
      has_status=1
      break
    fi
  done
fi

if [[ "$has_status" -eq 0 ]]; then
  add_unique_label "status:todo"
fi

unknown_labels=()
for label in "${labels[@]}"; do
  if ! array_contains "$label" "${canonical_labels[@]}"; then
    unknown_labels+=("$label")
  fi
done

if [[ "${#unknown_labels[@]}" -gt 0 ]]; then
  echo "error: unknown label(s): ${unknown_labels[*]}" >&2
  echo "hint: use canonical labels (type:*, status:*, priority:*, area:*, agent:*)" >&2
  exit 1
fi

load_repo_labels
missing_labels=()
for label in "${labels[@]}"; do
  if [[ "${#repo_labels[@]}" -eq 0 ]] || ! array_contains "$label" "${repo_labels[@]}"; then
    missing_labels+=("$label")
  fi
done

if [[ "${#missing_labels[@]}" -gt 0 ]]; then
  echo "[info] missing labels detected: ${missing_labels[*]}" >&2
  echo "[info] running setup-labels.sh once for bootstrap..." >&2
  "$setup_script" "$repo" >/dev/null
  load_repo_labels
  missing_labels=()
  for label in "${labels[@]}"; do
    if [[ "${#repo_labels[@]}" -eq 0 ]] || ! array_contains "$label" "${repo_labels[@]}"; then
      missing_labels+=("$label")
    fi
  done
fi

if [[ "${#missing_labels[@]}" -gt 0 ]]; then
  echo "error: labels not found after bootstrap: ${missing_labels[*]}" >&2
  exit 1
fi

gh_cmd=(gh issue create --repo "$repo" --title "$title")
if [[ -n "$body_file" ]]; then
  gh_cmd+=(--body-file "$body_file")
elif [[ -n "$body" ]]; then
  if [[ "$issue_body_mode" == "file" || ( "$issue_body_mode" == "auto" && "$body" == *$'\n'* ) ]]; then
    temp_body_file="$(mktemp)"
    printf '%s\n' "$body" >"$temp_body_file"
    gh_cmd+=(--body-file "$temp_body_file")
  else
    gh_cmd+=(--body "$body")
  fi
fi

for label in "${labels[@]}"; do
  gh_cmd+=(--label "$label")
done

if [[ "$dry_run" -eq 1 ]]; then
  echo "repo: $repo"
  echo "title: $title"
  if [[ -n "$body_file" ]]; then
    echo "body-file: $body_file"
  elif [[ -n "$temp_body_file" ]]; then
    echo "body-file: <generated>"
  elif [[ -n "$body" ]]; then
    echo "body: <inline>"
  else
    echo "body: <prompt>"
  fi
  echo "labels: ${labels[*]}"
  printf 'command:'
  for arg in "${gh_cmd[@]}"; do
    printf ' %q' "$arg"
  done
  printf '\n'
  exit 0
fi

"${gh_cmd[@]}"

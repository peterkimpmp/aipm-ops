#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/aipm-audit-repos.sh [--root <path>] [--format <table|tsv>] [--repo <path>]...

Examples:
  ./scripts/aipm-audit-repos.sh
  ./scripts/aipm-audit-repos.sh --root ~/GitHub --format table
  ./scripts/aipm-audit-repos.sh --repo ~/projects/app-a --repo ~/projects/app-b
USAGE
}

root="${HOME}/GitHub"
format="table"
repos=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="$2"
      shift 2
      ;;
    --format)
      format="$2"
      shift 2
      ;;
    --repo)
      repos+=("$2")
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

if [[ "$format" != "table" && "$format" != "tsv" ]]; then
  echo "invalid format: $format"
  exit 1
fi

collect_repos() {
  if [[ "${#repos[@]}" -gt 0 ]]; then
    printf '%s\n' "${repos[@]}"
    return
  fi

  local candidate
  for candidate in "$root"/*; do
    [[ -d "$candidate/.git" ]] || continue
    printf '%s\n' "$candidate"
  done
}

yes_no() {
  if [[ "$1" == "1" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

file_contains() {
  local pattern="$1"
  shift
  grep -Eq "$pattern" "$@" 2>/dev/null
}

print_row_table() {
  local repo="$1"
  local agent_rules="$2"
  local issue_log="$3"
  local labels="$4"
  local template="$5"
  local governance="$6"
  local hooks="$7"
  local ops_env="$8"
  local prefix="$9"

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$repo" "$agent_rules" "$issue_log" "$labels" "$template" "$governance" "$hooks" "$ops_env" "$prefix"
}

print_row_tsv() {
  local repo="$1"
  local agent_rules="$2"
  local issue_log="$3"
  local labels="$4"
  local template="$5"
  local governance="$6"
  local hooks="$7"
  local ops_env="$8"
  local prefix="$9"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$repo" "$agent_rules" "$issue_log" "$labels" "$template" "$governance" "$hooks" "$ops_env" "$prefix"
}

if [[ "$format" == "table" ]]; then
  echo "| Repo | AgentRules | IssueLog | Labels | MajorTemplate | GovernanceCI | Hooks(ready/active) | OpsEnv | Prefix |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
else
  echo -e "repo\tagent_rules\tissue_log\tlabels\tmajor_template\tgovernance_ci\thooks_ready_active\tops_env\tprefix"
fi

while IFS= read -r repo_path; do
  [[ -d "$repo_path/.git" ]] || continue

  repo_name="$(basename "$repo_path")"

  has_agent_rules=0
  if file_contains 'AIPM-ISSUE-OPS|AIPM-MAJOR|Issue-Driven Workflow|Create or identify a GitHub issue first|이슈.*먼저|Closes #<issue-number>' \
    "$repo_path/AGENTS.md" "$repo_path/CLAUDE.md"; then
    has_agent_rules=1
  fi

  has_issue_log=0
  [[ -f "$repo_path/scripts/issue-log.sh" ]] && has_issue_log=1

  has_labels=0
  if [[ -f "$repo_path/scripts/setup-labels.sh" || -f "$repo_path/.github/labels.yml" ]]; then
    has_labels=1
  fi

  has_major_template=0
  [[ -f "$repo_path/.github/ISSUE_TEMPLATE/aipm-major.md" ]] && has_major_template=1

  has_governance_ci=0
  if [[ -f "$repo_path/.github/workflows/aipm-governance.yml" ]]; then
    has_governance_ci=1
  fi

  has_hooks_ready=0
  if [[ -f "$repo_path/.githooks/prepare-commit-msg" && -f "$repo_path/.githooks/commit-msg" ]]; then
    has_hooks_ready=1
  fi

  hooks_path="$(git -C "$repo_path" config --local core.hooksPath || true)"
  has_hooks_active=0
  if [[ "$hooks_path" == ".githooks" ]]; then
    has_hooks_active=1
  fi

  has_ops_env=0
  prefix="-"
  if [[ -f "$repo_path/.aipm/ops.env" ]]; then
    has_ops_env=1
    prefix_line="$(grep -E '^ISSUE_KEY_PREFIX=' "$repo_path/.aipm/ops.env" || true)"
    prefix="${prefix_line#ISSUE_KEY_PREFIX=}"
    [[ -z "$prefix" ]] && prefix="-"
  fi

  hooks_state="$(yes_no "$has_hooks_ready")/$(yes_no "$has_hooks_active")"

  if [[ "$format" == "table" ]]; then
    print_row_table \
      "$repo_name" \
      "$(yes_no "$has_agent_rules")" \
      "$(yes_no "$has_issue_log")" \
      "$(yes_no "$has_labels")" \
      "$(yes_no "$has_major_template")" \
      "$(yes_no "$has_governance_ci")" \
      "$hooks_state" \
      "$(yes_no "$has_ops_env")" \
      "$prefix"
  else
    print_row_tsv \
      "$repo_name" \
      "$(yes_no "$has_agent_rules")" \
      "$(yes_no "$has_issue_log")" \
      "$(yes_no "$has_labels")" \
      "$(yes_no "$has_major_template")" \
      "$(yes_no "$has_governance_ci")" \
      "$hooks_state" \
      "$(yes_no "$has_ops_env")" \
      "$prefix"
  fi
done < <(collect_repos)

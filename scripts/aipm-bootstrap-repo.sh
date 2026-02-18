#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/aipm-bootstrap-repo.sh --repo <path> [--issue-key-prefix <prefix>] [--dry-run] [--force]

Options:
  --repo <path>              Target repository path (required)
  --issue-key-prefix <text>  Override issue key prefix (default: inferred from repo)
  --dry-run                  Show planned changes only
  --force                    Overwrite files managed by this bootstrap

Examples:
  ./scripts/aipm-bootstrap-repo.sh --repo ~/projects/my-app --dry-run
  ./scripts/aipm-bootstrap-repo.sh --repo ~/projects/my-service
USAGE
}

repo_path=""
issue_key_prefix=""
dry_run=0
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_path="$2"
      shift 2
      ;;
    --issue-key-prefix)
      issue_key_prefix="$2"
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

if [[ -z "$repo_path" ]]; then
  echo "--repo is required"
  usage
  exit 1
fi

repo_path="$(cd "$repo_path" && pwd)"
if [[ ! -d "$repo_path/.git" ]]; then
  echo "not a git repo: $repo_path"
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
aipm_root="$(cd "$script_dir/.." && pwd)"
template_root="$aipm_root/templates/aipm-ops"

if [[ ! -d "$template_root" ]]; then
  echo "template root missing: $template_root"
  exit 1
fi

repo_name="$(basename "$repo_path")"

derive_prefix_from_name() {
  local name="$1"
  if [[ "$name" == *-* || "$name" == *_* ]]; then
    echo "$name" | tr '_-' ' ' | awk '{for(i=1;i<=NF;i++) printf toupper(substr($i,1,1)); print ""}'
  else
    echo "$name" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9'
  fi
}

infer_existing_prefix() {
  local hint
  hint="$(grep -rhoE '\[[A-Z][A-Z0-9_-]*-[0-9]+\]' "$repo_path/.github/workflows" "$repo_path/.githooks" "$repo_path/AGENTS.md" "$repo_path/CLAUDE.md" "$repo_path/README.md" "$repo_path/docs" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$hint" ]]; then
    hint="${hint#[}"
    hint="${hint%%-*}"
    case "$hint" in
      ISSUE|TASK|EPIC|RESEARCH|FEATURE|BUG|CHORE|DOCS|PREFIX|EXAMPLE|SAMPLE|PLACEHOLDER)
        hint=""
        ;;
    esac
    [[ -z "$hint" ]] && return
    echo "$hint"
    return
  fi
  echo ""
}

sanitize_prefix() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_-'
}

if [[ -z "$issue_key_prefix" ]]; then
  if [[ -f "$repo_path/.aipm/ops.env" ]]; then
    existing_prefix="$(grep -E '^ISSUE_KEY_PREFIX=' "$repo_path/.aipm/ops.env" | head -n 1 | cut -d= -f2- || true)"
    issue_key_prefix="$existing_prefix"
  fi
fi

if [[ -z "$issue_key_prefix" ]]; then
  issue_key_prefix="$(infer_existing_prefix)"
fi

if [[ -z "$issue_key_prefix" ]]; then
  issue_key_prefix="$(derive_prefix_from_name "$repo_name")"
fi

issue_key_prefix="$(sanitize_prefix "$issue_key_prefix")"
if [[ -z "$issue_key_prefix" ]]; then
  issue_key_prefix="AIPM"
fi

managed_marker='Managed by AIPM Ops Bootstrap'

create_count=0
update_count=0
skip_count=0
plan_count=0

log_action() {
  local status="$1"
  local path="$2"
  local detail="$3"
  printf '%-8s %s %s\n' "$status" "$path" "$detail"
}

is_managed_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  grep -q "$managed_marker" "$path" 2>/dev/null
}

render_template() {
  local template="$1"
  sed "s/__ISSUE_KEY_PREFIX__/$issue_key_prefix/g" "$template"
}

ensure_template_file() {
  local rel_path="$1"
  local template_rel="$2"
  local mode="$3"

  local target="$repo_path/$rel_path"
  local template="$template_root/$template_rel"

  if [[ ! -f "$template" ]]; then
    echo "template not found: $template"
    exit 1
  fi

  if [[ -f "$target" ]]; then
    if [[ "$force" -eq 1 ]] && is_managed_file "$target"; then
      if [[ "$dry_run" -eq 1 ]]; then
        log_action "PLAN" "$rel_path" "would update managed file"
        plan_count=$((plan_count + 1))
      else
        mkdir -p "$(dirname "$target")"
        render_template "$template" >"$target"
        [[ -n "$mode" ]] && chmod "$mode" "$target"
        log_action "UPDATE" "$rel_path" "updated managed file"
        update_count=$((update_count + 1))
      fi
    else
      log_action "SKIP" "$rel_path" "already exists"
      skip_count=$((skip_count + 1))
    fi
    return
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log_action "PLAN" "$rel_path" "would create"
    plan_count=$((plan_count + 1))
    return
  fi

  mkdir -p "$(dirname "$target")"
  render_template "$template" >"$target"
  [[ -n "$mode" ]] && chmod "$mode" "$target"
  log_action "CREATE" "$rel_path" "created"
  create_count=$((create_count + 1))
}

ensure_instruction_block() {
  local rel_path="$1"
  local file_title="$2"
  local target="$repo_path/$rel_path"
  local begin='<!-- AIPM-ISSUE-OPS:BEGIN -->'
  local end='<!-- AIPM-ISSUE-OPS:END -->'

  local block
  block="$(cat <<'BLOCK'
$begin
## AIPM Issue Ops (Managed)

### `[PM]` Trigger
When a user prompt contains `[PM]` (case-insensitive), activate issue-driven lifecycle.
Auto-detect the current phase from context and execute the next step.
- `[PM] <description>` — Start or continue work on the described task.
- `[PM]` alone — Auto-advance to the next phase.
- Without `[PM]` — Execute directly, no issue tracking.

### Commit Format
- Subject: `[__ISSUE_KEY_PREFIX__-<n>] <type>(<scope>): <summary>`
- Body: `Refs #<n>` or `Closes #<n>` or `Fixes #<n>`

### Branch Naming
- `<type>/<__ISSUE_KEY_PREFIX__>-<n>-<slug>`

### Quick Commands
- `./scripts/setup-labels.sh`
- `./scripts/issue-log.sh <issue> start`
- `./scripts/issue-log.sh <issue> progress`
- `./scripts/issue-log.sh <issue> result docs/result.md --close`
$end
BLOCK
)"
  block="${block//__ISSUE_KEY_PREFIX__/$issue_key_prefix}"
  block="${block//\$begin/$begin}"
  block="${block//\$end/$end}"

  if [[ -f "$target" ]] && grep -q "$begin" "$target"; then
    log_action "SKIP" "$rel_path" "managed instruction block already present"
    skip_count=$((skip_count + 1))
    return
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    if [[ -f "$target" ]]; then
      log_action "PLAN" "$rel_path" "would append managed instruction block"
    else
      log_action "PLAN" "$rel_path" "would create and append managed instruction block"
    fi
    plan_count=$((plan_count + 1))
    return
  fi

  mkdir -p "$(dirname "$target")"
  if [[ ! -f "$target" ]]; then
    {
      echo "# $file_title"
      echo
      echo "$block"
      echo
    } >"$target"
    log_action "CREATE" "$rel_path" "created with managed instruction block"
    create_count=$((create_count + 1))
  else
    {
      echo
      echo "$block"
      echo
    } >>"$target"
    log_action "UPDATE" "$rel_path" "appended managed instruction block"
    update_count=$((update_count + 1))
  fi
}

ensure_hooks_path() {
  local hooks_path
  hooks_path="$(git -C "$repo_path" config --local core.hooksPath || true)"

  if [[ "$hooks_path" == ".githooks" ]]; then
    log_action "SKIP" "git-config" "core.hooksPath already .githooks"
    skip_count=$((skip_count + 1))
    return
  fi

  if [[ -n "$hooks_path" ]]; then
    log_action "SKIP" "git-config" "existing hooksPath is '$hooks_path'"
    skip_count=$((skip_count + 1))
    return
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log_action "PLAN" "git-config" "would set core.hooksPath=.githooks"
    plan_count=$((plan_count + 1))
    return
  fi

  git -C "$repo_path" config --local core.hooksPath .githooks
  log_action "UPDATE" "git-config" "set core.hooksPath=.githooks"
  update_count=$((update_count + 1))
}

echo "=== Bootstrap: $repo_name ==="
echo "Repo: $repo_path"
echo "Issue key prefix: $issue_key_prefix"

ensure_template_file "scripts/issue-log.sh" "scripts/issue-log.sh" "755"
ensure_template_file "scripts/setup-labels.sh" "scripts/setup-labels.sh" "755"
ensure_template_file ".aipm/ops.env" ".aipm/ops.env" "644"
ensure_template_file ".githooks/prepare-commit-msg" ".githooks/prepare-commit-msg" "755"
ensure_template_file ".githooks/commit-msg" ".githooks/commit-msg" "755"
ensure_template_file ".github/ISSUE_TEMPLATE/aipm-major.md" ".github/ISSUE_TEMPLATE/aipm-major.md" "644"

ensure_template_file ".github/workflows/aipm-governance.yml" ".github/workflows/aipm-governance.yml" "644"
ensure_template_file ".github/workflows/issue-status-sync.yml" ".github/workflows/issue-status-sync.yml" "644"
ensure_template_file ".github/workflows/ai-agent-dispatch.yml" ".github/workflows/ai-agent-dispatch.yml" "644"
ensure_template_file ".github/workflows/release-please.yml" ".github/workflows/release-please.yml" "644"
ensure_template_file ".github/pull_request_template.md" ".github/pull_request_template.md" "644"

ensure_instruction_block "AGENTS.md" "Agent Rules"
ensure_instruction_block "CLAUDE.md" "CLAUDE Rules"
ensure_hooks_path

echo "--- Summary ($repo_name) ---"
echo "create=$create_count update=$update_count skip=$skip_count plan=$plan_count"

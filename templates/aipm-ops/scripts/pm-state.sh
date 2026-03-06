#!/usr/bin/env bash
# Shared PM lifecycle state helpers.
set -euo pipefail

pm_state_dir() {
  printf '%s' "${AIPM_STATE_DIR:-.aipm/state}"
}

pm_active_issue_file() {
  printf '%s/active-issue.json' "$(pm_state_dir)"
}

pm_last_active_issue_file() {
  printf '%s/active-issue.last.json' "$(pm_state_dir)"
}

pm_iso_now() {
  python3 - <<'PY'
import datetime as dt
print(dt.datetime.now(dt.timezone.utc).isoformat())
PY
}

pm_slugify_title() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*\[[^]]+\][[:space:]]*//')"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$value" ]]; then
    value="work"
  fi
  printf '%s' "$value"
}

pm_infer_type_label_from_title() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    "[epic]"*) echo "type:epic" ;;
    "[feature]"*) echo "type:feature" ;;
    "[story]"*) echo "type:story" ;;
    "[task]"*|"[test]"*) echo "type:task" ;;
    "[bug]"*) echo "type:bug" ;;
    "[chore]"*) echo "type:chore" ;;
    "[docs]"*) echo "type:docs" ;;
    "[refactor]"*) echo "type:refactor" ;;
    "[prd]"*) echo "type:prd" ;;
    "[plan]"*) echo "type:plan" ;;
    "[result]"*) echo "type:result" ;;
    *) echo "type:task" ;;
  esac
}

pm_default_result_file() {
  local issue_number="$1"
  local title="$2"
  printf 'docs/results/result-%s-%s.md' "$issue_number" "$(pm_slugify_title "$title")"
}

pm_write_active_issue_state() {
  local issue_number="$1"
  local title="$2"
  local branch_name="$3"
  local worktree_path="$4"
  local repo="$5"
  local start_file="$6"
  local plan_file="$7"
  local progress_file="$8"
  local result_file="$9"
  local status="${10}"
  local started_at="${11}"
  local active_file
  active_file="$(pm_active_issue_file)"
  mkdir -p "$(pm_state_dir)"
  python3 - "$active_file" "$issue_number" "$title" "$branch_name" "$worktree_path" "$repo" "$start_file" "$plan_file" "$progress_file" "$result_file" "$status" "$started_at" <<'PY'
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    active_file,
    issue_number,
    title,
    branch_name,
    worktree_path,
    repo,
    start_file,
    plan_file,
    progress_file,
    result_file,
    status,
    started_at,
) = sys.argv[1:13]

payload = {
    "issue": int(issue_number),
    "title": title,
    "branch": branch_name,
    "worktree": worktree_path,
    "repo": repo,
    "started_at": started_at,
    "updated_at": datetime.now(timezone.utc).isoformat(),
    "start_file": start_file,
    "plan_file": plan_file,
    "progress_file": progress_file,
    "result_file": result_file,
    "status": status,
}
path = Path(active_file)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

pm_update_active_issue_status() {
  local next_status="$1"
  local active_file
  active_file="$(pm_active_issue_file)"
  [[ -f "$active_file" ]] || return 0
  python3 - "$active_file" "$next_status" <<'PY'
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
status = sys.argv[2]
payload = json.loads(path.read_text(encoding="utf-8"))
payload["status"] = status
payload["updated_at"] = datetime.now(timezone.utc).isoformat()
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

pm_read_active_field() {
  local field="$1"
  local active_file
  active_file="$(pm_active_issue_file)"
  if [[ ! -f "$active_file" ]]; then
    return 1
  fi
  python3 - "$active_file" "$field" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
payload = json.loads(path.read_text(encoding="utf-8"))
value = payload.get(field, "")
if isinstance(value, (dict, list)):
    import json as _json
    print(_json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

pm_read_active_json() {
  local active_file
  active_file="$(pm_active_issue_file)"
  [[ -f "$active_file" ]] || return 1
  cat "$active_file"
}

pm_active_issue_matches() {
  local issue_number="$1"
  local current_issue=""
  current_issue="$(pm_read_active_field issue 2>/dev/null || true)"
  [[ -n "$current_issue" && "$current_issue" == "$issue_number" ]]
}

pm_archive_active_issue() {
  local active_file last_file
  active_file="$(pm_active_issue_file)"
  last_file="$(pm_last_active_issue_file)"
  if [[ -f "$active_file" ]]; then
    mkdir -p "$(pm_state_dir)"
    mv "$active_file" "$last_file"
  fi
}

pm_clear_active_issue() {
  local active_file
  active_file="$(pm_active_issue_file)"
  [[ -f "$active_file" ]] || return 0
  rm -f "$active_file"
}

pm_set_issue_status_label() {
  local repo="$1"
  local issue_number="$2"
  local target_status="$3"
  gh issue edit "$issue_number" --repo "$repo" \
    --add-label "$target_status" \
    --remove-label "status:todo" \
    --remove-label "status:in-progress" \
    --remove-label "status:blocked" \
    --remove-label "status:review" \
    --remove-label "status:done" \
    --remove-label "status:wont-fix" \
    --remove-label "status:duplicate" >/dev/null
}

pm_add_type_label_if_missing() {
  local repo="$1"
  local issue_number="$2"
  local title="$3"
  local labels_json type_count inferred_type
  labels_json="$(gh issue view "$issue_number" --repo "$repo" --json labels)"
  type_count="$(jq '[.labels[].name | ascii_downcase | select(startswith("type:"))] | length' <<<"$labels_json")"
  if [[ "$type_count" -eq 0 ]]; then
    inferred_type="$(pm_infer_type_label_from_title "$title")"
    gh issue edit "$issue_number" --repo "$repo" --add-label "$inferred_type" >/dev/null
  fi
}

pm_find_recent_issue_from_comments() {
  local repo="$1"
  local limit="${2:-30}"
  local issues_json issue_number view_json
  issues_json="$(gh issue list --repo "$repo" --state open --limit "$limit" --json number,title,updatedAt,url \
    | jq 'sort_by(.updatedAt) | reverse')"
  while IFS= read -r issue_number; do
    [[ -n "$issue_number" ]] || continue
    view_json="$(gh issue view "$issue_number" --repo "$repo" --json number,title,state,url,labels,comments)"
    if jq -e '[.comments[].body | select(test("^### (START|PLAN|PROGRESS) \\| "; "m"))] | length > 0' <<<"$view_json" >/dev/null; then
      printf '%s\n' "$view_json"
      return 0
    fi
  done < <(jq -r '.[].number' <<<"$issues_json")
  return 1
}

pm_find_worktree_for_branch() {
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

pm_abs_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve())
PY
}

pm_resolve_path_in_worktree() {
  local worktree_path="$1"
  local repo_relative_path="$2"
  python3 - "$worktree_path" "$repo_relative_path" <<'PY'
from pathlib import Path
import sys

worktree = Path(sys.argv[1]).resolve()
relative = Path(sys.argv[2])
print((worktree / relative).resolve())
PY
}

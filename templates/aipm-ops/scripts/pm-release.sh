#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/pm-release.sh [patch|minor|major] [--dry-run] [--enforce-milestone|--no-enforce-milestone]
  ./scripts/pm-release.sh --backfill-all [--dry-run] [--bootstrap-if-missing|--no-bootstrap-if-missing] [--enforce-milestone|--no-enforce-milestone]

Description:
  Standardized release/tag workflow for AIPM.

Modes:
  1) Create release (default): bump SemVer and publish a new release.
     - default bump: patch
     - supported bump: patch | minor | major

  2) Backfill mode: standardize all existing release notes.
     - if no releases and --bootstrap-if-missing, create an initial release.

Notes:
  - In backfill mode, inferred text is marked with "(inferred)".
  - Scope for parity/backfill is SemVer tags only: ^[Vv]<major>.<minor>.<patch>$
  - Standard sections are enforced:
    Highlights / Changed by Type / Compatibility / Validation / Links
  - Milestone parity is enforced by default:
    Release version tag == Milestone title (1:1).
  - Milestone issue assignment is enforced by default:
    Release-range issues are assigned to the matching milestone.
  - In backfill mode, issue milestones may be reassigned by release window to restore parity.

Examples:
  ./scripts/pm-release.sh
  ./scripts/pm-release.sh minor
  ./scripts/pm-release.sh --backfill-all
  ./scripts/pm-release.sh --backfill-all --bootstrap-if-missing
  ./scripts/pm-release.sh --no-enforce-milestone
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

log() {
  printf '%s\n' "$*"
}

parse_semver_triplet() {
  local raw="$1"
  if [[ "$raw" =~ ^[Vv]([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi

  return 1
}

tag_rank() {
  local tag="$1"
  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "1"
  elif [[ "$tag" =~ ^[Vv][0-9]+\.[0-9]+$ ]]; then
    echo "2"
  elif [[ "$tag" =~ ^[Vv][0-9]+$ ]]; then
    echo "3"
  else
    echo "4"
  fi
}

build_semver_table_all() {
  local out="$1"
  : > "$out"

  {
    git tag --list
    gh release list --limit 200 --json tagName | jq -r '.[].tagName'
  } | sed '/^$/d' | sort -u | while read -r tag; do
    local triplet=""
    if triplet="$(parse_semver_triplet "$tag" 2>/dev/null)"; then
      local m n p
      read -r m n p <<< "$triplet"
      local rank
      rank="$(tag_rank "$tag")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$n" "$p" "$rank" "$tag" >> "$out"
    fi
  done
}

build_semver_table_releases() {
  local out="$1"
  : > "$out"

  gh release list --limit 200 --json tagName | jq -r '.[].tagName' | sed '/^$/d' | sort -u | while read -r tag; do
    local triplet=""
    if triplet="$(parse_semver_triplet "$tag" 2>/dev/null)"; then
      local m n p
      read -r m n p <<< "$triplet"
      local rank
      rank="$(tag_rank "$tag")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$n" "$p" "$rank" "$tag" >> "$out"
    fi
  done
}

latest_line_from_table() {
  local table="$1"
  if [[ ! -s "$table" ]]; then
    return 1
  fi
  sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4n "$table" | head -n 1
}

prev_tag_before_version() {
  local table="$1"
  local m="$2"
  local n="$3"
  local p="$4"

  awk -F $'\t' -v M="$m" -v N="$n" -v P="$p" '
    ($1+0 < M+0) ||
    ($1+0 == M+0 && $2+0 < N+0) ||
    ($1+0 == M+0 && $2+0 == N+0 && $3+0 < P+0)
  ' "$table" | sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4n | head -n 1 | cut -f5
}

next_version_tag() {
  local bump="$1"
  local table="$2"

  local m=0 n=0 p=0
  local latest=""
  if latest="$(latest_line_from_table "$table" 2>/dev/null)"; then
    m="$(printf '%s' "$latest" | cut -f1)"
    n="$(printf '%s' "$latest" | cut -f2)"
    p="$(printf '%s' "$latest" | cut -f3)"
  fi

  if [[ -z "$latest" ]]; then
    case "$bump" in
      patch|minor) echo "v0.1.0" ;;
      major) echo "v1.0.0" ;;
      *) echo "invalid bump: $bump" >&2; exit 1 ;;
    esac
    return 0
  fi

  case "$bump" in
    patch)
      p=$((p + 1))
      ;;
    minor)
      n=$((n + 1))
      p=0
      ;;
    major)
      m=$((m + 1))
      n=0
      p=0
      ;;
    *)
      echo "invalid bump: $bump" >&2
      exit 1
      ;;
  esac

  echo "v${m}.${n}.${p}"
}

extract_old_bullets() {
  local body="$1"
  printf '%s\n' "$body" | awk '
    /^[-*] / {
      line=$0
      sub(/^[-*] /, "", line)
      print line
      c++
      if (c == 3) exit
    }
  '
}

extract_validation_lines() {
  local body="$1"
  printf '%s\n' "$body" | awk '
    BEGIN {IGNORECASE=1}
    /(tests?|테스트|quality|게이트|e2e|pass|benchmark|words?|단어|pdf|epub)/ {
      line=$0
      sub(/^[-*] /, "", line)
      print line
      c++
      if (c == 3) exit
    }
  '
}

extract_compat_lines() {
  local body="$1"
  printf '%s\n' "$body" | awk '
    BEGIN {IGNORECASE=1}
    /(breaking|compat|호환|migration|upgrade|deprecated|removed|비호환)/ {
      line=$0
      sub(/^[-*] /, "", line)
      print line
      c++
      if (c == 2) exit
    }
  '
}

collect_issue_ids_from_commit_range() {
  local range_expr="$1"
  local out_file="$2"
  : > "$out_file"

  if [[ -z "$range_expr" ]]; then
    return 0
  fi

  local log_file
  log_file="$(mktemp)"
  git log "$range_expr" --pretty=format:'%s%n%b%n---' > "$log_file" 2>/dev/null || true

  local refs_file
  refs_file="$(mktemp)"
  local keys_file
  keys_file="$(mktemp)"

  awk 'BEGIN{IGNORECASE=1} /(refs|closes|fixes)[[:space:]]*#/ {print}' "$log_file" \
    | grep -Eo '#[0-9]+' \
    | tr -d '#' > "$refs_file" || true

  grep -Eo '\[[A-Z][A-Z0-9_-]*-[0-9]+\]' "$log_file" \
    | grep -Eo '[0-9]+' > "$keys_file" || true

  cat "$refs_file" "$keys_file" 2>/dev/null \
    | awk '$1+0 > 0 {print $1}' \
    | sort -u > "$out_file" || true

  rm -f "$log_file" "$refs_file" "$keys_file"
}

collect_issue_ids_from_release_body() {
  local body="$1"
  local out_file="$2"
  : > "$out_file"

  if [[ -z "$body" ]]; then
    return 0
  fi

  printf '%s\n' "$body" \
    | grep -Eo '#[0-9]+' \
    | tr -d '#' \
    | awk '$1+0 > 0 {print $1}' \
    | sort -u > "$out_file" || true
}

issue_exists() {
  local issue_number="$1"
  gh issue view "$issue_number" >/dev/null 2>&1
}

issue_milestone_title_by_number() {
  local issue_number="$1"
  gh issue view "$issue_number" --json milestone --jq '.milestone.title // ""' 2>/dev/null || true
}

resolve_release_range_expr() {
  local prev_tag="$1"
  local end_ref="$2"
  if [[ -n "$prev_tag" ]] && git rev-parse -q --verify "${prev_tag}^{commit}" >/dev/null 2>&1; then
    printf '%s..%s\n' "$prev_tag" "$end_ref"
  else
    printf '%s\n' "$end_ref"
  fi
}

release_published_at_by_tag() {
  local tag="$1"
  gh release view "$tag" --json publishedAt --jq '.publishedAt // ""' 2>/dev/null || true
}

issue_in_time_window() {
  local issue_number="$1"
  local start_iso="$2"
  local end_iso="$3"

  local created_at=""
  local closed_at=""
  local ts
  ts="$(gh issue view "$issue_number" --json createdAt,closedAt --jq '[.createdAt, (.closedAt // "")] | @tsv' 2>/dev/null || true)"
  if [[ -z "$ts" ]]; then
    return 1
  fi
  created_at="${ts%%$'\t'*}"
  closed_at="${ts#*$'\t'}"
  local reference_ts="$created_at"
  if [[ -n "$closed_at" ]]; then
    reference_ts="$closed_at"
  fi

  if [[ -n "$end_iso" && "$reference_ts" > "$end_iso" ]]; then
    return 1
  fi

  if [[ -n "$start_iso" ]] && [[ ! "$reference_ts" > "$start_iso" ]]; then
    return 1
  fi

  return 0
}

collect_commit_subjects() {
  local range_expr="$1"
  local limit="${2:-30}"
  if [[ -z "$range_expr" ]]; then
    return 0
  fi
  git log "$range_expr" --pretty=format:'%s' -n "$limit" 2>/dev/null || true
}

classify_commits() {
  local commit_file="$1"
  local added_file="$2"
  local changed_file="$3"
  local fixed_file="$4"
  local removed_file="$5"

  : > "$added_file"
  : > "$changed_file"
  : > "$fixed_file"
  : > "$removed_file"

  while IFS= read -r subject; do
    [[ -z "$subject" ]] && continue
    local lower
    lower="$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower" =~ (^feat(\(|:))|(^feature:) ]]; then
      printf '%s\n' "$subject" >> "$added_file"
    elif [[ "$lower" =~ (^fix(\(|:))|(^bug(\(|:))|\bbug\b ]]; then
      printf '%s\n' "$subject" >> "$fixed_file"
    elif [[ "$lower" =~ breaking|deprecated|removed|^remove(\(|:)|^drop(\(|:)|! ]]; then
      printf '%s\n' "$subject" >> "$removed_file"
    else
      printf '%s\n' "$subject" >> "$changed_file"
    fi
  done < "$commit_file"

  sort -u "$added_file" -o "$added_file"
  sort -u "$changed_file" -o "$changed_file"
  sort -u "$fixed_file" -o "$fixed_file"
  sort -u "$removed_file" -o "$removed_file"
}

emit_list_or_default() {
  local file="$1"
  local default_line="$2"
  local suffix="$3"

  if [[ -s "$file" ]]; then
    awk -v sfx="$suffix" 'NR<=5 {printf "- %s%s\n", $0, sfx}' "$file"
  else
    printf -- '- %s\n' "$default_line"
  fi
}

extract_pr_links() {
  local body="$1"
  local out="$2"
  : > "$out"
  printf '%s\n' "$body" | grep -oE 'https://github\.com/[^ )]+/pull/[0-9]+' | sort -u > "$out" || true
}

extract_issue_refs() {
  local body="$1"
  local out="$2"
  : > "$out"
  printf '%s\n' "$body" | grep -oE '#[0-9]+' | sort -u > "$out" || true
}

join_file_csv() {
  local in_file="$1"
  if [[ ! -s "$in_file" ]]; then
    return 1
  fi
  awk 'NR==1 {printf "%s", $0; next} {printf ", %s", $0} END {print ""}' "$in_file"
}

generate_release_notes() {
  local tag="$1"
  local prev_tag="$2"
  local end_ref="$3"
  local old_body="$4"
  local mode="$5"
  local out_file="$6"

  local estimate_suffix=""
  if [[ "$mode" == "backfill" ]]; then
    estimate_suffix=" (inferred)"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local commits_file="$tmp_dir/commits.txt"
  local added_file="$tmp_dir/added.txt"
  local changed_file="$tmp_dir/changed.txt"
  local fixed_file="$tmp_dir/fixed.txt"
  local removed_file="$tmp_dir/removed.txt"
  local prs_file="$tmp_dir/prs.txt"
  local issues_file="$tmp_dir/issues.txt"

  local range_expr=""
  if [[ -n "$prev_tag" ]] && git rev-parse -q --verify "${prev_tag}^{commit}" >/dev/null 2>&1; then
    range_expr="${prev_tag}..${end_ref}"
  else
    range_expr="$end_ref"
  fi

  collect_commit_subjects "$range_expr" 30 > "$commits_file"
  classify_commits "$commits_file" "$added_file" "$changed_file" "$fixed_file" "$removed_file"
  extract_pr_links "$old_body" "$prs_file"
  extract_issue_refs "$old_body" "$issues_file"

  local compare_link=""
  if [[ -n "$prev_tag" ]]; then
    compare_link="https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/compare/${prev_tag}...${tag}"
  else
    compare_link="https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/commits/${tag}"
  fi

  {
    echo "## Highlights"

    local highlights
    highlights="$(extract_old_bullets "$old_body" || true)"
    if [[ -n "$highlights" ]]; then
      printf '%s\n' "$highlights" | awk 'NF {printf "- %s\n", $0}'
    elif [[ -s "$commits_file" ]]; then
      awk -v sfx="$estimate_suffix" 'NR<=3 {printf "- %s%s\n", $0, sfx}' "$commits_file"
    else
      echo "- No structured highlights were available${estimate_suffix}."
    fi

    echo
    echo "## Changed by Type"
    echo "### Added"
    emit_list_or_default "$added_file" "Not explicitly documented${estimate_suffix}." "$estimate_suffix"
    echo
    echo "### Changed"
    emit_list_or_default "$changed_file" "Not explicitly documented${estimate_suffix}." "$estimate_suffix"
    echo
    echo "### Fixed"
    emit_list_or_default "$fixed_file" "Not explicitly documented${estimate_suffix}." "$estimate_suffix"
    echo
    echo "### Removed/Deprecated"
    emit_list_or_default "$removed_file" "None${estimate_suffix}." "$estimate_suffix"
    echo
    echo "### Security"
    echo "- None${estimate_suffix}."

    echo
    echo "## Compatibility"
    local compat
    compat="$(extract_compat_lines "$old_body" || true)"
    if [[ -n "$compat" ]]; then
      printf '%s\n' "$compat" | awk 'NR==1 {printf "- %s\n", $0} NR==2 {printf "- %s\n", $0}'
    else
      echo "- Breaking changes: none documented${estimate_suffix}."
      echo "- Upgrade notes: not explicitly documented${estimate_suffix}."
    fi

    echo
    echo "## Validation"
    local validation
    validation="$(extract_validation_lines "$old_body" || true)"
    if [[ -n "$validation" ]]; then
      printf '%s\n' "$validation" | awk 'NF {printf "- %s\n", $0}'
    else
      echo "- Tests: not explicitly documented${estimate_suffix}."
      echo "- Quality Gates: not explicitly documented${estimate_suffix}."
      echo "- E2E: not explicitly documented${estimate_suffix}."
    fi

    echo
    echo "## Links"
    echo "- Full Changelog: ${compare_link}"

    local pr_csv=""
    if pr_csv="$(join_file_csv "$prs_file" 2>/dev/null)"; then
      echo "- Key PRs: ${pr_csv}"
    else
      echo "- Key PRs: not explicitly documented${estimate_suffix}."
    fi

    local issue_csv=""
    if issue_csv="$(join_file_csv "$issues_file" 2>/dev/null)"; then
      echo "- Key Issues: ${issue_csv}"
    else
      echo "- Key Issues: not explicitly documented${estimate_suffix}."
    fi
  } > "$out_file"

  rm -rf "$tmp_dir"
}

ensure_remote_tag() {
  local tag="$1"
  local message="$2"
  local dry_run="$3"

  local has_remote=0
  if git ls-remote --tags origin "refs/tags/${tag}" | grep -q "refs/tags/${tag}$"; then
    has_remote=1
  fi

  if [[ "$has_remote" -eq 1 ]]; then
    return 0
  fi

  if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN tag create: $tag"
    else
      git tag -a "$tag" -m "$message"
    fi
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "DRY-RUN tag push: $tag"
  else
    git push origin "$tag"
  fi
}

release_exists() {
  local tag="$1"
  gh release view "$tag" >/dev/null 2>&1
}

repo_name_with_owner() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

milestone_number_by_title() {
  local title="$1"
  local repo
  repo="$(repo_name_with_owner)"
  gh api "repos/${repo}/milestones?state=all&per_page=100" --paginate \
    | jq -r --arg t "$title" '.[] | select(.title==$t) | .number' \
    | head -n 1
}

milestone_state_by_title() {
  local title="$1"
  local repo
  repo="$(repo_name_with_owner)"
  gh api "repos/${repo}/milestones?state=all&per_page=100" --paginate \
    | jq -r --arg t "$title" '.[] | select(.title==$t) | .state' \
    | head -n 1
}

ensure_milestone_for_tag() {
  local tag="$1"
  local dry_run="$2"
  local repo
  repo="$(repo_name_with_owner)"

  local number
  number="$(milestone_number_by_title "$tag")"
  if [[ -n "$number" ]]; then
    return 0
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "DRY-RUN milestone create: $tag"
    return 0
  fi

  gh api -X POST "repos/${repo}/milestones" -f title="$tag" >/dev/null
}

ensure_milestone_closed_for_tag() {
  local tag="$1"
  local dry_run="$2"
  local repo
  repo="$(repo_name_with_owner)"

  local number
  number="$(milestone_number_by_title "$tag")"
  if [[ -z "$number" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN milestone close: $tag (milestone would be created in non-dry-run mode)"
      return 0
    fi
    echo "error: milestone '$tag' not found after ensure step." >&2
    exit 1
  fi

  local state
  state="$(milestone_state_by_title "$tag")"
  if [[ "$state" == "closed" ]]; then
    return 0
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "DRY-RUN milestone close: $tag (#$number)"
    return 0
  fi

  gh api -X PATCH "repos/${repo}/milestones/${number}" -f state=closed >/dev/null
}

sanitize_milestone_description_issue_refs() {
  local tag="$1"
  local dry_run="$2"
  local repo
  repo="$(repo_name_with_owner)"

  local number
  number="$(milestone_number_by_title "$tag")"
  if [[ -z "$number" ]]; then
    return 0
  fi

  local description=""
  description="$(gh api "repos/${repo}/milestones/${number}" --jq '.description // ""' 2>/dev/null || true)"
  if [[ -z "$description" ]]; then
    return 0
  fi

  local sanitized=""
  sanitized="$(printf '%s' "$description" | sed -E 's/#[0-9]+//g; s/\([[:space:]]*\)//g')"
  if [[ "$sanitized" == "$description" ]]; then
    return 0
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "DRY-RUN milestone description sanitize: $tag (#$number)"
    return 0
  fi

  gh api -X PATCH "repos/${repo}/milestones/${number}" --raw-field description="$sanitized" >/dev/null
}

ensure_issue_assignment_for_tag() {
  local tag="$1"
  local range_expr="$2"
  local dry_run="$3"
  local enforce_milestone="$4"
  local start_iso="${5:-}"
  local end_iso="${6:-}"
  local reassign_conflicts="${7:-0}"
  local release_body="${8:-}"

  local milestone_number
  milestone_number="$(milestone_number_by_title "$tag")"
  if [[ -z "$milestone_number" ]]; then
    if [[ "$enforce_milestone" -eq 1 ]]; then
      ensure_milestone_for_tag "$tag" "$dry_run"
      milestone_number="$(milestone_number_by_title "$tag")"
      if [[ -z "$milestone_number" && "$dry_run" -eq 1 ]]; then
        log "DRY-RUN issue milestone assignment: $tag (milestone would be created in non-dry-run mode)"
        return 0
      fi
    else
      log "issue milestone assignment skipped: milestone '$tag' not found."
      return 0
    fi
  fi

  if [[ -z "$milestone_number" ]]; then
    echo "error: milestone '$tag' not found for issue assignment." >&2
    exit 1
  fi

  local milestone_state
  milestone_state="$(milestone_state_by_title "$tag")"
  local reopened_for_assignment=0

  local issue_ids_file
  issue_ids_file="$(mktemp)"
  collect_issue_ids_from_commit_range "$range_expr" "$issue_ids_file"

  if [[ ! -s "$issue_ids_file" ]]; then
    collect_issue_ids_from_release_body "$release_body" "$issue_ids_file"
    if [[ ! -s "$issue_ids_file" ]]; then
      log "issue milestone assignment: no issue ids found for $tag ($range_expr)."
      rm -f "$issue_ids_file"
      return 0
    fi
  fi

  local issue_number
  while IFS= read -r issue_number; do
    [[ -z "$issue_number" ]] && continue
    if ! issue_exists "$issue_number"; then
      log "issue milestone assignment: skip missing issue #$issue_number"
      continue
    fi
    if ! issue_in_time_window "$issue_number" "$start_iso" "$end_iso"; then
      log "issue milestone assignment: skip #$issue_number (outside release window)"
      continue
    fi

    local current_milestone
    current_milestone="$(issue_milestone_title_by_number "$issue_number")"
    if [[ "$current_milestone" == "$tag" ]]; then
      continue
    fi
    if [[ -n "$current_milestone" && "$current_milestone" != "$tag" ]]; then
      if [[ "$reassign_conflicts" -eq 1 ]]; then
        log "issue milestone assignment: reassign #$issue_number ($current_milestone -> $tag)"
      else
        log "issue milestone assignment: skip #$issue_number (already assigned to $current_milestone)"
        continue
      fi
    fi

    if [[ "$milestone_state" == "closed" && "$reopened_for_assignment" -eq 0 ]]; then
      if [[ "$dry_run" -eq 1 ]]; then
        log "DRY-RUN milestone reopen for issue assignment: $tag (#$milestone_number)"
      else
        gh api -X PATCH "repos/$(repo_name_with_owner)/milestones/${milestone_number}" -f state=open >/dev/null
      fi
      reopened_for_assignment=1
    fi

    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN issue milestone set: #$issue_number -> $tag"
    else
      gh issue edit "$issue_number" --milestone "$tag" >/dev/null
    fi
  done < "$issue_ids_file"

  if [[ "$milestone_state" == "closed" && "$reopened_for_assignment" -eq 1 ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN milestone re-close after issue assignment: $tag (#$milestone_number)"
    else
      gh api -X PATCH "repos/$(repo_name_with_owner)/milestones/${milestone_number}" -f state=closed >/dev/null
    fi
  fi

  rm -f "$issue_ids_file"
}

publish_or_update_release() {
  local tag="$1"
  local title="$2"
  local notes_file="$3"
  local dry_run="$4"

  if release_exists "$tag"; then
    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN release edit: $tag"
    else
      gh release edit "$tag" --title "$title" --notes-file "$notes_file"
    fi
  else
    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN release create: $tag"
    else
      gh release create "$tag" --verify-tag --title "$title" --notes-file "$notes_file"
    fi
  fi
}

run_new_release() {
  local bump="$1"
  local dry_run="$2"
  local enforce_milestone="$3"

  local table
  table="$(mktemp)"
  local notes_file
  notes_file="$(mktemp)"

  build_semver_table_all "$table"

  local new_tag
  new_tag="$(next_version_tag "$bump" "$table")"

  local new_triplet
  new_triplet="$(parse_semver_triplet "$new_tag")"
  local m n p
  read -r m n p <<< "$new_triplet"
  local prev_tag
  prev_tag="$(prev_tag_before_version "$table" "$m" "$n" "$p")"

  local old_body=""
  generate_release_notes "$new_tag" "$prev_tag" "HEAD" "$old_body" "create" "$notes_file"
  local release_title="${new_tag} — Standardized Release"
  local range_expr
  range_expr="$(resolve_release_range_expr "$prev_tag" "HEAD")"
  local start_iso=""
  local end_iso=""
  if [[ -n "$prev_tag" ]]; then
    start_iso="$(release_published_at_by_tag "$prev_tag")"
  fi
  end_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  log "repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  log "bump=$bump"
  log "prev_tag=${prev_tag:-none}"
  log "new_tag=$new_tag"

  if [[ "$enforce_milestone" -eq 1 ]]; then
    ensure_milestone_for_tag "$new_tag" "$dry_run"
    sanitize_milestone_description_issue_refs "$new_tag" "$dry_run"
  fi

  ensure_issue_assignment_for_tag "$new_tag" "$range_expr" "$dry_run" "$enforce_milestone" "$start_iso" "$end_iso" 0 "$old_body"
  ensure_remote_tag "$new_tag" "$new_tag — automated by pm-release" "$dry_run"
  publish_or_update_release "$new_tag" "$release_title" "$notes_file" "$dry_run"

  if [[ "$enforce_milestone" -eq 1 ]]; then
    ensure_milestone_closed_for_tag "$new_tag" "$dry_run"
  fi

  rm -f "$table" "$notes_file"
}

run_backfill_all() {
  local dry_run="$1"
  local bootstrap_if_missing="$2"
  local enforce_milestone="$3"

  local release_count
  release_count="$(gh release list --limit 200 --json tagName | jq 'length')"

  if [[ "$release_count" -eq 0 ]]; then
    if [[ "$bootstrap_if_missing" -eq 1 ]]; then
      log "No releases found; bootstrapping initial release."
      run_new_release "patch" "$dry_run" "$enforce_milestone"
      return 0
    fi
    log "No releases found and bootstrap disabled; nothing to do."
    return 0
  fi

  git fetch --tags --quiet || true

  local release_table
  release_table="$(mktemp)"
  build_semver_table_releases "$release_table"

  if [[ ! -s "$release_table" ]]; then
    if [[ "$bootstrap_if_missing" -eq 1 ]]; then
      log "No SemVer release tags (vX.Y.Z) found; bootstrapping initial release."
      run_new_release "patch" "$dry_run" "$enforce_milestone"
      rm -f "$release_table"
      return 0
    fi
    log "No SemVer release tags (vX.Y.Z) found; nothing to backfill."
    rm -f "$release_table"
    return 0
  fi

  local ordered
  ordered="$(mktemp)"
  sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n "$release_table" > "$ordered"

  local prev_tag=""
  while IFS=$'\t' read -r _m _n _p _rank tag; do
    [[ -z "$tag" ]] && continue

    local old_body
    old_body="$(gh release view "$tag" --json body --jq .body 2>/dev/null || true)"

    local notes_file
    notes_file="$(mktemp)"
    generate_release_notes "$tag" "$prev_tag" "$tag" "$old_body" "backfill" "$notes_file"
    local range_expr
    range_expr="$(resolve_release_range_expr "$prev_tag" "$tag")"
    local start_iso=""
    local end_iso=""
    if [[ -n "$prev_tag" ]]; then
      start_iso="$(release_published_at_by_tag "$prev_tag")"
    fi
    end_iso="$(release_published_at_by_tag "$tag")"

    local title
    title="$(gh release view "$tag" --json name --jq .name 2>/dev/null || true)"
    if [[ -z "$title" || "$title" == "null" ]]; then
      title="$tag — Standardized Release"
    fi

    log "backfill tag=$tag prev=${prev_tag:-none}"
    if [[ "$enforce_milestone" -eq 1 ]]; then
      ensure_milestone_for_tag "$tag" "$dry_run"
      sanitize_milestone_description_issue_refs "$tag" "$dry_run"
    fi
    ensure_issue_assignment_for_tag "$tag" "$range_expr" "$dry_run" "$enforce_milestone" "$start_iso" "$end_iso" 1 "$old_body"
    if [[ "$dry_run" -eq 1 ]]; then
      log "DRY-RUN release edit: $tag"
    else
      gh release edit "$tag" --title "$title" --notes-file "$notes_file"
    fi

    if [[ "$enforce_milestone" -eq 1 ]]; then
      ensure_milestone_closed_for_tag "$tag" "$dry_run"
    fi

    prev_tag="$tag"
    rm -f "$notes_file"
  done < "$ordered"

  rm -f "$release_table" "$ordered"
}

main() {
  require_cmd git
  require_cmd gh
  require_cmd jq
  require_cmd grep

  local bump="patch"
  local dry_run=0
  local backfill_all=0
  local bootstrap_if_missing=1
  local enforce_milestone=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      patch|minor|major)
        bump="$1"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --backfill-all)
        backfill_all=1
        shift
        ;;
      --bootstrap-if-missing)
        bootstrap_if_missing=1
        shift
        ;;
      --no-bootstrap-if-missing)
        bootstrap_if_missing=0
        shift
        ;;
      --enforce-milestone)
        enforce_milestone=1
        shift
        ;;
      --no-enforce-milestone)
        enforce_milestone=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  cd "$repo_root"

  if [[ "$backfill_all" -eq 1 ]]; then
    run_backfill_all "$dry_run" "$bootstrap_if_missing" "$enforce_milestone"
  else
    run_new_release "$bump" "$dry_run" "$enforce_milestone"
  fi
}

main "$@"

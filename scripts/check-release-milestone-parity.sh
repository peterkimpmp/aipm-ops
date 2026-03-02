#!/usr/bin/env bash
# Managed by AIPM Ops Bootstrap
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/check-release-milestone-parity.sh [--json] [--strict]

Description:
  Checks parity between GitHub release tags and milestone titles (SemVer tags only).

Rules:
  - Target set: tags matching ^v<major>.<minor>.<patch>$ (case-insensitive V/v)
  - Expected: every release tag has same-title milestone
  - Expected: milestone state is closed when release exists
  - Expected: milestone has at least one assigned issue when release exists
  - Expected: milestone description does not include issue references (#123)
  - Allowed: open milestone without release (planned future version)

Options:
  --json    Print machine-readable JSON output
  --strict  Exit non-zero on any parity issue (release-only / non-closed match / closed milestone-only / missing assigned issues / description issue refs)
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

json=0
strict=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      json=1
      shift
      ;;
    --strict)
      strict=1
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

require_cmd gh
require_cmd jq
require_cmd grep

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

releases_file="$tmp_dir/releases.txt"
ms_meta_file="$tmp_dir/milestones.tsv"
milestones_file="$tmp_dir/milestones.txt"
release_only_file="$tmp_dir/release_only.txt"
milestone_only_file="$tmp_dir/milestone_only.txt"
both_file="$tmp_dir/both.txt"
status_mismatch_file="$tmp_dir/status_mismatch.tsv"
open_unreleased_file="$tmp_dir/open_unreleased.txt"
closed_unreleased_file="$tmp_dir/closed_unreleased.txt"
assigned_issue_missing_file="$tmp_dir/assigned_issue_missing.txt"
description_issue_refs_file="$tmp_dir/description_issue_refs.txt"

# Normalize V-prefixed tags into v-prefixed tags.
gh release list --limit 200 --json tagName | jq -r '.[].tagName' \
  | sed -E 's/^V/v/' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u > "$releases_file" || true

gh api "repos/${repo}/milestones?state=all&per_page=100" --paginate \
  | jq -r '.[] | [.title, .state, .number, .open_issues, .closed_issues, ((.description // "") | test("#[0-9]+"))] | @tsv' \
  | sed -E 's/^V/v/' \
  | awk -F $'\t' '$1 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {print}' > "$ms_meta_file"

awk -F $'\t' '{print $1}' "$ms_meta_file" | sort -u > "$milestones_file"

comm -23 "$releases_file" "$milestones_file" > "$release_only_file"
comm -13 "$releases_file" "$milestones_file" > "$milestone_only_file"
comm -12 "$releases_file" "$milestones_file" > "$both_file"

: > "$status_mismatch_file"
: > "$assigned_issue_missing_file"
: > "$description_issue_refs_file"
while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  state="$(awk -F $'\t' -v t="$tag" '$1==t {print $2; exit}' "$ms_meta_file")"
  number="$(awk -F $'\t' -v t="$tag" '$1==t {print $3; exit}' "$ms_meta_file")"
  open_count="$(awk -F $'\t' -v t="$tag" '$1==t {print $4; exit}' "$ms_meta_file")"
  closed_count="$(awk -F $'\t' -v t="$tag" '$1==t {print $5; exit}' "$ms_meta_file")"
  has_issue_ref="$(awk -F $'\t' -v t="$tag" '$1==t {print $6; exit}' "$ms_meta_file")"
  open_count="${open_count:-0}"
  closed_count="${closed_count:-0}"
  if [[ "$state" != "closed" ]]; then
    printf '%s\t%s\t%s\n' "$tag" "$state" "$number" >> "$status_mismatch_file"
  fi
  if (( open_count + closed_count == 0 )); then
    printf '%s\n' "$tag" >> "$assigned_issue_missing_file"
  fi
  if [[ "$has_issue_ref" == "true" ]]; then
    printf '%s\n' "$tag" >> "$description_issue_refs_file"
  fi
done < "$both_file"

: > "$open_unreleased_file"
: > "$closed_unreleased_file"
while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  state="$(awk -F $'\t' -v t="$tag" '$1==t {print $2; exit}' "$ms_meta_file")"
  if [[ "$state" == "open" ]]; then
    echo "$tag" >> "$open_unreleased_file"
  else
    echo "$tag" >> "$closed_unreleased_file"
  fi
done < "$milestone_only_file"

if [[ "$json" -eq 1 ]]; then
  jq -n \
    --arg repo "$repo" \
    --argjson release_only "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$release_only_file")" \
    --argjson milestone_only "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$milestone_only_file")" \
    --argjson both "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$both_file")" \
    --argjson open_unreleased "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$open_unreleased_file")" \
    --argjson closed_unreleased "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$closed_unreleased_file")" \
    --argjson assigned_issue_missing "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$assigned_issue_missing_file")" \
    --argjson description_issue_refs "$(jq -R -s -c 'split("\n") | map(select(length>0))' "$description_issue_refs_file")" \
    --argjson status_mismatch "$(jq -R -s -c 'split("\n") | map(select(length>0)) | map(split("\t") | {tag: .[0], state: .[1], milestone_number: .[2]})' "$status_mismatch_file")" \
    '{repo:$repo, release_only:$release_only, milestone_only:$milestone_only, both:$both, open_unreleased:$open_unreleased, closed_unreleased:$closed_unreleased, assigned_issue_missing:$assigned_issue_missing, description_issue_refs:$description_issue_refs, status_mismatch:$status_mismatch}'
else
  echo "repo=$repo"
  echo "release_only=$(paste -sd ',' "$release_only_file" | sed 's/^$/none/')"
  echo "milestone_only=$(paste -sd ',' "$milestone_only_file" | sed 's/^$/none/')"
  echo "open_unreleased=$(paste -sd ',' "$open_unreleased_file" | sed 's/^$/none/')"
  echo "closed_unreleased=$(paste -sd ',' "$closed_unreleased_file" | sed 's/^$/none/')"
  echo "assigned_issue_missing=$(paste -sd ',' "$assigned_issue_missing_file" | sed 's/^$/none/')"
  echo "description_issue_refs=$(paste -sd ',' "$description_issue_refs_file" | sed 's/^$/none/')"
  if [[ -s "$status_mismatch_file" ]]; then
    echo "status_mismatch="
    awk -F $'\t' '{printf "- %s state=%s milestone#%s\n", $1, $2, $3}' "$status_mismatch_file"
  else
    echo "status_mismatch=none"
  fi
fi

if [[ "$strict" -eq 1 ]]; then
  if [[ -s "$release_only_file" || -s "$status_mismatch_file" || -s "$closed_unreleased_file" || -s "$assigned_issue_missing_file" || -s "$description_issue_refs_file" ]]; then
    exit 2
  fi
fi

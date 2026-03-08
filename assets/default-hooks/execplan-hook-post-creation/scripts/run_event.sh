#!/usr/bin/env bash
set -euo pipefail

PLAN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: run_event.sh --plan <plan_md>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PLAN" || ! -f "$PLAN" ]]; then
  echo "COMMANDS=none"
  echo "FAILURE_SUMMARY=--plan is required and must point to an existing file"
  echo "STATUS=fail"
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
ETERNAL_CYCLER_ROOT="${ETERNAL_CYCLER_ROOT:-}"
if [[ -z "$ETERNAL_CYCLER_ROOT" ]]; then
  echo "COMMANDS=none"
  echo "FAILURE_SUMMARY=ETERNAL_CYCLER_ROOT is not set; run through execplan_gate.sh"
  echo "STATUS=fail"
  exit 1
fi

# shellcheck source=/dev/null
source "$ETERNAL_CYCLER_ROOT/scripts/execplan_plan_metadata.sh"

commands=()
commands+=("git branch --show-current")
commands+=("git status --short")
commands+=("gh pr view --json url,title,body,state,isDraft,headRefName,baseRefName")

branch="$(git branch --show-current)"
git status --short >/dev/null

pr_json="$(gh pr view --json url,title,body,state,isDraft,headRefName,baseRefName 2>/dev/null || true)"
if [[ -z "$pr_json" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=failed to resolve current branch PR metadata; create the draft PR before execplan.post-creation"
  echo "STATUS=fail"
  exit 1
fi

pr_url="$(jq -r '.url // empty' <<< "$pr_json")"
pr_title="$(jq -r '.title // empty' <<< "$pr_json")"
pr_body="$(jq -r '.body // empty' <<< "$pr_json")"
pr_is_draft="$(jq -r '.isDraft // false' <<< "$pr_json")"
pr_head="$(jq -r '.headRefName // empty' <<< "$pr_json")"
pr_base="$(jq -r '.baseRefName // empty' <<< "$pr_json")"
creation_commit="$(git rev-parse HEAD)"

[[ -n "$pr_url" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=current branch PR URL is empty"
  echo "STATUS=fail"
  exit 1
}
[[ "$pr_head" == "$branch" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=current branch '${branch}' does not match PR head '${pr_head}'"
  echo "STATUS=fail"
  exit 1
}
[[ "$pr_is_draft" == "true" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=current branch PR must be a draft PR before execplan.post-creation"
  echo "STATUS=fail"
  exit 1
}
[[ -n "$pr_base" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=PR base branch is empty"
  echo "STATUS=fail"
  exit 1
}

existing_target_pr_url="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_target_pr_url")")"
existing_supersedes_plan="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_supersedes_plan")")"
existing_supersedes_pr_url="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_supersedes_pr_url")")"
branch_slug="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_branch_slug")")"
take="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_take")")"
existing_target_branch="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_target_branch")")"
existing_start_branch="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_start_branch")")"
existing_start_commit="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_start_commit")")"

[[ -n "$branch_slug" ]] || branch_slug="$(derive_branch_slug_from_branch "$branch")"
if ! [[ "$take" =~ ^[0-9]+$ ]] || [[ "$take" -le 0 ]]; then
  take="$(derive_take_from_title "$pr_title")"
fi

if [[ -n "$existing_target_branch" && "$existing_target_branch" != "$pr_base" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=plan target branch '${existing_target_branch}' does not match PR base '${pr_base}'"
  echo "STATUS=fail"
  exit 1
fi
if [[ -n "$existing_start_branch" && "$existing_start_branch" != "$branch" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=plan start branch '${existing_start_branch}' does not match current branch '${branch}'"
  echo "STATUS=fail"
  exit 1
fi
if [[ -n "$existing_start_commit" ]]; then
  creation_commit="$existing_start_commit"
fi

metadata_block=$(cat <<EOF_META
## ExecPlan Metadata

${EXECPLAN_METADATA_START}
- execplan_start_branch: ${branch}
- execplan_target_branch: ${pr_base}
- execplan_start_commit: ${creation_commit}
- execplan_pr_url: ${pr_url}
- execplan_pr_title: ${pr_title}
- execplan_branch_slug: ${branch_slug}
- execplan_take: ${take}
EOF_META
)

if [[ -n "$existing_target_pr_url" ]]; then
  metadata_block+=$'\n'
  metadata_block+="- execplan_target_pr_url: ${existing_target_pr_url}"
fi
if [[ -n "$existing_supersedes_plan" ]]; then
  metadata_block+=$'\n'
  metadata_block+="- execplan_supersedes_plan: ${existing_supersedes_plan}"
fi
if [[ -n "$existing_supersedes_pr_url" ]]; then
  metadata_block+=$'\n'
  metadata_block+="- execplan_supersedes_pr_url: ${existing_supersedes_pr_url}"
fi
metadata_block+=$'\n'
metadata_block+="${EXECPLAN_METADATA_END}"

pr_body_block=$(cat <<EOF_BODY
## ExecPlan PR Body

${EXECPLAN_PR_BODY_START}
${pr_body}
${EXECPLAN_PR_BODY_END}
EOF_BODY
)

commands+=("update execplan metadata block")
replace_or_append_block "$PLAN" "$EXECPLAN_METADATA_START" "$EXECPLAN_METADATA_END" "$metadata_block"
commands+=("update execplan PR body block")
replace_or_append_block "$PLAN" "$EXECPLAN_PR_BODY_START" "$EXECPLAN_PR_BODY_END" "$pr_body_block"

if ! rg -q "<!-- execplan-start-tracked:start -->" "$PLAN"; then
  commands+=("capture start tracked snapshot")
  cat >> "$PLAN" <<EOF_TRACKED

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
EOF_TRACKED

  snapshot_count=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    hash="(deleted)"
    if [[ -e "$path" ]]; then
      hash="$(git hash-object -- "$path" 2>/dev/null || echo "(missing)")"
    fi
    printf -- "- start_tracked_change: %s\t%s\n" "$hash" "$path" >> "$PLAN"
    snapshot_count=$((snapshot_count + 1))
  done < <(git diff --name-only HEAD -- | sort)

  if [[ "$snapshot_count" -eq 0 ]]; then
    echo "- start_tracked_change: (none)	(none)" >> "$PLAN"
  fi

  echo "<!-- execplan-start-tracked:end -->" >> "$PLAN"
fi

if ! rg -q "<!-- execplan-start-untracked:start -->" "$PLAN"; then
  commands+=("capture start untracked snapshot")
  cat >> "$PLAN" <<EOF_UNTRACKED

<!-- execplan-start-untracked:start -->
EOF_UNTRACKED

  snapshot_count=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    hash="$(git hash-object -- "$path" 2>/dev/null || echo "(missing)")"
    printf -- "- start_untracked_file: %s\t%s\n" "$hash" "$path" >> "$PLAN"
    snapshot_count=$((snapshot_count + 1))
  done < <(git ls-files --others --exclude-standard | sort)

  if [[ "$snapshot_count" -eq 0 ]]; then
    echo "- start_untracked_file: (none)	(none)" >> "$PLAN"
  fi

  echo "<!-- execplan-start-untracked:end -->" >> "$PLAN"
fi

echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
echo "FAILURE_SUMMARY=none"
echo "STATUS=pass"

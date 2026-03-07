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
commands+=("gh pr view --json url,title,body,state,headRefName,baseRefName")

current_branch="$(git branch --show-current)"
start_branch="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_start_branch")")"
start_commit="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_start_commit")")"
branch_slug="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_branch_slug")")"
take="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_take")")"
existing_target_pr_url="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_target_pr_url")")"
existing_supersedes_plan="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_supersedes_plan")")"
existing_supersedes_pr_url="$(trim_line "$(read_plan_scalar "$PLAN" "execplan_supersedes_pr_url")")"

if [[ -z "$start_branch" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=execplan_start_branch not found in plan; was execplan.post_creation run?"
  echo "STATUS=fail"
  exit 1
fi
if [[ "$current_branch" != "$start_branch" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=current branch '${current_branch}' does not match plan start branch '${start_branch}'"
  echo "STATUS=fail"
  exit 1
fi

pr_json="$(gh pr view --json url,title,body,state,headRefName,baseRefName 2>/dev/null || true)"
if [[ -z "$pr_json" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=failed to resolve the existing PR for the current branch"
  echo "STATUS=fail"
  exit 1
fi

pr_url="$(jq -r '.url // empty' <<< "$pr_json")"
pr_title="$(jq -r '.title // empty' <<< "$pr_json")"
pr_body="$(jq -r '.body // empty' <<< "$pr_json")"
pr_state="$(jq -r '.state // empty' <<< "$pr_json")"
pr_head="$(jq -r '.headRefName // empty' <<< "$pr_json")"
pr_base="$(jq -r '.baseRefName // empty' <<< "$pr_json")"

[[ -n "$pr_url" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=current branch PR URL is empty"
  echo "STATUS=fail"
  exit 1
}
[[ "$pr_state" == "OPEN" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=resume requires an OPEN PR; current state is '${pr_state}'"
  echo "STATUS=fail"
  exit 1
}
[[ "$pr_head" == "$current_branch" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=current branch '${current_branch}' does not match PR head '${pr_head}'"
  echo "STATUS=fail"
  exit 1
}
[[ -n "$pr_base" ]] || {
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=PR base branch is empty"
  echo "STATUS=fail"
  exit 1
}

[[ -n "$branch_slug" ]] || branch_slug="$(derive_branch_slug_from_branch "$current_branch")"
if ! [[ "$take" =~ ^[0-9]+$ ]] || [[ "$take" -le 0 ]]; then
  take="$(derive_take_from_title "$pr_title")"
fi

metadata_block=$(cat <<EOF_META
## ExecPlan Metadata

${EXECPLAN_METADATA_START}
- execplan_start_branch: ${start_branch}
- execplan_target_branch: ${pr_base}
- execplan_start_commit: ${start_commit}
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

resume_date="$(date -u +"%Y-%m-%d %H:%MZ")"
resume_commit="$(git rev-parse HEAD)"
if ! rg -q "resume_commit: ${resume_commit}" "$PLAN"; then
  commands+=("append resume record to plan")
  cat >> "$PLAN" <<EOF_RESUME

## ExecPlan Resume Record

- resume_date: ${resume_date}
- resume_commit: ${resume_commit}
- operator_feedback: (none)
EOF_RESUME
fi

echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
echo "FAILURE_SUMMARY=none"
echo "STATUS=pass"

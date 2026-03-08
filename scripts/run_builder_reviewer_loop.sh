#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/run_builder_reviewer_loop_lib/common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/run_builder_reviewer_loop_lib/git_pr.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/run_builder_reviewer_loop_lib/plan_state.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/run_builder_reviewer_loop_lib/cycle.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/run_builder_reviewer_loop_lib/prompts.sh"

TASK_TEXT=""
TASK_FILE=""
TARGET_BASE_BRANCH=""
PR_URL=""
PR_TITLE=""
PR_BODY=""
RESUME_PLAN=""
INITIAL_PR_WAS_PROVIDED=0
EXPECTED_PLAN_DOC_FILENAME=""
CURRENT_PLAN_PATH=""
MAX_ITERATIONS=20
MAX_REVIEWER_FAILURES=3
MODEL_BUILDER=""
MODEL_REVIEWER=""
LAST_CODEX_OUTPUT=""
FEEDBACK_HELPER_PATH=""
USER_FEEDBACK_DOC=""
BUILDER_RESPONSE_DOC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      TASK_TEXT="${2:-}"
      shift 2
      ;;
    --task-file)
      TASK_FILE="${2:-}"
      shift 2
      ;;
    --target-branch)
      TARGET_BASE_BRANCH="${2:-}"
      shift 2
      ;;
    --pr-title)
      PR_TITLE="${2:-}"
      shift 2
      ;;
    --pr-body)
      PR_BODY="${2:-}"
      shift 2
      ;;
    --resume-plan)
      RESUME_PLAN="${2:-}"
      INITIAL_PR_WAS_PROVIDED=1
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="${2:-}"
      shift 2
      ;;
    --max-reviewer-failures)
      MAX_REVIEWER_FAILURES="${2:-}"
      shift 2
      ;;
    --model-builder)
      MODEL_BUILDER="${2:-}"
      shift 2
      ;;
    --model-reviewer)
      MODEL_REVIEWER="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n "$TASK_TEXT" && -n "$TASK_FILE" ]]; then
  die "--task and --task-file are mutually exclusive"
fi

if [[ -n "$TASK_FILE" ]]; then
  [[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"
  TASK_TEXT="$(cat "$TASK_FILE")"
fi

if [[ -z "$TASK_TEXT" && -z "$RESUME_PLAN" ]]; then
  echo "either --task or --task-file is required" >&2
  usage >&2
  exit 2
fi

if [[ -z "$RESUME_PLAN" ]]; then
  [[ -n "$TARGET_BASE_BRANCH" ]] || die "--target-branch is required for new takes"
  [[ -n "$PR_TITLE" ]] || die "--pr-title is required for new takes"
  [[ -n "$PR_BODY" ]] || die "--pr-body is required for new takes"
fi

for n in "$MAX_ITERATIONS" "$MAX_REVIEWER_FAILURES"; do
  is_positive_int "$n" || die "numeric options must be positive integers"
done

for cmd in git gh codex jq rg perl; do
  require_cmd "$cmd"
done

WORKDIR="$(resolve_repo_root)"
cd "$WORKDIR"
SUBMODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/execplan_plan_metadata.sh"
SUBMODULE_REL="$(repo_rel_path "$WORKDIR" "$SUBMODULE_ROOT")"

PATH_CONTEXT="Path context (all paths are from the repository root):
- Policy docs:           ${SUBMODULE_REL}/PLANS.md, ${SUBMODULE_REL}/REVIEW.md
- Outside-sandbox rules: .codex/rules/eternal-cycler.rules
- ExecPlan gate:         ${SUBMODULE_REL}/scripts/execplan_gate.sh
- Feedback helper:       ${SUBMODULE_REL}/scripts/execplan_user_feedback.sh
- ExecPlan hooks:        .agents/skills/execplan-hook-*/  (copied from ${SUBMODULE_REL}/assets/default-hooks/ by setup.sh)
- Hook naming/path rules: see ${SUBMODULE_REL}/PLANS.md (single source of truth)
- Plans dir:             eternal-cycler-out/plans/
- User feedback dir:     eternal-cycler-out/user-feedback/
- Builder response dir:  eternal-cycler-out/builder-response/
- ExecPlan metadata:     use the execplan-metadata and execplan-pr-body marker blocks inside the plan file
Paths to policy docs and gate script are relative to ${SUBMODULE_REL}/. Paths to hooks and plans are relative to the repository root."

if [[ -n "$(git ls-files -u)" ]]; then
  die "unmerged paths detected; resolve conflicts first"
fi
if has_tracked_dirty; then
  die "tracked working tree is dirty; commit/stash before running the loop"
fi

CURRENT_WORK_BRANCH="$(resolve_current_branch || true)"
[[ -n "$CURRENT_WORK_BRANCH" ]] || die "unable to resolve current branch"
CURRENT_BRANCH_SLUG="$(derive_branch_slug_from_branch "$CURRENT_WORK_BRANCH")"
if [[ -n "$PR_TITLE" ]]; then
  PR_TITLE_BASE="$(strip_take_suffix "$PR_TITLE")"
  CURRENT_TAKE="$(derive_take_from_title "$PR_TITLE")"
fi
if [[ -n "$PR_BODY" ]]; then
  PR_BODY_BASE="$(strip_revision_note_block "$PR_BODY")"
fi

if [[ -n "$RESUME_PLAN" ]]; then
  EXPECTED_PLAN_DOC_FILENAME="$(repo_rel_path "$WORKDIR" "$(plan_abs_path "$WORKDIR" "$RESUME_PLAN")")"
  [[ -f "$(plan_abs_path "$WORKDIR" "$EXPECTED_PLAN_DOC_FILENAME")" ]] || die "resume plan not found: $RESUME_PLAN"
  [[ "$EXPECTED_PLAN_DOC_FILENAME" == eternal-cycler-out/plans/active/* ]] || die "--resume-plan must point to an active plan: $EXPECTED_PLAN_DOC_FILENAME"

  resume_start_branch="$(trim_line "$(read_plan_scalar "$(plan_abs_path "$WORKDIR" "$EXPECTED_PLAN_DOC_FILENAME")" "execplan_start_branch")")"
  PR_URL="$(trim_line "$(read_plan_scalar "$(plan_abs_path "$WORKDIR" "$EXPECTED_PLAN_DOC_FILENAME")" "execplan_pr_url")")"
  plan_target_branch="$(trim_line "$(read_plan_scalar "$(plan_abs_path "$WORKDIR" "$EXPECTED_PLAN_DOC_FILENAME")" "execplan_target_branch")")"
  if [[ -n "$TARGET_BASE_BRANCH" && "$TARGET_BASE_BRANCH" != "$plan_target_branch" ]]; then
    log "ignoring explicit --target-branch=${TARGET_BASE_BRANCH} for resume; using plan target branch ${plan_target_branch}"
  fi
  TARGET_BASE_BRANCH="$plan_target_branch"
  [[ -n "$resume_start_branch" ]] || die "resume plan is missing execplan_start_branch: $EXPECTED_PLAN_DOC_FILENAME"
  [[ -n "$PR_URL" ]] || die "resume plan is missing execplan_pr_url: $EXPECTED_PLAN_DOC_FILENAME"
  [[ -n "$TARGET_BASE_BRANCH" ]] || die "resume plan is missing execplan_target_branch: $EXPECTED_PLAN_DOC_FILENAME"
  if [[ -z "$TASK_TEXT" ]]; then
    TASK_TEXT="Resume the ExecPlan at ${EXPECTED_PLAN_DOC_FILENAME}. Read it in full, update the living document if needed for the current state, then execute all incomplete actions."
  fi

  refresh_target_branch_or_die "$TARGET_BASE_BRANCH"
  switch_or_track_branch "$resume_start_branch"
  CURRENT_WORK_BRANCH="$resume_start_branch"
  run_command_or_die "failed to pull resume branch origin/${CURRENT_WORK_BRANCH}" git pull --ff-only origin "$CURRENT_WORK_BRANCH"
  validate_existing_pr_context "$PR_URL"
  ensure_resume_gate_for_current_head "$EXPECTED_PLAN_DOC_FILENAME"
  "$SCRIPT_DIR/run_builder_reviewer_doctor.sh" --pr-url "$PR_URL" >/dev/null
  load_plan_runtime_metadata "$EXPECTED_PLAN_DOC_FILENAME"
else
  refresh_target_branch_or_die "$TARGET_BASE_BRANCH"
  CURRENT_BRANCH_SLUG="$(derive_branch_slug_from_task "$TASK_TEXT")"
  CURRENT_WORK_BRANCH="$(generate_unique_work_branch "$CURRENT_BRANCH_SLUG")"
  run_command_or_die "failed to create new work branch ${CURRENT_WORK_BRANCH}" git switch -c "$CURRENT_WORK_BRANCH"
  EXPECTED_PLAN_DOC_FILENAME="$(plan_rel_path_for_branch "$CURRENT_WORK_BRANCH")"
  CURRENT_BRANCH_SLUG="${CURRENT_BRANCH_SLUG:-$(derive_branch_slug_from_branch "$CURRENT_WORK_BRANCH")}"
  CURRENT_TAKE=1
  PR_TITLE_BASE="$(strip_take_suffix "$PR_TITLE")"
  PR_BODY_BASE="$(strip_revision_note_block "$PR_BODY")"

  "$SCRIPT_DIR/run_builder_reviewer_doctor.sh" --head-branch "$CURRENT_WORK_BRANCH" >/dev/null
  "$SCRIPT_DIR/execplan_gate.sh" --event execplan.pre-creation >/dev/null
  PR_URL="$(create_or_reuse_draft_pr_for_branch "$CURRENT_WORK_BRANCH" "$TARGET_BASE_BRANCH" "$PR_TITLE" "$PR_BODY")"
fi

FEEDBACK_HELPER_PATH="${SUBMODULE_REL}/scripts/execplan_user_feedback.sh"
refresh_feedback_doc_paths

if [[ -n "$(git ls-files -u)" ]]; then
  die "unmerged paths detected after PR preparation"
fi
if has_tracked_dirty; then
  die "tracked working tree became dirty after PR preparation"
fi

BASELINE_UNTRACKED_LIST=""
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  BASELINE_UNTRACKED_LIST+="${path}"$'\n'
done < <(git ls-files --others --exclude-standard)

START_COMMIT="$(git rev-parse HEAD)"
LATEST_COMMIT="$START_COMMIT"
RUN_ID="loop-$(date -u +%Y%m%dT%H%M%SZ)-$$"

log "loop started (work_branch=$CURRENT_WORK_BRANCH, target_branch=$TARGET_BASE_BRANCH, pr_url=$PR_URL, expected_plan=$EXPECTED_PLAN_DOC_FILENAME, start_commit=$START_COMMIT, run_id=$RUN_ID)"

run_builder_cycle "builder_initial" "$(build_initial_builder_prompt)" "$START_COMMIT"

REVIEWER_FAILURES=0

for ((ITERATION=1; ITERATION<=MAX_ITERATIONS; ITERATION++)); do
  local_reviewer_schema_file="$(write_reviewer_output_schema)"
  if ! run_codex_prompt_capture "reviewer" "$MODEL_REVIEWER" "$(build_reviewer_prompt)" "$local_reviewer_schema_file"; then
    rm -f "$local_reviewer_schema_file"
    REVIEWER_FAILURES=$((REVIEWER_FAILURES + 1))
    if [[ "$REVIEWER_FAILURES" -ge "$MAX_REVIEWER_FAILURES" ]]; then
      die "reviewer execution failed $REVIEWER_FAILURES times consecutively"
    fi
    continue
  fi
  rm -f "$local_reviewer_schema_file"

  reviewer_payload_json="$(parse_reviewer_payload_json "$LAST_CODEX_OUTPUT" || true)"
  if [[ -z "$reviewer_payload_json" ]]; then
    REVIEWER_FAILURES=$((REVIEWER_FAILURES + 1))
    if [[ "$REVIEWER_FAILURES" -ge "$MAX_REVIEWER_FAILURES" ]]; then
      die "reviewer output was not valid JSON payload for $REVIEWER_FAILURES consecutive attempts"
    fi
    log "reviewer output was not valid JSON payload; retrying review iteration"
    continue
  fi

  reviewer_pr_url="$(jq -r '.pr_url' <<< "$reviewer_payload_json")"
  reviewer_comment_body="$(jq -r '.comment_body' <<< "$reviewer_payload_json")"
  reviewer_approve_merge="$(jq -r '.approve_merge' <<< "$reviewer_payload_json")"

  normalized_reviewer_pr_url="$(normalize_pr_url "$reviewer_pr_url")"
  normalized_target_pr_url="$(normalize_pr_url "$PR_URL")"

  if [[ "$normalized_reviewer_pr_url" != "$normalized_target_pr_url" ]]; then
    REVIEWER_FAILURES=$((REVIEWER_FAILURES + 1))
    if [[ "$REVIEWER_FAILURES" -ge "$MAX_REVIEWER_FAILURES" ]]; then
      die "reviewer payload PR URL mismatch for $REVIEWER_FAILURES consecutive attempts"
    fi
    log "reviewer payload PR URL mismatch (expected=$normalized_target_pr_url got=$normalized_reviewer_pr_url)"
    continue
  fi

  if ! post_output="$(post_pr_comment "$normalized_target_pr_url" "$reviewer_comment_body")"; then
    REVIEWER_FAILURES=$((REVIEWER_FAILURES + 1))
    if [[ "$REVIEWER_FAILURES" -ge "$MAX_REVIEWER_FAILURES" ]]; then
      die "failed to post reviewer comment for $REVIEWER_FAILURES consecutive attempts"
    fi
    continue
  fi

  comment_url="$(printf '%s\n' "$post_output" | rg -o 'https://github\\.com/[^[:space:]]+' | head -n1 || true)"
  REVIEWER_FAILURES=0

  if [[ "$reviewer_approve_merge" == "true" ]]; then
    log "reviewer approve_merge=true for commit $LATEST_COMMIT; loop finished"
    exit 0
  fi

  old_pr_url="$PR_URL"
  old_work_branch="$CURRENT_WORK_BRANCH"

  prepare_next_take_after_rejection "$old_pr_url"

  replacement_work_branch="$CURRENT_WORK_BRANCH"
  replacement_pr_url="$PR_URL"
  replacement_pr_title="$PR_TITLE"
  replacement_pr_body="$PR_BODY"
  replacement_take="$CURRENT_TAKE"

  switch_or_track_branch "$old_work_branch"
  CURRENT_WORK_BRANCH="$old_work_branch"
  superseded_plan_path="$(move_plan_to_completed_as_superseded "$CURRENT_PLAN_PATH" "$old_pr_url" "$reviewer_comment_body")"
  auto_stage_commit_and_push "docs(plan): supersede rejected take"
  close_current_pr_after_rejection "$old_pr_url"

  switch_or_track_branch "$replacement_work_branch"
  CURRENT_WORK_BRANCH="$replacement_work_branch"
  PR_URL="$replacement_pr_url"
  PR_TITLE="$replacement_pr_title"
  PR_BODY="$replacement_pr_body"
  CURRENT_TAKE="$replacement_take"
  EXPECTED_PLAN_DOC_FILENAME="$(plan_rel_path_for_branch "$CURRENT_WORK_BRANCH")"
  refresh_feedback_doc_paths
  LATEST_COMMIT="$(git rev-parse HEAD)"

  builder_prompt="$(build_retake_builder_prompt "$superseded_plan_path" "$old_pr_url" "$reviewer_comment_body" "$comment_url")"
  run_builder_cycle "builder_retake_take_${CURRENT_TAKE}" "$builder_prompt" "$LATEST_COMMIT"
done

die "max iterations reached without reviewer approve_merge=true for commit $LATEST_COMMIT"

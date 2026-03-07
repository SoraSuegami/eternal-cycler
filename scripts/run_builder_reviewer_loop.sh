#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  run_builder_reviewer_loop.sh [--task <text> | --task-file <path>] [options]

Options:
  --task <text>                      Builder initial task text.
  --task-file <path>                 Builder initial task file path.
  --target-branch <branch>           Required PR base branch for this take.
  --pr-title <text>                  Required PR title in English.
  --pr-body <markdown>               Required PR body in English markdown.
  --pr-url <url>                     Optional existing PR URL for resume.
                                    When provided, the PR must already be OPEN and
                                    its head/base must match the current branch and
                                    --target-branch.
  --max-iterations <n>               Max review iterations (default: 20).
  --max-builder-cleanup-retries <n>  Max builder cleanup retries per cycle (default: 5).
  --max-reviewer-failures <n>        Max consecutive reviewer-phase failures (default: 3).
  --model-builder <model>            Optional model for builder codex runs.
  --model-reviewer <model>           Optional model for reviewer codex runs.
  --help                             Show this help.
USAGE
}

log() {
  echo "[loop $(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_current_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    return 1
  fi
  printf '%s\n' "$branch"
}

normalize_pr_url() {
  local pr_url="$1"
  printf '%s\n' "$pr_url" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s:/+$::'
}

parse_reviewer_payload_json() {
  local raw="$1"
  jq -e -c '
    if type != "object" then
      error("reviewer output must be a JSON object")
    else
      .
    end
    | if (.pr_url | type) != "string" then error("pr_url must be string") else . end
    | if (.comment_body | type) != "string" then error("comment_body must be string") else . end
    | .pr_url |= (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | if (.pr_url | length) == 0 then error("pr_url must be non-empty") else . end
    | if (.comment_body | length) == 0 then error("comment_body must be non-empty") else . end
    | if (.approve_merge | type) != "boolean" then error("approve_merge must be boolean") else . end
    | {pr_url, comment_body, approve_merge}
  ' <<< "$raw" 2>/dev/null
}

parse_builder_payload_json() {
  local raw="$1"
  jq -e -c '
    if type != "object" then
      error("builder output must be a JSON object")
    else
      .
    end
    | if (.plan_doc_filename | type) != "string" then error("plan_doc_filename must be string") else . end
    | if (.result | type) != "string" then error("result must be string") else . end
    | if (.comment | type) != "string" then error("comment must be string") else . end
    | .plan_doc_filename |= (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | .comment |= (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | if (.plan_doc_filename | length) == 0 then error("plan_doc_filename must be non-empty") else . end
    | if (.comment | length) == 0 then error("comment must be non-empty") else . end
    | if (.result != "success" and .result != "failed_after_3_retries") then
        error("result must be success or failed_after_3_retries")
      else
        .
      end
    | {plan_doc_filename, result, comment}
  ' <<< "$raw" 2>/dev/null
}

LAST_CODEX_OUTPUT=""

has_tracked_dirty() {
  if ! git diff --quiet --; then
    return 0
  fi
  if ! git diff --cached --quiet --; then
    return 0
  fi
  if [[ -n "$(git ls-files -u)" ]]; then
    return 0
  fi
  return 1
}

branch_head_is_pushed() {
  local branch="$1"
  local local_head remote_head remote_output rc

  local_head="$(git rev-parse HEAD)"

  set +e
  remote_output="$(git ls-remote --heads origin "$branch" 2>/dev/null)"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "failed to query origin/$branch via git ls-remote; treating branch as not pushed yet"
    return 1
  fi

  remote_head="$(awk '{print $1}' <<< "$remote_output" | head -n1)"
  [[ -n "$remote_head" && "$remote_head" == "$local_head" ]]
}

run_codex_prompt() {
  local role="$1"
  local model="$2"
  local prompt_text="$3"

  local cmd=(codex exec --dangerously-bypass-approvals-and-sandbox --cd "$WORKDIR")
  if [[ -n "$model" ]]; then
    cmd+=(--model "$model")
  fi
  cmd+=(-)

  if ! printf '%s\n' "$prompt_text" | "${cmd[@]}"; then
    log "$role codex execution failed"
    return 1
  fi

  return 0
}

write_reviewer_output_schema() {
  local schema_file
  schema_file="$(mktemp)"
  cat > "$schema_file" <<'EOF_SCHEMA'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["pr_url", "comment_body", "approve_merge"],
  "properties": {
    "pr_url": {
      "type": "string",
      "minLength": 1
    },
    "comment_body": {
      "type": "string",
      "minLength": 1
    },
    "approve_merge": {
      "type": "boolean"
    }
  }
}
EOF_SCHEMA
  printf '%s\n' "$schema_file"
}

write_builder_output_schema() {
  local schema_file
  schema_file="$(mktemp)"
  cat > "$schema_file" <<'EOF_SCHEMA'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["plan_doc_filename", "result", "comment"],
  "properties": {
    "plan_doc_filename": {
      "type": "string",
      "minLength": 1
    },
    "result": {
      "type": "string",
      "enum": ["success", "failed_after_3_retries"]
    },
    "comment": {
      "type": "string",
      "minLength": 1
    }
  }
}
EOF_SCHEMA
  printf '%s\n' "$schema_file"
}

run_codex_prompt_capture() {
  local role="$1"
  local model="$2"
  local prompt_text="$3"
  local schema_file="${4:-}"
  local rc last_message_file

  local cmd=(codex exec --dangerously-bypass-approvals-and-sandbox --cd "$WORKDIR")
  if [[ -n "$model" ]]; then
    cmd+=(--model "$model")
  fi
  if [[ -n "$schema_file" ]]; then
    last_message_file="$(mktemp)"
    cmd+=(--output-schema "$schema_file" --output-last-message "$last_message_file")
  fi
  cmd+=(-)

  set +e
  printf '%s\n' "$prompt_text" | "${cmd[@]}"
  rc=$?
  set -e

  if [[ -n "$schema_file" ]]; then
    LAST_CODEX_OUTPUT="$(cat "$last_message_file" 2>/dev/null || true)"
    rm -f "$last_message_file"
  fi

  if [[ "$rc" -ne 0 ]]; then
    log "$role codex execution failed"
    return 1
  fi

  if [[ -n "$schema_file" && -z "$(printf '%s' "$LAST_CODEX_OUTPUT" | tr -d '[:space:]')" ]]; then
    log "$role codex execution produced empty structured output"
    return 1
  fi

  return 0
}

post_pr_comment() {
  local pr_url="$1"
  local comment_body="$2"
  local output rc

  set +e
  output="$(gh pr comment "$pr_url" --body "$comment_body" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "failed to post PR comment for $pr_url: $output"
    return 1
  fi

  printf '%s\n' "$output"
  return 0
}

push_branch() {
  local branch="$1"
  git push -u origin "$branch" >/dev/null 2>&1 || die "failed to push branch to origin/$branch"
}

ensure_pr_ready() {
  local pr_url="$1"
  local is_draft

  is_draft="$(gh pr view "$pr_url" --json isDraft --jq '.isDraft' 2>/dev/null || echo "unknown")"
  if [[ "$is_draft" == "false" ]]; then
    return 0
  fi

  gh pr ready "$pr_url" >/dev/null 2>&1 || true
  is_draft="$(gh pr view "$pr_url" --json isDraft --jq '.isDraft' 2>/dev/null || echo "unknown")"
  [[ "$is_draft" == "false" ]] || die "failed to mark PR ready: $pr_url"
}

get_new_untracked_paths() {
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ -z "${BASELINE_UNTRACKED[$path]+x}" ]]; then
      printf '%s\n' "$path"
    fi
  done < <(git ls-files --others --exclude-standard)
}

auto_stage_commit_and_push() {
  local commit_message="$1"

  git add -u -- . >/dev/null 2>&1 || die "failed to stage tracked changes"

  mapfile -t NEW_UNTRACKED < <(get_new_untracked_paths)
  if [[ ${#NEW_UNTRACKED[@]} -gt 0 ]]; then
    for path in "${NEW_UNTRACKED[@]}"; do
      git add -- "$path" >/dev/null 2>&1 || die "failed to stage new untracked path: $path"
    done
  fi

  if ! git diff --cached --quiet; then
    git commit -m "$commit_message" >/dev/null 2>&1 || die "failed to create loop commit: $commit_message"
  fi

  if ! branch_head_is_pushed "$CURRENT_WORK_BRANCH"; then
    push_branch "$CURRENT_WORK_BRANCH"
  fi
}

run_builder_cleanup_until_stable() {
  local base_commit="$1"
  local attempt=0
  local current_commit tracked_dirty pushed
  local cleanup_prompt
  local untracked_msg

  while true; do
    auto_stage_commit_and_push "loop: checkpoint builder output"

    current_commit="$(git rev-parse HEAD)"

    tracked_dirty=0
    if has_tracked_dirty; then
      tracked_dirty=1
    fi

    mapfile -t NEW_UNTRACKED < <(get_new_untracked_paths)

    pushed=0
    if branch_head_is_pushed "$CURRENT_WORK_BRANCH"; then
      pushed=1
    fi

    if [[ "$current_commit" != "$base_commit" && "$tracked_dirty" -eq 0 && ${#NEW_UNTRACKED[@]} -eq 0 && "$pushed" -eq 1 ]]; then
      printf 'changed|%s\n' "$current_commit"
      return 0
    fi

    if [[ "$current_commit" == "$base_commit" && "$tracked_dirty" -eq 0 && ${#NEW_UNTRACKED[@]} -eq 0 && "$pushed" -eq 1 ]]; then
      printf 'unchanged|%s\n' "$current_commit"
      return 0
    fi

    if [[ "$attempt" -ge "$MAX_BUILDER_CLEANUP_RETRIES" ]]; then
      log "cleanup retries exhausted for base_commit=$base_commit (current=$current_commit, tracked_dirty=$tracked_dirty, new_untracked=${#NEW_UNTRACKED[@]}, pushed=$pushed)"
      return 1
    fi

    attempt=$((attempt + 1))

    if [[ ${#NEW_UNTRACKED[@]} -gt 0 ]]; then
      untracked_msg="$(printf '%s\n' "${NEW_UNTRACKED[@]}")"
    else
      untracked_msg="(none)"
    fi

    cleanup_prompt="You are called by a parent agent as a builder agent.
You are the BUILDER agent in an autonomous loop.

Cleanup request:
- Base commit before your previous attempt: ${base_commit}
- Current commit: ${current_commit}
- Work branch: ${CURRENT_WORK_BRANCH}
- Target branch: ${TARGET_BASE_BRANCH}
- tracked_dirty: ${tracked_dirty}
- new_untracked_outside_baseline:
${untracked_msg}
- pushed_to_origin: ${pushed}

Do the following now:
1) Resolve remaining tracked changes or newly-created untracked files produced by your previous work.
2) Do not modify unrelated baseline untracked files that existed before this loop started.
3) Do not run git commit or git push. The loop script performs commit/push automatically.

After finishing, exit."

    if ! run_codex_prompt "builder_cleanup" "$MODEL_BUILDER" "$cleanup_prompt"; then
      log "builder cleanup attempt ${attempt} failed"
      return 1
    fi
  done
}

sync_pr_state_from_remote() {
  local pr_url="$1"
  local pr_json

  pr_json="$(gh pr view "$pr_url" --json url,title,body,headRefName,baseRefName,state,isDraft 2>/dev/null || true)"
  [[ -n "$pr_json" ]] || die "failed to read PR metadata: $pr_url"

  PR_URL="$(jq -r '.url // empty' <<< "$pr_json")"
  PR_TITLE="$(jq -r '.title // empty' <<< "$pr_json")"
  PR_BODY="$(jq -r '.body // empty' <<< "$pr_json")"
  CURRENT_PR_STATE="$(jq -r '.state // empty' <<< "$pr_json")"
  CURRENT_PR_IS_DRAFT="$(jq -r '.isDraft // false' <<< "$pr_json")"
  CURRENT_PR_HEAD="$(jq -r '.headRefName // empty' <<< "$pr_json")"
  CURRENT_PR_BASE="$(jq -r '.baseRefName // empty' <<< "$pr_json")"

  PR_TITLE_BASE="$(strip_take_suffix "$PR_TITLE")"
  PR_BODY_BASE="$(strip_revision_note_block "$PR_BODY")"
  CURRENT_TAKE="$(derive_take_from_title "$PR_TITLE")"
}

validate_existing_pr_context() {
  local pr_url="$1"

  sync_pr_state_from_remote "$pr_url"

  [[ -n "$CURRENT_PR_HEAD" ]] || die "failed to resolve PR head branch from: $pr_url"
  [[ -n "$CURRENT_PR_BASE" ]] || die "failed to resolve PR base branch from: $pr_url"
  [[ "$CURRENT_PR_STATE" == "OPEN" ]] || die "resume requires an OPEN PR: $pr_url"
  [[ "$CURRENT_PR_HEAD" == "$CURRENT_WORK_BRANCH" ]] || die "--pr-url head branch ($CURRENT_PR_HEAD) must match current local branch ($CURRENT_WORK_BRANCH)"
  [[ "$CURRENT_PR_BASE" == "$TARGET_BASE_BRANCH" ]] || die "--pr-url base branch ($CURRENT_PR_BASE) must match --target-branch ($TARGET_BASE_BRANCH)"
}

resolve_existing_open_pr_for_branch() {
  local branch="$1"
  local open_json

  open_json="$(gh pr list --state open --head "$branch" --json url,updatedAt,isDraft,baseRefName,title,body --limit 20 2>/dev/null || true)"
  jq -r '[.[]] | sort_by(.updatedAt) | reverse | .[0].url // empty' <<< "$open_json"
}

create_or_reuse_draft_pr_for_branch() {
  local branch="$1"
  local base_branch="$2"
  local pr_title="$3"
  local pr_body="$4"
  local pr_url

  pr_url="$(resolve_existing_open_pr_for_branch "$branch")"
  if [[ -n "$pr_url" ]]; then
    validate_existing_pr_context "$pr_url"
    gh pr edit "$pr_url" --title "$pr_title" --body "$pr_body" >/dev/null 2>&1 || die "failed to update existing PR metadata: $pr_url"
    sync_pr_state_from_remote "$pr_url"
    printf '%s\n' "$PR_URL"
    return 0
  fi

  push_branch "$branch"

  set +e
  gh pr create --draft --title "$pr_title" --body "$pr_body" --head "$branch" --base "$base_branch" >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || die "failed to create draft PR for branch '$branch' against '$base_branch'"

  pr_url="$(resolve_existing_open_pr_for_branch "$branch")"
  [[ -n "$pr_url" ]] || die "failed to resolve created draft PR for branch '$branch'"
  sync_pr_state_from_remote "$pr_url"
  [[ "$CURRENT_PR_BASE" == "$base_branch" ]] || die "created PR base branch ($CURRENT_PR_BASE) did not match expected target branch ($base_branch)"
  printf '%s\n' "$PR_URL"
}

branch_exists_anywhere() {
  local branch="$1"
  git show-ref --verify --quiet "refs/heads/$branch" || git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

switch_or_track_branch() {
  local branch="$1"

  if [[ "$(resolve_current_branch || true)" == "$branch" ]]; then
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git switch "$branch" >/dev/null 2>&1 || die "failed to switch to branch: $branch"
    return 0
  fi

  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git switch -c "$branch" --track "origin/$branch" >/dev/null 2>&1 || die "failed to switch to tracking branch: origin/$branch"
    return 0
  fi

  die "branch not found locally or on origin: $branch"
}

generate_unique_work_branch() {
  local slug="$1"
  local stamp candidate suffix=0

  stamp="$(date +"%Y%m%d-%H%M")"
  candidate="${slug}-${stamp}"

  while branch_exists_anywhere "$candidate"; do
    suffix=$((suffix + 1))
    candidate="${slug}-${stamp}-${suffix}"
  done

  printf '%s\n' "$candidate"
}

move_plan_to_completed_as_superseded() {
  local plan_path="$1"
  local closed_pr_url="$2"
  local reviewer_comment="$3"
  local abs_path rel_path destination first_line timestamp

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || die "plan file not found for supersede flow: $plan_path"

  timestamp="$(date -u +"%Y-%m-%d %H:%MZ")"
  first_line="$(printf '%s\n' "$reviewer_comment" | head -n1 | sed -E 's/[[:space:]]+/ /g')"

  cat >> "$abs_path" <<EOF_NOTE

## ExecPlan Superseded Record

- superseded_at: ${timestamp}
- superseded_reason: reviewer_rejected
- superseded_pr_url: ${closed_pr_url}
- superseded_comment_excerpt: ${first_line}
EOF_NOTE

  rel_path="$(repo_rel_path "$WORKDIR" "$abs_path")"
  if [[ "$rel_path" == eternal-cycler-out/plans/active/* ]]; then
    destination="$WORKDIR/eternal-cycler-out/plans/completed/$(basename "$abs_path")"
    mkdir -p "$(dirname "$destination")"
    mv "$abs_path" "$destination"
    printf '%s\n' "$(repo_rel_path "$WORKDIR" "$destination")"
    return 0
  fi

  printf '%s\n' "$rel_path"
}

load_plan_runtime_metadata() {
  local plan_path="$1"
  local abs_path plan_target_branch plan_pr_url plan_pr_title plan_branch_slug plan_take plan_body

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || die "plan file not found: $plan_path"

  CURRENT_PLAN_PATH="$(repo_rel_path "$WORKDIR" "$abs_path")"
  plan_target_branch="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_target_branch")")"
  plan_pr_url="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_pr_url")")"
  plan_pr_title="$(read_plan_scalar "$abs_path" "execplan_pr_title")"
  plan_branch_slug="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_branch_slug")")"
  plan_take="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_take")")"
  plan_body="$(read_plan_block "$abs_path" "$EXECPLAN_PR_BODY_START" "$EXECPLAN_PR_BODY_END")"

  if [[ -n "$plan_target_branch" && "$plan_target_branch" != "$TARGET_BASE_BRANCH" ]]; then
    die "plan target branch ($plan_target_branch) does not match loop target branch ($TARGET_BASE_BRANCH): $CURRENT_PLAN_PATH"
  fi

  if [[ -n "$plan_pr_url" ]]; then
    PR_URL="$(normalize_pr_url "$plan_pr_url")"
  fi
  if [[ -n "$plan_pr_title" ]]; then
    PR_TITLE="$plan_pr_title"
  fi
  if [[ -n "$plan_body" ]]; then
    PR_BODY="$plan_body"
  fi
  if [[ -n "$plan_branch_slug" ]]; then
    CURRENT_BRANCH_SLUG="$plan_branch_slug"
  fi
  if is_positive_int "${plan_take:-0}"; then
    CURRENT_TAKE="$plan_take"
  fi

  if [[ -n "$PR_TITLE" ]]; then
    PR_TITLE_BASE="$(strip_take_suffix "$PR_TITLE")"
  fi
  if [[ -n "$PR_BODY" ]]; then
    PR_BODY_BASE="$(strip_revision_note_block "$PR_BODY")"
  fi
}

post_builder_comment_and_handle_result() {
  local stage="$1"
  local payload_json="$2"
  local result comment_body

  result="$(jq -r '.result' <<< "$payload_json")"
  comment_body="$(jq -r '.comment' <<< "$payload_json")"

  [[ -n "$PR_URL" ]] || die "builder stage ${stage} completed without a PR URL"
  ensure_pr_ready "$PR_URL"
  post_pr_comment "$PR_URL" "$comment_body" >/dev/null || die "failed to post builder comment to $PR_URL"

  if [[ "$result" == "failed_after_3_retries" ]]; then
    die "builder reported failed_after_3_retries at stage=${stage}; plan_doc_filename=$(jq -r '.plan_doc_filename' <<< "$payload_json")"
  fi
}

run_builder_cycle() {
  local stage="$1"
  local prompt_text="$2"
  local base_commit="$3"
  local builder_schema_file builder_payload_json cleanup_result cleanup_kind cleanup_commit plan_doc_filename

  builder_schema_file="$(write_builder_output_schema)"
  if ! run_codex_prompt_capture "$stage" "$MODEL_BUILDER" "$prompt_text" "$builder_schema_file"; then
    rm -f "$builder_schema_file"
    die "${stage} builder execution failed"
  fi
  rm -f "$builder_schema_file"

  builder_payload_json="$(parse_builder_payload_json "$LAST_CODEX_OUTPUT" || true)"
  [[ -n "$builder_payload_json" ]] || die "${stage} builder output was not valid JSON payload"

  cleanup_result="$(run_builder_cleanup_until_stable "$base_commit" || true)"
  [[ -n "$cleanup_result" ]] || die "builder cleanup failed at stage ${stage}"

  cleanup_kind="${cleanup_result%%|*}"
  cleanup_commit="${cleanup_result#*|}"
  plan_doc_filename="$(jq -r '.plan_doc_filename' <<< "$builder_payload_json")"

  load_plan_runtime_metadata "$plan_doc_filename"
  post_builder_comment_and_handle_result "$stage" "$builder_payload_json"

  if [[ "$cleanup_kind" == "changed" ]]; then
    log "new commit detected after builder stage ${stage}: $cleanup_commit"
  else
    log "no new commit after builder stage ${stage}; continuing"
  fi

  LATEST_COMMIT="$cleanup_commit"
}

build_initial_builder_prompt() {
  local plan_bootstrap_instructions=""

  if [[ "$INITIAL_PR_WAS_PROVIDED" -eq 0 ]]; then
    plan_bootstrap_instructions=$(cat <<EOF_BOOTSTRAP
- You are starting a new ExecPlan for this take.
- Create a new ExecPlan in eternal-cycler-out/plans/active/.
- Do NOT modify or resume any existing plan document in eternal-cycler-out/plans/.
- Run execplan.post_creation immediately after writing the new plan.
EOF_BOOTSTRAP
)
  fi

  cat <<EOF_PROMPT
You are the BUILDER agent in an autonomous loop.

${PATH_CONTEXT}

Start by reading ${SUBMODULE_REL}/PLANS.md in full.
Follow the ExecPlan lifecycle defined in that document to complete the task below.

Current execution context:
- Work branch: ${CURRENT_WORK_BRANCH}
- Target branch: ${TARGET_BASE_BRANCH}
- PR URL: ${PR_URL}
- PR title: ${PR_TITLE}
- Branch slug: ${CURRENT_BRANCH_SLUG}
- Take number: ${CURRENT_TAKE}

Task:
${TASK_TEXT}

Requirements:
- Work only on branch: ${CURRENT_WORK_BRANCH}
- The current take must target branch ${TARGET_BASE_BRANCH}
- Existing PR for this take: ${PR_URL}
- Current PR title: ${PR_TITLE}
- Current PR body is already prepared by the caller and stored on the PR.
- If you are resuming an existing ExecPlan, keep working from that plan unless the caller explicitly instructs otherwise.
- If you are starting a new take without an existing plan, follow the new-plan lifecycle.
${plan_bootstrap_instructions}
- If you create a new ExecPlan in this run, include execplan_target_branch: ${TARGET_BASE_BRANCH}, execplan_branch_slug: ${CURRENT_BRANCH_SLUG}, and execplan_take: ${CURRENT_TAKE} in the plan metadata.
- If the caller preamble specifies execplan_target_pr_url or other optional metadata, preserve it in the plan.
- Do not run git commit or git push. The loop script performs commit/push automatically.
- Keep unrelated baseline untracked files untouched.
- Try up to 3 implementation attempts before declaring failure.
- Return exactly one JSON object and nothing else:
  {"plan_doc_filename":"<relative-plan-path>","result":"success|failed_after_3_retries","comment":"<english hook-summary-or-failure-reason>"}
- Use result=success only when implementation is complete for this request.
- Use result=failed_after_3_retries only after 3 attempts fail.
- On success, comment must summarize the hook execution results in English.
- On failed_after_3_retries, comment must explain the concrete failure reason in English.
EOF_PROMPT
}

build_retake_builder_prompt() {
  local superseded_plan_path="$1"
  local superseded_pr_url="$2"
  local reviewer_comment="$3"
  local reviewer_comment_url="$4"

  cat <<EOF_PROMPT
You are the BUILDER agent in an autonomous loop.

${PATH_CONTEXT}

Start by reading ${SUBMODULE_REL}/PLANS.md in full.
You are creating a new take after reviewer rejection.

Current execution context:
- Work branch: ${CURRENT_WORK_BRANCH}
- Target branch: ${TARGET_BASE_BRANCH}
- PR URL: ${PR_URL}
- PR title: ${PR_TITLE}
- Branch slug: ${CURRENT_BRANCH_SLUG}
- Take number: ${CURRENT_TAKE}
- Superseded plan: ${superseded_plan_path}
- Superseded PR: ${superseded_pr_url}
- Reviewer comment URL: ${reviewer_comment_url}

Reviewer feedback to address:
${reviewer_comment}

Requirements:
- Create a new ExecPlan in eternal-cycler-out/plans/active/.
- Do not modify the superseded plan ${superseded_plan_path}.
- The new plan must include execplan_target_branch: ${TARGET_BASE_BRANCH}, execplan_branch_slug: ${CURRENT_BRANCH_SLUG}, execplan_take: ${CURRENT_TAKE}, execplan_supersedes_plan: ${superseded_plan_path}, and execplan_supersedes_pr_url: ${superseded_pr_url}.
- Work only on branch: ${CURRENT_WORK_BRANCH}
- Do not run git commit or git push. The loop script performs commit/push automatically.
- Keep unrelated baseline untracked files untouched.
- Try up to 3 implementation attempts before declaring failure.
- Return exactly one JSON object and nothing else:
  {"plan_doc_filename":"<relative-plan-path>","result":"success|failed_after_3_retries","comment":"<english hook-summary-or-failure-reason>"}
- On success, comment must summarize the hook execution results in English.
- On failed_after_3_retries, comment must explain the concrete failure reason in English.
EOF_PROMPT
}

build_reviewer_prompt() {
  cat <<EOF_PROMPT
You are the REVIEWER agent in an autonomous loop.

${PATH_CONTEXT}

Start by reading ${SUBMODULE_REL}/REVIEW.md in full.
Follow the review policy defined in that document.

Review target:
- PR URL: ${PR_URL}
- Target commit and newer commits on head branch: ${LATEST_COMMIT}

- Do not post any GitHub comment directly in autonomous loop mode.
- Return exactly one JSON object and nothing else:
  {"pr_url":"<target-pr-url>","comment_body":"<comment body in English>","approve_merge":true|false}
- Set pr_url to the same PR URL shown above.
- If CI is running, do not wait for completion; decide from current evidence.
- If the latest plan in this PR appears unresolved after three failures, include explicit remediation request text in comment_body.
- Use approve_merge=true only when merge should be approved now.
EOF_PROMPT
}

close_current_pr_after_rejection() {
  local pr_url="$1"
  gh pr close "$pr_url" >/dev/null 2>&1 || die "failed to close rejected PR: $pr_url"
}

prepare_next_take_after_rejection() {
  local reviewer_comment="$1"
  local comment_url="$2"
  local old_pr_url="$3"
  local superseded_plan_path="$4"
  local next_branch next_title next_body base_commit builder_prompt

  switch_or_track_branch "$TARGET_BASE_BRANCH"
  git pull --ff-only origin "$TARGET_BASE_BRANCH" >/dev/null 2>&1 || die "failed to pull target branch origin/$TARGET_BASE_BRANCH"

  CURRENT_TAKE=$((CURRENT_TAKE + 1))
  next_branch="$(generate_unique_work_branch "$CURRENT_BRANCH_SLUG")"
  git switch -c "$next_branch" >/dev/null 2>&1 || die "failed to create new work branch: $next_branch"
  CURRENT_WORK_BRANCH="$next_branch"

  "$SCRIPT_DIR/execplan_gate.sh" --event execplan.pre_creation >/dev/null

  next_title="$(format_take_title "$PR_TITLE_BASE" "$CURRENT_TAKE")"
  next_body="$(append_revision_note_to_body "$PR_BODY_BASE" "$old_pr_url")"
  PR_TITLE="$next_title"
  PR_BODY="$next_body"

  PR_URL="$(create_or_reuse_draft_pr_for_branch "$CURRENT_WORK_BRANCH" "$TARGET_BASE_BRANCH" "$PR_TITLE" "$PR_BODY")"
  [[ -n "$PR_URL" ]] || die "failed to create draft PR for retake branch $CURRENT_WORK_BRANCH"

  base_commit="$(git rev-parse HEAD)"
  LATEST_COMMIT="$base_commit"

  builder_prompt="$(build_retake_builder_prompt "$superseded_plan_path" "$old_pr_url" "$reviewer_comment" "$comment_url")"
  run_builder_cycle "builder_retake_take_${CURRENT_TAKE}" "$builder_prompt" "$base_commit"
}

TASK_TEXT=""
TASK_FILE=""
TARGET_BASE_BRANCH=""
PR_URL=""
PR_TITLE=""
PR_BODY=""
INITIAL_PR_WAS_PROVIDED=0
MAX_ITERATIONS=20
MAX_BUILDER_CLEANUP_RETRIES=5
MAX_REVIEWER_FAILURES=3
MODEL_BUILDER=""
MODEL_REVIEWER=""

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
    --pr-url)
      PR_URL="${2:-}"
      INITIAL_PR_WAS_PROVIDED=1
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="${2:-}"
      shift 2
      ;;
    --max-builder-cleanup-retries)
      MAX_BUILDER_CLEANUP_RETRIES="${2:-}"
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

if [[ -z "$TASK_TEXT" ]]; then
  echo "either --task or --task-file is required" >&2
  usage >&2
  exit 2
fi

[[ -n "$TARGET_BASE_BRANCH" ]] || die "--target-branch is required"
[[ -n "$PR_TITLE" ]] || die "--pr-title is required"
[[ -n "$PR_BODY" ]] || die "--pr-body is required"

for n in "$MAX_ITERATIONS" "$MAX_BUILDER_CLEANUP_RETRIES" "$MAX_REVIEWER_FAILURES"; do
  is_positive_int "$n" || die "numeric options must be positive integers"
done

for cmd in git gh codex jq rg; do
  require_cmd "$cmd"
done

WORKDIR="$(resolve_repo_root)"
cd "$WORKDIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBMODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUBMODULE_REL="$(realpath --relative-to="$WORKDIR" "$SUBMODULE_ROOT")"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/execplan_plan_metadata.sh"

PATH_CONTEXT="Path context (all paths are from the repository root):
- Policy docs:           ${SUBMODULE_REL}/PLANS.md, ${SUBMODULE_REL}/REVIEW.md
- ExecPlan gate:         ${SUBMODULE_REL}/scripts/execplan_gate.sh
- ExecPlan hooks:        .agents/skills/execplan-hook-*/  (copied from ${SUBMODULE_REL}/assets/default-hooks/ by setup.sh)
- Hook naming rule:      only execplan.* and hook.* are valid; strip that namespace, replace '_' and '.' with '-', then prefix execplan-hook- (for example execplan.post_creation -> execplan-hook-post-creation, hook.tooling -> execplan-hook-tooling)
- Sandbox policy:        .agents/skills/execplan-sandbox-escalation/SKILL.md
- Plans dir:             eternal-cycler-out/plans/
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
PR_TITLE_BASE="$(strip_take_suffix "$PR_TITLE")"
PR_BODY_BASE="$(strip_revision_note_block "$PR_BODY")"
CURRENT_TAKE="$(derive_take_from_title "$PR_TITLE")"

if [[ -n "$PR_URL" ]]; then
  "$SCRIPT_DIR/run_builder_reviewer_doctor.sh" --pr-url "$PR_URL" >/dev/null
  validate_existing_pr_context "$PR_URL"
else
  "$SCRIPT_DIR/run_builder_reviewer_doctor.sh" --head-branch "$CURRENT_WORK_BRANCH" >/dev/null
  "$SCRIPT_DIR/execplan_gate.sh" --event execplan.pre_creation >/dev/null
  PR_URL="$(create_or_reuse_draft_pr_for_branch "$CURRENT_WORK_BRANCH" "$TARGET_BASE_BRANCH" "$PR_TITLE" "$PR_BODY")"
fi

if [[ -n "$(git ls-files -u)" ]]; then
  die "unmerged paths detected after PR preparation"
fi
if has_tracked_dirty; then
  die "tracked working tree became dirty after PR preparation"
fi

declare -A BASELINE_UNTRACKED=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  BASELINE_UNTRACKED["$path"]=1
done < <(git ls-files --others --exclude-standard)

START_COMMIT="$(git rev-parse HEAD)"
LATEST_COMMIT="$START_COMMIT"
RUN_ID="loop-$(date -u +%Y%m%dT%H%M%SZ)-$$"

log "loop started (work_branch=$CURRENT_WORK_BRANCH, target_branch=$TARGET_BASE_BRANCH, pr_url=$PR_URL, start_commit=$START_COMMIT, run_id=$RUN_ID)"

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
  close_current_pr_after_rejection "$old_pr_url"
  superseded_plan_path="$(move_plan_to_completed_as_superseded "$CURRENT_PLAN_PATH" "$old_pr_url" "$reviewer_comment_body")"
  auto_stage_commit_and_push "docs(plan): supersede rejected take"
  prepare_next_take_after_rejection "$reviewer_comment_body" "$comment_url" "$old_pr_url" "$superseded_plan_path"
done

die "max iterations reached without reviewer approve_merge=true for commit $LATEST_COMMIT"

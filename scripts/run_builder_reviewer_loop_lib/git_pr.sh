#!/usr/bin/env bash

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

stage_managed_plan_doc_if_needed() {
  local plan_path="$1"
  local abs_path

  [[ -n "$plan_path" ]] || return 0

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || return 0

  if git ls-files --error-unmatch -- "$plan_path" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "$(git ls-files --others --exclude-standard -- "$plan_path")" ]]; then
    git add -- "$plan_path" >/dev/null 2>&1 || die "failed to stage managed plan document: $plan_path"
  fi
}

auto_stage_commit_and_push() {
  local commit_message="$1"

  git add -u -- . >/dev/null 2>&1 || die "failed to stage tracked changes"
  stage_managed_plan_doc_if_needed "$EXPECTED_PLAN_DOC_FILENAME"
  stage_managed_plan_doc_if_needed "$CURRENT_PLAN_PATH"

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

finalize_builder_output_once() {
  local base_commit="$1"
  local current_commit

  auto_stage_commit_and_push "loop: checkpoint builder output"
  current_commit="$(git rev-parse HEAD)"

  if has_tracked_dirty; then
    log "tracked changes remain after finalizing builder output"
    return 1
  fi

  if ! branch_head_is_pushed "$CURRENT_WORK_BRANCH"; then
    log "branch head is still not pushed after finalizing builder output"
    return 1
  fi

  if [[ "$current_commit" != "$base_commit" ]]; then
    printf 'changed|%s\n' "$current_commit"
  else
    printf 'unchanged|%s\n' "$current_commit"
  fi
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
  [[ "$CURRENT_PR_HEAD" == "$CURRENT_WORK_BRANCH" ]] || die "resume PR head branch ($CURRENT_PR_HEAD) must match current local branch ($CURRENT_WORK_BRANCH)"
  if [[ -n "$TARGET_BASE_BRANCH" ]]; then
    [[ "$CURRENT_PR_BASE" == "$TARGET_BASE_BRANCH" ]] || die "resume PR base branch ($CURRENT_PR_BASE) must match plan target branch ($TARGET_BASE_BRANCH)"
  else
    TARGET_BASE_BRANCH="$CURRENT_PR_BASE"
  fi
}

validate_existing_draft_pr_context() {
  local pr_url="$1"

  validate_existing_pr_context "$pr_url"
  [[ "$CURRENT_PR_IS_DRAFT" == "true" ]] || die "new takes require a draft PR; existing open PR is not draft: $pr_url"
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
    validate_existing_draft_pr_context "$pr_url"
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
    run_command_or_die "failed to switch to branch ${branch}" git switch "$branch"
    return 0
  fi

  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    run_command_or_die "failed to switch to tracking branch origin/${branch}" git switch -c "$branch" --track "origin/$branch"
    return 0
  fi

  die "branch not found locally or on origin: $branch"
}

pull_branch_ff_only() {
  local branch="$1"
  run_command_or_die "failed to pull target branch origin/${branch}" git pull --ff-only origin "$branch"
}

refresh_target_branch_or_die() {
  local branch="$1"
  switch_or_track_branch "$branch"
  pull_branch_ff_only "$branch"
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

derive_branch_slug_from_task() {
  local text="$1"
  local first_line slug

  first_line="$(printf '%s\n' "$text" | awk 'NF { print; exit }')"
  if [[ -z "$first_line" ]]; then
    printf 'task\n'
    return 0
  fi

  slug="$(printf '%s\n' "$first_line" \
    | awk '{
        for (i = 1; i <= NF; i++) {
          if ($i !~ /[\\/]/) {
            printf "%s ", $i
          }
        }
      }' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"

  if [[ -z "$slug" ]]; then
    printf 'task\n'
    return 0
  fi

  printf '%s\n' "$slug"
}

close_current_pr_after_rejection() {
  local pr_url="$1"
  gh pr close "$pr_url" >/dev/null 2>&1 || die "failed to close rejected PR: $pr_url"
}

prepare_next_take_after_rejection() {
  local old_pr_url="$1"
  local next_branch next_title next_body

  switch_or_track_branch "$TARGET_BASE_BRANCH"
  git pull --ff-only origin "$TARGET_BASE_BRANCH" >/dev/null 2>&1 || die "failed to pull target branch origin/$TARGET_BASE_BRANCH"

  CURRENT_TAKE=$((CURRENT_TAKE + 1))
  next_branch="$(generate_unique_work_branch "$CURRENT_BRANCH_SLUG")"
  git switch -c "$next_branch" >/dev/null 2>&1 || die "failed to create new work branch: $next_branch"
  CURRENT_WORK_BRANCH="$next_branch"
  EXPECTED_PLAN_DOC_FILENAME="$(plan_rel_path_for_branch "$CURRENT_WORK_BRANCH")"

  "$SCRIPT_DIR/execplan_gate.sh" --event execplan.pre-creation >/dev/null

  next_title="$(format_take_title "$PR_TITLE_BASE" "$CURRENT_TAKE")"
  next_body="$(append_revision_note_to_body "$PR_BODY_BASE" "$old_pr_url")"
  PR_TITLE="$next_title"
  PR_BODY="$next_body"

  PR_URL="$(create_or_reuse_draft_pr_for_branch "$CURRENT_WORK_BRANCH" "$TARGET_BASE_BRANCH" "$PR_TITLE" "$PR_BODY")"
  [[ -n "$PR_URL" ]] || die "failed to create draft PR for retake branch $CURRENT_WORK_BRANCH"
}

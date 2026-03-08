#!/usr/bin/env bash

post_builder_comment() {
  local stage="$1"
  local comment_body="$2"

  [[ -n "$PR_URL" ]] || die "builder stage ${stage} completed without a PR URL"
  ensure_pr_ready "$PR_URL"
  post_pr_comment "$PR_URL" "$comment_body" >/dev/null || die "failed to post builder comment to $PR_URL"
}

run_builder_cycle() {
  local stage="$1"
  local prompt_text="$2"
  local base_commit="$3"
  local builder_schema_file builder_payload_json builder_result builder_comment cleanup_result cleanup_kind cleanup_commit

  builder_schema_file="$(write_builder_output_schema)"
  if ! run_agent_prompt_capture "$stage" "$BUILDER_PROVIDER" "$MODEL_BUILDER" "$prompt_text" "$builder_schema_file"; then
    rm -f "$builder_schema_file"
    die "${stage} builder execution failed"
  fi
  rm -f "$builder_schema_file"

  builder_payload_json="$(parse_builder_payload_json "$LAST_AGENT_OUTPUT" || true)"
  [[ -n "$builder_payload_json" ]] || die "${stage} builder output was not valid JSON payload"
  builder_result="$(jq -r '.result' <<< "$builder_payload_json")"
  builder_comment="$(jq -r '.comment' <<< "$builder_payload_json")"

  if [[ "$builder_result" == "failed_after_3_retries" ]]; then
    force_close_failed_builder_plan_for_branch "$CURRENT_WORK_BRANCH" "$stage" "$builder_comment"
    post_builder_comment "$stage" "$builder_comment"
    die "builder reported failed_after_3_retries at stage=${stage}; plan document=${CURRENT_PLAN_PATH:-$EXPECTED_PLAN_DOC_FILENAME}"
  fi

  load_completed_plan_runtime_metadata_for_branch "$CURRENT_WORK_BRANCH"
  ensure_completed_plan_contract "$stage"

  cleanup_result="$(finalize_builder_output_once "$base_commit" || true)"
  [[ -n "$cleanup_result" ]] || die "failed to finalize builder output at stage ${stage}"
  cleanup_kind="${cleanup_result%%|*}"
  cleanup_commit="${cleanup_result#*|}"

  post_builder_comment "$stage" "$builder_comment"

  if [[ "$cleanup_kind" == "changed" ]]; then
    log "new commit detected after builder stage ${stage}: $cleanup_commit"
  else
    log "no new commit after builder stage ${stage}; continuing"
  fi

  LATEST_COMMIT="$cleanup_commit"
}

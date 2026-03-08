#!/usr/bin/env bash

test_feedback_submit_creates_user_feedback_doc() {
  local repo branch plan_rel feedback_doc

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2320"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  write_execplan "$repo" "$plan_rel" "$branch" "- [x] hook_events=none; done." "$(post_creation_pass_entry)"

  run_feedback_helper_capture \
    "$repo" \
    submit \
    --plan "$plan_rel" \
    --item "Use approach B instead of approach A." \
    --item "Keep the current API unchanged."
  [[ "$HELPER_RC" -eq 0 ]] || return 1
  [[ "$(jq -r '.feedback_ids | length' <<< "$HELPER_OUTPUT")" -eq 2 ]] || return 1

  feedback_doc="$repo/eternal-cycler-out/user-feedback/${branch}.md"
  [[ -f "$feedback_doc" ]] || return 1
  assert_file_contains "$feedback_doc" "plan_filename: ${branch}.md" || return 1
  assert_file_contains "$feedback_doc" "feedback_id=uf-001" || return 1
  assert_file_contains "$feedback_doc" "feedback_id=uf-002" || return 1
}

test_feedback_respond_records_builder_question() {
  local repo branch plan_rel response_doc

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2325"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  write_execplan "$repo" "$plan_rel" "$branch" "- [x] hook_events=none; done." "$(post_creation_pass_entry)"

  run_feedback_helper_capture "$repo" submit --plan "$plan_rel" --item "Use a repository pattern here."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  run_feedback_helper_capture \
    "$repo" \
    respond \
    --plan "$plan_rel" \
    --feedback-id uf-001 \
    --status question \
    --message "Which repository interface should be used?"
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  response_doc="$repo/eternal-cycler-out/builder-response/${branch}.md"
  [[ -f "$response_doc" ]] || return 1
  assert_file_contains "$response_doc" "response_id=br-001; feedback_id=uf-001; status=question" || return 1
}

test_feedback_status_reports_unanswered_ids() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2330"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  write_execplan "$repo" "$plan_rel" "$branch" "- [x] hook_events=none; done." "$(post_creation_pass_entry)"

  run_feedback_helper_capture \
    "$repo" \
    submit \
    --plan "$plan_rel" \
    --item "Use approach B instead of approach A." \
    --item "Keep the current API unchanged."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  run_feedback_helper_capture \
    "$repo" \
    respond \
    --plan "$plan_rel" \
    --feedback-id uf-001 \
    --status implemented \
    --message "Implemented with approach B."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  run_feedback_helper_capture "$repo" status --plan "$plan_rel" --format json
  [[ "$HELPER_RC" -eq 0 ]] || return 1
  [[ "$(jq -r '.unanswered_feedback_ids | join(",")' <<< "$HELPER_OUTPUT")" == "uf-002" ]]
}

test_feedback_submit_rejects_nonexistent_plan() {
  local repo

  repo="$(setup_fixture_repo)" || return 1

  run_feedback_helper_capture \
    "$repo" \
    submit \
    --plan "eternal-cycler-out/plans/active/does-not-exist.md" \
    --item "hello"
  [[ "$HELPER_RC" -ne 0 ]] || return 1
  [[ "$HELPER_OUTPUT" == *"plan file not found: eternal-cycler-out/plans/active/does-not-exist.md"* ]] || return 1
  [[ ! -f "$repo/eternal-cycler-out/user-feedback/does-not-exist.md" ]]
}

test_feedback_status_rejects_nonexistent_plan() {
  local repo

  repo="$(setup_fixture_repo)" || return 1

  run_feedback_helper_capture \
    "$repo" \
    status \
    --plan "eternal-cycler-out/plans/active/does-not-exist.md" \
    --format json
  [[ "$HELPER_RC" -ne 0 ]] || return 1
  [[ "$HELPER_OUTPUT" == *"plan file not found: eternal-cycler-out/plans/active/does-not-exist.md"* ]]
}

test_feedback_status_rejects_non_active_plan() {
  local repo branch completed_plan

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2332"
  completed_plan="eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan "$repo" "$completed_plan" "$branch" "- [x] hook_events=none; done." "$(post_creation_pass_entry)"

  run_feedback_helper_capture "$repo" status --plan "$completed_plan" --format json
  [[ "$HELPER_RC" -ne 0 ]] || return 1
  [[ "$HELPER_OUTPUT" == *"plan must be an active ExecPlan: ${completed_plan}"* ]]
}

test_post_completion_requires_builder_responses_for_feedback() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2335"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=hook.tooling; update implementation." \
    "$(post_creation_pass_entry)
$(hook_tooling_pass_entry)"

  run_feedback_helper_capture "$repo" submit --plan "$plan_rel" --item "Use approach B instead of approach A."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  run_post_completion_hook_capture "$repo" "$plan_rel"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"missing builder response doc for eternal-cycler-out/user-feedback/${branch}.md"* ]]
}

test_post_completion_accepts_question_response_as_answered() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2340"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=hook.tooling; update implementation." \
    "$(post_creation_pass_entry)
$(hook_tooling_pass_entry)"

  run_feedback_helper_capture "$repo" submit --plan "$plan_rel" --item "Use approach B instead of approach A."
  [[ "$HELPER_RC" -eq 0 ]] || return 1
  run_feedback_helper_capture \
    "$repo" \
    respond \
    --plan "$plan_rel" \
    --feedback-id uf-001 \
    --status objection \
    --message "Approach B conflicts with the existing invariants."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  run_post_completion_hook_capture "$repo" "$plan_rel"
  [[ "$HOOK_RC" -eq 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"STATUS=pass"* ]]
}

test_post_completion_accepts_answered_feedback_with_large_response_doc() {
  local repo branch plan_rel response_doc huge_suffix

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2341"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=hook.tooling; update implementation." \
    "$(post_creation_pass_entry)
$(hook_tooling_pass_entry)"

  run_feedback_helper_capture "$repo" submit --plan "$plan_rel" --item "Use approach B instead of approach A."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  response_doc="$repo/eternal-cycler-out/builder-response/${branch}.md"
  mkdir -p "$(dirname "$response_doc")"
  cat > "$response_doc" <<EOF_RESPONSE
# ExecPlan Builder Responses

plan_filename: ${branch}.md

<!-- execplan-builder-response:start -->
- response_item: response_id=br-001; feedback_id=uf-001; status=implemented; created_at=2026-03-08T00:00:00Z
  message_en: Implemented.
EOF_RESPONSE
  huge_suffix="$(perl -e 'print "9" x 200000')"
  cat >> "$response_doc" <<EOF_RESPONSE_ITEM

- response_item: response_id=br-${huge_suffix}; feedback_id=uf-${huge_suffix}; status=implemented; created_at=2026-03-08T00:00:00Z
  message_en: filler response
EOF_RESPONSE_ITEM
  cat >> "$response_doc" <<'EOF_RESPONSE_END'
<!-- execplan-builder-response:end -->
EOF_RESPONSE_END

  run_post_completion_hook_capture "$repo" "$plan_rel"
  [[ "$HOOK_RC" -eq 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"STATUS=pass"* ]]
}

test_post_completion_rejects_prefixed_response_statuses() {
  local repo branch plan_rel response_doc

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2342"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=hook.tooling; update implementation." \
    "$(post_creation_pass_entry)
$(hook_tooling_pass_entry)"

  run_feedback_helper_capture "$repo" submit --plan "$plan_rel" --item "Use approach B instead of approach A."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  response_doc="$repo/eternal-cycler-out/builder-response/${branch}.md"
  mkdir -p "$(dirname "$response_doc")"
  cat > "$response_doc" <<EOF_RESPONSE
# ExecPlan Builder Responses

plan_filename: ${branch}.md

<!-- execplan-builder-response:start -->
- response_item: response_id=br-001; feedback_id=uf-001; status=questionable; created_at=2026-03-08T00:00:00Z
  message_en: This should not count as valid.
<!-- execplan-builder-response:end -->
EOF_RESPONSE

  run_post_completion_hook_capture "$repo" "$plan_rel"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"malformed builder response doc: eternal-cycler-out/builder-response/${branch}.md"* ]]
}

test_feedback_status_rejects_embedded_prior_status_field() {
  local repo branch plan_rel response_doc

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2343"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  write_execplan "$repo" "$plan_rel" "$branch" "- [x] hook_events=none; done." "$(post_creation_pass_entry)"

  run_feedback_helper_capture "$repo" submit --plan "$plan_rel" --item "Use approach B instead of approach A."
  [[ "$HELPER_RC" -eq 0 ]] || return 1

  response_doc="$repo/eternal-cycler-out/builder-response/${branch}.md"
  mkdir -p "$(dirname "$response_doc")"
  cat > "$response_doc" <<EOF_RESPONSE
# ExecPlan Builder Responses

plan_filename: ${branch}.md

<!-- execplan-builder-response:start -->
- response_item: response_id=br-001; feedback_id=uf-001; prior_status=question; created_at=2026-03-08T00:00:00Z
  message_en: This should not count as valid.
<!-- execplan-builder-response:end -->
EOF_RESPONSE

  run_feedback_helper_capture "$repo" status --plan "$plan_rel" --format json
  [[ "$HELPER_RC" -ne 0 ]] || return 1
  [[ "$HELPER_OUTPUT" == *"malformed builder response doc: eternal-cycler-out/builder-response/${branch}.md"* ]]
}

test_builder_prompts_reference_feedback_docs() {
  assert_file_contains \
    "$REPO_ROOT/scripts/prompt_templates/run_builder_reviewer_loop/builder_initial.tmpl" \
    "User feedback doc for this take: {{USER_FEEDBACK_DOC}}" || return 1
  assert_file_contains \
    "$REPO_ROOT/scripts/prompt_templates/run_builder_reviewer_loop/builder_initial.tmpl" \
    "Builder response doc for this take: {{BUILDER_RESPONSE_DOC}}" || return 1
  assert_file_contains \
    "$REPO_ROOT/scripts/prompt_templates/run_builder_reviewer_loop/builder_initial.tmpl" \
    "Use {{FEEDBACK_HELPER_PATH}} for all live-feedback reads/writes." || return 1
}

test_docs_describe_feedback_polling_without_stopping_loop() {
  assert_file_contains \
    "$REPO_ROOT/PLANS.md" \
    "Do not stop the loop merely because a question/objection was forwarded." || return 1
  assert_file_contains \
    "$REPO_ROOT/SKILL.md" \
    "forward them to the user as intermediate output without ending the caller agent turn or stopping the loop." || return 1
}

test_loop_retake_refreshes_feedback_doc_paths() {
  [[ "$(count_file_matches "$REPO_ROOT/scripts/run_builder_reviewer_loop.sh" "refresh_feedback_doc_paths")" -eq 2 ]] || return 1
  assert_file_contains \
    "$REPO_ROOT/scripts/run_builder_reviewer_loop.sh" \
    'EXPECTED_PLAN_DOC_FILENAME="$(plan_rel_path_for_branch "$CURRENT_WORK_BRANCH")"' || return 1
}

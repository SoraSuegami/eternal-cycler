#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$TEST_ROOT/lib/execplan_testlib.sh"
source "$TEST_ROOT/cases/execplan_gate_tests.sh"
source "$TEST_ROOT/cases/execplan_hook_tests.sh"
source "$TEST_ROOT/cases/execplan_feedback_tests.sh"
source "$TEST_ROOT/cases/execplan_loop_new_take_tests.sh"
source "$TEST_ROOT/cases/execplan_loop_resume_tests.sh"

init_test_workspace
trap cleanup_test_workspace EXIT

run_test "completed plan helper resolves completed path" test_completed_plan_helper_requires_completed_path
run_test "completed plan helper rejects active-only plans" test_completed_plan_helper_fails_without_completed_plan
run_test "post completion accepts hook_events=none" test_post_completion_allows_hook_events_none
run_test "post completion accepts actions without hook events" test_post_completion_allows_actions_without_hook_events
run_test "post completion requires declared hook pass coverage" test_post_completion_requires_declared_hook_passes
run_test "post completion requires hook event actions checked off" test_post_completion_requires_hook_event_actions_checked_off
run_test "gate rejects lifecycle events in hook_events" test_gate_rejects_lifecycle_event_in_hook_events
run_test "gate rejects non-hook namespaces" test_gate_rejects_non_hook_namespaces
run_test "gate rejects underscore event ids" test_gate_rejects_underscore_event_ids
run_test "gate rejects verify_events" test_gate_rejects_verify_events_field
run_test "gate blocks lifecycle unresolved state before post completion" test_gate_blocks_lifecycle_unresolved_before_post_completion
run_test "post completion hook blocks lifecycle unresolved state" test_post_completion_hook_blocks_lifecycle_unresolved
run_test "post completion hook rejects completed plan input" test_post_completion_hook_rejects_completed_plan_input
run_test "gate force-closes escalated active plan" test_gate_force_closes_escalated_active_plan
run_test "pre creation requires clean tracked worktree" test_pre_creation_requires_clean_tracked_worktree
run_test "pre creation allows untracked files" test_pre_creation_allows_untracked_files
run_test "pre creation rejects existing nonempty plan file" test_pre_creation_rejects_existing_nonempty_plan_file
run_test "post creation requires draft pr" test_post_creation_requires_draft_pr
run_test "docs only hook allows rules paths" test_docs_only_hook_allows_rules_paths
run_test "get_new_untracked_paths ignores large baseline matches" test_get_new_untracked_paths_ignores_large_baseline_matches
run_test "feedback submit creates user feedback doc" test_feedback_submit_creates_user_feedback_doc
run_test "feedback respond records builder question" test_feedback_respond_records_builder_question
run_test "feedback status reports unanswered ids" test_feedback_status_reports_unanswered_ids
run_test "feedback submit rejects nonexistent plan" test_feedback_submit_rejects_nonexistent_plan
run_test "feedback status rejects nonexistent plan" test_feedback_status_rejects_nonexistent_plan
run_test "feedback status rejects non-active plan" test_feedback_status_rejects_non_active_plan
run_test "post completion requires builder responses for feedback" test_post_completion_requires_builder_responses_for_feedback
run_test "post completion accepts question response as answered" test_post_completion_accepts_question_response_as_answered
run_test "post completion accepts answered feedback with large response doc" test_post_completion_accepts_answered_feedback_with_large_response_doc
run_test "post completion rejects prefixed response statuses" test_post_completion_rejects_prefixed_response_statuses
run_test "feedback status rejects embedded prior status field" test_feedback_status_rejects_embedded_prior_status_field
run_test "builder prompts reference feedback docs" test_builder_prompts_reference_feedback_docs
run_test "docs describe feedback polling without stopping loop" test_docs_describe_feedback_polling_without_stopping_loop
run_test "loop retake refreshes feedback doc paths" test_loop_retake_refreshes_feedback_doc_paths
run_test "supersede flow uses two-arg completed destination helper" test_supersede_flow_uses_two_arg_completed_destination_helper
run_test "new take requires target branch refresh" test_new_take_requires_target_branch_refresh
run_test "new take starts from target branch" test_new_take_starts_from_target_branch_even_when_invoked_from_feature_branch
run_test "loop rejects non-draft pr reuse for new take" test_loop_rejects_non_draft_pr_reuse_for_new_take
run_test "loop force closes failed builder plan" test_loop_force_closes_failed_builder_plan
run_test "loop accepts resume-only plan for post completion" test_loop_accepts_resume_only_plan_for_post_completion
run_test "loop rejects active plan missing post creation or resume pass" test_loop_rejects_active_plan_missing_post_creation_or_resume_pass
run_test "resume plan requires target branch refresh" test_resume_plan_requires_target_branch_refresh
run_test "loop rejects legacy pr-url resume entrypoint" test_loop_rejects_legacy_pr_url_resume_entrypoint
run_test "resume loop invokes execplan.resume gate when missing" test_resume_loop_invokes_resume_gate_when_missing
run_test "resume loop skips duplicate execplan.resume gate" test_resume_loop_skips_duplicate_resume_gate

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'all tests passed\n'

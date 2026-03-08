#!/usr/bin/env bash

test_completed_plan_helper_requires_completed_path() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1200"
  plan_rel="eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=none; finalize take." \
    "$(post_creation_pass_entry)"

  run_completed_plan_helper "$repo" "$branch"
  [[ "$HELPER_RC" -eq 0 ]] || return 1
  [[ "$HELPER_OUTPUT" == "$plan_rel" ]]
}

test_completed_plan_helper_fails_without_completed_plan() {
  local repo branch

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1300"
  write_execplan \
    "$repo" \
    "eternal-cycler-out/plans/active/${branch}.md" \
    "$branch" \
    "- [x] hook_events=none; finalize take." \
    "$(post_creation_pass_entry)"

  run_completed_plan_helper "$repo" "$branch"
  [[ "$HELPER_RC" -ne 0 ]]
}

test_post_completion_allows_hook_events_none() {
  local repo branch active_rel active_abs completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1400"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  active_abs="$repo/$active_rel"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [x] hook_events=none; finalize take." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$active_rel" --event execplan.post-completion
  [[ "$GATE_RC" -eq 0 ]] || return 1
  [[ "$GATE_OUTPUT" == *"STATUS=pass"* ]] || return 1
  [[ ! -f "$active_abs" ]] || return 1
  [[ -f "$completed_abs" ]] || return 1
  assert_file_contains "$completed_abs" "event_id=execplan.post-completion; attempt=1; status=pass"
}

test_post_completion_allows_actions_without_hook_events() {
  local repo branch active_rel completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1450"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [x] finalize take without hook linkage." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$active_rel" --event execplan.post-completion
  [[ "$GATE_RC" -eq 0 ]] || return 1
  [[ -f "$completed_abs" ]] || return 1
  assert_file_contains "$completed_abs" "event_id=execplan.post-completion; attempt=1; status=pass"
}

test_post_completion_requires_declared_hook_passes() {
  local repo branch active_rel active_abs completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1500"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  active_abs="$repo/$active_rel"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=hook.tooling; worker_type=worker; finalize take." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$active_rel" --event execplan.post-completion
  [[ "$GATE_RC" -ne 0 ]] || return 1
  [[ -f "$active_abs" ]] || return 1
  [[ ! -f "$completed_abs" ]] || return 1
  assert_file_contains "$active_abs" "failure_summary=missing pass entries for required hook_events: hook.tooling"
}

test_post_completion_requires_hook_event_actions_checked_off() {
  local repo branch active_rel active_abs completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1555"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  active_abs="$repo/$active_rel"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [ ] hook_events=hook.tooling; finalize take." \
    "$(post_creation_pass_entry)$(printf '\n')$(hook_tooling_pass_entry)"

  run_gate_capture "$repo" --plan "$active_rel" --event execplan.post-completion
  [[ "$GATE_RC" -ne 0 ]] || return 1
  [[ -f "$active_abs" ]] || return 1
  [[ ! -f "$completed_abs" ]] || return 1
  return 0
}

test_gate_rejects_lifecycle_event_in_hook_events() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1600"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=execplan.post-completion; worker_type=worker; run tooling." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event hook.tooling
  [[ "$GATE_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "failure_summary=hook_events must not contain lifecycle event: execplan.post-completion"
}

test_gate_rejects_non_hook_namespaces() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1700"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=action.foo,custom.foo; worker_type=worker; run tooling." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event hook.tooling
  [[ "$GATE_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "failure_summary=hook_events must contain only hook.* values: action.foo" || return 1
  assert_file_contains "$plan_abs" "hook_events must contain only hook.* values: custom.foo"
}

test_gate_rejects_underscore_event_ids() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1750"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=hook.docs_only; run docs checks." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event hook.docs_only
  [[ "$GATE_RC" -ne 0 ]] || return 1
  [[ "$GATE_OUTPUT" == *"Underscore event IDs are not supported"* ]] || return 1
  ! assert_file_contains "$plan_abs" "event_id=hook.docs_only;"
}

test_gate_rejects_verify_events_field() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1800"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=hook.tooling; verify_events=hook.docs-only; worker_type=worker; run tooling." \
    "$(post_creation_pass_entry)$(printf '\n')$(hook_tooling_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event hook.tooling
  [[ "$GATE_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "failure_summary=verify_events is not supported"
}

test_gate_blocks_lifecycle_unresolved_before_post_completion() {
  local repo branch active_rel active_abs completed_abs ledger_lines

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1900"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  active_abs="$repo/$active_rel"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"
  ledger_lines="$(post_creation_pass_entry)
$(cat <<'EOF_ENTRY'
- attempt_record: event_id=execplan.resume; attempt=1; status=fail; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=resume blocked; notify_reference=not_requested;
EOF_ENTRY
)"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$ledger_lines"

  run_gate_capture "$repo" --plan "$active_rel" --event execplan.post-completion
  [[ "$GATE_RC" -ne 0 ]] || return 1
  [[ -f "$active_abs" ]] || return 1
  [[ ! -f "$completed_abs" ]] || return 1
  assert_file_contains "$active_abs" "failure_summary=unresolved event status remains for execplan.resume:fail"
}

test_post_completion_hook_blocks_lifecycle_unresolved() {
  local repo branch active_rel ledger_lines

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2000"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  ledger_lines="$(post_creation_pass_entry)
$(cat <<'EOF_ENTRY'
- attempt_record: event_id=execplan.resume; attempt=1; status=fail; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=resume blocked; notify_reference=not_requested;
EOF_ENTRY
)"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$ledger_lines"

  run_post_completion_hook_capture "$repo" "$active_rel"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=latest hook event is unresolved: execplan.resume:fail"* ]]
}

test_post_completion_hook_rejects_completed_plan_input() {
  local repo branch completed_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2050"
  completed_rel="eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$completed_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$(post_creation_pass_entry)"

  run_post_completion_hook_capture "$repo" "$completed_rel"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=execplan.post-completion requires an active plan path"* ]]
}

test_gate_force_closes_escalated_active_plan() {
  local repo branch active_rel active_abs completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2100"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  active_abs="$repo/$active_rel"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$active_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=action.foo; worker_type=worker; run tooling." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$active_rel" --event hook.tooling --attempt 3
  [[ "$GATE_RC" -ne 0 ]] || return 1
  [[ ! -f "$active_abs" ]] || return 1
  [[ -f "$completed_abs" ]] || return 1
  assert_file_contains "$completed_abs" "status=escalated" || return 1
  assert_file_contains "$completed_abs" "escalation_record:" || return 1
  assert_file_contains "$completed_abs" "Event hook.tooling escalated at attempt 3."
}

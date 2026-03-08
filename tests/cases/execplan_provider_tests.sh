#!/usr/bin/env bash

write_provider_gh_stub() {
  local repo="$1"
  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<'EOF_STUB'
#!/usr/bin/env bash
state_dir=".git/gh-stub"
mkdir -p "$state_dir"
if [[ "$1 $2" == "auth status" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  head=""
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--head" ]]; then
      next=$((i + 1))
      head="${!next}"
    fi
  done
  if [[ -n "$head" && -f "$state_dir/pr-${head}" ]]; then
    url="$(cat "$state_dir/pr-${head}")"
    cat <<EOF_JSON
[{"url":"${url}","updatedAt":"2026-03-08T00:00:00Z","isDraft":true,"baseRefName":"main","title":"Test PR","body":"## Summary\n- ready"}]
EOF_JSON
  else
    echo "[]"
  fi
  exit 0
fi
if [[ "$1 $2" == "pr create" ]]; then
  head=""
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--head" ]]; then
      next=$((i + 1))
      head="${!next}"
    fi
  done
  printf 'https://github.com/example/repo/pull/99\n' > "$state_dir/pr-${head}"
  exit 0
fi
if [[ "$1 $2" == "pr view" ]]; then
  if [[ " $* " == *" --jq "* ]]; then
    echo "false"
    exit 0
  fi
  head="$(git branch --show-current)"
  cat <<EOF_JSON
{"url":"https://github.com/example/repo/pull/99","title":"Test PR","body":"## Summary\n- ready","headRefName":"${head}","baseRefName":"main","state":"OPEN","isDraft":true}
EOF_JSON
  exit 0
fi
if [[ "$1 $2" == "pr edit" || "$1 $2" == "pr ready" || "$1 $2" == "pr comment" ]]; then
  [[ "$1 $2" == "pr comment" ]] && echo "https://github.com/example/repo/pull/99#issuecomment-1"
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh"
}

write_codex_provider_stub() {
  local repo="$1"
  local mode="$2"
  local flow="${3:-new_take}"
  cat > "$repo/bin/codex" <<EOF_STUB
#!/usr/bin/env bash
mode="${mode}"
flow="${flow}"
if [[ "\$1 \$2" == "login status" ]]; then
  if [[ "\$mode" == "auth-fail" ]]; then
    exit 1
  fi
  exit 0
fi
if [[ "\$1" != "exec" ]]; then
  exit 1
fi
if [[ "\$mode" == "fail-if-called" ]]; then
  : > .git/codex-invoked-unexpectedly
  exit 97
fi
state_file=".git/codex-call-count"
count=0
if [[ -f "\$state_file" ]]; then
  count="\$(cat "\$state_file")"
fi
count=\$((count + 1))
printf '%s\n' "\$count" > "\$state_file"
out=""
for ((i=1; i<=\$#; i++)); do
  if [[ "\${!i}" == "--output-last-message" ]]; then
    next=\$((i + 1))
    out="\${!next}"
  fi
done
branch="\$(git branch --show-current)"
head_commit="\$(git rev-parse HEAD)"
active_plan="eternal-cycler-out/plans/active/\${branch}.md"
completed_plan="eternal-cycler-out/plans/completed/\${branch}.md"
builder_payload='{"result":"success","comment":"builder success"}'
reviewer_payload='{"pr_url":"https://github.com/example/repo/pull/99","comment_body":"reviewer approved","approve_merge":true}'
if [[ "\$mode" == "both" && "\$count" -eq 1 ]] || [[ "\$mode" == "builder-only" && "\$count" -eq 1 ]]; then
  rm -f "\$active_plan"
  if [[ "\$flow" == "resume" ]]; then
    cat > "\$completed_plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [x] hook_events=none; finalize take.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.resume; attempt=1; status=pass; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=none; notify_reference=not_requested;
- attempt_record: event_id=execplan.post-completion; attempt=1; status=pass; started_at=2026-03-08 00:10Z; finished_at=2026-03-08 00:11Z; commands=hook runner execplan.post-completion; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: \${branch}
- execplan_target_branch: main
- execplan_start_commit: \${head_commit}
- execplan_pr_url: https://github.com/example/repo/pull/99
- execplan_pr_title: Test PR
- execplan_branch_slug: task-branch
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- ready
<!-- execplan-pr-body:end -->

## ExecPlan Resume Record

- resume_date: 2026-03-08 00:05Z
- resume_commit: \${head_commit}
- operator_feedback: (none)

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
- start_tracked_change: (none)\t(none)
<!-- execplan-start-tracked:end -->

<!-- execplan-start-untracked:start -->
- start_untracked_file: (none)\t(none)
<!-- execplan-start-untracked:end -->
EOF_PLAN
  else
    cat > "\$completed_plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [x] hook_events=none; finalize take.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.post-creation; attempt=1; status=pass; started_at=2026-03-08 00:00Z; finished_at=2026-03-08 00:01Z; commands=hook runner execplan.post-creation; failure_summary=none; notify_reference=not_requested;
- attempt_record: event_id=execplan.post-completion; attempt=1; status=pass; started_at=2026-03-08 00:10Z; finished_at=2026-03-08 00:11Z; commands=hook runner execplan.post-completion; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: \${branch}
- execplan_target_branch: main
- execplan_start_commit: \${head_commit}
- execplan_pr_url: https://github.com/example/repo/pull/99
- execplan_pr_title: Test PR
- execplan_branch_slug: task-branch
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- ready
<!-- execplan-pr-body:end -->

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
- start_tracked_change: (none)\t(none)
<!-- execplan-start-tracked:end -->

<!-- execplan-start-untracked:start -->
- start_untracked_file: (none)\t(none)
<!-- execplan-start-untracked:end -->
EOF_PLAN
  fi
  if [[ -n "\$out" ]]; then
    printf '%s\n' "\$builder_payload" > "\$out"
  fi
  printf '%s\n' "\$builder_payload"
  exit 0
fi
if [[ "\$mode" == "reviewer-only" ]] || [[ "\$mode" == "both" && "\$count" -ge 2 ]]; then
  if [[ -n "\$out" ]]; then
    printf '%s\n' "\$reviewer_payload" > "\$out"
  fi
  printf '%s\n' "\$reviewer_payload"
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/codex"
}

write_claude_provider_stub() {
  local repo="$1"
  local mode="$2"
  local flow="${3:-new_take}"
  cat > "$repo/bin/claude" <<EOF_STUB
#!/usr/bin/env bash
mode="${mode}"
flow="${flow}"
if [[ "\$1 \$2" == "auth status" ]]; then
  if [[ "\$mode" == "auth-fail" ]]; then
    echo "auth failed" >&2
    exit 1
  fi
  exit 0
fi
if [[ "\$1" == "doctor" ]]; then
  if [[ "\$mode" == "doctor-fail" ]]; then
    echo "doctor failed" >&2
    exit 1
  fi
  exit 0
fi
if [[ "\$1" != "-p" ]]; then
  exit 1
fi
if [[ "\$mode" == "fail-if-called" ]]; then
  : > .git/claude-invoked-unexpectedly
  exit 97
fi
state_file=".git/claude-call-count"
schema_seen_file=".git/claude-json-schema-seen"
count=0
if [[ -f "\$state_file" ]]; then
  count="\$(cat "\$state_file")"
fi
count=\$((count + 1))
printf '%s\n' "\$count" > "\$state_file"
branch="\$(git branch --show-current)"
head_commit="\$(git rev-parse HEAD)"
active_plan="eternal-cycler-out/plans/active/\${branch}.md"
completed_plan="eternal-cycler-out/plans/completed/\${branch}.md"
builder_payload='{"result":"success","comment":"builder success"}'
reviewer_payload='{"pr_url":"https://github.com/example/repo/pull/99","comment_body":"reviewer approved","approve_merge":true}'
builder_envelope='{"type":"result","subtype":"success","result":"{\"result\":\"success\",\"comment\":\"builder success\"}"}'
reviewer_envelope='{"type":"result","subtype":"success","result":"{\"pr_url\":\"https://github.com/example/repo/pull/99\",\"comment_body\":\"reviewer approved\",\"approve_merge\":true}"}'
invalid_envelope='{"type":"result","subtype":"success","result":"not-json"}'
for ((i=1; i<=\$#; i++)); do
  if [[ "\${!i}" == "--json-schema" ]]; then
    next=\$((i + 1))
    printf '%s\n' "\${!next}" > "\$schema_seen_file"
  fi
done
if [[ "\$mode" == "both" && "\$count" -eq 1 ]] || [[ "\$mode" == "builder-only" && "\$count" -eq 1 ]] || [[ "\$mode" == "invalid-builder" && "\$count" -eq 1 ]] || [[ "\$mode" == "stderr-warning" && "\$count" -eq 1 ]]; then
  rm -f "\$active_plan"
  if [[ "\$flow" == "resume" ]]; then
    cat > "\$completed_plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [x] hook_events=none; finalize take.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.resume; attempt=1; status=pass; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=none; notify_reference=not_requested;
- attempt_record: event_id=execplan.post-completion; attempt=1; status=pass; started_at=2026-03-08 00:10Z; finished_at=2026-03-08 00:11Z; commands=hook runner execplan.post-completion; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: \${branch}
- execplan_target_branch: main
- execplan_start_commit: \${head_commit}
- execplan_pr_url: https://github.com/example/repo/pull/99
- execplan_pr_title: Test PR
- execplan_branch_slug: task-branch
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- ready
<!-- execplan-pr-body:end -->

## ExecPlan Resume Record

- resume_date: 2026-03-08 00:05Z
- resume_commit: \${head_commit}
- operator_feedback: (none)

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
- start_tracked_change: (none)\t(none)
<!-- execplan-start-tracked:end -->

<!-- execplan-start-untracked:start -->
- start_untracked_file: (none)\t(none)
<!-- execplan-start-untracked:end -->
EOF_PLAN
  else
    cat > "\$completed_plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [x] hook_events=none; finalize take.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.post-creation; attempt=1; status=pass; started_at=2026-03-08 00:00Z; finished_at=2026-03-08 00:01Z; commands=hook runner execplan.post-creation; failure_summary=none; notify_reference=not_requested;
- attempt_record: event_id=execplan.post-completion; attempt=1; status=pass; started_at=2026-03-08 00:10Z; finished_at=2026-03-08 00:11Z; commands=hook runner execplan.post-completion; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: \${branch}
- execplan_target_branch: main
- execplan_start_commit: \${head_commit}
- execplan_pr_url: https://github.com/example/repo/pull/99
- execplan_pr_title: Test PR
- execplan_branch_slug: task-branch
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- ready
<!-- execplan-pr-body:end -->

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
- start_tracked_change: (none)\t(none)
<!-- execplan-start-tracked:end -->

<!-- execplan-start-untracked:start -->
- start_untracked_file: (none)\t(none)
<!-- execplan-start-untracked:end -->
EOF_PLAN
  fi
  if [[ "\$mode" == "invalid-builder" ]]; then
    printf '%s\n' "\$invalid_envelope"
  else
    if [[ "\$mode" == "stderr-warning" ]]; then
      echo "benign warning from stderr" >&2
    fi
    printf '%s\n' "\$builder_envelope"
  fi
  exit 0
fi
if [[ "\$mode" == "reviewer-only" ]] || [[ "\$mode" == "both" && "\$count" -ge 2 ]] || [[ "\$mode" == "stderr-warning" && "\$count" -ge 2 ]]; then
  if [[ "\$mode" == "stderr-warning" ]]; then
    echo "benign warning from stderr" >&2
  fi
  printf '%s\n' "\$reviewer_envelope"
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/claude"
}

write_provider_agent_stubs_for_roles() {
  local repo="$1"
  local builder_provider="$2"
  local reviewer_provider="$3"
  local flow="${4:-new_take}"
  local codex_mode="fail-if-called"
  local claude_mode="fail-if-called"

  if [[ "$builder_provider" == "codex" && "$reviewer_provider" == "codex" ]]; then
    codex_mode="both"
  elif [[ "$builder_provider" == "codex" ]]; then
    codex_mode="builder-only"
  elif [[ "$reviewer_provider" == "codex" ]]; then
    codex_mode="reviewer-only"
  fi

  if [[ "$builder_provider" == "claude" && "$reviewer_provider" == "claude" ]]; then
    claude_mode="both"
  elif [[ "$builder_provider" == "claude" ]]; then
    claude_mode="builder-only"
  elif [[ "$reviewer_provider" == "claude" ]]; then
    claude_mode="reviewer-only"
  fi

  write_codex_provider_stub "$repo" "$codex_mode" "$flow"
  write_claude_provider_stub "$repo" "$claude_mode" "$flow"
}

assert_provider_call_counts() {
  local repo="$1"
  local builder_provider="$2"
  local reviewer_provider="$3"

  if [[ "$builder_provider" == "codex" && "$reviewer_provider" == "codex" ]]; then
    [[ "$(cat "$repo/.git/codex-call-count")" == "2" ]] || return 1
    [[ ! -f "$repo/.git/claude-call-count" ]] || return 1
    return 0
  fi

  if [[ "$builder_provider" == "claude" && "$reviewer_provider" == "claude" ]]; then
    [[ "$(cat "$repo/.git/claude-call-count")" == "2" ]] || return 1
    [[ ! -f "$repo/.git/codex-call-count" ]] || return 1
    return 0
  fi

  [[ "$(cat "$repo/.git/codex-call-count")" == "1" ]] || return 1
  [[ "$(cat "$repo/.git/claude-call-count")" == "1" ]]
}

run_provider_matrix_new_take_case() {
  local builder_provider="$1"
  local reviewer_provider="$2"
  local repo completed_plan

  repo="$(setup_fixture_repo)" || return 1
  attach_bare_origin_and_push_current_branch "$repo" || return 1
  write_provider_gh_stub "$repo"
  write_provider_agent_stubs_for_roles "$repo" "$builder_provider" "$reviewer_provider" "new_take"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add provider cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "provider matrix task" \
    --target-branch main \
    --builder-provider "$builder_provider" \
    --reviewer-provider "$reviewer_provider" \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -eq 0 ]] || return 1
  completed_plan="$(find "$repo/eternal-cycler-out/plans/completed" -maxdepth 1 -name '*.md' | head -n1)"
  [[ -n "$completed_plan" ]] || return 1
  assert_file_contains "$completed_plan" "event_id=execplan.post-creation; attempt=1; status=pass" || return 1
  assert_file_contains "$completed_plan" "event_id=execplan.post-completion; attempt=1; status=pass" || return 1
  assert_provider_call_counts "$repo" "$builder_provider" "$reviewer_provider"
}

run_provider_matrix_resume_case() {
  local builder_provider="$1"
  local reviewer_provider="$2"
  local repo branch plan_rel completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-${builder_provider}-${reviewer_provider}-resume"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [ ] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; resume work." \
    "$(resume_pass_entry)"
  append_resume_record "$repo/$plan_rel" "$(cd "$repo" && git rev-parse HEAD)"

  attach_bare_origin_and_push_current_branch "$repo" || return 1
  write_provider_gh_stub "$repo"
  write_provider_agent_stubs_for_roles "$repo" "$builder_provider" "$reviewer_provider" "resume"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add provider cli stubs" >/dev/null &&
    git push origin "$branch" >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "resume provider matrix task" \
    --max-reviewer-failures 1 \
    --builder-provider "$builder_provider" \
    --reviewer-provider "$reviewer_provider" \
    --resume-plan "$plan_rel"

  [[ "$LOOP_RC" -eq 0 ]] || return 1
  [[ -f "$completed_abs" ]] || return 1
  assert_file_contains "$completed_abs" "event_id=execplan.resume; attempt=1; status=pass" || return 1
  assert_file_contains "$completed_abs" "event_id=execplan.post-completion; attempt=1; status=pass" || return 1
  assert_provider_call_counts "$repo" "$builder_provider" "$reviewer_provider"
}

test_doctor_supports_claude_without_codex() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  write_provider_gh_stub "$repo"
  write_claude_provider_stub "$repo" "builder-only"

  run_doctor_capture "$repo" --builder-provider claude --reviewer-provider claude --head-branch main

  [[ "$DOCTOR_RC" -eq 0 ]] || return 1
  [[ "$DOCTOR_OUTPUT" == *"[OK] found command: claude"* ]] || return 1
  [[ "$DOCTOR_OUTPUT" != *"missing command: codex"* ]]
}

test_doctor_fails_when_selected_claude_auth_fails() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  write_provider_gh_stub "$repo"
  write_claude_provider_stub "$repo" "auth-fail"

  run_doctor_capture "$repo" --builder-provider claude --reviewer-provider claude --head-branch main

  [[ "$DOCTOR_RC" -ne 0 ]] || return 1
  [[ "$DOCTOR_OUTPUT" == *"[FAIL] Claude authentication"* ]]
}

test_doctor_rejects_missing_selected_provider() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  write_provider_gh_stub "$repo"

  run_doctor_capture "$repo" --builder-provider claude --reviewer-provider claude --head-branch main

  [[ "$DOCTOR_RC" -ne 0 ]] || return 1
  [[ "$DOCTOR_OUTPUT" == *"missing command: claude"* ]] || return 1
  [[ "$DOCTOR_OUTPUT" != *"missing command: codex"* ]]
}

test_doctor_fails_when_selected_codex_auth_fails() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  write_provider_gh_stub "$repo"
  write_codex_provider_stub "$repo" "auth-fail"

  run_doctor_capture "$repo" --builder-provider codex --reviewer-provider codex --head-branch main

  [[ "$DOCTOR_RC" -ne 0 ]] || return 1
  [[ "$DOCTOR_OUTPUT" == *"[FAIL] Codex authentication"* ]]
}

test_doctor_fails_when_selected_claude_doctor_fails() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  write_provider_gh_stub "$repo"
  write_claude_provider_stub "$repo" "doctor-fail"

  run_doctor_capture "$repo" --builder-provider claude --reviewer-provider claude --head-branch main

  [[ "$DOCTOR_RC" -ne 0 ]] || return 1
  [[ "$DOCTOR_OUTPUT" == *"[FAIL] Claude doctor"* ]]
}

test_loop_defaults_to_codex_when_both_agent_clis_exist() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  attach_bare_origin_and_push_current_branch "$repo" || return 1
  write_provider_gh_stub "$repo"
  write_codex_provider_stub "$repo" "both"
  write_claude_provider_stub "$repo" "fail-if-called"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add provider cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "provider default task" \
    --target-branch main \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -eq 0 ]] || return 1
  [[ -f "$repo/.git/codex-call-count" ]] || return 1
  [[ "$(cat "$repo/.git/codex-call-count")" == "2" ]] || return 1
  [[ ! -f "$repo/.git/claude-invoked-unexpectedly" ]]
}

test_loop_new_take_success_matrix() {
  local builder_provider reviewer_provider

  for builder_provider in codex claude; do
    for reviewer_provider in codex claude; do
      if ! run_provider_matrix_new_take_case "$builder_provider" "$reviewer_provider"; then
        printf 'provider matrix new-take failed for builder=%s reviewer=%s\n' "$builder_provider" "$reviewer_provider" >&2
        return 1
      fi
    done
  done
}

test_loop_resume_success_matrix() {
  local builder_provider reviewer_provider

  for builder_provider in codex claude; do
    for reviewer_provider in codex claude; do
      if ! run_provider_matrix_resume_case "$builder_provider" "$reviewer_provider"; then
        printf 'provider matrix resume failed for builder=%s reviewer=%s\n' "$builder_provider" "$reviewer_provider" >&2
        return 1
      fi
    done
  done
}

test_loop_passes_json_schema_to_claude() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  attach_bare_origin_and_push_current_branch "$repo" || return 1
  write_provider_gh_stub "$repo"
  write_claude_provider_stub "$repo" "both"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add provider cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "provider schema task" \
    --target-branch main \
    --builder-provider claude \
    --reviewer-provider claude \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -eq 0 ]] || return 1
  [[ -f "$repo/.git/claude-json-schema-seen" ]] || return 1
  jq -e '.type == "object"' "$repo/.git/claude-json-schema-seen" >/dev/null 2>&1
}

test_loop_ignores_claude_stderr_when_stdout_json_is_valid() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  attach_bare_origin_and_push_current_branch "$repo" || return 1
  write_provider_gh_stub "$repo"
  write_claude_provider_stub "$repo" "stderr-warning"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add provider cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "provider stderr task" \
    --target-branch main \
    --builder-provider claude \
    --reviewer-provider claude \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -eq 0 ]] || return 1
  [[ "$(cat "$repo/.git/claude-call-count")" == "2" ]]
}

test_loop_rejects_invalid_claude_builder_payload() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  attach_bare_origin_and_push_current_branch "$repo" || return 1
  write_provider_gh_stub "$repo"
  write_claude_provider_stub "$repo" "invalid-builder"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add provider cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "provider invalid task" \
    --target-branch main \
    --builder-provider claude \
    --reviewer-provider claude \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$LOOP_OUTPUT" == *"builder output was not valid JSON payload"* ]]
}

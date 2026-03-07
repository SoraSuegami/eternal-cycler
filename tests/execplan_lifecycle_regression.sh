#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIRS=()
FAILURES=0
GATE_OUTPUT=""
GATE_RC=0
HELPER_OUTPUT=""
HELPER_RC=0
HOOK_OUTPUT=""
HOOK_RC=0
LOOP_OUTPUT=""
LOOP_RC=0

cleanup() {
  local dir
  for dir in "${TMP_DIRS[@]}"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    rm -rf "$dir"
  done
}
trap cleanup EXIT

run_test() {
  local name="$1"
  shift

  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

setup_fixture_repo() {
  local tmp repo

  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  TMP_DIRS+=("$tmp")

  mkdir -p "$repo/.agents/skills" "$repo/eternal-cycler-out/plans/active" "$repo/eternal-cycler-out/plans/completed"
  cp -R "$REPO_ROOT/scripts" "$repo/"
  cp -R "$REPO_ROOT/assets/default-hooks/." "$repo/.agents/skills/"
  find "$repo/scripts" "$repo/.agents/skills" -type f -name '*.sh' -exec chmod +x {} +

  (
    cd "$repo" &&
    git init -b main >/dev/null &&
    git config user.email "test@example.com" &&
    git config user.name "ExecPlan Tests" &&
    git add . &&
    git commit -m "fixture bootstrap" >/dev/null
  ) >/dev/null 2>&1 || return 1

  printf '%s\n' "$repo"
}

write_execplan() {
  local repo="$1"
  local rel_path="$2"
  local branch="$3"
  local progress_lines="$4"
  local ledger_lines="$5"

  mkdir -p "$repo/$(dirname "$rel_path")"
  cat > "$repo/$rel_path" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

${progress_lines}

## Hook Ledger

<!-- hook-ledger:start -->
${ledger_lines}
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: ${branch}
- execplan_target_branch: main
- execplan_start_commit: deadbeef
- execplan_pr_url: https://example.com/pr/1
- execplan_pr_title: Test PR
- execplan_branch_slug: test
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- test body
<!-- execplan-pr-body:end -->

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
- start_tracked_change: (none)	(none)
<!-- execplan-start-tracked:end -->

<!-- execplan-start-untracked:start -->
- start_untracked_file: (none)	(none)
<!-- execplan-start-untracked:end -->
EOF_PLAN
}

post_creation_pass_entry() {
  cat <<'EOF_ENTRY'
- attempt_record: event_id=execplan.post_creation; attempt=1; status=pass; started_at=2026-03-08 00:00Z; finished_at=2026-03-08 00:01Z; commands=hook runner execplan.post_creation; failure_summary=none; notify_reference=not_requested;
EOF_ENTRY
}

hook_tooling_pass_entry() {
  cat <<'EOF_ENTRY'
- attempt_record: event_id=hook.tooling; attempt=1; status=pass; started_at=2026-03-08 00:02Z; finished_at=2026-03-08 00:03Z; commands=hook runner hook.tooling; failure_summary=none; notify_reference=not_requested;
EOF_ENTRY
}

resume_pass_entry() {
  cat <<'EOF_ENTRY'
- attempt_record: event_id=execplan.resume; attempt=1; status=pass; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=none; notify_reference=not_requested;
EOF_ENTRY
}

append_resume_record() {
  local plan_path="$1"
  local commit="$2"

  cat >> "$plan_path" <<EOF_RECORD

## ExecPlan Resume Record

- resume_date: 2026-03-08 00:05Z
- resume_commit: ${commit}
- operator_feedback: (none)
EOF_RECORD
}

run_gate_capture() {
  local repo="$1"
  shift

  set +e
  GATE_OUTPUT="$(cd "$repo" && scripts/execplan_gate.sh "$@" 2>&1)"
  GATE_RC=$?
  set -e
}

run_completed_plan_helper() {
  local repo="$1"
  local branch="$2"

  set +e
  HELPER_OUTPUT="$(
    bash -c 'source "$1/scripts/execplan_plan_metadata.sh"; resolve_completed_plan_rel_path_for_branch "$1" "$2"' \
      _ "$repo" "$branch" 2>&1
  )"
  HELPER_RC=$?
  set -e
}

run_post_completion_hook_capture() {
  local repo="$1"
  local plan_rel="$2"

  set +e
  HOOK_OUTPUT="$(
    cd "$repo" &&
    ETERNAL_CYCLER_ROOT="$repo" \
    REPO_ROOT="$repo" \
    ./.agents/skills/execplan-hook-post-completion/scripts/run_event.sh --plan "$plan_rel" 2>&1
  )"
  HOOK_RC=$?
  set -e
}

run_pre_creation_hook_capture() {
  local repo="$1"

  set +e
  HOOK_OUTPUT="$(
    cd "$repo" &&
    ETERNAL_CYCLER_ROOT="$repo" \
    REPO_ROOT="$repo" \
    ./.agents/skills/execplan-hook-pre-creation/scripts/run_event.sh 2>&1
  )"
  HOOK_RC=$?
  set -e
}

run_post_creation_hook_capture() {
  local repo="$1"
  local plan_rel="$2"

  set +e
  HOOK_OUTPUT="$(
    cd "$repo" &&
    ETERNAL_CYCLER_ROOT="$repo" \
    REPO_ROOT="$repo" \
    ./.agents/skills/execplan-hook-post-creation/scripts/run_event.sh --plan "$plan_rel" 2>&1
  )"
  HOOK_RC=$?
  set -e
}

run_loop_capture() {
  local repo="$1"
  shift

  set +e
  LOOP_OUTPUT="$(cd "$repo" && PATH="$repo/bin:$PATH" scripts/run_builder_reviewer_loop.sh "$@" 2>&1)"
  LOOP_RC=$?
  set -e
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  rg -Fq -- "$expected" "$path"
}

count_file_matches() {
  local path="$1"
  local pattern="$2"
  rg -c -- "$pattern" "$path" | awk -F: '{sum += $NF} END {print sum+0}'
}

test_completed_plan_helper_requires_completed_path() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1200"
  plan_rel="eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
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
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$(post_creation_pass_entry)"

  run_completed_plan_helper "$repo" "$branch"
  [[ "$HELPER_RC" -ne 0 ]]
}

test_post_completion_allows_hook_events_none() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1400"
  plan_rel="eternal-cycler-out/plans/completed/${branch}.md"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event execplan.post_completion
  [[ "$GATE_RC" -eq 0 ]] || return 1
  [[ "$GATE_OUTPUT" == *"STATUS=pass"* ]]
}

test_post_completion_requires_declared_hook_passes() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1500"
  plan_rel="eternal-cycler-out/plans/completed/${branch}.md"
  plan_abs="$repo/$plan_rel"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=hook.tooling; worker_type=worker; finalize take." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event execplan.post_completion
  [[ "$GATE_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "failure_summary=missing pass entries for required hook_events: hook.tooling"
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
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=execplan.post_completion; worker_type=worker; run tooling." \
    "$(post_creation_pass_entry)"

  run_gate_capture "$repo" --plan "$plan_rel" --event hook.tooling
  [[ "$GATE_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "failure_summary=hook_events must not contain lifecycle event: execplan.post_completion"
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
  local repo branch plan_rel plan_abs ledger_lines

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-1900"
  plan_rel="eternal-cycler-out/plans/completed/${branch}.md"
  plan_abs="$repo/$plan_rel"
  ledger_lines="$(post_creation_pass_entry)
$(cat <<'EOF_ENTRY'
- attempt_record: event_id=execplan.resume; attempt=1; status=fail; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=resume blocked; notify_reference=not_requested;
EOF_ENTRY
)"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$ledger_lines"

  run_gate_capture "$repo" --plan "$plan_rel" --event execplan.post_completion
  [[ "$GATE_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "failure_summary=unresolved event status remains for execplan.resume:fail"
}

test_post_completion_hook_blocks_lifecycle_unresolved() {
  local repo branch plan_rel ledger_lines

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2000"
  plan_rel="eternal-cycler-out/plans/completed/${branch}.md"
  ledger_lines="$(post_creation_pass_entry)
$(cat <<'EOF_ENTRY'
- attempt_record: event_id=execplan.resume; attempt=1; status=fail; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=resume blocked; notify_reference=not_requested;
EOF_ENTRY
)"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take." \
    "$ledger_lines"

  run_post_completion_hook_capture "$repo" "$plan_rel"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=latest hook event is unresolved: execplan.resume:fail"* ]]
}

test_gate_force_closes_escalated_active_plan() {
  local repo branch active_rel active_abs completed_rel completed_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2100"
  active_rel="eternal-cycler-out/plans/active/${branch}.md"
  active_abs="$repo/$active_rel"
  completed_rel="eternal-cycler-out/plans/completed/${branch}.md"
  completed_abs="$repo/$completed_rel"
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
  assert_file_contains "$completed_abs" "status=escalated"
}

test_pre_creation_requires_clean_worktree() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  printf 'dirty\n' > "$repo/untracked.txt"

  run_pre_creation_hook_capture "$repo"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=working tree must be clean before execplan.pre_creation"* ]]
}

test_pre_creation_truncates_existing_plan_file() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2300"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  mkdir -p "$(dirname "$plan_abs")"
  printf 'stale plan content\n' > "$plan_abs"
  (
    cd "$repo" &&
    git add "$plan_rel" &&
    git commit -m "seed stale plan" >/dev/null
  ) || return 1

  run_pre_creation_hook_capture "$repo"
  [[ "$HOOK_RC" -eq 0 ]] || return 1
  [[ -f "$plan_abs" ]] || return 1
  [[ ! -s "$plan_abs" ]]
}

test_post_creation_requires_draft_pr() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2310"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [ ] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; create plan." \
    ""

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<EOF_STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "pr view" ]]; then
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/44","title":"Plan PR","body":"## Summary\n- plan","headRefName":"${branch}","baseRefName":"main","state":"OPEN","isDraft":false}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh"

  set +e
  HOOK_OUTPUT="$(
    cd "$repo" &&
    PATH="$repo/bin:$PATH" \
    ETERNAL_CYCLER_ROOT="$repo" \
    REPO_ROOT="$repo" \
    ./.agents/skills/execplan-hook-post-creation/scripts/run_event.sh --plan "$plan_rel" 2>&1
  )"
  HOOK_RC=$?
  set -e

  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=current branch PR must be a draft PR before execplan.post_creation"* ]]
}

test_supersede_flow_uses_two_arg_completed_destination_helper() {
  assert_file_contains \
    "$REPO_ROOT/scripts/run_builder_reviewer_loop.sh" \
    'generate_unique_completed_plan_destination "$WORKDIR" "$abs_path"'
}

test_loop_rejects_non_draft_pr_reuse_for_new_take() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2320"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<EOF_STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "pr list" ]]; then
  cat <<'EOF_JSON'
[{"url":"https://github.com/example/repo/pull/45","updatedAt":"2026-03-08T00:00:00Z","isDraft":false,"baseRefName":"main","title":"Existing Ready PR","body":"## Summary\n- ready"}]
EOF_JSON
  exit 0
fi
if [[ "\$1 \$2" == "pr view" ]]; then
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/45","title":"Existing Ready PR","body":"## Summary\n- ready","headRefName":"${branch}","baseRefName":"main","state":"OPEN","isDraft":false}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  cat > "$repo/bin/codex" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "login status" ]]; then
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh" "$repo/bin/codex"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add cli stubs" >/dev/null
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "new task" \
    --target-branch main \
    --pr-title "Existing Ready PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$LOOP_OUTPUT" == *"new takes require a draft PR; existing open PR is not draft"* ]]
}

test_resume_loop_invokes_resume_gate_when_missing() {
  local repo branch plan_rel plan_abs pr_url head_commit

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2200"
  pr_url="https://github.com/example/repo/pull/42"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  head_commit="$(cd "$repo" && git rev-parse HEAD)"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [ ] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; resume work." \
    "$(post_creation_pass_entry)"

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<EOF_STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "pr view" ]]; then
  cat <<'EOF_JSON'
{"url":"${pr_url}","title":"Resume PR","body":"## Summary\n- resumed","headRefName":"${branch}","baseRefName":"main","state":"OPEN","isDraft":false}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  cat > "$repo/bin/codex" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "login status" ]]; then
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh" "$repo/bin/codex"

  run_loop_capture \
    "$repo" \
    --task "resume task" \
    --target-branch main \
    --pr-title "Resume PR" \
    --pr-body "## Summary\n- resumed" \
    --pr-url "$pr_url"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  assert_file_contains "$plan_abs" "event_id=execplan.resume; attempt=1; status=pass" || return 1
  assert_file_contains "$plan_abs" "- resume_commit: ${head_commit}"
}

test_resume_loop_skips_duplicate_resume_gate() {
  local repo branch plan_rel plan_abs pr_url head_commit

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2210"
  pr_url="https://github.com/example/repo/pull/43"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  head_commit="$(cd "$repo" && git rev-parse HEAD)"
  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [ ] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; resume work." \
    "$(post_creation_pass_entry)
$(resume_pass_entry)"
  append_resume_record "$repo/$plan_rel" "$head_commit"

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<EOF_STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "pr view" ]]; then
  cat <<'EOF_JSON'
{"url":"${pr_url}","title":"Resume PR","body":"## Summary\n- resumed","headRefName":"${branch}","baseRefName":"main","state":"OPEN","isDraft":false}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  cat > "$repo/bin/codex" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "login status" ]]; then
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh" "$repo/bin/codex"

  run_loop_capture \
    "$repo" \
    --task "resume task" \
    --target-branch main \
    --pr-title "Resume PR" \
    --pr-body "## Summary\n- resumed" \
    --pr-url "$pr_url"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$(count_file_matches "$plan_abs" 'event_id=execplan.resume;')" -eq 1 ]] || return 1
  assert_file_contains "$plan_abs" "- resume_commit: ${head_commit}" || return 1
  [[ "$LOOP_OUTPUT" == *"skipping duplicate gate invocation"* ]]
}

run_test "completed plan helper resolves completed path" test_completed_plan_helper_requires_completed_path
run_test "completed plan helper rejects active-only plans" test_completed_plan_helper_fails_without_completed_plan
run_test "post completion accepts hook_events=none" test_post_completion_allows_hook_events_none
run_test "post completion requires declared hook pass coverage" test_post_completion_requires_declared_hook_passes
run_test "gate rejects lifecycle events in hook_events" test_gate_rejects_lifecycle_event_in_hook_events
run_test "gate rejects non-hook namespaces" test_gate_rejects_non_hook_namespaces
run_test "gate rejects verify_events" test_gate_rejects_verify_events_field
run_test "gate blocks lifecycle unresolved state before post completion" test_gate_blocks_lifecycle_unresolved_before_post_completion
run_test "post completion hook blocks lifecycle unresolved state" test_post_completion_hook_blocks_lifecycle_unresolved
run_test "gate force-closes escalated active plan" test_gate_force_closes_escalated_active_plan
run_test "pre creation requires clean worktree" test_pre_creation_requires_clean_worktree
run_test "pre creation truncates existing plan file" test_pre_creation_truncates_existing_plan_file
run_test "post creation requires draft pr" test_post_creation_requires_draft_pr
run_test "supersede flow uses two-arg completed destination helper" test_supersede_flow_uses_two_arg_completed_destination_helper
run_test "loop rejects non-draft pr reuse for new take" test_loop_rejects_non_draft_pr_reuse_for_new_take
run_test "resume loop invokes execplan.resume gate when missing" test_resume_loop_invokes_resume_gate_when_missing
run_test "resume loop skips duplicate execplan.resume gate" test_resume_loop_skips_duplicate_resume_gate

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'all tests passed\n'

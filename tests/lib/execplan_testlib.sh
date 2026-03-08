#!/usr/bin/env bash

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
TEST_OUT_DIR="$TESTS_ROOT/out"

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

init_test_workspace() {
  mkdir -p "$TEST_OUT_DIR"
  find "$TEST_OUT_DIR" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} +
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
}

cleanup_test_workspace() {
  mkdir -p "$TEST_OUT_DIR"
  find "$TEST_OUT_DIR" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} +
}

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

  tmp="$(mktemp -d "$TEST_OUT_DIR/tmp.repo.XXXXXX")"
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

attach_bare_origin_and_push_current_branch() {
  local repo="$1"
  local tmp remote branch

  tmp="$(mktemp -d "$TEST_OUT_DIR/tmp.origin.XXXXXX")"
  remote="$tmp/origin.git"
  TMP_DIRS+=("$tmp")

  git init --bare "$remote" >/dev/null 2>&1 || return 1
  (
    cd "$repo" &&
    git remote add origin "$remote" &&
    git push -u origin main >/dev/null 2>&1
  ) || return 1

  branch="$(cd "$repo" && git branch --show-current)"
  if [[ "$branch" != "main" ]]; then
    (
      cd "$repo" &&
      git push -u origin "$branch" >/dev/null 2>&1
    ) || return 1
  fi
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
- attempt_record: event_id=execplan.post-creation; attempt=1; status=pass; started_at=2026-03-08 00:00Z; finished_at=2026-03-08 00:01Z; commands=hook runner execplan.post-creation; failure_summary=none; notify_reference=not_requested;
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

run_docs_only_hook_capture() {
  local repo="$1"
  local plan_rel="$2"

  set +e
  HOOK_OUTPUT="$(
    cd "$repo" &&
    ./.agents/skills/execplan-hook-docs-only/scripts/run_event.sh --plan "$plan_rel" 2>&1
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

run_feedback_helper_capture() {
  local repo="$1"
  shift

  set +e
  HELPER_OUTPUT="$(cd "$repo" && scripts/execplan_user_feedback.sh "$@" 2>&1)"
  HELPER_RC=$?
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

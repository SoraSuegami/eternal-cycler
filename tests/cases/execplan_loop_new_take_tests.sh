#!/usr/bin/env bash

test_new_take_requires_target_branch_refresh() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c feature-incidental >/dev/null
  ) >/dev/null 2>&1 || return 1

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then
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
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$LOOP_OUTPUT" == *"failed to pull target branch origin/main"* ]]
}

test_new_take_starts_from_target_branch_even_when_invoked_from_feature_branch() {
  local repo target_head completed_plan completed_branch

  repo="$(setup_fixture_repo)" || return 1
  attach_bare_origin_and_push_current_branch "$repo" || return 1

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
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/99","title":"Test PR","body":"## Summary\n- ready","headRefName":"task-branch","baseRefName":"main","state":"OPEN","isDraft":true}
EOF_JSON
  exit 0
fi
if [[ "$1 $2" == "pr edit" || "$1 $2" == "pr ready" || "$1 $2" == "pr comment" ]]; then
  [[ "$1 $2" == "pr comment" ]] && echo "https://github.com/example/repo/pull/99#issuecomment-1"
  exit 0
fi
exit 1
EOF_STUB
  cat > "$repo/bin/codex" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "login status" ]]; then
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  state_file=".git/codex-call-count"
  if [[ -f "$state_file" ]]; then
    count="$(cat "$state_file")"
  else
    count=0
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$state_file"
  if [[ "$count" -ge 2 ]]; then
    exit 1
  fi
  out=""
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--output-last-message" ]]; then
      next=$((i + 1))
      out="${!next}"
    fi
  done
  branch="$(git branch --show-current)"
  head_commit="$(git rev-parse HEAD)"
  active_plan="eternal-cycler-out/plans/active/${branch}.md"
  completed_plan="eternal-cycler-out/plans/completed/${branch}.md"
  rm -f "$active_plan"
  cat > "$completed_plan" <<EOF_PLAN
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
- execplan_start_branch: ${branch}
- execplan_target_branch: main
- execplan_start_commit: ${head_commit}
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
  if [[ -n "$out" ]]; then
    cat <<'EOF_JSON' > "$out"
{"result":"success","comment":"builder success"}
EOF_JSON
  fi
  cat <<'EOF_JSON'
{"result":"success","comment":"builder success"}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh" "$repo/bin/codex"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1
  ) || return 1

  target_head="$(cd "$repo" && git rev-parse main)"
  (
    cd "$repo" &&
    git switch -c feature-incidental >/dev/null &&
    printf 'incidental\n' > incidental.txt &&
    git add incidental.txt &&
    git commit -m "incidental branch commit" >/dev/null &&
    git push -u origin feature-incidental >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "task branch" \
    --target-branch main \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready" \
    --max-reviewer-failures 1

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  completed_plan="$(find "$repo/eternal-cycler-out/plans/completed" -maxdepth 1 -name '*.md' | head -n1)"
  [[ -n "$completed_plan" ]] || return 1
  assert_file_contains "$completed_plan" "execplan_start_commit: ${target_head}" || return 1
  completed_branch="$(sed -n 's/^- execplan_start_branch: //p' "$completed_plan" | head -n1)"
  [[ "$completed_branch" != "feature-incidental" ]]
}

test_loop_rejects_non_draft_pr_reuse_for_new_take() {
  local repo branch

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2320"
  attach_bare_origin_and_push_current_branch "$repo" || return 1

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
  printf '%s\n' "$head" > "$state_dir/last-head"
  cat <<EOF_JSON
[{"url":"https://github.com/example/repo/pull/45","updatedAt":"2026-03-08T00:00:00Z","isDraft":false,"baseRefName":"main","title":"Existing Ready PR","body":"## Summary\\n- ready","headRefName":"${head}"}]
EOF_JSON
  exit 0
fi
if [[ "$1 $2" == "pr view" ]]; then
  head="$(cat "$state_dir/last-head" 2>/dev/null || echo unknown)"
  cat <<EOF_JSON
{"url":"https://github.com/example/repo/pull/45","title":"Existing Ready PR","body":"## Summary\\n- ready","headRefName":"${head:-unknown}","baseRefName":"main","state":"OPEN","isDraft":false}
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
    git commit -m "add cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1 &&
    git switch -c "$branch" >/dev/null
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "new task" \
    --target-branch main \
    --pr-title "Existing Ready PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  printf '%s' "$LOOP_OUTPUT" | rg -Fq "new takes require a draft PR; existing open PR is not draft" || return 1
  return 0
}

test_loop_force_closes_failed_builder_plan() {
  local repo branch completed_plan pr_url

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2330"
  pr_url="https://github.com/example/repo/pull/46"

  attach_bare_origin_and_push_current_branch "$repo" || return 1

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
[{"url":"${url}","updatedAt":"2026-03-08T00:00:00Z","isDraft":true,"baseRefName":"main","title":"Resume PR","body":"## Summary\n- resumed"}]
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
  printf 'https://github.com/example/repo/pull/46\n' > "$state_dir/pr-${head}"
  exit 0
fi
if [[ "$1 $2" == "pr view" ]]; then
  if [[ " $* " == *" --jq "* ]]; then
    echo "false"
    exit 0
  fi
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/46","title":"Resume PR","body":"## Summary\n- resumed","headRefName":"generated-branch","baseRefName":"main","state":"OPEN","isDraft":true}
EOF_JSON
  exit 0
fi
if [[ "$1 $2" == "pr edit" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr ready" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr comment" ]]; then
  echo "https://github.com/example/repo/pull/46#issuecomment-1"
  exit 0
fi
exit 1
EOF_STUB
  cat > "$repo/bin/codex" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "login status" ]]; then
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  out=""
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--output-last-message" ]]; then
      next=$((i + 1))
      out="${!next}"
    fi
  done
  branch="$(git branch --show-current)"
  plan="eternal-cycler-out/plans/active/${branch}.md"
  cat > "$plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [ ] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; resume work.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.post-creation; attempt=1; status=pass; started_at=2026-03-08 00:00Z; finished_at=2026-03-08 00:01Z; commands=hook runner execplan.post-creation; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: ${branch}
- execplan_target_branch: main
- execplan_start_commit: deadbeef
- execplan_pr_url: ${pr_url}
- execplan_pr_title: Resume PR
- execplan_branch_slug: test
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- resumed
<!-- execplan-pr-body:end -->

## ExecPlan Start Snapshot

<!-- execplan-start-tracked:start -->
- start_tracked_change: (none)\t(none)
<!-- execplan-start-tracked:end -->

<!-- execplan-start-untracked:start -->
- start_untracked_file: (none)\t(none)
<!-- execplan-start-untracked:end -->
EOF_PLAN
  if [[ -n "$out" ]]; then
    cat <<'EOF_JSON' > "$out"
{"result":"failed_after_3_retries","comment":"builder failed"}
EOF_JSON
  fi
  cat <<'EOF_JSON'
{"result":"failed_after_3_retries","comment":"builder failed"}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh" "$repo/bin/codex"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1 &&
    git switch -c "$branch" >/dev/null
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "new task" \
    --target-branch main \
    --pr-title "Resume PR" \
    --pr-body "## Summary\n- resumed"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  completed_plan="$(find "$repo/eternal-cycler-out/plans/completed" -maxdepth 1 -name '*.md' | head -n1)"
  [[ -n "$completed_plan" ]] || return 1
  assert_file_contains "$completed_plan" "event_id=execplan.post-creation; attempt=1; status=pass" || return 1
  assert_file_contains "$completed_plan" "builder_failure_record: stage=builder_initial; status=failed_after_3_retries" || return 1
  assert_file_contains "$completed_plan" "failure_record:" || return 1
  assert_file_contains "$completed_plan" "Builder exhausted three retries at builder_initial." || return 1
  printf '%s' "$LOOP_OUTPUT" | rg -Fq "builder reported failed_after_3_retries" || return 1
  return 0
}

test_loop_rejects_active_plan_missing_post_creation_or_resume_pass() {
  local repo branch

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2341"

  attach_bare_origin_and_push_current_branch "$repo" || return 1

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
  printf 'https://github.com/example/repo/pull/48\n' > "$state_dir/pr-${head}"
  exit 0
fi
if [[ "$1 $2" == "pr view" ]]; then
  if [[ " $* " == *" --jq "* ]]; then
    echo "false"
    exit 0
  fi
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/48","title":"Test PR","body":"## Summary\n- ready","headRefName":"generated-branch","baseRefName":"main","state":"OPEN","isDraft":true}
EOF_JSON
  exit 0
fi
if [[ "$1 $2" == "pr edit" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr ready" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr comment" ]]; then
  echo "https://github.com/example/repo/pull/48#issuecomment-1"
  exit 0
fi
exit 1
EOF_STUB
  cat > "$repo/bin/codex" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "login status" ]]; then
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  printf '1\n' > .git/codex-call-count
  out=""
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--output-last-message" ]]; then
      next=$((i + 1))
      out="${!next}"
    fi
  done
  branch="$(git branch --show-current)"
  active_plan="eternal-cycler-out/plans/active/${branch}.md"
  completed_plan="eternal-cycler-out/plans/completed/${branch}.md"
  rm -f "$active_plan"
  cat > "$completed_plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.post-completion; attempt=1; status=pass; started_at=2026-03-08 00:10Z; finished_at=2026-03-08 00:11Z; commands=hook runner execplan.post-completion; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: ${branch}
- execplan_target_branch: main
- execplan_start_commit: deadbeef
- execplan_pr_url: https://github.com/example/repo/pull/48
- execplan_pr_title: Test PR
- execplan_branch_slug: test
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
  if [[ -n "$out" ]]; then
    cat <<'EOF_JSON' > "$out"
{"result":"success","comment":"builder success"}
EOF_JSON
  fi
  cat <<'EOF_JSON'
{"result":"success","comment":"builder success"}
EOF_JSON
  exit 0
fi
exit 1
EOF_STUB
  chmod +x "$repo/bin/gh" "$repo/bin/codex"
  (
    cd "$repo" &&
    git add bin/ &&
    git commit -m "add cli stubs" >/dev/null &&
    git push origin main >/dev/null 2>&1 &&
    git switch -c "$branch" >/dev/null
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "new task" \
    --target-branch main \
    --pr-title "Test PR" \
    --pr-body "## Summary\n- ready"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  printf '%s' "$LOOP_OUTPUT" | rg -Fq "missing pass evidence for execplan.post-creation or execplan.resume" || return 1
  [[ -f "$repo/.git/codex-call-count" ]] || return 1
  [[ "$(cat "$repo/.git/codex-call-count")" == "1" ]] || return 1
  return 0
}

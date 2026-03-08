#!/usr/bin/env bash

test_resume_plan_requires_target_branch_refresh() {
  local repo branch plan_rel plan_abs

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2325"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  plan_abs="$repo/$plan_rel"

  (
    cd "$repo" &&
    git commit --allow-empty -m "init" >/dev/null &&
    git switch -c "$branch" >/dev/null
  ) >/dev/null 2>&1 || return 1

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [ ] hook_events=none; resume work." \
    "$(resume_pass_entry)"
  sed -i 's/^- execplan_target_branch: main$/- execplan_target_branch: missing-target/' "$plan_abs"

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<EOF_STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "pr view" ]]; then
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/52","title":"Resume PR","body":"## Summary\n- resumed","headRefName":"${branch}","baseRefName":"missing-target","state":"OPEN","isDraft":false}
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
    --task "resume task" \
    --target-branch main \
    --resume-plan "$plan_rel"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$LOOP_OUTPUT" == *"branch not found locally or on origin: missing-target"* ]]
}

test_loop_rejects_legacy_pr_url_resume_entrypoint() {
  local repo

  repo="$(setup_fixture_repo)" || return 1

  run_loop_capture \
    "$repo" \
    --task "resume task" \
    --pr-url "https://github.com/example/repo/pull/42"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$LOOP_OUTPUT" == *"unknown argument: --pr-url"* ]]
}

test_loop_accepts_resume_only_plan_for_post_completion() {
  local repo branch plan_rel completed_abs head_commit

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2340"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"
  completed_abs="$repo/eternal-cycler-out/plans/completed/${branch}.md"

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
    "$(resume_pass_entry)"
  append_resume_record "$repo/$plan_rel" "$head_commit"

  attach_bare_origin_and_push_current_branch "$repo" || return 1

  mkdir -p "$repo/bin"
  cat > "$repo/bin/gh" <<EOF_STUB
#!/usr/bin/env bash
if [[ "\$1 \$2" == "auth status" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "pr view" ]]; then
  if [[ " \$* " == *" --jq "* ]]; then
    echo "false"
    exit 0
  fi
  cat <<'EOF_JSON'
{"url":"https://github.com/example/repo/pull/47","title":"Test PR","body":"## Summary\n- ready","headRefName":"feature-20260308-2340","baseRefName":"main","state":"OPEN","isDraft":true}
EOF_JSON
  exit 0
fi
if [[ "\$1 \$2" == "pr ready" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "pr comment" ]]; then
  echo "https://github.com/example/repo/pull/47#issuecomment-1"
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
  active_plan="eternal-cycler-out/plans/active/${branch}.md"
  completed_plan="eternal-cycler-out/plans/completed/${branch}.md"
  printf 'generated output\n' > generated.txt
  rm -f "$active_plan"
  cat > "$completed_plan" <<EOF_PLAN
# Test Plan

This ExecPlan is a living document.

## Progress

- [x] action_id=a1; mode=serial; depends_on=none; file_locks=none; hook_events=none; worker_type=worker; finalize take.

## Hook Ledger

<!-- hook-ledger:start -->
- attempt_record: event_id=execplan.resume; attempt=1; status=pass; started_at=2026-03-08 00:04Z; finished_at=2026-03-08 00:05Z; commands=hook runner execplan.resume; failure_summary=none; notify_reference=not_requested;
- attempt_record: event_id=execplan.post-completion; attempt=1; status=pass; started_at=2026-03-08 00:10Z; finished_at=2026-03-08 00:11Z; commands=hook runner execplan.post-completion; failure_summary=none; notify_reference=not_requested;
<!-- hook-ledger:end -->

## ExecPlan Metadata

<!-- execplan-metadata:start -->
- execplan_start_branch: ${branch}
- execplan_target_branch: main
- execplan_start_commit: ${head_commit}
- execplan_pr_url: https://github.com/example/repo/pull/47
- execplan_pr_title: Test PR
- execplan_branch_slug: test
- execplan_take: 1
<!-- execplan-metadata:end -->

## ExecPlan PR Body

<!-- execplan-pr-body:start -->
## Summary
- ready
<!-- execplan-pr-body:end -->

## ExecPlan Resume Record

- resume_date: 2026-03-08 00:05Z
- resume_commit: ${head_commit}
- operator_feedback: (none)

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
    git push origin "$branch" >/dev/null 2>&1
  ) || return 1

  run_loop_capture \
    "$repo" \
    --task "resume task" \
    --max-reviewer-failures 1 \
    --resume-plan "$plan_rel"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ -f "$completed_abs" ]] || return 1
  assert_file_contains "$completed_abs" "event_id=execplan.resume; attempt=1; status=pass" || return 1
  assert_file_contains "$completed_abs" "event_id=execplan.post-completion; attempt=1; status=pass" || return 1
  (cd "$repo" && git ls-files --error-unmatch generated.txt >/dev/null 2>&1) || return 1
  printf '%s' "$LOOP_OUTPUT" | rg -Fq "reviewer codex execution failed" || return 1
  return 0
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

  attach_bare_origin_and_push_current_branch "$repo" || return 1

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
    --resume-plan "$plan_rel"

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

  attach_bare_origin_and_push_current_branch "$repo" || return 1

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
    --resume-plan "$plan_rel"

  [[ "$LOOP_RC" -ne 0 ]] || return 1
  [[ "$(count_file_matches "$plan_abs" 'event_id=execplan.resume;')" -eq 1 ]] || return 1
  assert_file_contains "$plan_abs" "- resume_commit: ${head_commit}" || return 1
  [[ "$LOOP_OUTPUT" == *"skipping duplicate gate invocation"* ]]
}

#!/usr/bin/env bash

test_pre_creation_requires_clean_tracked_worktree() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  printf 'dirty\n' > "$repo/tracked.txt"
  (
    cd "$repo" &&
    git add tracked.txt &&
    git commit -m "add tracked file" >/dev/null
  ) || return 1
  printf 'changed\n' > "$repo/tracked.txt"

  run_pre_creation_hook_capture "$repo"
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=tracked working tree must be clean before execplan.pre-creation"* ]]
}

test_pre_creation_allows_untracked_files() {
  local repo

  repo="$(setup_fixture_repo)" || return 1
  printf 'untracked\n' > "$repo/untracked.txt"

  run_pre_creation_hook_capture "$repo"
  [[ "$HOOK_RC" -eq 0 ]] || return 1
}

test_pre_creation_rejects_existing_nonempty_plan_file() {
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
  [[ "$HOOK_RC" -ne 0 ]] || return 1
  [[ -f "$plan_abs" ]] || return 1
  assert_file_contains "$plan_abs" "stale plan content" || return 1
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=active plan already exists at ${plan_rel}; resume it or choose a new branch"* ]]
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
  [[ "$HOOK_OUTPUT" == *"FAILURE_SUMMARY=current branch PR must be a draft PR before execplan.post-creation"* ]]
}

test_docs_only_hook_allows_rules_paths() {
  local repo branch plan_rel

  repo="$(setup_fixture_repo)" || return 1
  branch="feature-20260308-2315"
  plan_rel="eternal-cycler-out/plans/active/${branch}.md"

  write_execplan \
    "$repo" \
    "$plan_rel" \
    "$branch" \
    "- [x] hook_events=hook.docs-only; update policy." \
    "$(post_creation_pass_entry)"

  mkdir -p "$repo/.codex/rules"
  printf 'policy\n' > "$repo/.codex/rules/eternal-cycler.rules"

  run_docs_only_hook_capture "$repo" "$plan_rel"
  [[ "$HOOK_RC" -eq 0 ]] || return 1
  [[ "$HOOK_OUTPUT" == *"STATUS=pass"* ]]
}

test_supersede_flow_uses_two_arg_completed_destination_helper() {
  assert_file_contains \
    "$REPO_ROOT/scripts/run_builder_reviewer_loop.sh" \
    'generate_unique_completed_plan_destination "$WORKDIR" "$abs_path"'
}

#!/usr/bin/env bash

move_plan_to_completed_as_superseded() {
  local plan_path="$1"
  local closed_pr_url="$2"
  local reviewer_comment="$3"
  local abs_path rel_path destination first_line timestamp

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || die "plan file not found for supersede flow: $plan_path"

  timestamp="$(date -u +"%Y-%m-%d %H:%MZ")"
  first_line="$(printf '%s\n' "$reviewer_comment" | head -n1 | sed -E 's/[[:space:]]+/ /g')"

  cat >> "$abs_path" <<EOF_NOTE

## ExecPlan Superseded Record

- superseded_at: ${timestamp}
- superseded_reason: reviewer_rejected
- superseded_pr_url: ${closed_pr_url}
- superseded_comment_excerpt: ${first_line}
EOF_NOTE

  rel_path="$(repo_rel_path "$WORKDIR" "$abs_path")"
  if [[ "$rel_path" == eternal-cycler-out/plans/active/* ]]; then
    destination="$(generate_unique_completed_plan_destination "$WORKDIR" "$abs_path")"
    mkdir -p "$(dirname "$destination")"
    mv "$abs_path" "$destination"
    printf '%s\n' "$(repo_rel_path "$WORKDIR" "$destination")"
    return 0
  fi

  printf '%s\n' "$rel_path"
}

load_completed_plan_runtime_metadata_for_branch() {
  local branch="$1"
  local completed_plan_path

  completed_plan_path="$(resolve_completed_plan_rel_path_for_branch "$WORKDIR" "$branch" || true)"
  [[ -n "$completed_plan_path" ]] || die "completed plan not found for branch: $(completed_plan_rel_path_for_branch "$branch")"

  load_plan_runtime_metadata "$completed_plan_path"
}

append_note_to_markdown_section() {
  local file="$1"
  local heading="$2"
  local note="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v heading="$heading" -v note="$note" '
    BEGIN {
      target = "## " heading
    }
    $0 == target {
      found = 1
      print
      print ""
      print note
      inserted = 1
      next
    }
    { print }
    END {
      if (!found) {
        print ""
        print target
        print ""
        print note
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

record_builder_failure_in_plan() {
  local plan_path="$1"
  local stage="$2"
  local failure_comment="$3"
  local abs_path timestamp progress_note ledger_note outcomes_note

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || return 0

  timestamp="$(date -u +"%Y-%m-%d %H:%MZ")"
  progress_note="- failure_record: ${timestamp}; builder exhausted three retries at ${stage}; summary=${failure_comment}"
  ledger_note="- builder_failure_record: stage=${stage}; status=failed_after_3_retries; recorded_at=${timestamp}; failure_summary=${failure_comment}"
  outcomes_note="- ${timestamp}: Builder exhausted three retries at ${stage}. The loop force-closed this take as failed. Summary: ${failure_comment}"

  append_note_to_markdown_section "$abs_path" "Progress" "$progress_note"
  append_note_to_markdown_section "$abs_path" "Hook Ledger" "$ledger_note"
  append_note_to_markdown_section "$abs_path" "Outcomes & Retrospective" "$outcomes_note"
}

force_close_failed_builder_plan_for_branch() {
  local branch="$1"
  local stage="$2"
  local failure_comment="$3"
  local active_plan_path active_abs completed_abs

  active_plan_path="$(plan_rel_path_for_branch "$branch")"
  active_abs="$(plan_abs_path "$WORKDIR" "$active_plan_path")"

  if [[ -f "$active_abs" ]]; then
    record_builder_failure_in_plan "$active_plan_path" "$stage" "$failure_comment"
    load_plan_runtime_metadata "$active_plan_path"
    completed_abs="$(completed_plan_abs_path_for_active_plan "$WORKDIR" "$active_abs")" || \
      die "failed to derive completed destination for failed builder plan: $active_plan_path"
    [[ ! -e "$completed_abs" ]] || die "completed destination already exists for failed builder plan: $completed_abs"
    mkdir -p "$(dirname "$completed_abs")"
    mv "$active_abs" "$completed_abs"
    CURRENT_PLAN_PATH="$(repo_rel_path "$WORKDIR" "$completed_abs")"
    auto_stage_commit_and_push "docs(plan): force-close failed builder take"
    load_completed_plan_runtime_metadata_for_branch "$branch"
    return 0
  fi

  load_completed_plan_runtime_metadata_for_branch "$branch"
}

latest_ledger_status_for_event() {
  local plan_path="$1"
  local event_id="$2"
  local abs_path

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || return 1

  awk -v target="$event_id" '
    /event_id=/ && /status=/ {
      event=""
      status=""
      n=split($0, parts, ";")
      for (i=1; i<=n; i++) {
        if (parts[i] ~ /event_id=/) {
          tmp=parts[i]
          gsub(/^.*event_id=/, "", tmp)
          gsub(/^ +| +$/, "", tmp)
          event=tmp
        }
        if (parts[i] ~ /status=/) {
          tmp=parts[i]
          gsub(/^.*status=/, "", tmp)
          gsub(/^ +| +$/, "", tmp)
          status=tmp
        }
      }
      if (event == target) {
        latest=status
      }
    }
    END {
      if (latest == "") {
        exit 1
      }
      print latest
    }
  ' "$abs_path"
}

plan_has_pass_for_event() {
  local plan_path="$1"
  local event_id="$2"
  local abs_path

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || return 1

  rg -q "event_id=${event_id};.*status=pass" "$abs_path"
}

ensure_plan_has_lifecycle_ready_pass() {
  local stage="$1"
  local plan_path="$2"

  [[ -n "$plan_path" ]] || die "lifecycle contract check requires a plan path"

  if plan_has_pass_for_event "$plan_path" "execplan.post-creation"; then
    return 0
  fi
  if plan_has_pass_for_event "$plan_path" "execplan.resume"; then
    return 0
  fi

  die "plan is missing pass evidence for execplan.post-creation or execplan.resume after ${stage}: ${plan_path}"
}

ensure_completed_plan_contract() {
  local stage="$1"

  [[ -n "$CURRENT_PLAN_PATH" ]] || die "completed plan contract check requires CURRENT_PLAN_PATH"

  ensure_plan_has_lifecycle_ready_pass "$stage" "$CURRENT_PLAN_PATH"
  if ! plan_has_pass_for_event "$CURRENT_PLAN_PATH" "execplan.post-completion"; then
    die "completed plan is missing pass evidence for execplan.post-completion after ${stage}: ${CURRENT_PLAN_PATH}"
  fi
}

plan_has_resume_record_for_commit() {
  local plan_path="$1"
  local commit="$2"
  local abs_path

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || return 1

  rg -q "^- resume_commit: ${commit}$" "$abs_path"
}

resume_gate_already_satisfied_for_current_head() {
  local plan_path="$1"
  local head_commit latest_resume_status

  head_commit="$(git rev-parse HEAD)"
  latest_resume_status="$(latest_ledger_status_for_event "$plan_path" "execplan.resume" || true)"

  [[ "$latest_resume_status" == "pass" ]] || return 1
  plan_has_resume_record_for_commit "$plan_path" "$head_commit"
}

ensure_resume_gate_for_current_head() {
  local plan_path="$1"

  if resume_gate_already_satisfied_for_current_head "$plan_path"; then
    log "execplan.resume already satisfied for current HEAD; skipping duplicate gate invocation"
    return 0
  fi

  "$SCRIPT_DIR/execplan_gate.sh" --plan "$plan_path" --event execplan.resume >/dev/null
}

load_plan_runtime_metadata() {
  local plan_path="$1"
  local abs_path plan_target_branch plan_pr_url plan_pr_title plan_branch_slug plan_take plan_body

  abs_path="$(plan_abs_path "$WORKDIR" "$plan_path")"
  [[ -f "$abs_path" ]] || die "plan file not found: $plan_path"

  CURRENT_PLAN_PATH="$(repo_rel_path "$WORKDIR" "$abs_path")"
  plan_target_branch="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_target_branch")")"
  plan_pr_url="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_pr_url")")"
  plan_pr_title="$(read_plan_scalar "$abs_path" "execplan_pr_title")"
  plan_branch_slug="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_branch_slug")")"
  plan_take="$(trim_line "$(read_plan_scalar "$abs_path" "execplan_take")")"
  plan_body="$(read_plan_block "$abs_path" "$EXECPLAN_PR_BODY_START" "$EXECPLAN_PR_BODY_END")"

  if [[ -n "$plan_target_branch" ]]; then
    if [[ -n "$TARGET_BASE_BRANCH" && "$plan_target_branch" != "$TARGET_BASE_BRANCH" ]]; then
      die "plan target branch ($plan_target_branch) does not match loop target branch ($TARGET_BASE_BRANCH): $CURRENT_PLAN_PATH"
    fi
    if [[ -z "$TARGET_BASE_BRANCH" ]]; then
      TARGET_BASE_BRANCH="$plan_target_branch"
    fi
  fi

  if [[ -n "$plan_pr_url" && -z "$PR_URL" ]]; then
    PR_URL="$(normalize_pr_url "$plan_pr_url")"
  fi
  if [[ -n "$plan_pr_title" && -z "$PR_TITLE" ]]; then
    PR_TITLE="$plan_pr_title"
  fi
  if [[ -n "$plan_body" && -z "$PR_BODY" ]]; then
    PR_BODY="$plan_body"
  fi
  if [[ -n "$plan_branch_slug" ]]; then
    CURRENT_BRANCH_SLUG="$plan_branch_slug"
  fi
  if is_positive_int "${plan_take:-0}"; then
    CURRENT_TAKE="$plan_take"
  fi

  if [[ -n "$PR_TITLE" ]]; then
    PR_TITLE_BASE="$(strip_take_suffix "$PR_TITLE")"
  fi
  if [[ -n "$PR_BODY" ]]; then
    PR_BODY_BASE="$(strip_revision_note_block "$PR_BODY")"
  fi
}

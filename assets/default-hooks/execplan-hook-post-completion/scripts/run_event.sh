#!/usr/bin/env bash
set -euo pipefail

PLAN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: run_event.sh --plan <plan_md>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PLAN" || ! -f "$PLAN" ]]; then
  echo "COMMANDS=none"
  echo "FAILURE_SUMMARY=plan file not found"
  echo "STATUS=fail"
  exit 1
fi

plan_is_abs=0
if [[ "$PLAN" == /* ]]; then
  plan_is_abs=1
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
ETERNAL_CYCLER_ROOT="${ETERNAL_CYCLER_ROOT:-}"
if [[ -z "$ETERNAL_CYCLER_ROOT" ]]; then
  echo "COMMANDS=none"
  echo "FAILURE_SUMMARY=ETERNAL_CYCLER_ROOT is not set; run through execplan_gate.sh"
  echo "STATUS=fail"
  exit 1
fi

# shellcheck source=/dev/null
source "$ETERNAL_CYCLER_ROOT/scripts/execplan_plan_metadata.sh"

commands=()
commands+=("rg -n execplan_start_branch|execplan_target_branch|execplan_pr_url|execplan_pr_title|execplan_branch_slug|execplan_take <plan>")

rollback_plan_path=""

emit_fail() {
  local summary="$1"
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=$summary"
  echo "STATUS=fail"
  if [[ -n "$rollback_plan_path" ]]; then
    echo "PLAN_PATH=$rollback_plan_path"
  fi
  exit 1
}

to_plan_style_path() {
  local rel="$1"
  if [[ "$plan_is_abs" -eq 1 ]]; then
    printf "%s/%s" "$REPO_ROOT" "$rel"
  else
    printf "%s" "$rel"
  fi
}

rollback_to_active() {
  local target_rel target_path

  if [[ "$PLAN" == eternal-cycler-out/plans/completed/* || "$PLAN" == */eternal-cycler-out/plans/completed/* ]]; then
    target_rel="eternal-cycler-out/plans/active/$(basename "$PLAN")"
    target_path="$(to_plan_style_path "$target_rel")"
    if [[ "$PLAN" != "$target_path" && -f "$PLAN" ]]; then
      mkdir -p "$(dirname "$target_path")"
      commands+=("rollback plan $PLAN -> $target_path")
      mv "$PLAN" "$target_path"
      PLAN="$target_path"
      rollback_plan_path="$target_path"
    fi
  fi
}

fail_validation() {
  local summary="$1"
  rollback_to_active
  emit_fail "$summary"
}

ledger_lines() {
  if rg -q "<!-- hook-ledger:start -->" "$PLAN"; then
    sed -n '/<!-- hook-ledger:start -->/,/<!-- hook-ledger:end -->/p' "$PLAN"
    return 0
  fi
  if rg -q "<!-- verification-ledger:start -->" "$PLAN"; then
    sed -n '/<!-- verification-ledger:start -->/,/<!-- verification-ledger:end -->/p' "$PLAN"
    return 0
  fi
  return 1
}

has_unresolved_latest_nonpass_event() {
  ledger_lines | awk '
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
      if (event != "") {
        latest[event]=status
      }
    }
    END {
      for (e in latest) {
        if (e == "execplan.pre_creation" || e == "execplan.post_creation" || \
            e == "execplan.resume" || e == "execplan.post_completion") {
          continue
        }
        if (latest[e] == "fail" || latest[e] == "escalated") {
          print e ":" latest[e]
          exit 0
        }
      }
      exit 1
    }
  '
}

if ! rg -q "event_id=execplan.post_creation;.*status=pass" "$PLAN" && \
   ! rg -q "event_id=execplan.resume;.*status=pass" "$PLAN"; then
  fail_validation "missing pass entry for execplan.post_creation or execplan.resume"
fi

if ! awk '
  /event_id=/ && /status=pass/ {
    event=""
    n=split($0, parts, ";")
    for (i=1; i<=n; i++) {
      if (parts[i] ~ /event_id=/) {
        gsub(/^.*event_id=/, "", parts[i])
        gsub(/^ +| +$/, "", parts[i])
        event=parts[i]
      }
    }
    if (event != "" && event != "execplan.pre_creation" && event != "execplan.post_creation" \
        && event != "execplan.resume" && event != "execplan.post_completion") {
      found=1
    }
  }
  END { exit(found?0:1) }
' "$PLAN"; then
  fail_validation "missing pass entry for non-lifecycle event"
fi

required_keys=(
  execplan_start_branch
  execplan_target_branch
  execplan_start_commit
  execplan_pr_url
  execplan_pr_title
  execplan_branch_slug
  execplan_take
)
for key in "${required_keys[@]}"; do
  if [[ -z "$(trim_line "$(read_plan_scalar "$PLAN" "$key")")" ]]; then
    fail_validation "missing required plan metadata: ${key}"
  fi
done

if ! rg -q -F "$EXECPLAN_PR_BODY_START" "$PLAN" || ! rg -q -F "$EXECPLAN_PR_BODY_END" "$PLAN"; then
  fail_validation "missing ExecPlan PR body block in plan"
fi

if rg -q "^- \[ \]" "$PLAN"; then
  fail_validation "plan still contains incomplete Progress actions"
fi

if unresolved_latest="$(has_unresolved_latest_nonpass_event)"; then
  fail_validation "latest hook event is unresolved: $unresolved_latest"
fi

commands+=("git status --short")
git status --short >/dev/null

if ! rg -q "<!-- execplan-start-untracked:start -->" "$PLAN"; then
  fail_validation "missing execplan start untracked snapshot in plan; run execplan.post_creation and retry"
fi
if ! rg -q "<!-- execplan-start-tracked:start -->" "$PLAN"; then
  fail_validation "missing execplan start tracked snapshot in plan; run execplan.post_creation and retry"
fi

echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
echo "FAILURE_SUMMARY=none"
echo "STATUS=pass"

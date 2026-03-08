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

emit_fail() {
  local summary="$1"
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=$summary"
  echo "STATUS=fail"
  exit 1
}

fail_validation() {
  local summary="$1"
  emit_fail "$summary"
}

ledger_lines() {
  if rg -q "<!-- hook-ledger:start -->" "$PLAN"; then
    sed -n '/<!-- hook-ledger:start -->/,/<!-- hook-ledger:end -->/p' "$PLAN"
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
        if (e == "execplan.post-completion") {
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

collect_user_feedback_ids() {
  local feedback_doc="$1"

  [[ -f "$feedback_doc" ]] || return 0
  sed -n "/${EXECPLAN_USER_FEEDBACK_START//\//\\/}/,/${EXECPLAN_USER_FEEDBACK_END//\//\\/}/p" "$feedback_doc" | awk '
    /^- feedback_item:/ {
      if (!match($0, /feedback_id=uf-[0-9]+/)) {
        print "__parse_error__"
        exit 0
      }
      id = substr($0, RSTART, RLENGTH)
      sub(/^feedback_id=/, "", id)
      print id
    }
  '
}

collect_builder_response_feedback_ids() {
  local response_doc="$1"

  [[ -f "$response_doc" ]] || return 0
  sed -n "/${EXECPLAN_BUILDER_RESPONSE_START//\//\\/}/,/${EXECPLAN_BUILDER_RESPONSE_END//\//\\/}/p" "$response_doc" | awk '
    /^- response_item:/ {
      status = ""
      feedback = ""
      n = split($0, parts, ";")
      for (i = 1; i <= n; i++) {
        part = parts[i]
        gsub(/^[[:space:]]*-[[:space:]]*response_item:[[:space:]]*/, "", part)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", part)
        if (part ~ /^status=(implemented|question|objection)$/) {
          status = part
          sub(/^status=/, "", status)
        } else if (part ~ /^feedback_id=uf-[0-9]+$/) {
          feedback = part
          sub(/^feedback_id=/, "", feedback)
        }
      }
      if (status == "" || feedback == "") {
        print "__parse_error__"
        exit 0
      }
      print feedback
    }
  '
}

plan_rel="$(repo_rel_path "$REPO_ROOT" "$PLAN")"
if [[ "$plan_rel" != eternal-cycler-out/plans/active/* ]]; then
  fail_validation "execplan.post-completion requires an active plan path; got ${plan_rel}"
fi

if ! rg -q "event_id=execplan.post-creation;.*status=pass" "$PLAN" && \
   ! rg -q "event_id=execplan.resume;.*status=pass" "$PLAN"; then
  fail_validation "missing pass entry for execplan.post-creation or execplan.resume"
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
  fail_validation "missing execplan start untracked snapshot in plan; run execplan.post-creation and retry"
fi
if ! rg -q "<!-- execplan-start-tracked:start -->" "$PLAN"; then
  fail_validation "missing execplan start tracked snapshot in plan; run execplan.post-creation and retry"
fi

user_feedback_rel="$(user_feedback_rel_path_for_plan "$PLAN")"
user_feedback_abs="$(plan_abs_path "$REPO_ROOT" "$user_feedback_rel")"
builder_response_rel="$(builder_response_rel_path_for_plan "$PLAN")"
builder_response_abs="$(plan_abs_path "$REPO_ROOT" "$builder_response_rel")"
if [[ -f "$user_feedback_abs" ]]; then
  declare -A feedback_ids=()
  declare -A responded_ids=()
  unanswered_ids=()

  while IFS= read -r feedback_id; do
    [[ -z "$feedback_id" ]] && continue
    if [[ "$feedback_id" == "__parse_error__" ]]; then
      fail_validation "malformed user feedback doc: ${user_feedback_rel}"
    fi
    feedback_ids["$feedback_id"]=1
  done < <(collect_user_feedback_ids "$user_feedback_abs")

  if [[ "${#feedback_ids[@]}" -gt 0 ]]; then
    [[ -f "$builder_response_abs" ]] || fail_validation "missing builder response doc for ${user_feedback_rel}"
    while IFS= read -r feedback_id; do
      [[ -z "$feedback_id" ]] && continue
      if [[ "$feedback_id" == "__parse_error__" ]]; then
        fail_validation "malformed builder response doc: ${builder_response_rel}"
      fi
      responded_ids["$feedback_id"]=1
    done < <(collect_builder_response_feedback_ids "$builder_response_abs")

    for feedback_id in "${!feedback_ids[@]}"; do
      if [[ -z "${responded_ids[$feedback_id]:-}" ]]; then
        unanswered_ids+=("$feedback_id")
      fi
    done
    if [[ "${#unanswered_ids[@]}" -gt 0 ]]; then
      fail_validation "unanswered user feedback remains in ${user_feedback_rel}: ${unanswered_ids[*]}"
    fi
  fi
fi

echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
echo "FAILURE_SUMMARY=none"
echo "STATUS=pass"

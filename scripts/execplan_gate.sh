#!/usr/bin/env bash
set -euo pipefail

MAX_ATTEMPTS=3
PRE_CREATION_EVENT_ID="execplan.pre-creation"
POST_CREATION_EVENT_ID="execplan.post-creation"
RESUME_EVENT_ID="execplan.resume"
POST_EVENT_ID="execplan.post-completion"

usage() {
  cat <<'USAGE'
Usage:
  execplan_gate.sh --event <event_id> [--plan <plan_md>] [--attempt <n>]

Notes:
  --plan is not accepted by execplan.pre-creation (no plan file exists yet).
  All other events require --plan.
USAGE
}

is_lifecycle_event() {
  local e="$1"
  [[ "$e" == "$PRE_CREATION_EVENT_ID" || "$e" == "$POST_CREATION_EVENT_ID" \
    || "$e" == "$RESUME_EVENT_ID" || "$e" == "$POST_EVENT_ID" ]]
}

PLAN=""
EVENT=""
ATTEMPT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN="${2:-}"
      shift 2
      ;;
    --event)
      EVENT="${2:-}"
      shift 2
      ;;
    --attempt)
      ATTEMPT_OVERRIDE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$EVENT" ]]; then
  usage >&2
  exit 2
fi

if [[ "$EVENT" != "$PRE_CREATION_EVENT_ID" && -z "$PLAN" ]]; then
  echo "--plan is required for event: $EVENT" >&2
  usage >&2
  exit 2
fi

if [[ "$EVENT" == "$PRE_CREATION_EVENT_ID" && -n "$PLAN" ]]; then
  echo "--plan is not accepted for event: $EVENT (plan file does not exist yet)" >&2
  usage >&2
  exit 2
fi

if [[ -n "$PLAN" && ! -f "$PLAN" ]]; then
  echo "Plan file not found: $PLAN" >&2
  exit 1
fi

HAS_PLAN_FILE=0
if [[ -n "$PLAN" && -f "$PLAN" ]]; then
  HAS_PLAN_FILE=1
fi

# SUBMODULE_ROOT: root of this eternal-cycler installation (where scripts/, assets/ etc. live).
# Resolved from the script's own location so it works correctly whether eternal-cycler is used
# as a git subtree, a plain copy, or called directly from its own checkout.
SUBMODULE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# REPO_ROOT: root of the consuming git repository (may equal SUBMODULE_ROOT when eternal-cycler
# is checked out directly; differs when installed as a subtree under a consuming repo).
REPO_ROOT="$(git -C "$SUBMODULE_ROOT" rev-parse --show-toplevel)"

# Export so event scripts can locate both roots without recomputing them.
export ETERNAL_CYCLER_ROOT="$SUBMODULE_ROOT"
export REPO_ROOT

# shellcheck source=/dev/null
source "$SUBMODULE_ROOT/scripts/execplan_plan_metadata.sh"

# Hook directories are read from the consuming repo's .agents/skills/ directory.
# Default hooks are copied there by setup.sh. Supported event namespaces are:
#   execplan.<lifecycle-name> -> .agents/skills/execplan-hook-<lifecycle-name>/
#   hook.<hook-name>          -> .agents/skills/execplan-hook-<hook-name>/
event_to_hook_suffix() {
  local event_id="$1"
  local suffix

  case "$event_id" in
    execplan.*)
      suffix="${event_id#execplan.}"
      if [[ "$suffix" == *_* ]]; then
        echo "Underscore event IDs are not supported; use dash-form event IDs instead: $event_id" >&2
        return 1
      fi
      ;;
    hook.*)
      suffix="${event_id#hook.}"
      if [[ "$suffix" == *_* ]]; then
        echo "Underscore event IDs are not supported; use dash-form event IDs instead: $event_id" >&2
        return 1
      fi
      ;;
    action.*)
      echo "Legacy action.* event IDs are not supported: $event_id (use hook.${event_id#action.})" >&2
      return 1
      ;;
    *)
      echo "Unsupported event namespace: $event_id (expected execplan.* or hook.*)" >&2
      return 1
      ;;
  esac

  suffix="${suffix//./-}"
  [[ -n "$suffix" ]] || return 1
  printf '%s\n' "$suffix"
}

event_to_hook_dir() {
  local event_id="$1"
  local suffix

  suffix="$(event_to_hook_suffix "$event_id")" || return 1
  printf 'execplan-hook-%s\n' "$suffix"
}

is_registered_event() {
  local event_id="$1"
  resolve_event_script "$event_id" >/dev/null 2>&1
}

require_mandatory_lifecycle_events() {
  local required hook_dir
  for required in "$PRE_CREATION_EVENT_ID" "$POST_CREATION_EVENT_ID" "$RESUME_EVENT_ID" "$POST_EVENT_ID"; do
    if ! is_registered_event "$required"; then
      hook_dir="$(event_to_hook_dir "$required" 2>/dev/null || echo "(invalid-event-id)")"
      echo "Mandatory lifecycle hook missing or not executable for ${required}: $REPO_ROOT/.agents/skills/${hook_dir}/scripts/run_event.sh" >&2
      exit 1
    fi
  done
}

resolve_event_script() {
  local event_id="$1"
  local hook_dir script_abs

  hook_dir="$(event_to_hook_dir "$event_id")" || {
    echo "Unsupported event id format: $event_id" >&2
    return 1
  }
  script_abs="$REPO_ROOT/.agents/skills/$hook_dir/scripts/run_event.sh"

  if [[ ! -x "$script_abs" ]]; then
    echo "Hook script is missing or not executable: $script_abs" >&2
    return 1
  fi

  echo "$script_abs"
}

force_close_failed_plan_if_needed() {
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 0
  fi

  local abs_path rel_path destination

  abs_path="$(plan_abs_path "$REPO_ROOT" "$PLAN")"
  [[ -f "$abs_path" ]] || return 0

  rel_path="$(repo_rel_path "$REPO_ROOT" "$abs_path")"
  if [[ "$rel_path" == eternal-cycler-out/plans/completed/* ]]; then
    PLAN="$rel_path"
    return 0
  fi

  if [[ "$rel_path" != eternal-cycler-out/plans/active/* ]]; then
    return 0
  fi

  destination="$(completed_plan_abs_path_for_active_plan "$REPO_ROOT" "$abs_path")" || return 0
  if [[ -e "$destination" ]]; then
    echo "Failed to force-close active plan; completed destination already exists: $destination" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$destination")"
  mv "$abs_path" "$destination"
  PLAN="$(repo_rel_path "$REPO_ROOT" "$destination")"
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

record_escalation_in_plan() {
  if [[ "$HAS_PLAN_FILE" -ne 1 || "$FINAL_STATUS" != "escalated" ]]; then
    return 0
  fi

  local abs_path timestamp progress_note outcomes_note

  abs_path="$(plan_abs_path "$REPO_ROOT" "$PLAN")"
  [[ -f "$abs_path" ]] || return 0

  timestamp="$(date -u +"%Y-%m-%d %H:%MZ")"
  progress_note="- escalation_record: ${timestamp}; event=${EVENT}; attempt=${ATTEMPT}; summary=${FAILURE_SUMMARY}"
  outcomes_note="- ${timestamp}: Event ${EVENT} escalated at attempt ${ATTEMPT}. Summary: ${FAILURE_SUMMARY}"

  append_note_to_markdown_section "$abs_path" "Progress" "$progress_note"
  append_note_to_markdown_section "$abs_path" "Outcomes & Retrospective" "$outcomes_note"
}

move_active_plan_to_completed_on_pass() {
  if [[ "$HAS_PLAN_FILE" -ne 1 || "$EVENT" != "$POST_EVENT_ID" || "$FINAL_STATUS" != "pass" ]]; then
    return 0
  fi

  local abs_path rel_path destination

  abs_path="$(plan_abs_path "$REPO_ROOT" "$PLAN")"
  [[ -f "$abs_path" ]] || return 0

  rel_path="$(repo_rel_path "$REPO_ROOT" "$abs_path")"
  if [[ "$rel_path" == eternal-cycler-out/plans/completed/* ]]; then
    PLAN="$rel_path"
    return 0
  fi

  if [[ "$rel_path" != eternal-cycler-out/plans/active/* ]]; then
    echo "execplan.post-completion requires an active plan path, got: $rel_path" >&2
    exit 1
  fi

  destination="$(completed_plan_abs_path_for_active_plan "$REPO_ROOT" "$abs_path")" || {
    echo "failed to derive completed destination for active plan: $rel_path" >&2
    exit 1
  }
  if [[ -e "$destination" ]]; then
    echo "completed destination already exists for execplan.post-completion: $destination" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  mv "$abs_path" "$destination"
  PLAN="$(repo_rel_path "$REPO_ROOT" "$destination")"
}

sanitize() {
  echo "$1" | tr '\n' ' ' | sed -E 's/[;]+/,/g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}

LEDGER_HEADING="## Hook Ledger"
LEDGER_START_MARKER="<!-- hook-ledger:start -->"
LEDGER_END_MARKER="<!-- hook-ledger:end -->"

current_ledger_start_marker() {
  if rg -q "$LEDGER_START_MARKER" "$PLAN"; then
    printf '%s\n' "$LEDGER_START_MARKER"
    return 0
  fi
  return 1
}

current_ledger_end_marker() {
  if rg -q "$LEDGER_END_MARKER" "$PLAN"; then
    printf '%s\n' "$LEDGER_END_MARKER"
    return 0
  fi
  return 1
}

ensure_ledger_block() {
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 0
  fi
  if ! current_ledger_start_marker >/dev/null 2>&1; then
    {
      echo
      echo "$LEDGER_HEADING"
      echo
      echo "$LEDGER_START_MARKER"
      echo "$LEDGER_END_MARKER"
    } >> "$PLAN"
  fi
}

ledger_lines() {
  local start_marker end_marker
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 0
  fi
  start_marker="$(current_ledger_start_marker)" || return 0
  end_marker="$(current_ledger_end_marker)" || return 0
  sed -n "/${start_marker//\//\\/}/,/${end_marker//\//\\/}/p" "$PLAN"
}

count_attempts() {
  local event_id="$1"
  ledger_lines | awk -v target="$event_id" '
    /event_id=/ {
      n=split($0, parts, ";")
      for (i=1; i<=n; i++) {
        if (parts[i] ~ /event_id=/) {
          tmp=parts[i]
          gsub(/^.*event_id=/, "", tmp)
          gsub(/^ +| +$/, "", tmp)
          if (tmp == target) { count++ }
        }
      }
    }
    END { print count+0 }
  '
}

has_pass() {
  local event_id="$1"
  ledger_lines | awk -v target="$event_id" '
    /event_id=/ && /status=/ {
      event=""; status=""
      n=split($0, parts, ";")
      for (i=1; i<=n; i++) {
        if (parts[i] ~ /event_id=/) {
          tmp=parts[i]; gsub(/^.*event_id=/, "", tmp); gsub(/^ +| +$/, "", tmp); event=tmp
        }
        if (parts[i] ~ /status=/) {
          tmp=parts[i]; gsub(/^.*status=/, "", tmp); gsub(/^ +| +$/, "", tmp); status=tmp
        }
      }
      if (event == target && status == "pass") { found=1 }
    }
    END { exit(found ? 0 : 1) }
  '
}

validate_progress_hook_fields() {
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 1
  fi

  local issues
  issues="$(
    awk -v pre="$PRE_CREATION_EVENT_ID" \
        -v post_creation="$POST_CREATION_EVENT_ID" \
        -v resume="$RESUME_EVENT_ID" \
        -v post="$POST_EVENT_ID" '
      function trim(s) {
        gsub(/^[[:space:]]+/, "", s)
        gsub(/[[:space:]]+$/, "", s)
        return s
      }
      function add_issue(msg) {
        if (!(msg in seen)) {
          seen[msg]=1
          issues[++issue_count]=msg
        }
      }
      /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ {
        if (index($0, "verify_events=") > 0) {
          add_issue("verify_events is not supported")
        }
        if (index($0, "hook_events=") == 0) {
          next
        }
        n=split($0, parts, ";")
        for (i=1; i<=n; i++) {
          if (parts[i] !~ /hook_events=/) {
            continue
          }
          field=parts[i]
          gsub(/^.*hook_events=/, "", field)
          field=trim(field)
          event_count=split(field, events, ",")
          for (j=1; j<=event_count; j++) {
            ev=trim(events[j])
            if (ev == "" || ev == "none" || ev == "-") {
              continue
            }
            if (ev ~ /_/) {
              add_issue("hook_events must use dash-form event IDs: " ev)
              continue
            }
            if (ev !~ /^hook\./) {
              if (ev == pre || ev == post_creation || ev == resume || ev == post) {
                add_issue("hook_events must not contain lifecycle event: " ev)
              } else {
                add_issue("hook_events must contain only hook.* values: " ev)
              }
            }
          }
        }
      }
      END {
        if (issue_count == 0) {
          exit 1
        }
        for (i=1; i<=issue_count; i++) {
          print issues[i]
        }
      }
    ' "$PLAN"
  )" || true

  if [[ -z "$issues" ]]; then
    return 1
  fi

  printf '%s\n' "$issues" | paste -sd '|' - | sed 's/|/; /g'
  return 0
}

find_incomplete_hook_event_actions() {
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 1
  fi

  local issues
  issues="$(
    awk '
      function trim(s) {
        gsub(/^[[:space:]]+/, "", s)
        gsub(/[[:space:]]+$/, "", s)
        return s
      }
      /^[[:space:]]*-[[:space:]]*\[[[:space:]]\]/ && /hook_events=/ {
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]*/, "", line)
        n=split(line, parts, ";")
        for (i=1; i<=n; i++) {
          if (parts[i] ~ /hook_events=/) {
            field=parts[i]
            gsub(/^.*hook_events=/, "", field)
            field=trim(field)
            if (field != "" && field != "none" && field != "-") {
              print NR ":" trim(line)
              break
            }
          }
        }
      }
    ' "$PLAN"
  )"

  [[ -n "$issues" ]] || return 1
  printf '%s\n' "$issues" | paste -sd '|' - | sed 's/|/; /g'
  return 0
}

find_unresolved_nonpass_event() {
  local current_event="$1"
  ledger_lines | awk -v current="$current_event" '
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
        latest_status[event]=status
      }
    }
    END {
      for (e in latest_status) {
        if (e == current) {
          continue
        }
        if (latest_status[e] == "fail" || latest_status[e] == "escalated") {
          print e ":" latest_status[e]
          exit 0
        }
      }
      exit 1
    }
  '
}

missing_required_hook_event_passes() {
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 1
  fi
  local required_events event
  required_events="$(
    awk '
      /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ && /hook_events=/ {
        n=split($0, parts, ";")
        for (i=1; i<=n; i++) {
          if (parts[i] ~ /hook_events=/) {
            field=parts[i]
            gsub(/^.*hook_events=/, "", field)
            gsub(/^ +| +$/, "", field)
            split(field, events, ",")
            for (j in events) {
              ev=events[j]
              gsub(/^ +| +$/, "", ev)
              if (ev != "" && ev != "none" && ev != "-") {
                required[ev]=1
              }
            }
          }
        }
      }
      END {
        for (ev in required) {
          print ev
        }
      }
    ' "$PLAN" | sort
  )"

  if [[ -z "$required_events" ]]; then
    return 1
  fi

  local missing=()
  while IFS= read -r event; do
    [[ -z "$event" ]] && continue
    if ! has_pass "$event"; then
      missing+=("$event")
    fi
  done <<< "$required_events"

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}" | sort | paste -sd ',' -
    return 0
  fi

  return 1
}

append_ledger_entry() {
  if [[ "$HAS_PLAN_FILE" -ne 1 ]]; then
    return 0
  fi
  local entry="$1"
  local tmp
  local end_marker
  tmp="$(mktemp)"
  end_marker="$(current_ledger_end_marker || true)"

  if [[ -z "$end_marker" ]]; then
    end_marker="$LEDGER_END_MARKER"
  fi

  awk -v entry="$entry" -v end_marker="$end_marker" -v ledger_heading="$LEDGER_HEADING" \
      -v ledger_start="$LEDGER_START_MARKER" -v ledger_end="$LEDGER_END_MARKER" '
    index($0, end_marker) && !inserted {
      print entry
      inserted=1
    }
    { print }
    END {
      if (!inserted) {
        print ledger_heading
        print ""
        print ledger_start
        print entry
        print ledger_end
      }
    }
  ' "$PLAN" > "$tmp"

  mv "$tmp" "$PLAN"
}

require_mandatory_lifecycle_events
if ! is_registered_event "$EVENT"; then
  expected_hook_dir="$(event_to_hook_dir "$EVENT" 2>&1)" || {
    echo "$expected_hook_dir" >&2
    exit 2
  }
  if [[ "$EVENT" == action.* ]]; then
    echo "Legacy action.* event IDs are not supported: $EVENT (use hook.${EVENT#action.})" >&2
    exit 2
  fi
  echo "Unsupported event or missing hook: $EVENT (expected .agents/skills/${expected_hook_dir}/scripts/run_event.sh)" >&2
  exit 2
fi

EVENT_SCRIPT="$(resolve_event_script "$EVENT")"

ensure_ledger_block

existing_attempts="$(count_attempts "$EVENT")"
if [[ -n "$ATTEMPT_OVERRIDE" ]]; then
  ATTEMPT="$ATTEMPT_OVERRIDE"
else
  ATTEMPT="$((existing_attempts + 1))"
fi

if ! [[ "$ATTEMPT" =~ ^[0-9]+$ ]] || [[ "$ATTEMPT" -lt 1 ]]; then
  echo "Invalid attempt value: $ATTEMPT" >&2
  exit 2
fi

STARTED_AT="$(date -u +"%Y-%m-%d %H:%MZ")"
FINAL_STATUS=""
COMMANDS=""
FAILURE_SUMMARY=""
NOTIFY_REFERENCE="not_requested"

if [[ -z "$FINAL_STATUS" ]]; then
  if invalid_hook_fields="$(validate_progress_hook_fields)"; then
    FINAL_STATUS="fail"
    COMMANDS="gate prerequisite: Progress hook field validation"
    FAILURE_SUMMARY="$invalid_hook_fields"
  fi
fi

if [[ -z "$FINAL_STATUS" ]]; then
  if unresolved="$(find_unresolved_nonpass_event "$EVENT")"; then
    FINAL_STATUS="fail"
    COMMANDS="gate prerequisite: unresolved event status scan"
    FAILURE_SUMMARY="unresolved event status remains for ${unresolved}; resolve and re-run before advancing"
  fi
fi

if [[ -z "$FINAL_STATUS" ]] && ! is_lifecycle_event "$EVENT"; then
  if ! has_pass "$POST_CREATION_EVENT_ID" && ! has_pass "$RESUME_EVENT_ID"; then
    FINAL_STATUS="fail"
    COMMANDS="gate prerequisite: require ${POST_CREATION_EVENT_ID} or ${RESUME_EVENT_ID} pass"
    FAILURE_SUMMARY="missing pass evidence for ${POST_CREATION_EVENT_ID} or ${RESUME_EVENT_ID}"
  fi
fi

if [[ -z "$FINAL_STATUS" && "$EVENT" == "$POST_EVENT_ID" ]]; then
  if ! has_pass "$POST_CREATION_EVENT_ID" && ! has_pass "$RESUME_EVENT_ID"; then
    FINAL_STATUS="fail"
    COMMANDS="gate prerequisite: require ${POST_CREATION_EVENT_ID} or ${RESUME_EVENT_ID} pass"
    FAILURE_SUMMARY="missing pass evidence for ${POST_CREATION_EVENT_ID} or ${RESUME_EVENT_ID}"
  fi
fi

if [[ -z "$FINAL_STATUS" && "$EVENT" == "$POST_EVENT_ID" ]]; then
  if incomplete_hook_actions="$(find_incomplete_hook_event_actions)"; then
    FINAL_STATUS="fail"
    COMMANDS="gate prerequisite: hook_events action completion scan"
    FAILURE_SUMMARY="hook_events actions must be checked off before ${POST_EVENT_ID}: ${incomplete_hook_actions}"
  fi
fi

if [[ -z "$FINAL_STATUS" && "$EVENT" == "$POST_EVENT_ID" ]]; then
  if missing_events="$(missing_required_hook_event_passes)"; then
    FINAL_STATUS="fail"
    COMMANDS="gate prerequisite: required hook_events pass coverage scan"
    FAILURE_SUMMARY="missing pass entries for required hook_events: ${missing_events}"
  fi
fi

if [[ -z "$FINAL_STATUS" ]]; then
  if [[ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]]; then
    FINAL_STATUS="escalated"
    COMMANDS="gate retry bound pre-check"
    FAILURE_SUMMARY="retry bound exceeded before execution (attempt=${ATTEMPT})"
  fi
fi

if [[ -z "$FINAL_STATUS" ]]; then
  set +e
  if [[ -n "$PLAN" ]]; then
    EVENT_OUTPUT="$($EVENT_SCRIPT --plan "$PLAN" 2>&1)"
  else
    EVENT_OUTPUT="$($EVENT_SCRIPT 2>&1)"
  fi
  EVENT_RC=$?
  set -e

  COMMANDS="$(echo "$EVENT_OUTPUT" | sed -n 's/^COMMANDS=//p' | tail -n1)"
  FAILURE_SUMMARY="$(echo "$EVENT_OUTPUT" | sed -n 's/^FAILURE_SUMMARY=//p' | tail -n1)"
  RUN_STATUS="$(echo "$EVENT_OUTPUT" | sed -n 's/^STATUS=//p' | tail -n1)"
  if [[ -z "$COMMANDS" ]]; then
    COMMANDS="hook runner ${EVENT}"
  fi

  if [[ $EVENT_RC -eq 0 && "$RUN_STATUS" == "pass" ]]; then
    FINAL_STATUS="pass"
    FAILURE_SUMMARY="none"
  else
    FINAL_STATUS="fail"
    if [[ -z "$FAILURE_SUMMARY" ]]; then
      FAILURE_SUMMARY="event runner failed"
    fi
    echo "$EVENT_OUTPUT" >&2
  fi
fi

if [[ "$FINAL_STATUS" == "fail" ]]; then
  if [[ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
    FINAL_STATUS="escalated"
    FAILURE_SUMMARY="$(sanitize "$FAILURE_SUMMARY ; retry bound exceeded (attempt=${ATTEMPT})")"
  fi
fi

if [[ -z "$FAILURE_SUMMARY" ]]; then
  FAILURE_SUMMARY="none"
fi

FINISHED_AT="$(date -u +"%Y-%m-%d %H:%MZ")"
ENTRY="- attempt_record: event_id=${EVENT}; attempt=${ATTEMPT}; status=${FINAL_STATUS}; started_at=${STARTED_AT}; finished_at=${FINISHED_AT}; commands=$(sanitize "$COMMANDS"); failure_summary=$(sanitize "$FAILURE_SUMMARY"); notify_reference=$(sanitize "$NOTIFY_REFERENCE");"
append_ledger_entry "$ENTRY"
move_active_plan_to_completed_on_pass

if [[ "$FINAL_STATUS" == "escalated" ]]; then
  record_escalation_in_plan
  force_close_failed_plan_if_needed
fi

echo "EVENT=$EVENT"
echo "ATTEMPT=$ATTEMPT"
echo "STATUS=$FINAL_STATUS"

if [[ "$FINAL_STATUS" == "pass" ]]; then
  exit 0
fi

exit 1

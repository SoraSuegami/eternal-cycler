#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/execplan_plan_metadata.sh"

usage() {
  cat <<'EOF'
Usage:
  execplan_user_feedback.sh submit --plan <plan_md> --item <english_text> [--item <english_text> ...]
  execplan_user_feedback.sh respond --plan <plan_md> --feedback-id <id> --status implemented|question|objection --message <english_text>
  execplan_user_feedback.sh status --plan <plan_md> [--format json]
EOF
}

die() {
  echo "execplan_user_feedback.sh: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

validate_live_feedback_plan() {
  local repo_root="$1"
  local plan="$2"
  local plan_abs plan_rel

  plan_abs="$(plan_abs_path "$repo_root" "$plan")"
  [[ -f "$plan_abs" ]] || die "plan file not found: $plan"
  plan_rel="$(repo_rel_path "$repo_root" "$plan_abs")"
  [[ "$plan_rel" == eternal-cycler-out/plans/active/*.md ]] || die "plan must be an active ExecPlan: $plan_rel"
}

normalize_message() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

current_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ensure_user_feedback_doc() {
  local path="$1"
  local plan_filename="$2"

  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    return 0
  fi

  cat > "$path" <<EOF
# ExecPlan User Feedback

plan_filename: ${plan_filename}

${EXECPLAN_USER_FEEDBACK_START}
${EXECPLAN_USER_FEEDBACK_END}
EOF
}

ensure_builder_response_doc() {
  local path="$1"
  local plan_filename="$2"

  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    return 0
  fi

  cat > "$path" <<EOF
# ExecPlan Builder Responses

plan_filename: ${plan_filename}

${EXECPLAN_BUILDER_RESPONSE_START}
${EXECPLAN_BUILDER_RESPONSE_END}
EOF
}

next_feedback_id() {
  local file="$1"
  awk '
    match($0, /feedback_id=uf-[0-9]+/) {
      id = substr($0, RSTART, RLENGTH)
      sub(/^feedback_id=uf-/, "", id)
      if ((id + 0) > max) {
        max = id + 0
      }
    }
    END {
      printf "uf-%03d\n", max + 1
    }
  ' "$file"
}

next_response_id() {
  local file="$1"
  awk '
    match($0, /response_id=br-[0-9]+/) {
      id = substr($0, RSTART, RLENGTH)
      sub(/^response_id=br-/, "", id)
      if ((id + 0) > max) {
        max = id + 0
      }
    }
    END {
      printf "br-%03d\n", max + 1
    }
  ' "$file"
}

append_user_feedback_item() {
  local file="$1"
  local message_en="$2"
  local feedback_id created_at block_content new_block

  feedback_id="$(next_feedback_id "$file")"
  created_at="$(current_timestamp)"
  block_content="$(read_plan_block "$file" "$EXECPLAN_USER_FEEDBACK_START" "$EXECPLAN_USER_FEEDBACK_END" || true)"
  new_block="$(trim_trailing_blank_lines "$block_content")"
  if [[ -n "$new_block" ]]; then
    new_block+=$'\n\n'
  fi
  new_block+="- feedback_item: feedback_id=${feedback_id}; created_at=${created_at}"$'\n'
  new_block+="  message_en: ${message_en}"

  replace_or_append_block \
    "$file" \
    "$EXECPLAN_USER_FEEDBACK_START" \
    "$EXECPLAN_USER_FEEDBACK_END" \
    "$(printf '%s\n%s\n%s\n' "$EXECPLAN_USER_FEEDBACK_START" "$new_block" "$EXECPLAN_USER_FEEDBACK_END")"

  printf '%s\n' "$feedback_id"
}

feedback_id_exists() {
  local file="$1"
  local feedback_id="$2"
  rg -q -F "feedback_id=${feedback_id}" "$file"
}

append_builder_response() {
  local file="$1"
  local feedback_id="$2"
  local status="$3"
  local message_en="$4"
  local response_id created_at block_content new_block

  response_id="$(next_response_id "$file")"
  created_at="$(current_timestamp)"
  block_content="$(read_plan_block "$file" "$EXECPLAN_BUILDER_RESPONSE_START" "$EXECPLAN_BUILDER_RESPONSE_END" || true)"
  new_block="$(trim_trailing_blank_lines "$block_content")"
  if [[ -n "$new_block" ]]; then
    new_block+=$'\n\n'
  fi
  new_block+="- response_item: response_id=${response_id}; feedback_id=${feedback_id}; status=${status}; created_at=${created_at}"$'\n'
  new_block+="  message_en: ${message_en}"

  replace_or_append_block \
    "$file" \
    "$EXECPLAN_BUILDER_RESPONSE_START" \
    "$EXECPLAN_BUILDER_RESPONSE_END" \
    "$(printf '%s\n%s\n%s\n' "$EXECPLAN_BUILDER_RESPONSE_START" "$new_block" "$EXECPLAN_BUILDER_RESPONSE_END")"

  printf '%s\n' "$response_id"
}

parse_user_feedback_tsv() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -n "/${EXECPLAN_USER_FEEDBACK_START//\//\\/}/,/${EXECPLAN_USER_FEEDBACK_END//\//\\/}/p" "$file" | awk '
    /^- feedback_item:/ {
      line = $0
      id = ""
      created = ""
      if (match(line, /feedback_id=uf-[0-9]+/)) {
        id = substr(line, RSTART, RLENGTH)
        sub(/^feedback_id=/, "", id)
      }
      if (match(line, /created_at=[^;]+$/)) {
        created = substr(line, RSTART, RLENGTH)
        sub(/^created_at=/, "", created)
      }
      if (getline > 0) {
        msg = $0
        sub(/^[[:space:]]*message_en:[[:space:]]*/, "", msg)
      } else {
        msg = ""
      }
      if (id != "") {
        printf "%s\t%s\t%s\n", id, created, msg
      }
    }
  '
}

parse_builder_response_tsv() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -n "/${EXECPLAN_BUILDER_RESPONSE_START//\//\\/}/,/${EXECPLAN_BUILDER_RESPONSE_END//\//\\/}/p" "$file" | awk '
    /^- response_item:/ {
      line = $0
      response = ""
      feedback = ""
      status = ""
      created = ""
      n = split(line, parts, ";")
      for (i = 1; i <= n; i++) {
        part = parts[i]
        gsub(/^[[:space:]]*-[[:space:]]*response_item:[[:space:]]*/, "", part)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", part)
        if (part ~ /^response_id=br-[0-9]+$/) {
          response = part
          sub(/^response_id=/, "", response)
        } else if (part ~ /^feedback_id=uf-[0-9]+$/) {
          feedback = part
          sub(/^feedback_id=/, "", feedback)
        } else if (part ~ /^status=(implemented|question|objection)$/) {
          status = part
          sub(/^status=/, "", status)
        } else if (part ~ /^created_at=/) {
          created = part
          sub(/^created_at=/, "", created)
        }
      }
      if (getline > 0) {
        msg = $0
        sub(/^[[:space:]]*message_en:[[:space:]]*/, "", msg)
      } else {
        msg = ""
      }
      if (response == "" || feedback == "" || status == "") {
        printf "__parse_error__\t__parse_error__\t__parse_error__\t__parse_error__\t__parse_error__\n"
        exit 0
      }
      if (response != "" && feedback != "") {
        printf "%s\t%s\t%s\t%s\t%s\n", response, feedback, status, created, msg
      }
    }
  '
}

tsv_to_items_json() {
  jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map({
        feedback_id: .[0],
        created_at: .[1],
        message_en: .[2]
      })
  '
}

tsv_to_responses_json() {
  jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map({
        response_id: .[0],
        feedback_id: .[1],
        status: .[2],
        created_at: .[3],
        message_en: .[4]
      })
  '
}

command_submit() {
  local repo_root="$1"
  local plan="$2"
  shift 2
  local items=("$@")
  local plan_filename user_feedback_rel user_feedback_abs item normalized created_ids=()

  [[ "${#items[@]}" -gt 0 ]] || die "submit requires at least one --item"
  validate_live_feedback_plan "$repo_root" "$plan"
  plan_filename="$(basename "$plan")"
  user_feedback_rel="$(user_feedback_rel_path_for_plan "$plan")"
  user_feedback_abs="$(plan_abs_path "$repo_root" "$user_feedback_rel")"
  ensure_user_feedback_doc "$user_feedback_abs" "$plan_filename"

  for item in "${items[@]}"; do
    normalized="$(normalize_message "$item")"
    [[ -n "$normalized" ]] || die "feedback item must not be empty"
    created_ids+=("$(append_user_feedback_item "$user_feedback_abs" "$normalized")")
  done

  jq -n \
    --arg feedback_doc "$user_feedback_rel" \
    --arg plan_filename "$plan_filename" \
    --argjson feedback_ids "$(printf '%s\n' "${created_ids[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
    '{feedback_doc: $feedback_doc, plan_filename: $plan_filename, feedback_ids: $feedback_ids}'
}

command_respond() {
  local repo_root="$1"
  local plan="$2"
  local feedback_id="$3"
  local status="$4"
  local message="$5"
  local plan_filename user_feedback_rel user_feedback_abs builder_response_rel builder_response_abs response_id normalized

  case "$status" in
    implemented|question|objection) ;;
    *)
      die "respond requires status implemented|question|objection"
      ;;
  esac

  validate_live_feedback_plan "$repo_root" "$plan"
  normalized="$(normalize_message "$message")"
  [[ -n "$normalized" ]] || die "response message must not be empty"
  plan_filename="$(basename "$plan")"
  user_feedback_rel="$(user_feedback_rel_path_for_plan "$plan")"
  user_feedback_abs="$(plan_abs_path "$repo_root" "$user_feedback_rel")"
  [[ -f "$user_feedback_abs" ]] || die "user feedback doc not found: $user_feedback_rel"
  feedback_id_exists "$user_feedback_abs" "$feedback_id" || die "feedback_id not found in user feedback doc: $feedback_id"

  builder_response_rel="$(builder_response_rel_path_for_plan "$plan")"
  builder_response_abs="$(plan_abs_path "$repo_root" "$builder_response_rel")"
  ensure_builder_response_doc "$builder_response_abs" "$plan_filename"
  response_id="$(append_builder_response "$builder_response_abs" "$feedback_id" "$status" "$normalized")"

  jq -n \
    --arg response_doc "$builder_response_rel" \
    --arg response_id "$response_id" \
    --arg feedback_id "$feedback_id" \
    --arg status "$status" \
    '{response_doc: $response_doc, response_id: $response_id, feedback_id: $feedback_id, status: $status}'
}

command_status() {
  local repo_root="$1"
  local plan="$2"
  local plan_filename user_feedback_rel builder_response_rel user_feedback_abs builder_response_abs items_json responses_json

  validate_live_feedback_plan "$repo_root" "$plan"
  plan_filename="$(basename "$plan")"
  user_feedback_rel="$(user_feedback_rel_path_for_plan "$plan")"
  builder_response_rel="$(builder_response_rel_path_for_plan "$plan")"
  user_feedback_abs="$(plan_abs_path "$repo_root" "$user_feedback_rel")"
  builder_response_abs="$(plan_abs_path "$repo_root" "$builder_response_rel")"

  items_json="$(parse_user_feedback_tsv "$user_feedback_abs" | tsv_to_items_json)"
  responses_json="$(parse_builder_response_tsv "$builder_response_abs" | tsv_to_responses_json)"

  if jq -e '.[] | select(.response_id == "__parse_error__")' >/dev/null 2>&1 <<< "$responses_json"; then
    die "malformed builder response doc: $builder_response_rel"
  fi

  jq -n \
    --arg plan_filename "$plan_filename" \
    --arg feedback_doc "$user_feedback_rel" \
    --arg response_doc "$builder_response_rel" \
    --argjson items "$items_json" \
    --argjson responses "$responses_json" '
    {
      plan_filename: $plan_filename,
      feedback_doc: $feedback_doc,
      response_doc: $response_doc,
      items: $items,
      responses: $responses,
      unanswered_feedback_ids: (
        ($items | map(.feedback_id))
        -
        ($responses | map(.feedback_id) | unique)
      ),
      question_or_objection_responses: (
        $responses | map(select(.status == "question" or .status == "objection"))
      )
    }'
}

main() {
  local command="${1:-}"
  local plan=""
  local format="json"
  local feedback_id=""
  local status=""
  local message=""
  local items=()

  [[ -n "$command" ]] || {
    usage >&2
    exit 2
  }
  shift || true

  case "$command" in
    submit)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --plan)
            plan="${2:-}"
            shift 2
            ;;
          --item)
            items+=("${2:-}")
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            die "unknown submit argument: $1"
            ;;
        esac
      done
      ;;
    respond)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --plan)
            plan="${2:-}"
            shift 2
            ;;
          --feedback-id)
            feedback_id="${2:-}"
            shift 2
            ;;
          --status)
            status="${2:-}"
            shift 2
            ;;
          --message)
            message="${2:-}"
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            die "unknown respond argument: $1"
            ;;
        esac
      done
      ;;
    status)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --plan)
            plan="${2:-}"
            shift 2
            ;;
          --format)
            format="${2:-}"
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            die "unknown status argument: $1"
            ;;
        esac
      done
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac

  [[ -n "$plan" ]] || die "--plan is required"
  if [[ "$format" != "json" ]]; then
    die "--format must be json"
  fi

  require_cmd jq
  local repo_root
  repo_root="$(resolve_repo_root)"

  case "$command" in
    submit)
      command_submit "$repo_root" "$plan" "${items[@]}"
      ;;
    respond)
      [[ -n "$feedback_id" ]] || die "--feedback-id is required"
      [[ -n "$status" ]] || die "--status is required"
      [[ -n "$message" ]] || die "--message is required"
      command_respond "$repo_root" "$plan" "$feedback_id" "$status" "$message"
      ;;
    status)
      command_status "$repo_root" "$plan"
      ;;
  esac
}

main "$@"

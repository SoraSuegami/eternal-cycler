#!/usr/bin/env bash

usage() {
  cat <<'USAGE'
Usage:
  run_builder_reviewer_loop.sh [--task <text> | --task-file <path>] [options]

Options:
  --task <text>                      Optional builder task text.
  --task-file <path>                 Optional builder task file path.
  --target-branch <branch>           Required for new takes; ignored for resume.
  --pr-title <text>                  Required for new takes only.
  --pr-body <markdown>               Required for new takes only.
  --resume-plan <path>               Canonical resume entrypoint for an active plan.
  --max-iterations <n>               Max review iterations (default: 20).
  --max-reviewer-failures <n>        Max consecutive reviewer-phase failures (default: 3).
  --builder-provider <provider>      Builder agent provider: codex or claude.
  --reviewer-provider <provider>     Reviewer agent provider: codex or claude.
  --model-builder <model>            Optional model for builder provider runs.
  --model-reviewer <model>           Optional model for reviewer provider runs.
  --help                             Show this help.
USAGE
}

log() {
  echo "[loop $(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

is_supported_provider() {
  [[ "$1" == "codex" || "$1" == "claude" ]]
}

validate_provider_or_die() {
  local provider="$1"
  local role="$2"
  is_supported_provider "$provider" || die "unsupported ${role} provider: ${provider} (expected codex or claude)"
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_current_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    return 1
  fi
  printf '%s\n' "$branch"
}

refresh_feedback_doc_paths() {
  [[ -n "${EXPECTED_PLAN_DOC_FILENAME:-}" ]] || die "cannot refresh feedback doc paths without EXPECTED_PLAN_DOC_FILENAME"
  USER_FEEDBACK_DOC="$(user_feedback_rel_path_for_plan "$EXPECTED_PLAN_DOC_FILENAME")"
  BUILDER_RESPONSE_DOC="$(builder_response_rel_path_for_plan "$EXPECTED_PLAN_DOC_FILENAME")"
}

normalize_pr_url() {
  local pr_url="$1"
  printf '%s\n' "$pr_url" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s:/+$::'
}

parse_reviewer_payload_json() {
  local raw="$1"
  jq -e -c '
    if type != "object" then
      error("reviewer output must be a JSON object")
    else
      .
    end
    | if (.pr_url | type) != "string" then error("pr_url must be string") else . end
    | if (.comment_body | type) != "string" then error("comment_body must be string") else . end
    | .pr_url |= (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | if (.pr_url | length) == 0 then error("pr_url must be non-empty") else . end
    | if (.comment_body | length) == 0 then error("comment_body must be non-empty") else . end
    | if (.approve_merge | type) != "boolean" then error("approve_merge must be boolean") else . end
    | {pr_url, comment_body, approve_merge}
  ' <<< "$raw" 2>/dev/null
}

parse_builder_payload_json() {
  local raw="$1"
  jq -e -c '
    if type != "object" then
      error("builder output must be a JSON object")
    else
      .
    end
    | if (.result | type) != "string" then error("result must be string") else . end
    | if (.comment | type) != "string" then error("comment must be string") else . end
    | .comment |= (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | if (.comment | length) == 0 then error("comment must be non-empty") else . end
    | if (.result != "success" and .result != "failed_after_3_retries") then
        error("result must be success or failed_after_3_retries")
      else
        .
      end
    | {result, comment}
  ' <<< "$raw" 2>/dev/null
}

write_reviewer_output_schema() {
  local schema_file
  schema_file="$(mktemp)"
  cat > "$schema_file" <<'EOF_SCHEMA'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["pr_url", "comment_body", "approve_merge"],
  "properties": {
    "pr_url": {
      "type": "string",
      "minLength": 1
    },
    "comment_body": {
      "type": "string",
      "minLength": 1
    },
    "approve_merge": {
      "type": "boolean"
    }
  }
}
EOF_SCHEMA
  printf '%s\n' "$schema_file"
}

write_builder_output_schema() {
  local schema_file
  schema_file="$(mktemp)"
  cat > "$schema_file" <<'EOF_SCHEMA'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["result", "comment"],
  "properties": {
    "result": {
      "type": "string",
      "enum": ["success", "failed_after_3_retries"]
    },
    "comment": {
      "type": "string",
      "minLength": 1
    }
  }
}
EOF_SCHEMA
  printf '%s\n' "$schema_file"
}

extract_claude_message_text() {
  local raw="$1"
  jq -e -r '
    def textify:
      if type == "string" then .
      elif type == "array" then [ .[]? | textify ] | join("")
      elif type == "object" then
        if (.result? | type) == "string" then .result
        elif (.text? | type) == "string" then .text
        elif has("message") then .message | textify
        elif has("content") then .content | textify
        elif has("messages") then ([ .messages[]? | select((.role? // .type? // "") == "assistant") | textify ][-1]? // "")
        else ""
        end
      else ""
      end;
    textify
  ' <<< "$raw" 2>/dev/null
}

run_codex_prompt_capture() {
  local role="$1"
  local model="$2"
  local prompt_text="$3"
  local schema_file="${4:-}"
  local rc last_message_file

  local cmd=(codex exec --dangerously-bypass-approvals-and-sandbox --cd "$WORKDIR")
  if [[ -n "$model" ]]; then
    cmd+=(--model "$model")
  fi
  if [[ -n "$schema_file" ]]; then
    last_message_file="$(mktemp)"
    cmd+=(--output-schema "$schema_file" --output-last-message "$last_message_file")
  fi
  cmd+=(-)

  set +e
  printf '%s\n' "$prompt_text" | "${cmd[@]}"
  rc=$?
  set -e

  LAST_AGENT_OUTPUT=""
  if [[ -n "$schema_file" ]]; then
    LAST_AGENT_OUTPUT="$(cat "$last_message_file" 2>/dev/null || true)"
    rm -f "$last_message_file"
  fi

  if [[ "$rc" -ne 0 ]]; then
    log "$role codex execution failed"
    return 1
  fi

  if [[ -n "$schema_file" && -z "$(printf '%s' "$LAST_AGENT_OUTPUT" | tr -d '[:space:]')" ]]; then
    log "$role codex execution produced empty structured output"
    return 1
  fi

  return 0
}

run_claude_prompt_capture() {
  local role="$1"
  local model="$2"
  local prompt_text="$3"
  local schema_file="${4:-}"
  local rc schema_json stdout_file stderr_file raw_output stderr_output
  local cmd=(claude -p --cwd "$WORKDIR" --output-format json --permission-mode bypassPermissions)

  if [[ -n "$model" ]]; then
    cmd+=(--model "$model")
  fi
  if [[ -n "$schema_file" ]]; then
    schema_json="$(jq -c . "$schema_file" 2>/dev/null)" || die "failed to compact Claude JSON schema from ${schema_file}"
    cmd+=(--json-schema "$schema_json")
  fi

  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  set +e
  "${cmd[@]}" "$prompt_text" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  LAST_AGENT_OUTPUT=""
  raw_output="$(cat "$stdout_file" 2>/dev/null || true)"
  stderr_output="$(cat "$stderr_file" 2>/dev/null || true)"
  rm -f "$stdout_file" "$stderr_file"

  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$(printf '%s' "$stderr_output" | tr -d '[:space:]')" ]]; then
      log "$role claude execution failed: $(printf '%s\n' "$stderr_output" | head -n1 | sed -E 's/[[:space:]]+/ /g')"
    else
      log "$role claude execution failed"
    fi
    return 1
  fi

  if [[ -n "$schema_file" ]]; then
    LAST_AGENT_OUTPUT="$(extract_claude_message_text "$raw_output" || true)"
    if [[ -z "$(printf '%s' "$LAST_AGENT_OUTPUT" | tr -d '[:space:]')" ]]; then
      log "$role claude execution produced empty structured output"
      return 1
    fi
  else
    LAST_AGENT_OUTPUT="$raw_output"
  fi

  return 0
}

run_agent_prompt_capture() {
  local role="$1"
  local provider="$2"
  local model="$3"
  local prompt_text="$4"
  local schema_file="${5:-}"

  case "$provider" in
    codex)
      run_codex_prompt_capture "$role" "$model" "$prompt_text" "$schema_file"
      ;;
    claude)
      run_claude_prompt_capture "$role" "$model" "$prompt_text" "$schema_file"
      ;;
    *)
      die "unsupported ${role} provider: ${provider}"
      ;;
  esac
}

post_pr_comment() {
  local pr_url="$1"
  local comment_body="$2"
  local output rc

  set +e
  output="$(gh pr comment "$pr_url" --body "$comment_body" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    log "failed to post PR comment for $pr_url: $output"
    return 1
  fi

  printf '%s\n' "$output"
  return 0
}

push_branch() {
  local branch="$1"
  git push -u origin "$branch" >/dev/null 2>&1 || die "failed to push branch to origin/$branch"
}

run_command_or_die() {
  local failure_message="$1"
  shift
  local output rc

  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    die "${failure_message}: ${output}"
  fi
}

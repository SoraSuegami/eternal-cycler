#!/usr/bin/env bash

EXECPLAN_METADATA_START="<!-- execplan-metadata:start -->"
EXECPLAN_METADATA_END="<!-- execplan-metadata:end -->"
EXECPLAN_PR_BODY_START="<!-- execplan-pr-body:start -->"
EXECPLAN_PR_BODY_END="<!-- execplan-pr-body:end -->"
EXECPLAN_BUILDER_STATUS_START="<!-- execplan-builder-status:start -->"
EXECPLAN_BUILDER_STATUS_END="<!-- execplan-builder-status:end -->"
EXECPLAN_BUILDER_COMMENT_START="<!-- execplan-builder-comment:start -->"
EXECPLAN_BUILDER_COMMENT_END="<!-- execplan-builder-comment:end -->"
EXECPLAN_REVISION_NOTE_START="<!-- execplan-revision-note:start -->"
EXECPLAN_REVISION_NOTE_END="<!-- execplan-revision-note:end -->"

repo_rel_path() {
  local repo_root="$1"
  local path="$2"

  if [[ "$path" == "$repo_root/"* ]]; then
    printf '%s\n' "${path#"$repo_root/"}"
    return 0
  fi

  printf '%s\n' "$path"
}

plan_abs_path() {
  local repo_root="$1"
  local path="$2"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  printf '%s/%s\n' "$repo_root" "$path"
}

plan_rel_path_for_branch() {
  local branch="$1"
  printf 'eternal-cycler-out/plans/active/%s.md\n' "$branch"
}

plan_abs_path_for_branch() {
  local repo_root="$1"
  local branch="$2"
  plan_abs_path "$repo_root" "$(plan_rel_path_for_branch "$branch")"
}

trim_line() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

read_plan_scalar() {
  local plan="$1"
  local key="$2"

  awk -v key="$key" '
    $0 ~ ("^[[:space:]-]*" key ":[[:space:]]*") {
      line = $0
      sub("^[[:space:]-]*" key ":[[:space:]]*", "", line)
      print line
      exit
    }
  ' "$plan" | sed -E 's/[[:space:]]+$//'
}

read_plan_block() {
  local plan="$1"
  local start_marker="$2"
  local end_marker="$3"

  sed -n "/${start_marker//\//\\/}/,/${end_marker//\//\\/}/p" "$plan" | sed '1d;$d'
}

replace_or_append_block() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local content="$4"
  local start_line end_line tmp

  start_line="$(rg -n -F "$start_marker" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  end_line="$(rg -n -F "$end_marker" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  tmp="$(mktemp)"

  if [[ -n "$start_line" && -n "$end_line" && "$end_line" -ge "$start_line" ]]; then
    if [[ "$start_line" -gt 1 ]]; then
      sed -n "1,$((start_line - 1))p" "$file" > "$tmp"
    fi
    printf '%s\n' "$content" >> "$tmp"
    sed -n "$((end_line + 1)),\$p" "$file" >> "$tmp"
  else
    cat "$file" > "$tmp"
    if [[ -s "$tmp" ]]; then
      printf '\n' >> "$tmp"
    fi
    printf '%s\n' "$content" >> "$tmp"
  fi

  mv "$tmp" "$file"
}

upsert_scalar_in_content() {
  local content="$1"
  local key="$2"
  local value="$3"

  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ ("^[[:space:]-]*" key ":[[:space:]]*") {
      if (!updated) {
        print "- " key ": " value
        updated = 1
      }
      next
    }
    { print }
    END {
      if (!updated) {
        print "- " key ": " value
      }
    }
  ' <<< "$content"
}

update_plan_metadata_scalar() {
  local plan="$1"
  local key="$2"
  local value="$3"
  local metadata_inner metadata_block

  metadata_inner="$(read_plan_block "$plan" "$EXECPLAN_METADATA_START" "$EXECPLAN_METADATA_END")"
  metadata_inner="$(upsert_scalar_in_content "$metadata_inner" "$key" "$value")"
  metadata_inner="$(trim_trailing_blank_lines "$metadata_inner")"

  metadata_block=$(cat <<EOF_META
## ExecPlan Metadata

${EXECPLAN_METADATA_START}
${metadata_inner}
${EXECPLAN_METADATA_END}
EOF_META
)

  replace_or_append_block "$plan" "$EXECPLAN_METADATA_START" "$EXECPLAN_METADATA_END" "$metadata_block"
}

trim_trailing_blank_lines() {
  printf '%s' "$1" | awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) {
        last--
      }
      for (i = 1; i <= last; i++) {
        print lines[i]
      }
    }
  '
}

strip_take_suffix() {
  printf '%s\n' "$1" | sed -E 's/ \(Take [0-9]+\)$//'
}

derive_take_from_title() {
  local title="$1"

  if [[ "$title" =~ \(Take[[:space:]]+([0-9]+)\)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '1\n'
}

format_take_title() {
  local base_title="$1"
  local take="$2"

  if [[ "$take" -le 1 ]]; then
    printf '%s\n' "$base_title"
    return 0
  fi

  printf '%s (Take %s)\n' "$base_title" "$take"
}

derive_branch_slug_from_branch() {
  printf '%s\n' "$1" | sed -E 's/-[0-9]{8}-[0-9]{4}(-[0-9]+)?$//'
}

strip_revision_note_block() {
  local body="$1"
  local stripped

  stripped="$(printf '%s' "$body" | awk -v start="$EXECPLAN_REVISION_NOTE_START" -v end="$EXECPLAN_REVISION_NOTE_END" '
    $0 == start { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ')"

  trim_trailing_blank_lines "$stripped"
}

append_revision_note_to_body() {
  local current_body="$1"
  local closed_pr_url="$2"
  local base_body

  base_body="$(strip_revision_note_block "$current_body")"
  base_body="$(trim_trailing_blank_lines "$base_body")"

  if [[ -n "$base_body" ]]; then
    cat <<EOF
${base_body}

${EXECPLAN_REVISION_NOTE_START}
This draft revises the closed PR: ${closed_pr_url}
${EXECPLAN_REVISION_NOTE_END}
EOF
    return 0
  fi

  cat <<EOF
${EXECPLAN_REVISION_NOTE_START}
This draft revises the closed PR: ${closed_pr_url}
${EXECPLAN_REVISION_NOTE_END}
EOF
}

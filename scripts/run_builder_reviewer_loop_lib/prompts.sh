#!/usr/bin/env bash

LOOP_PROMPT_TEMPLATE_DIR="${SCRIPT_DIR}/prompt_templates/run_builder_reviewer_loop"

render_prompt_template() {
  local template_path="$1"
  (
    export PATH_CONTEXT SUBMODULE_REL CURRENT_WORK_BRANCH TARGET_BASE_BRANCH PR_URL PR_TITLE CURRENT_BRANCH_SLUG CURRENT_TAKE
    export TASK_TEXT EXPECTED_PLAN_DOC_FILENAME INITIAL_PR_WAS_PROVIDED PR_TITLE_BASE PR_BODY_BASE CURRENT_PLAN_PATH
    export SUPERSEDED_PLAN_PATH SUPERSEDED_PR_URL REVIEWER_COMMENT REVIEWER_COMMENT_URL LATEST_COMMIT
    export PLAN_BOOTSTRAP_INSTRUCTIONS PLAN_FILENAME_INSTRUCTIONS RESUME_PLAN_INSTRUCTIONS
    perl -0pe 's/\{\{([A-Z0-9_]+)\}\}/defined $ENV{$1} ? $ENV{$1} : ""/ge' "$template_path"
  )
}

build_initial_builder_prompt() {
  PLAN_BOOTSTRAP_INSTRUCTIONS=""
  PLAN_FILENAME_INSTRUCTIONS=""
  RESUME_PLAN_INSTRUCTIONS=""

  if [[ "$INITIAL_PR_WAS_PROVIDED" -eq 0 ]]; then
    PLAN_BOOTSTRAP_INSTRUCTIONS=$(cat <<'EOF_BOOTSTRAP'
- You are starting a new ExecPlan for this take.
- Create a new ExecPlan in eternal-cycler-out/plans/active/.
- Do NOT modify or resume any existing plan document in eternal-cycler-out/plans/.
- Run execplan.post-creation immediately after writing the new plan.
EOF_BOOTSTRAP
)
  fi

  if [[ -n "$EXPECTED_PLAN_DOC_FILENAME" ]]; then
    PLAN_FILENAME_INSTRUCTIONS=$(cat <<EOF_PLAN
- The plan document path for this branch is fixed: ${EXPECTED_PLAN_DOC_FILENAME}
- The execplan.pre-creation hook already created an empty file at that exact path.
- Write the current take's plan into that file instead of creating any differently named plan document.
- Do not include any plan path or filename in your JSON output.
EOF_PLAN
)
  fi

  if [[ "$INITIAL_PR_WAS_PROVIDED" -eq 1 ]]; then
    RESUME_PLAN_INSTRUCTIONS=$(cat <<EOF_RESUME
- You are resuming the existing ExecPlan at ${EXPECTED_PLAN_DOC_FILENAME}.
- Read that plan in full before taking any action.
- Do NOT create a new ExecPlan.
- If the current task or operator feedback requires it, update the existing living document before continuing implementation.
- You may update the living-document sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective to reflect the current plan and state of work.
- Do not invent lifecycle records or hand-edit Hook Ledger semantics beyond normal lifecycle execution.
EOF_RESUME
)
  fi

  render_prompt_template "${LOOP_PROMPT_TEMPLATE_DIR}/builder_initial.tmpl"
}

build_retake_builder_prompt() {
  SUPERSEDED_PLAN_PATH="$1"
  SUPERSEDED_PR_URL="$2"
  REVIEWER_COMMENT="$3"
  REVIEWER_COMMENT_URL="$4"

  render_prompt_template "${LOOP_PROMPT_TEMPLATE_DIR}/builder_retake.tmpl"
}

build_reviewer_prompt() {
  render_prompt_template "${LOOP_PROMPT_TEMPLATE_DIR}/reviewer.tmpl"
}

---
name: eternal-cycler
description: A skill for automating the loop between the implementation builder agent and the implementation reviewer agent, with ExecPlan metadata stored only in the plan file.
---

# Skill: eternal-cycler

This skill drives the builder/reviewer loop and the ExecPlan lifecycle. ExecPlan runtime artifacts live under `eternal-cycler-out/plans/`; PR metadata is stored inline in each plan document, not in separate PR tracking docs. Outside-sandbox policy changes, when explicitly approved, are recorded in `.codex/rules/eternal-cycler.rules`.

The loop's built-in `git`, `gh`, and `codex exec` orchestration commands are trusted runtime operations audited in `.codex/rules/eternal-cycler.rules`. The manual sandbox escalation workflow applies when the operator or agent needs additional out-of-sandbox commands beyond those built-in loop operations.

## Runtime scripts

All paths are relative to this SKILL.md file's location.

- `scripts/run_builder_reviewer_doctor.sh`
- `scripts/run_builder_reviewer_loop.sh`
- `scripts/execplan_gate.sh`

## Input resolution

The skill accepts optional `target-branch` and `target-pr-url` inputs.

- `target-branch` means the branch that the current take's PR should merge into.
- `target-pr-url` means the PR whose **base branch** should be used as the target branch.
- If both are provided, they must resolve to the same branch or the skill must stop with an error.
- If neither is provided, use `main`.

If `target-pr-url` is provided, resolve it with:

`gh pr view <url> --json baseRefName --jq '.baseRefName'`

## Phase 0: Plan selection

1. Inspect `eternal-cycler-out/plans/active/` for active plan documents.
2. If one or more active plans exist, ask the user whether to resume one of them or start a new one.
3. If multiple active plans exist and the user chooses resume, show a numbered list using filename + first heading.
4. If the user chooses resume, follow **Resume plan flow**.
5. Otherwise, follow **New plan flow**.

## Resume plan flow

1. Read the selected plan in full.
2. Ask the user whether they want any plan modifications before resuming. If they provide modifications, apply them before continuing.
3. Read these values from the plan:
   - `execplan_start_branch`
   - `execplan_target_branch`
   - `execplan_pr_url`
   - `execplan_pr_title`
   - `execplan_branch_slug`
   - `execplan_take`
   - PR body block between `<!-- execplan-pr-body:start -->` and `<!-- execplan-pr-body:end -->`
4. If `execplan_pr_url` is missing or empty, stop. Resume requires an existing PR.
5. Resolve the requested target branch from user input only if the user explicitly supplied `target-branch` or `target-pr-url`.
6. If an explicit target branch was resolved and it does not match `execplan_target_branch`, stop with an error.
7. Switch to `execplan_start_branch`:
   - if the branch exists locally: `git switch <branch>`
   - else if `origin/<branch>` exists: `git switch -c <branch> --track origin/<branch>`
   - else: stop and ask the user for guidance
8. Pull the latest branch state:
   - `git pull --ff-only origin <execplan_start_branch>`
9. Run the resume gate:
   - first read `.codex/rules/eternal-cycler.rules`
   - `scripts/execplan_gate.sh --plan <plan_md> --event execplan.resume`
10. Compose the builder task:
   - prepend:
     ```
     You are resuming the ExecPlan at <plan_md>. Read that document in full before taking any action.
     Do NOT create a new ExecPlan. Do NOT modify any other plan document in eternal-cycler-out/plans/.
     ```
   - if the user provided task text or a task file, append it
   - otherwise append:
     ```
     Execute all incomplete actions listed in the Progress section of the plan (unchecked checkboxes).
     Follow the ExecPlan lifecycle from PLANS.md, starting at step 3 (execute actions).
     ```
11. Run doctor on the existing PR:
   - `scripts/run_builder_reviewer_doctor.sh --pr-url <execplan_pr_url>`
12. Invoke the loop with the stored PR metadata:
   - `scripts/run_builder_reviewer_loop.sh --task-file <task_md> --target-branch <execplan_target_branch> --pr-title <execplan_pr_title> --pr-body <stored_pr_body> --pr-url <execplan_pr_url>`

## New plan flow

1. Resolve the user task. If neither task text nor task file is provided, stop and ask. Do not invent a fallback task.
2. Resolve the target branch from `target-branch`, `target-pr-url`, or default `main`.
3. Switch to the target branch:
   - if the branch exists locally: `git switch <target_branch>`
   - else if `origin/<target_branch>` exists: `git switch -c <target_branch> --track origin/<target_branch>`
   - else: stop with an error
4. If `git switch` fails because of unstaged files, stop and ask the user to clean up the working tree. After they do, retry the switch.
5. Pull the latest target branch:
   - `git pull --ff-only origin <target_branch>`
6. Derive a branch slug from the first non-empty line of the original task text:
   - remove tokens containing `/` or `\`
   - lowercase
   - replace non `[a-z0-9]` with `-`
   - collapse repeated `-`
   - trim leading/trailing `-`
   - default to `task`
7. Create a unique work branch named `<slug>-YYYYMMDD-HHMM`. If it already exists locally or on origin, append `-1`, `-2`, ... until unique.
8. Switch to the new work branch.
9. Run the pre-creation gate:
   - first read `.codex/rules/eternal-cycler.rules`
   - `scripts/execplan_gate.sh --event execplan.pre_creation`
   - this creates an empty plan file at `eternal-cycler-out/plans/active/<current-branch>.md`
10. Compose the builder task:
   - prepend:
     ```
     You are starting a new ExecPlan. Create a new plan document in eternal-cycler-out/plans/active/.
     Do NOT modify or resume any existing plan document in eternal-cycler-out/plans/.
     Run execplan.post_creation gate immediately after writing the new plan.
     Use the pre-created file whose path matches the current branch name: eternal-cycler-out/plans/active/<current-branch>.md
     Include execplan_target_branch: <target_branch>, execplan_branch_slug: <slug>, and execplan_take: 1 in the plan metadata.
     ```
   - if the user supplied `target-pr-url`, also add:
     ```
     Include execplan_target_pr_url: <target_pr_url> in the plan metadata.
     ```
   - append the original task text after the preamble
11. Create an English PR title and body that summarize the requested work. These are loop inputs, not builder JSON outputs.
12. Run doctor on the new work branch:
   - `scripts/run_builder_reviewer_doctor.sh --head-branch <work_branch>`
13. Invoke the loop:
   - `scripts/run_builder_reviewer_loop.sh --task-file <task_md> --target-branch <target_branch> --pr-title <english_title> --pr-body <english_body>`

## Always

1. Treat `run_builder_reviewer_loop.sh` as non-interactive.
2. Stream builder/reviewer output to the operator in real time.
3. Do not surface incidental intermediate JSON emitted by builder/reviewer agents.
4. The only structured builder payload that matters is:
   - `{"result":"success|failed_after_3_retries","comment":"<english text>"}`
5. The reviewer payload remains:
   - `{"pr_url":"<target-pr-url>","comment_body":"<english text>","approve_merge":true|false}`
6. Do not stop the loop without explicit user instruction. If the loop script exits on its own, report the outcome and ask whether to continue.

## Suggested invocations

Resolve the eternal-cycler installation path first.

Resume existing plan with an open PR:

    SKILL_ROOT=<path-to-eternal-cycler>
    cat .codex/rules/eternal-cycler.rules
    git switch <execplan_start_branch>
    git pull --ff-only origin <execplan_start_branch>
    $SKILL_ROOT/scripts/execplan_gate.sh --plan <plan_md> --event execplan.resume
    $SKILL_ROOT/scripts/run_builder_reviewer_doctor.sh --pr-url <execplan_pr_url>
    $SKILL_ROOT/scripts/run_builder_reviewer_loop.sh \
      --task-file <task_md> \
      --target-branch <execplan_target_branch> \
      --pr-title "<execplan_pr_title>" \
      --pr-body "<stored_pr_body>" \
      --pr-url <execplan_pr_url>

New plan:

    SKILL_ROOT=<path-to-eternal-cycler>
    cat .codex/rules/eternal-cycler.rules
    git switch <target_branch>
    git pull --ff-only origin <target_branch>
    git switch -c <slug-YYYYMMDD-HHMM>
    $SKILL_ROOT/scripts/execplan_gate.sh --event execplan.pre_creation
    $SKILL_ROOT/scripts/run_builder_reviewer_doctor.sh --head-branch <work_branch>
    $SKILL_ROOT/scripts/run_builder_reviewer_loop.sh \
      --task-file <task_md> \
      --target-branch <target_branch> \
      --pr-title "<english_title>" \
      --pr-body "<english_body>"

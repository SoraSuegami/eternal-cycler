---
name: eternal-cycler
description: A skill for automating the loop between the implementation builder agent and the implementation reviewer agent, with ExecPlan metadata cached in the plan file.
---

# Skill: eternal-cycler

This skill drives the builder/reviewer loop and the ExecPlan lifecycle. ExecPlan runtime artifacts live under `eternal-cycler-out/plans/`; PR metadata and PR body are cached inline in each plan document, while the remote GitHub PR remains authoritative. Outside-sandbox policy changes, when explicitly approved, are recorded in `.codex/rules/eternal-cycler.rules`.

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
2. If `execplan_pr_url` is missing or empty, stop. Resume requires an existing PR.
3. Resolve the requested target branch from user input only if the user explicitly supplied `target-branch` or `target-pr-url`.
4. If the user supplied task text or a task file, pass it through to the loop.
5. Invoke the loop with the selected plan:
   - `scripts/run_builder_reviewer_loop.sh --resume-plan <plan_md> [--task-file <task_md> | --task <text>] [--target-branch <branch>]`
6. Do not manually run doctor, `execplan.resume`, or branch switching commands beforehand. The loop owns those mechanical steps, including refreshing the target branch before switching back to the plan branch.
7. The builder will read the resumed plan, update the living document if needed, and continue execution inside the loop.

## New plan flow

1. Resolve the user task. If neither task text nor task file is provided, stop and ask. Do not invent a fallback task.
2. Resolve the target branch from `target-branch`, `target-pr-url`, or default `main`.
3. Create an English PR title and body that summarize the requested work. These are loop inputs, not builder JSON outputs.
4. Invoke the loop directly:
   - `scripts/run_builder_reviewer_loop.sh --task-file <task_md> --target-branch <target_branch> --pr-title <english_title> --pr-body <english_body>`
5. Do not manually run doctor or `execplan.pre-creation` beforehand. The loop owns those mechanical steps, including switching to the target branch, pulling it with `--ff-only`, and then creating the new take branch.

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
    $SKILL_ROOT/scripts/run_builder_reviewer_loop.sh \
      --resume-plan <plan_md> \
      --task-file <task_md>

New plan:

    SKILL_ROOT=<path-to-eternal-cycler>
    $SKILL_ROOT/scripts/run_builder_reviewer_loop.sh \
      --task-file <task_md> \
      --target-branch <target_branch> \
      --pr-title "<english_title>" \
      --pr-body "<english_body>"

---
name: eternal-cycler
description: A skill for automating the loop between the implementation builder agent and the implementation reviewer agent, with ExecPlan metadata cached in the plan file.
---

# Skill: eternal-cycler

This skill drives the builder/reviewer loop and the ExecPlan lifecycle. ExecPlan runtime artifacts live under `eternal-cycler-out/plans/`; PR metadata and PR body are cached inline in each plan document, while the remote GitHub PR remains authoritative. Outside-sandbox policy changes, when explicitly approved, are recorded in `.codex/rules/eternal-cycler.rules`.

The loop's built-in `git`, `gh`, `codex exec`, and `claude -p` orchestration commands are trusted runtime operations audited in `.codex/rules/eternal-cycler.rules`. The manual sandbox escalation workflow applies when the operator or agent needs additional out-of-sandbox commands beyond those built-in loop operations.

## Runtime scripts

All paths are relative to this SKILL.md file's location.

- `scripts/run_builder_reviewer_doctor.sh`
- `scripts/run_builder_reviewer_loop.sh`
- `scripts/execplan_gate.sh`
- `scripts/execplan_user_feedback.sh`

## Input resolution

The skill accepts optional `target-branch` input for new takes.

- `target-branch` means the branch that the current take's PR should merge into.
- If it is omitted for a new take, use `main`.
- Resume ignores direct target-branch input and uses the branch recorded in the selected plan.

## Provider selection

Before invoking `run_builder_reviewer_loop.sh`, resolve the provider for each role and pass both explicitly with loop flags.

1. Detect installed agent CLIs with `command -v codex` and `command -v claude`.
2. Treat launcher identity as caller-owned context:
   - if this skill is running inside Claude Code, use the Claude-launched rules below
   - if this skill is running inside Codex, use the Codex-launched rules below
3. Claude-launched rules:
   - If `claude` and `codex` are both installed, ask the user which provider to use for the builder and which provider to use for the reviewer before starting the loop.
   - Ask role-by-role, not as one global provider choice.
   - Recommend `claude` for both roles.
   - If only `claude` is installed, use `claude` for both roles without asking.
   - If the user selects `codex` for a role but `codex` is unavailable, stop and ask for a different provider.
4. Codex-launched rules:
   - Default both builder and reviewer to `codex`.
   - Do not ask provider-selection questions by default.
   - Only switch builder and/or reviewer to `claude` when the user explicitly asks for Claude Code for that role.
   - If the user explicitly requests `claude` for a role but `claude` is unavailable, stop and ask for a different provider.
5. Pass the resolved providers explicitly:
   - `--builder-provider <codex|claude>`
   - `--reviewer-provider <codex|claude>`
6. Do not rely on the loop script to infer launcher identity from shell state.

## Phase 0: Plan selection

1. Inspect `eternal-cycler-out/plans/active/` for active plan documents.
2. If one or more active plans exist, ask the user whether to resume one of them or start a new one.
3. If multiple active plans exist and the user chooses resume, show a numbered list using filename + first heading.
4. If the user chooses resume, follow **Resume plan flow**.
5. Otherwise, follow **New plan flow**.

## Resume plan flow

1. Read the selected plan in full.
2. If `execplan_pr_url` is missing or empty, stop. Resume requires an existing PR.
3. Do not resolve or override the target branch from user input during resume. The selected plan's recorded `execplan_target_branch` is authoritative.
4. If the user supplied task text or a task file, pass it through to the loop.
5. Invoke the loop with the selected plan:
   - `scripts/run_builder_reviewer_loop.sh --resume-plan <plan_md> --builder-provider <provider> --reviewer-provider <provider> [--task-file <task_md> | --task <text>]`
6. Do not manually run doctor, `execplan.resume`, or branch switching commands beforehand. The loop owns those mechanical steps, including refreshing the target branch before switching back to the plan branch.
7. The builder will read the resumed plan, update the living document if needed, and continue execution inside the loop.

## New plan flow

1. Resolve the user task. If neither task text nor task file is provided, stop and ask. Do not invent a fallback task.
2. Resolve the target branch from `target-branch` or default `main`.
3. Create an English PR title and body that summarize the requested work. These are loop inputs, not builder JSON outputs.
4. Invoke the loop directly:
   - `scripts/run_builder_reviewer_loop.sh --task-file <task_md> --target-branch <target_branch> --builder-provider <provider> --reviewer-provider <provider> --pr-title <english_title> --pr-body <english_body>`
5. Do not manually run doctor or `execplan.pre-creation` beforehand. The loop owns those mechanical steps, including switching to the target branch, pulling it with `--ff-only`, and then creating the new take branch.

## Always

1. Treat `run_builder_reviewer_loop.sh` as non-interactive.
2. Stream builder/reviewer output to the operator in real time.
3. Do not surface incidental intermediate JSON emitted by builder/reviewer agents.
4. The only structured builder payload that matters is:
   - `{"result":"success|failed_after_3_retries","comment":"<english text>"}`
5. The reviewer payload remains:
   - `{"pr_url":"<pr-url>","comment_body":"<english text>","approve_merge":true|false}`
6. Do not stop the loop without explicit user instruction. If the loop script exits on its own, report the outcome and ask whether to continue.
7. If the user sends follow-up instructions while the loop is running, translate them to English, decompose them into independent items, and write them only through `scripts/execplan_user_feedback.sh submit --plan <plan_md> --item <english_text>`.
8. While the loop is running, poll `scripts/execplan_user_feedback.sh status --plan <plan_md> --format json`. If the builder has appended new `question` or `objection` responses, forward them to the user as intermediate output without ending the caller agent turn or stopping the loop.
9. Do not write to `eternal-cycler-out/builder-response/`; treat it as builder-owned read-only state. See `PLANS.md` for the full feedback contract.

## Suggested invocations

Resolve the eternal-cycler installation path first.

Resume existing plan with an open PR:

    SKILL_ROOT=<path-to-eternal-cycler>
    $SKILL_ROOT/scripts/run_builder_reviewer_loop.sh \
      --resume-plan <plan_md> \
      --builder-provider <provider> \
      --reviewer-provider <provider> \
      --task-file <task_md>

New plan:

    SKILL_ROOT=<path-to-eternal-cycler>
    $SKILL_ROOT/scripts/run_builder_reviewer_loop.sh \
      --task-file <task_md> \
      --target-branch <target_branch> \
      --builder-provider <provider> \
      --reviewer-provider <provider> \
      --pr-title "<english_title>" \
      --pr-body "<english_body>"

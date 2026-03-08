# Codex Execution Plans (ExecPlans)

## Global Requirements

- All documentation, git commit messages, and PRs must be written in English.
- When documenting file paths, use only paths relative to the repository top directory. Do not write absolute paths in documentation.

An execution plan ("ExecPlan") is a design document that a coding agent follows to deliver a working feature or system change. Treat the reader as a complete beginner: they have only the current working tree and the single ExecPlan file. There is no memory of prior plans and no external context.

## Behavior when working with ExecPlans

- **Read PLANS.md in full** before authoring or implementing. Start a new plan from the skeleton below.
- **Proceed autonomously after entrypoint selection.** Once the user has chosen the active plan / resume-vs-new-plan entrypoint, do not prompt for "next steps." Resolve ambiguities in the plan itself; do not pause for confirmation unless the escalation bound is reached.
- **Mark progress immediately.** When a `Progress` action finishes, mark it `[x]` before starting the next action. When operating manually, commit frequently; when running through the loop, the loop script owns checkpoint commits and pushes.
- **One plan per objective.** Merge sub-agent outcomes into the same ExecPlan; do not create separate sub-plan lifecycle documents.
- **Record decisions.** All design choices go into the `Decision Log` with rationale. It must always be possible to restart from only the ExecPlan.
- **Research deeply.** Use prototyping milestones for risky or unknown requirements; read library source code; embed all required knowledge in the plan itself rather than linking to external docs.

## Requirements

Every ExecPlan must satisfy these non-negotiable requirements:

* **Self-contained and novice-enabling.** In its current form it contains all knowledge needed for a complete novice to implement the feature end-to-end without prior knowledge of this repository.
* **Living document.** Revise it as progress is made, as discoveries occur, and as decisions are finalized. Each revision must remain fully self-contained.
* **Demonstrably working.** The plan must produce observable behavior, not merely code changes that "meet a definition."
* **Plain language.** Define every term of art immediately. Do not say "as defined previously" or "see the architecture doc."

State purpose and intent first: explain why the work matters, what someone can do after the change that they could not do before, and how to observe it working. Then provide the exact steps to achieve that outcome.

The executing agent can list files, read files, search, run the project, and run tests. It has no prior context. Repeat any assumption you rely on. If this plan builds on a prior checked-in ExecPlan, incorporate it by reference; otherwise include all relevant context.

## Formatting

Each ExecPlan is one single fenced code block labeled `md` (triple backticks). Do not nest additional triple-backtick fences inside; show commands, transcripts, diffs, or code as indented blocks. When writing an ExecPlan to a standalone `.md` file, omit the triple backticks.

Write in plain prose. Prefer sentences over lists. Checklists are permitted only in `Progress`, where they are mandatory. Narrative sections must be prose-first.

## Guidelines

**Resolve ambiguity in the plan, not in execution.** Do not outsource key decisions to the reader. When ambiguity exists, choose a path and explain why. Err toward over-explaining user-visible effects and under-specifying implementation details.

**Anchor with observable outcomes.** Phrase acceptance as behavior a human can verify ("after starting the server, navigating to http://localhost:8080/health returns HTTP 200 with body OK"), not internal attributes. For internal changes, show how to observe the effect through tests or a scenario.

**Specify repository context explicitly.** Name files by full repository-relative paths. Name functions and modules precisely. Show the working directory and exact command line for every command. When outcomes depend on environment, state the assumptions.

**Be idempotent and safe.** Write steps that can be run multiple times without drift. For risky or destructive steps, provide a retry path or rollback.

**Validation is mandatory.** Include test commands, expected outputs, and a short end-to-end scenario. State exact test commands and how to interpret results. Show how to prove the change is effective beyond compilation.

**Capture evidence.** Include terminal output, short diffs, or logs as indented examples inside the plan fence.

## Milestones

Milestones are narrative, not bureaucracy. Each milestone introduces its scope in one paragraph — goal, work, result, proof — and must be independently verifiable and incrementally implement the overall goal. Never abbreviate a milestone for the sake of brevity; do not omit details that could be crucial for a future implementation.

Milestones and Progress serve different roles: milestones tell the story, Progress tracks granular work. Both must exist.

## Prototyping milestones and parallel implementations

Include explicit prototyping milestones when they de-risk a larger change (feasibility probes, toy implementations, spikes). Keep prototypes additive and testable. Label scope as "prototyping," describe how to run and observe results, and state the criteria for promoting or discarding the prototype.

Prefer additive changes followed by subtractions that keep tests passing. Parallel implementations are acceptable during migration — describe how to validate both paths and how to retire one safely.

## Living plans and design decisions

ExecPlans must contain and maintain these sections (all are mandatory):

* `Progress` — checkbox list, always reflecting the current state
* `Hook Ledger` — all gate attempt records
* `Surprises & Discoveries` — unexpected behaviors, bugs, or insights with short evidence
* `Decision Log` — every decision with rationale, date, and author
* `Outcomes & Retrospective` — summary at major milestones and at completion

If you change course mid-implementation, document why in `Decision Log` and reflect the implications in `Progress`.

## Plan file locations

* Active plans → `eternal-cycler-out/plans/active/`
* Completed plans → `eternal-cycler-out/plans/completed/`
* Technical debt → `eternal-cycler-out/plans/tech-debt/`

Active plans are the only plans that may still be revised or retried. Completed plans are terminal artifacts only: successfully finalized plans, failed/escalated plans, and superseded plans from reviewer-rejected takes. A rejected take must not reuse its old plan on a new branch; the replacement take creates a brand new active plan.

Files in `tech-debt/` must include explicit repository-relative markdown links to the related plans (active or completed) that introduced, mitigated, or depend on that debt.

Live operator feedback artifacts are stored separately from plan lifecycle documents:

* Caller-written feedback → `eternal-cycler-out/user-feedback/<plan-filename>.md`
* Builder-written responses → `eternal-cycler-out/builder-response/<plan-filename>.md`

Those filenames are keyed only by the plan filename so they remain stable while the plan moves between `active/` and `completed/`.

## ExecPlan Metadata

Every skill-managed ExecPlan stores its runtime branch / PR metadata inline in the plan file.
The remote GitHub PR is authoritative for PR URL, title, body, and head/base state. The inline metadata and PR body block in the plan are a cache refreshed by lifecycle hooks so the builder and scripts can read them locally.

Required scalar metadata:

* `execplan_start_branch`
* `execplan_target_branch`
* `execplan_start_commit`
* `execplan_pr_url`
* `execplan_pr_title`
* `execplan_branch_slug`
* `execplan_take`

Optional scalar metadata:

* `execplan_supersedes_plan`
* `execplan_supersedes_pr_url`

The current PR body must be stored between:

* `<!-- execplan-pr-body:start -->`
* `<!-- execplan-pr-body:end -->`

When authoring a new plan before `execplan.post-creation`, include at least `execplan_target_branch`, `execplan_branch_slug`, and `execplan_take` so the hook can preserve the intended target/take context.

## Action-Level Parallel Execution

One lifecycle, one ExecPlan per objective. For large work, decompose into action-level units inside that one plan; do not create separate sub-plan lifecycle documents.

If a `Progress` checklist step is coupled to a hook, document that linkage with `hook_events`. Steps without hook coupling may omit `hook_events`. Additional fields such as `action_id`, `mode`, `depends_on`, `file_locks`, and `worker_type` are optional advisory metadata for humans/LLMs; the current gate/loop implementation does not schedule from them.

## Verification Policy

Verification is enforced by the gate script and event-local hooks.

**Path note:** Gate script path is relative to the eternal-cycler installation root (shown in "Path context" in your prompt). Hook and plan paths are relative to the consuming repository root.

Operational source of truth:

* each installed hook under `.agents/skills/execplan-hook-*/`
* `.codex/rules/eternal-cycler.rules`
* `scripts/execplan_gate.sh`

Templates (do not edit directly; edit copies in `.agents/skills/`): `assets/default-hooks/execplan-hook-*/`

### Event model

Each event resolves to a hook directory by naming convention. Supported event namespaces are `execplan.*` and `hook.*`. Event IDs must use dash-form names only (no underscores). Strip the namespace, replace `.` with `-`, then prefix `execplan-hook-`.

Examples:

* `execplan.post-creation` → `.agents/skills/execplan-hook-post-creation/`
* `hook.docs-only` → `.agents/skills/execplan-hook-docs-only/`

When choosing `hook_events` for a `Progress` action, search the installed skill index for `execplan-hook-*` hooks and select the matching event ID.

Mandatory lifecycle events (must always have matching hooks):

* `execplan.pre-creation`
* `execplan.post-creation`
* `execplan.resume`
* `execplan.post-completion`

Non-lifecycle events are flexible and may be added or removed without changing this policy text, as long as their derived hook directories exist under `.agents/skills/`.
Legacy `action.*` event IDs are rejected; `action` is reserved for `Progress` checklist items only.

### Enforcement model

Gate command: `scripts/execplan_gate.sh --event <event_id> [--plan <plan_md>] [--attempt <n>]`

The gate blocks lifecycle progress when any previously attempted event remains in `fail` or `escalated` state, and additionally:

* rejects lifecycle events (`execplan.pre-creation`, `execplan.post-creation`, `execplan.resume`, `execplan.post-completion`) in `Progress` action `hook_events`
* blocks `execplan.post-completion` until `execplan.post-creation` or `execplan.resume` has a `pass` entry, and every event referenced by `hook_events` has at least one `pass` entry in the Hook Ledger

### Retry and escalation

Max attempts per event: **3**. If the bound is exceeded, the gate marks the event `escalated` and stops progress. After escalation:

* document failure explicitly in `Progress`, `Hook Ledger`, and `Outcomes & Retrospective`
* force-close the current plan as failed (move to `eternal-cycler-out/plans/completed/`)
* resume only via a new ExecPlan in `eternal-cycler-out/plans/active/` seeded from human-operator feedback referencing the failed plan

### Sandbox escalation policy

This policy governs manual out-of-sandbox lifecycle invocations and additional out-of-sandbox commands proposed during ExecPlan action execution. The loop's built-in orchestrator commands (`git`, `gh`, `codex exec`) are trusted runtime operations audited separately in `.codex/rules/eternal-cycler.rules`; they do not use a per-command allowlist workflow at runtime.

Before running any additional out-of-sandbox command outside those built-in loop operations:

1. Read `.codex/rules/eternal-cycler.rules`
2. Use an existing allowed prefix from that rules file when possible
3. If none apply, request human approval and add a safely generalized prefix to `.codex/rules/eternal-cycler.rules`

Skipping this step is a policy violation. The current gate/hook implementation does not independently attest allowlist usage or approval provenance, so callers and reviewers must enforce this policy from the recorded commands and surrounding context.

### Evidence policy

Record every gate attempt in the plan's `## Hook Ledger` with:

`event_id`, `attempt`, `status` (`pass`/`fail`/`escalated`), `commands`, `failure_summary`, `started_at`, `finished_at`

Do not store verification logs in separate temporary files.

## ExecPlan Lifecycle

Two paths depending on whether you are starting a new plan or resuming an existing one.

### New plan

1. **Pre-creation gate** — run out-of-sandbox before creating the plan document:
   `scripts/execplan_gate.sh --event execplan.pre-creation`
   In loop-managed execution, the loop first switches to `TARGET_BASE_BRANCH`, runs `git pull --ff-only origin <target-branch>`, and only then creates the new work branch for this take. If either git step fails, stop and report the git error to the operator. The pre-creation gate then validates environment (branch, tracked working tree) and seeds an empty plan file at `eternal-cycler-out/plans/active/<current-branch>.md` when none exists yet. Benign pre-existing untracked files are allowed. If a non-empty active plan already exists for the current branch, this gate fails instead of clobbering that living document. No ledger entry is written because the plan content does not exist yet.
2. **Create plan and post-creation gate** — create the plan document in `eternal-cycler-out/plans/active/`, write the full plan, and define `Progress` actions with `hook_events` (`hook_events` must contain only `hook.*` IDs in dash-form; lifecycle events must never appear in `hook_events`). Optional advisory metadata such as `action_id`, `mode`, `depends_on`, `file_locks`, and `worker_type` may be included when useful for human/LLM planning. Then immediately run:
   `scripts/execplan_gate.sh --plan <plan_md> --event execplan.post-creation`
   Before invoking this step, ensure the current branch already has the draft PR for this take; the default `execplan.post-creation` hook fails if the current branch has no PR or only a non-draft PR. This step reads PR metadata and PR body from that draft PR, records the start snapshot, and refreshes the inline ExecPlan metadata / PR body blocks that `execplan.post-completion` requires.
3. **Execute actions** in dependency order. Mark each `[x]` immediately when complete. Out-of-sandbox commands must follow the sandbox escalation policy.
4. **Run hook after each action** — run `scripts/execplan_gate.sh` for each event in `hook_events`. The gate blocks progress on failure.
5. **Record all gate attempts** in `## Hook Ledger`.
6. **On failure** — retry up to 3 attempts. On escalation:
   * document failure in `Progress`, `Hook Ledger`, and `Outcomes & Retrospective`
   * move the plan to `eternal-cycler-out/plans/completed/` as failed
   * stop; resume only via a new ExecPlan after operator feedback
7. **Finalize plan** after all actions pass:
   * update all living-document sections (`Progress`, `Surprises & Discoveries`, `Decision Log`, `Outcomes & Retrospective`)
   * note which hook scripts were referenced, created, modified, or left unchanged, and why
   * ensure all implementation changes are ready to be committed and pushed; in loop-managed execution, the loop owns checkpoint/finalization commits and pushes after successful builder cycles and may add extra docs-only commits when force-closing failed takes or superseding reviewer-rejected takes
   * treat non-ignored files created during execution as intended outputs; if a temporary/build/log artifact should not be committed, ignore it before lifecycle completion
   * add tech-debt follow-up plans if needed
8. **Post-completion gate** — run out-of-sandbox:
   * `scripts/execplan_gate.sh --plan <active_plan_md> --event execplan.post-completion`
   * `execplan.post-completion` is validation-only: no `git add`, `git commit`, or `git push`
   * In loop-managed execution, the builder runs this gate and must not return success until the completed plan contains the resulting pass entry.
   * If `eternal-cycler-out/user-feedback/<plan-filename>.md` exists, `execplan.post-completion` also requires every `feedback_id` in that file to have at least one terminal response record in `eternal-cycler-out/builder-response/<plan-filename>.md`.
   * On pass: the gate appends the pass ledger entry and moves the plan to `eternal-cycler-out/plans/completed/`; the loop then verifies that completed plan and continues with its normal checkpoint/finalization commit/push behavior without invoking any further builder edits.
   * On failure: the plan stays in `eternal-cycler-out/plans/active/` for revision and retry.
   * On escalation: same as step 6 — document failure, move the plan to `eternal-cycler-out/plans/completed/` as failed, and stop.
   * Lifecycle complete.

### Resume existing plan

1. **Select plan** from `eternal-cycler-out/plans/active/`. If there is operator feedback, pass it to the loop/builder; do not require manual plan editing before resume.
2. **Resume gate** — run out-of-sandbox:
   `scripts/execplan_gate.sh --plan <plan_md> --event execplan.resume`
   In loop-managed execution, the loop always treats the target branch recorded in the plan as authoritative. It first refreshes that plan-recorded target branch with `git pull --ff-only origin <target-branch>`, then switches back to the plan's recorded start branch before running this gate. Any direct resume-time target-branch input must be ignored. If target-branch refresh or branch switching fails, stop and report the git error to the operator. The resume gate validates that the current branch matches the plan's recorded start branch and that the branch's PR is still `OPEN`, refreshes the inline ExecPlan metadata / PR body blocks from that open PR, and appends a resume record to the plan.
3. Continue from step 3 of the new-plan path (execute actions, verify, finalize, post-completion gate).

## Live Feedback Interrupts

Live follow-up feedback is file-mediated. The loop does not inject new input into a running builder session. Instead, the caller agent and builder coordinate through two append-only runtime artifacts.

Caller responsibilities:

* Translate user follow-up into English before handing it to the builder workflow.
* Decompose follow-up into independent items.
* Write only through `scripts/execplan_user_feedback.sh submit --plan <plan_md> --item <english_text> [--item ...]`.
* Poll `scripts/execplan_user_feedback.sh status --plan <plan_md> --format json` while the loop runs.
* If the builder has appended any new `status=question` or `status=objection` entries, forward them to the user as intermediate status output.
* Do not stop the loop merely because a question/objection was forwarded. The loop continues unless the user explicitly requests stop.

Builder responsibilities:

* Read `eternal-cycler-out/user-feedback/<plan-filename>.md` whenever it exists.
* Write only through `scripts/execplan_user_feedback.sh respond`.
* Never edit the user-feedback or builder-response documents directly.
* For every `feedback_id`, record at least one terminal response before returning success:
  * `status=implemented` when the feedback was accepted and applied
  * `status=question` when clarification is needed
  * `status=objection` when the builder rejects the requested approach
* `implemented`, `question`, and `objection` all count as answered for `execplan.post-completion`.

## Skeleton of a Good ExecPlan

    # <Short, action-oriented description>

    This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

    If PLANS.md is checked into this repo, reference its path here from the repository root and note that this document must be maintained in accordance with PLANS.md.

    ## Purpose / Big Picture

    Explain in a few sentences what someone gains after this change and how they can see it working. State the user-visible behavior you will enable.

    ## Progress

    Use a list with checkboxes to summarize granular steps. Every stopping point must be documented here, even if it requires splitting a partially completed task into two ("done" vs. "remaining"). This section must always reflect the actual current state.

    - [x] (2025-10-01 13:00Z) Example completed step.
    - [ ] Example incomplete step.
    - [ ] hook_events=hook.tooling; implement lookup cache rewrite.

    Use timestamps to measure rates of progress. Mark each action `[x]` immediately when it finishes.

    If a `Progress` line is coupled to a hook, define that linkage with `hook_events`. Steps without hook coupling may omit it. Optional advisory metadata (`action_id`, `mode`, `depends_on`, `file_locks`, `worker_type`) may be added when useful, but scripts do not currently schedule from them. `hook_events` must contain only dash-form `hook.*` events; lifecycle events are executed only by lifecycle steps.

    ## Hook Ledger

    Record every gate attempt with one entry per attempt:

    - `event_id`
    - `attempt`
    - `status` (`pass`, `fail`, `escalated`)
    - `commands`
    - `failure_summary`
    - `started_at`
    - `finished_at`

    ## ExecPlan Metadata

    Store the current take's branch / PR metadata inline:

    <!-- execplan-metadata:start -->
    - execplan_start_branch: <work-branch>
    - execplan_target_branch: <merge-target-branch>
    - execplan_start_commit: <commit-sha>
    - execplan_pr_url: <open-pr-url>
    - execplan_pr_title: <english-pr-title>
    - execplan_branch_slug: <branch-slug>
    - execplan_take: <positive-integer>
    <!-- execplan-metadata:end -->

    ## ExecPlan PR Body

    <!-- execplan-pr-body:start -->
    <current PR body markdown>
    <!-- execplan-pr-body:end -->

    ## Surprises & Discoveries

    Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation. Provide concise evidence.

    - Observation: …
      Evidence: …

    ## Decision Log

    Record every decision made while working on the plan:

    - Decision: …
      Rationale: …
      Date/Author: …

    ## Outcomes & Retrospective

    Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result against the original purpose.

    ## Context and Orientation

    Describe the current state relevant to this task as if the reader knows nothing. Name key files and modules by full path. Define any non-obvious term you will use. Do not refer to prior plans.

    ## Plan of Work

    Describe, in prose, the sequence of edits and additions. For each edit, name the file and location (function, module) and what to insert or change. Keep it concrete and minimal.

    ## Concrete Steps

    State the exact commands to run and the working directory. Show short expected output for commands that produce output. Update this section as work proceeds.

    ## Validation and Acceptance

    Describe how to exercise the system and what to observe. Phrase acceptance as behavior with specific inputs and outputs. If tests are involved: "run <test command> and expect <N> passed; the new test <name> fails before the change and passes after."

    ## Idempotence and Recovery

    If steps can be repeated safely, say so. If a step is risky, provide a retry or rollback path.

    ## Artifacts and Notes

    Include the most important transcripts, diffs, or snippets as indented examples.

    ## Interfaces and Dependencies

    Name the libraries, modules, and services to use and why. Specify types, interfaces, and function signatures that must exist at the end of the milestone.

A single, stateless agent — or a human novice — must be able to read your ExecPlan from top to bottom and produce a working, observable result. That is the bar: SELF-CONTAINED, SELF-SUFFICIENT, NOVICE-GUIDING, OUTCOME-FOCUSED.

When you revise a plan, ensure changes are reflected across all sections and write a note at the bottom describing what changed and why.

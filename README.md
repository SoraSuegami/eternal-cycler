# eternal-cycler

An autonomous builder/reviewer loop for [Codex](https://github.com/openai/codex) agents. Install it as a git subtree in your repository to get:

- an autonomous agent loop that writes code, opens draft PRs, reuses existing draft PRs, reviews them, and iterates until the reviewer approves
- an ExecPlan lifecycle system with verification gates and escalation bounds
- inline ExecPlan metadata that stores branch / target branch / PR information directly in each plan document

## Directory layout after installation

```text
your-repo/
├── .codex/
│   └── rules/
│       └── eternal-cycler.rules
├── .agents/
│   └── skills/
│       ├── eternal-cycler/
│       │   ├── SKILL.md
│       │   ├── PLANS.md
│       │   ├── REVIEW.md
│       │   ├── setup.sh
│       │   ├── scripts/
│       │   └── assets/default-hooks/
│       ├── execplan-hook-pre-creation/
│       ├── execplan-hook-post-creation/
│       ├── execplan-hook-resume/
│       ├── execplan-hook-post-completion/
│       ├── execplan-hook-docs-only/
│       ├── execplan-hook-tooling/
│       └── execplan-sandbox-escalation/
└── eternal-cycler-out/
    └── plans/
        ├── active/
        ├── completed/
        └── tech-debt/
```

The skill directory (`.agents/skills/eternal-cycler/`) is static and never written to at runtime. Dynamic output goes only to `eternal-cycler-out/plans/`.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `git` | version control |
| `gh` | GitHub CLI for PR operations |
| `codex` | OpenAI Codex CLI |
| `jq` | JSON parsing in loop scripts |
| `rg` | fast search in scripts and plans |

## Installation

Add eternal-cycler as a git subtree under `.agents/skills/eternal-cycler/`:

```bash
git subtree add \
  --prefix .agents/skills/eternal-cycler \
  https://github.com/SoraSuegami/eternal-cycler.git \
  main \
  --squash
```

Then run setup:

```bash
bash .agents/skills/eternal-cycler/setup.sh
```

Setup copies the shared hook skills, installs the Codex rules file, and creates the plan directories:

```text
[setup] OK   copied execplan-hook-pre-creation -> .agents/skills/execplan-hook-pre-creation
[setup] OK   copied execplan-hook-post-creation -> .agents/skills/execplan-hook-post-creation
[setup] OK   copied execplan-hook-resume -> .agents/skills/execplan-hook-resume
[setup] OK   copied execplan-hook-post-completion -> .agents/skills/execplan-hook-post-completion
[setup] OK   copied execplan-hook-docs-only -> .agents/skills/execplan-hook-docs-only
[setup] OK   copied execplan-hook-tooling -> .agents/skills/execplan-hook-tooling
[setup] OK   copied execplan-sandbox-escalation -> .agents/skills/execplan-sandbox-escalation
[setup] OK   copied eternal-cycler.rules -> .codex/rules/eternal-cycler.rules
[setup] Creating eternal-cycler-out/ output directories under /path/to/your-repo/
[setup] OK   eternal-cycler-out/plans/active
[setup] OK   eternal-cycler-out/plans/completed
[setup] OK   eternal-cycler-out/plans/tech-debt
```

Commit the result:

```bash
git add .codex/ .agents/ eternal-cycler-out/
git commit -m "chore: install eternal-cycler"
```

## Runtime model

Each ExecPlan stores its own runtime metadata in the plan file:

- `execplan_start_branch`
- `execplan_target_branch`
- `execplan_start_commit`
- `execplan_pr_url`
- `execplan_pr_title`
- `execplan_branch_slug`
- `execplan_take`
- optional `execplan_target_pr_url`
- optional `execplan_supersedes_plan`
- optional `execplan_supersedes_pr_url`

The current PR body is stored in the plan between:

- `<!-- execplan-pr-body:start -->`
- `<!-- execplan-pr-body:end -->`

## Usage

The preferred entrypoint is the skill in `SKILL.md`, which handles:

- target branch resolution from `target-branch` or `target-pr-url`
- active plan selection
- branch switching and pulling
- direct loop invocation with the required PR title/body inputs

You can also invoke the loop directly after preparing the branch yourself.

New take:

```bash
git switch main
git pull --ff-only origin main
git switch -c login-validation-20260307-1430
.agents/skills/eternal-cycler/scripts/run_builder_reviewer_loop.sh \
  --task "add input validation to the login form" \
  --target-branch main \
  --pr-title "feat: add login form input validation" \
  --pr-body "## Summary\n- validate login form input before submit\n- add regression coverage"
```

Resume an existing plan/PR:

```bash
PLAN=eternal-cycler-out/plans/active/login-validation-20260307-1430.md
.agents/skills/eternal-cycler/scripts/execplan_gate.sh --plan "$PLAN" --event execplan.resume
.agents/skills/eternal-cycler/scripts/run_builder_reviewer_loop.sh \
  --task-file task.md \
  --target-branch main \
  --pr-title "feat: add login form input validation" \
  --pr-body "$(sed -n '/<!-- execplan-pr-body:start -->/,/<!-- execplan-pr-body:end -->/p' "$PLAN" | sed '1d;$d')" \
  --pr-url https://github.com/your-org/your-repo/pull/42
```

## Updating

Pull upstream changes with git subtree:

```bash
git subtree pull \
  --prefix .agents/skills/eternal-cycler \
  https://github.com/SoraSuegami/eternal-cycler.git \
  main \
  --squash
```

Re-run setup after updating so the default hooks and allowlist stay in sync:

```bash
bash .agents/skills/eternal-cycler/setup.sh
```

## Adding custom hooks

The gate script resolves hook scripts from `.agents/skills/` in your repository.

1. Pick an event ID such as `hook.your_event`.
2. Derive the hook directory name from the portion after the first `.` by replacing `_` and `.` with `-`.
3. Create `.agents/skills/execplan-hook-your-event/` with a `scripts/run_event.sh` that emits `STATUS=pass` or `STATUS=fail`.
4. Reference that event ID in an ExecPlan `Progress` action’s `hook_events`.

See `assets/default-hooks/execplan-hook-tooling/` for an example.

## Key documents

| File | Purpose |
|------|---------|
| `PLANS.md` | ExecPlan authoring and lifecycle policy |
| `REVIEW.md` | reviewer policy |
| `SKILL.md` | skill contract for the builder/reviewer loop |
| `assets/default-hooks/execplan-sandbox-escalation/references/allowed_command_prefixes.md` | approved out-of-sandbox command prefixes |

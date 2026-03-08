# eternal-cycler

An autonomous builder/reviewer loop for [Codex](https://github.com/openai/codex) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) agents. Install it as a git subtree in your repository to get:

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
│       └── execplan-hook-tooling/
└── eternal-cycler-out/
    ├── plans/
    │   ├── active/
    │   ├── completed/
    │   └── tech-debt/
    ├── user-feedback/
    └── builder-response/
```

The skill directory (`.agents/skills/eternal-cycler/`) is static at runtime. ExecPlan lifecycle artifacts live under `eternal-cycler-out/plans/`. Live operator feedback uses `eternal-cycler-out/user-feedback/` and `eternal-cycler-out/builder-response/`. Operator-maintained outside-sandbox policy changes are recorded in `.codex/rules/eternal-cycler.rules`.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `git` | version control |
| `gh` | GitHub CLI for PR operations |
| `codex` | OpenAI Codex CLI for builder/reviewer runs when `codex` is selected |
| `claude` | Claude Code CLI for builder/reviewer runs when `claude` is selected |
| `jq` | JSON parsing in loop scripts |
| `rg` | fast search in scripts and plans |
| `perl` | prompt template expansion inside the loop |

Platform support:

- Linux and macOS are supported.
- The common CLI set is `git`, `gh`, `jq`, `rg`, and `perl`.
- Install at least one agent CLI: `codex` and/or `claude`.
- On macOS, stock `/bin/bash` 3.2 is supported and GNU coreutils are not required.
- On Linux, no extra platform-specific tools are required beyond the CLI set above.

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

Setup copies the shared runtime skills, installs the Codex rules file, and creates the plan directories:

```text
[setup] OK   copied execplan-hook-pre-creation -> .agents/skills/execplan-hook-pre-creation
[setup] OK   copied execplan-hook-post-creation -> .agents/skills/execplan-hook-post-creation
[setup] OK   copied execplan-hook-resume -> .agents/skills/execplan-hook-resume
[setup] OK   copied execplan-hook-post-completion -> .agents/skills/execplan-hook-post-completion
[setup] OK   copied execplan-hook-docs-only -> .agents/skills/execplan-hook-docs-only
[setup] OK   copied execplan-hook-tooling -> .agents/skills/execplan-hook-tooling
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

Each ExecPlan caches its own runtime metadata in the plan file:

- `execplan_start_branch`
- `execplan_target_branch`
- `execplan_start_commit`
- `execplan_pr_url`
- `execplan_pr_title`
- `execplan_branch_slug`
- `execplan_take`
- optional `execplan_supersedes_plan`
- optional `execplan_supersedes_pr_url`

The current PR body is cached in the plan between:

- `<!-- execplan-pr-body:start -->`
- `<!-- execplan-pr-body:end -->`

The remote GitHub PR is authoritative for PR URL, title, body, and head/base state. The plan is authoritative for ExecPlan-local state such as actions, Hook Ledger entries, snapshots, resume records, supersede/failure records, and retrospectives.

If you want to feed follow-up instructions into a running take, use `.agents/skills/eternal-cycler/scripts/execplan_user_feedback.sh`. The caller agent writes translated English feedback items into `eternal-cycler-out/user-feedback/`, polls `status --format json`, and forwards any new builder `question` / `objection` responses to the user as intermediate output without stopping the loop. The full contract lives in `PLANS.md`.

## Usage

Use the skill in `SKILL.md` as the operator-facing entrypoint. The loop script is an internal runtime entrypoint used by that skill and is not the documented normal usage path.

Important:

- The autonomous loop invokes `codex` and/or `claude` internally as child processes outside the sandbox when those providers are selected.
- Treat this as a trusted automation path for a repository you control. Review `.codex/rules/eternal-cycler.rules` and your local provider authentication/session state before running it.

The skill handles:

- target branch resolution from `target-branch` or default `main` for new takes
- active plan selection
- launcher-aware builder/reviewer provider selection before loop start
- target-branch refresh before starting a new take or resuming a plan
- using the selected plan's recorded target branch as authoritative during resume
- passing optional task text or task files through to the loop

In practice:

- If active plans exist, the skill asks whether to resume one or start a new take.
- If the skill is running inside Claude Code and both `claude` and `codex` are installed, it asks which provider to use for builder and reviewer before starting the loop.
- If the skill is running inside Codex, builder/reviewer default to `codex` unless the user explicitly asks to use `claude` for one or both roles.
- For new takes, omitting `target-branch` means `main`.
- For resume, the selected plan's `execplan_target_branch` remains authoritative even if the user also mentions another branch.
- Follow-up instructions during a running take are written through `scripts/execplan_user_feedback.sh`; the full contract lives in `PLANS.md` and `SKILL.md`.

The loop also accepts explicit provider flags when you need to bypass skill defaults:

```bash
bash .agents/skills/eternal-cycler/scripts/run_builder_reviewer_loop.sh \
  --task-file /tmp/task.md \
  --target-branch main \
  --builder-provider claude \
  --reviewer-provider codex \
  --pr-title "feat: example" \
  --pr-body "## Summary"
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

Re-run setup after updating so the default hooks and `.codex/rules/eternal-cycler.rules` stay in sync:

```bash
bash .agents/skills/eternal-cycler/setup.sh
```

For a quick compatibility check:

```bash
bash .agents/skills/eternal-cycler/setup.sh
bash .agents/skills/eternal-cycler/scripts/run_builder_reviewer_loop.sh --help
bash .agents/skills/eternal-cycler/tests/execplan_tests.sh
```

On macOS, use `/bin/bash` instead of `bash` if you want to validate the stock system shell explicitly.

## Adding custom hooks

The gate script resolves hook scripts from `.agents/skills/` in your repository.

1. Pick an event ID such as `hook.your-event`.
2. Follow the hook naming/path rules in `PLANS.md` as the single source of truth.
3. Create `.agents/skills/execplan-hook-your-event/` with a `scripts/run_event.sh` that emits `STATUS=pass` or `STATUS=fail`.
4. Reference that event ID in an ExecPlan `Progress` action’s `hook_events`.

See `assets/default-hooks/execplan-hook-tooling/` for an example.

## Key documents

| File | Purpose |
|------|---------|
| `PLANS.md` | ExecPlan authoring and lifecycle policy |
| `REVIEW.md` | reviewer policy |
| `SKILL.md` | skill contract for the builder/reviewer loop |
| `eternal-cycler.rules` | approved outside-sandbox command prefixes for trusted runtime/manual escalation |

# Repository Guidelines

## Autonomous PR Loop Rule
- When directly invoked by a human user, run the `pr-autoloop` skill by default unless the user explicitly says not to run it. In that mode, do not execute, propose, inspect, or otherwise pay attention to anything outside the `pr-autoloop` workflow.
- When called by a parent Codex agent as a `builder agent`, start and execute the ExecPlan lifecycle exactly as defined in `PLANS.md`.
- When called by a parent Codex agent as a `reviewer agent`, execute review work exactly as defined in `REVIEW.md`.


## Meta Rules
The following documents define *meta-rules* for how agents should create, update, and reference documents. Agents must carefully read and understand them.

### Plans (PLANS.md)
Read PLANS.md before starting any new task. You must write an ExecPlan following this document from design through implementation.

### Verification (PLANS.md + repository-local verification scripts)
Read `PLANS.md` verification sections before implementation to determine verification policy and enforcement requirements, especially when:
- adding new features, changing behavior, or touching performance/correctness-critical code,
- modifying tests/CI, introducing new test categories, or changing required checks.
ExecPlan verification execution must use repository-local verification scripts under `assets/verification/execplan-event-*/` plus index mapping under `assets/verification/execplan-event-index/`, and gate/notify scripts under `scripts/`.

**Path resolution note:** All paths in this document are relative to this file's location (the eternal-cycler installation root). When this repository is installed as a subtree or skill at a non-root path (e.g. `.agents/eternal-cycler/`), prefix every path with that installation prefix. The parent loop script injects the correct prefix into your prompt under "Path context".

### Review (REVIEW.md)
Read REVIEW.md when you are asked to review a PR or to act as a reviewer.
In reviewer mode, follow REVIEW.md as the governing policy for independent review posture, required checks, and GitHub PR comment reporting.

## Global Requirements
- All documentation in this repository, along with git commit messages and PRs, must be written in English.
- When documenting file paths, use only paths relative to the repository top directory. Do not write absolute paths in documentation.

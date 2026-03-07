---
name: execplan-hook-resume
description: Hook for execplan.resume. Run when resuming an existing ExecPlan to validate branch consistency and record a resume record in the plan.
---

# Hook: execplan.resume

This hook executes the "resume existing plan" workflow:

- read `execplan_start_branch` from the plan and verify that the current branch matches,
- refresh the inline `execplan-metadata` and `execplan-pr-body` blocks from the existing PR,
- append an `## ExecPlan Resume Record` section to the plan (idempotent per resume commit).

Requires `--plan`. Branch management is the caller's responsibility.

Execution policy:

- This event must be executed out-of-sandbox.
- Run through gate as: `scripts/execplan_gate.sh --plan <plan_md> --event execplan.resume`.

## Script

- `scripts/run_event.sh --plan <plan_md>`

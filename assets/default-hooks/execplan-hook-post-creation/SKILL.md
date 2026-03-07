---
name: execplan-hook-post-creation
description: Hook for execplan.post_creation. Run immediately after the ExecPlan document is created to record the start snapshot and inline ExecPlan metadata.
---

# Hook: execplan.post_creation

This hook executes the "after plan document creation" workflow:

- append `execplan_start_branch` and `execplan_start_commit` markers to the plan (idempotent),
- append an `## ExecPlan Start Snapshot` section with tracked and untracked file snapshots (idempotent),
- refresh the inline `execplan-metadata` block with branch / target branch / PR fields,
- refresh the inline `execplan-pr-body` block with the current PR body.

Requires `--plan`. Branch management is the caller's responsibility.

Execution policy:

- This event must be executed out-of-sandbox.
- Run through gate as: `scripts/execplan_gate.sh --plan <plan_md> --event execplan.post_creation`.

## Script

- `scripts/run_event.sh --plan <plan_md>`

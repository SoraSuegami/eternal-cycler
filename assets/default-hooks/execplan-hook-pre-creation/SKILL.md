---
name: execplan-hook-pre-creation
description: Hook for execplan.pre_creation. Lightweight environment check before the ExecPlan document is created, plus creation of the branch-named empty plan file.
---

# Hook: execplan.pre_creation

This hook executes a lightweight environment check before the ExecPlan document is created:

- capture branch/status/log context,
- query PR context when `gh` is available.
- create the empty plan file at `eternal-cycler-out/plans/active/<current-branch>.md` if it does not already exist.

This event takes **no arguments** — `--plan` is not accepted because the plan file does not exist yet. Branch management is the caller's responsibility.

After creating the plan document, run `execplan.post_creation` (which requires `--plan`) to record the start snapshot and inline ExecPlan metadata.

Execution policy:

- This event must be executed out-of-sandbox.
- Run through gate as: `scripts/execplan_gate.sh --event execplan.pre_creation` (no `--plan`).

## Script

- `scripts/run_event.sh`

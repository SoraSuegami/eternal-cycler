---
name: execplan-hook-post-completion
description: Hook for execplan.post-completion. Use after plan document finalization to enforce validation-only completion checks.
---

# Hook: execplan.post-completion

This hook executes the "after main ExecPlan completion" workflow:

- validate ledger completion prerequisites,
- validate the inline ExecPlan metadata and PR body blocks stored in the plan,
- ensure no unresolved progress actions or unresolved latest hook events remain,
- verify start snapshot markers are present in the plan,
- require that the input plan is still under `eternal-cycler-out/plans/active/`,
- do not run `git add`, `git commit`, or `git push` in this event.

Execution policy:

- This event must be executed out-of-sandbox.
- Run through gate as: `scripts/execplan_gate.sh --plan <active_plan_md> --event execplan.post-completion` with out-of-sandbox execution.
- Do not run this event inside sandbox; the lifecycle policy requires this gate to execute out-of-sandbox even though the current default hook only inspects plan content and local Git state.
- This hook does not verify whether implementation commits were pushed. In loop-managed execution, the builder runs this hook before it returns success; the loop then only verifies the resulting completed plan and continues with its normal checkpoint/finalization commit-push behavior without invoking further builder edits.

## Script

- `scripts/run_event.sh --plan <plan_md>`

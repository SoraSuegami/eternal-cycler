---
name: execplan-sandbox-escalation
description: Policy skill for out-of-sandbox command execution during ExecPlan actions and verification. Use this before requesting any new sandbox escalation.
---

# ExecPlan Sandbox Escalation

This skill defines the required workflow for out-of-sandbox command execution during ExecPlan action execution and validation.
This is a mandatory skill: do not execute any out-of-sandbox command before applying this skill workflow.
Current implementation note: `execplan_gate.sh` does not independently audit allowlist lookup or approval provenance, so this policy must be enforced by the caller and reviewer from the recorded commands and repo context.

## When to use

Use this skill whenever a command cannot run inside sandbox constraints and out-of-sandbox execution is required.

## Workflow

1. Read `.codex/rules/eternal-cycler.rules` first.
2. Read `references/allowed_command_prefixes.md`.
3. Check whether the required operation can be implemented with an existing allowed prefix.
4. For any `gh` command family operation, prefer out-of-sandbox execution by default, even when a sandbox attempt might intermittently work.
5. Always execute `execplan.pre_creation` and `execplan.post_completion` gate commands out-of-sandbox. This is a lifecycle policy requirement; `execplan.pre_creation` may consult GitHub state, while the current default `execplan.post_completion` hook only inspects plan content and local Git state.
6. If yes, run the existing allowed command path and continue.
7. If no, request human operator approval for the new out-of-sandbox command.
8. After approval, add the narrowest safely generalized prefix to `references/allowed_command_prefixes.md`.
9. Record the command usage and result in the current ExecPlan `Hook Ledger`. If you add a new prefix entry, also record rationale in the `Decision Log`.

## Safety constraints

- Prefer least-privilege prefixes over broad prefixes.
- Do not request a broad prefix when a narrower reusable prefix can satisfy the same task.
- Keep the allowlist maintainable by documenting why existing prefixes were insufficient.

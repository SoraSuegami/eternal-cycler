# Allowed Out-of-Sandbox Command Prefixes

This allowlist is used by the `execplan-sandbox-escalation` skill.

Before requesting a new out-of-sandbox command approval, verify whether one of these prefixes can safely satisfy the task.

## Pre-approved prefixes

Policy note: `gh` prefixed commands are expected to run out-of-sandbox by default for stable GitHub API access.

Path note: prefixes beginning with `scripts/` or `.agents/` are relative to the eternal-cycler installation root (injected into your prompt as `Path context`). When eternal-cycler is installed as a subtree at a non-root path (e.g. `.agents/eternal-cycler/`), prefix those entries with that installation path.

- `git status --short`
- `git branch --show-current`
- `git add -A`
- `git commit -m`
- `git push`
- `gh pr view`
- `gh pr checks`
- `gh pr comment`
- `gh pr create`
- `gh pr ready`
- `gh pr status`
- `gh pr edit`
- `gh api graphql`
- `mv assets/prs/active/`
- `mkdir -p assets/prs/active`
- `scripts/execplan_gate.sh --event execplan.pre_creation`
- `scripts/execplan_gate.sh --plan`
- `scripts/run_builder_reviewer_doctor.sh`
- `scripts/run_builder_reviewer_loop.sh`

## Entry requirements for new prefixes

When adding a new prefix, include:

- exact prefix pattern,
- why existing prefixes were insufficient,
- why the new prefix is the safest reusable generalization.

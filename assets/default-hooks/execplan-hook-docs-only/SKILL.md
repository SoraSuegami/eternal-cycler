---
name: execplan-hook-docs-only
description: Hook backing hook.docs-only. Use when a Progress action modifies only docs/policy paths, including rules files.
---

# Hook: hook.docs-only

This hook validates docs-only Progress action scope and policy hygiene:

- ensure changed files are documentation-only paths,
- allow rules/policy paths such as `*.rules` and `.codex/rules/**`,
- scan for stale policy placeholders (`TODO|TBD|FIXME`) in documentation/policy files.

## Script

- `scripts/run_event.sh --plan <plan_md>`

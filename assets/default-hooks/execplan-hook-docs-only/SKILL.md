---
name: execplan-hook-docs-only
description: Hook backing hook.docs_only. Use when a Progress action modifies only docs/policy paths.
---

# Hook: hook.docs_only

This hook validates docs-only Progress action scope and policy hygiene:

- ensure changed files are documentation-only paths,
- scan for stale policy placeholders (`TODO|TBD|FIXME`) in documentation/policy files.

## Script

- `scripts/run_event.sh --plan <plan_md>`

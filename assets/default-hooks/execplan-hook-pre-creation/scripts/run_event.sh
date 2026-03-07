#!/usr/bin/env bash
set -euo pipefail

# execplan.pre_creation — lightweight environment check run before the plan file exists.
# --plan is not accepted; branch management is the caller's responsibility.
# Records git state, seeds the branch-named plan file, and returns pass.
# Follow with execplan.post_creation after writing the plan.

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: run_event.sh"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
ETERNAL_CYCLER_ROOT="${ETERNAL_CYCLER_ROOT:-}"
if [[ -z "$ETERNAL_CYCLER_ROOT" ]]; then
  echo "COMMANDS=none"
  echo "FAILURE_SUMMARY=ETERNAL_CYCLER_ROOT is not set; run through execplan_gate.sh"
  echo "STATUS=fail"
  exit 1
fi

# shellcheck source=/dev/null
source "$ETERNAL_CYCLER_ROOT/scripts/execplan_plan_metadata.sh"

commands=()
commands+=("git branch --show-current")
commands+=("git status --short")
commands+=("git log --oneline --decorate --max-count=20")

branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=failed to resolve current branch"
  echo "STATUS=fail"
  exit 1
fi

git status --short >/dev/null
git log --oneline --decorate --max-count=20 >/dev/null

if command -v gh >/dev/null 2>&1; then
  commands+=("gh pr status")
  set +e
  gh pr status >/dev/null 2>&1
  set -e
fi

plan_rel_path="$(plan_rel_path_for_branch "$branch")"
plan_abs_path="$(plan_abs_path_for_branch "$REPO_ROOT" "$branch")"
plan_dir="$(dirname "$plan_abs_path")"

commands+=("mkdir -p $(repo_rel_path "$REPO_ROOT" "$plan_dir")")
mkdir -p "$plan_dir"

if [[ -e "$plan_abs_path" && ! -f "$plan_abs_path" ]]; then
  echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
  echo "FAILURE_SUMMARY=plan path exists but is not a regular file: ${plan_rel_path}"
  echo "STATUS=fail"
  exit 1
fi

commands+=("touch ${plan_rel_path}")
if [[ ! -e "$plan_abs_path" ]]; then
  : > "$plan_abs_path"
fi

echo "COMMANDS=$(IFS=' | '; echo "${commands[*]}")"
echo "FAILURE_SUMMARY=none"
echo "STATUS=pass"

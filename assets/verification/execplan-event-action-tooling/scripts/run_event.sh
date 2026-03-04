#!/usr/bin/env bash
set -euo pipefail

# SUBMODULE_ROOT: eternal-cycler installation root (3 levels up from this script).
# Works correctly whether eternal-cycler is the repo root or a subtree.
SUBMODULE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

PLAN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: run_event.sh --plan <plan_md>"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PLAN" || ! -f "$PLAN" ]]; then
  echo "COMMANDS=none"
  echo "FAILURE_SUMMARY=plan file not found"
  echo "STATUS=fail"
  exit 1
fi

commands="bash -n ${SUBMODULE_ROOT}/scripts/*.sh ${SUBMODULE_ROOT}/assets/verification/execplan-event-*/scripts/*.sh"

if ! bash -n "${SUBMODULE_ROOT}"/scripts/*.sh "${SUBMODULE_ROOT}"/assets/verification/execplan-event-*/scripts/*.sh; then
  echo "COMMANDS=$commands"
  echo "FAILURE_SUMMARY=tooling script syntax check failed"
  echo "STATUS=fail"
  exit 1
fi

echo "COMMANDS=$commands"
echo "FAILURE_SUMMARY=none"
echo "STATUS=pass"

#!/usr/bin/env bash
# Verify prerequisites after adding eternal-cycler via git subtree or as a standalone copy.
# Run from anywhere inside the consuming repository:
#   bash .agents/eternal-cycler/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SUBMODULE_REL="$(realpath --relative-to="$REPO_ROOT" "$SCRIPT_DIR")"

log()  { echo "[setup] $*"; }
warn() { echo "[setup] WARN: $*" >&2; }

log "eternal-cycler path: ${SUBMODULE_REL}/"
log "git repo root:       ${REPO_ROOT}/"
echo

# Check that key scripts are executable
LOOP_SCRIPT="$SCRIPT_DIR/scripts/run_builder_reviewer_loop.sh"
if [[ -x "$LOOP_SCRIPT" ]]; then
  log "OK  run_builder_reviewer_loop.sh is executable"
else
  warn "run_builder_reviewer_loop.sh not executable; run:"
  warn "  chmod +x ${SUBMODULE_REL}/scripts/run_builder_reviewer_loop.sh"
fi

DOCTOR_SCRIPT="$SCRIPT_DIR/scripts/run_builder_reviewer_doctor.sh"
if [[ -x "$DOCTOR_SCRIPT" ]]; then
  log "OK  run_builder_reviewer_doctor.sh is executable"
else
  warn "run_builder_reviewer_doctor.sh not executable; run:"
  warn "  chmod +x ${SUBMODULE_REL}/scripts/run_builder_reviewer_doctor.sh"
fi

GATE_SCRIPT="$SCRIPT_DIR/scripts/execplan_gate.sh"
if [[ -x "$GATE_SCRIPT" ]]; then
  log "OK  execplan_gate.sh is executable"
else
  warn "execplan_gate.sh not executable; run: chmod +x ${SUBMODULE_REL}/scripts/execplan_gate.sh"
fi

# Check for required CLIs
for bin in git gh codex jq rg; do
  if command -v "$bin" >/dev/null 2>&1; then
    log "OK  $bin found"
  else
    warn "$bin not found (required for pr-autoloop)"
  fi
done
echo


log "Setup check complete."
log ""
log "To start the builder/reviewer loop:"
log "  ${SUBMODULE_REL}/scripts/run_builder_reviewer_loop.sh \\"
log "    --task 'describe the task here'"

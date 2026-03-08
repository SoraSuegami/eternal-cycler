#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  run_builder_reviewer_doctor.sh [--pr-url <url> | --head-branch <branch>] [--builder-provider <provider>] [--reviewer-provider <provider>] [--offline-ok]
  run_builder_reviewer_doctor.sh --help

Checks:
  - required CLIs (`git`, `gh`, `jq`, `rg`, and selected agent CLIs)
  - `gh auth status`
  - `codex login status` when Codex is selected
  - `claude auth status` when Claude is selected
  - `claude doctor` when Claude is selected
  - PR metadata access (`gh pr view`) when `--pr-url` is provided
  - PR discovery access by head branch when `--head-branch` is provided
USAGE
}

PR_URL=""
HEAD_BRANCH=""
OFFLINE_OK=0
BUILDER_PROVIDER="${ETERNAL_CYCLER_BUILDER_PROVIDER:-codex}"
REVIEWER_PROVIDER="${ETERNAL_CYCLER_REVIEWER_PROVIDER:-codex}"

resolve_current_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    return 1
  fi
  printf '%s\n' "$branch"
}

is_supported_provider() {
  [[ "$1" == "codex" || "$1" == "claude" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url)
      PR_URL="${2:-}"
      shift 2
      ;;
    --head-branch)
      HEAD_BRANCH="${2:-}"
      shift 2
      ;;
    --builder-provider)
      BUILDER_PROVIDER="${2:-}"
      shift 2
      ;;
    --reviewer-provider)
      REVIEWER_PROVIDER="${2:-}"
      shift 2
      ;;
    --offline-ok)
      OFFLINE_OK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$PR_URL" && -n "$HEAD_BRANCH" ]]; then
  echo "--pr-url and --head-branch are mutually exclusive" >&2
  exit 2
fi

if [[ -z "$PR_URL" && -z "$HEAD_BRANCH" ]]; then
  HEAD_BRANCH="$(resolve_current_branch || true)"
fi

if [[ -z "$PR_URL" && -z "$HEAD_BRANCH" ]]; then
  echo "either --pr-url or --head-branch is required (or run from a named branch)" >&2
  usage >&2
  exit 2
fi

if ! is_supported_provider "$BUILDER_PROVIDER"; then
  echo "unsupported builder provider: $BUILDER_PROVIDER" >&2
  exit 2
fi
if ! is_supported_provider "$REVIEWER_PROVIDER"; then
  echo "unsupported reviewer provider: $REVIEWER_PROVIDER" >&2
  exit 2
fi

missing=0
for bin in git gh jq rg; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[FAIL] missing command: $bin" >&2
    missing=1
  else
    echo "[OK] found command: $bin"
  fi
done
if [[ "$BUILDER_PROVIDER" == "codex" || "$REVIEWER_PROVIDER" == "codex" ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    echo "[FAIL] missing command: codex" >&2
    missing=1
  else
    echo "[OK] found command: codex"
  fi
fi
if [[ "$BUILDER_PROVIDER" == "claude" || "$REVIEWER_PROVIDER" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "[FAIL] missing command: claude" >&2
    missing=1
  else
    echo "[OK] found command: claude"
  fi
fi
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

hard_fail=0
warn_count=0

run_check() {
  local label="$1"
  shift
  local out_file
  local rc
  local summary

  out_file="$(mktemp)"

  set +e
  "$@" >"$out_file" 2>&1
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "[OK] $label"
    rm -f "$out_file"
    return 0
  fi

  summary="$(head -n 1 "$out_file" | sed -E 's/[[:space:]]+/ /g')"
  if [[ "$OFFLINE_OK" -eq 1 ]] && grep -Eqi 'error connecting|network|timed out|connection refused|could not resolve host|api.github.com' "$out_file"; then
    echo "[WARN] $label (offline tolerated): ${summary:-unknown error}"
    warn_count=$((warn_count + 1))
    rm -f "$out_file"
    return 0
  fi

  echo "[FAIL] $label: ${summary:-unknown error}" >&2
  cat "$out_file" >&2
  hard_fail=1
  rm -f "$out_file"
  return 1
}

run_check "GitHub authentication" gh auth status
if [[ "$BUILDER_PROVIDER" == "codex" || "$REVIEWER_PROVIDER" == "codex" ]]; then
  run_check "Codex authentication" codex login status
fi
if [[ "$BUILDER_PROVIDER" == "claude" || "$REVIEWER_PROVIDER" == "claude" ]]; then
  run_check "Claude authentication" claude auth status
  run_check "Claude doctor" claude doctor
fi

if [[ -n "$PR_URL" ]]; then
  run_check "PR metadata access" gh pr view "$PR_URL" --json number,url,state,mergedAt,headRefName,baseRefName,isDraft
else
  if git show-ref --verify --quiet "refs/heads/$HEAD_BRANCH" || git ls-remote --exit-code --heads origin "$HEAD_BRANCH" >/dev/null 2>&1; then
    echo "[OK] head branch is visible: $HEAD_BRANCH"
  else
    echo "[FAIL] head branch is not visible locally or on origin: $HEAD_BRANCH" >&2
    hard_fail=1
  fi

  run_check "PR discovery access by head branch" gh pr list --head "$HEAD_BRANCH" --state all --json number,url,headRefName,state,isDraft,mergedAt --limit 20
fi

if [[ "$hard_fail" -ne 0 ]]; then
  echo "doctor result: FAIL" >&2
  exit 1
fi

echo "doctor result: PASS"
echo "warnings: $warn_count"

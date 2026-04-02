#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DIR="$SCRIPT_DIR"
COMMON_SCRIPT=""
while [[ -n "$CURRENT_DIR" && "$CURRENT_DIR" != "$(dirname "$CURRENT_DIR")" ]]; do
  CANDIDATE="$CURRENT_DIR/scripts/deploy/common/deployment-scaffold.sh"
  if [[ -f "$CANDIDATE" ]]; then
    COMMON_SCRIPT="$CANDIDATE"
    break
  fi
  CURRENT_DIR="$(dirname "$CURRENT_DIR")"
done

if [[ -z "$COMMON_SCRIPT" ]]; then
  printf 'Unable to locate deployment-scaffold.sh from %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$COMMON_SCRIPT"
invoke_bash_deployment "$0" '04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion' 'az-verify-cluster-ad' "$@"

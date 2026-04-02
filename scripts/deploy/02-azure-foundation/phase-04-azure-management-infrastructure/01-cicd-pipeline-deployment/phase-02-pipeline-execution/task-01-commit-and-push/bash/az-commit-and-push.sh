#!/usr/bin/env bash
# ==============================================================================
# Script:  az-commit-and-push.sh
# Purpose: Stage, commit, and push Terraform configuration changes to trigger
#          the CI/CD pipeline for Phase 04 management infrastructure.
# Usage:   ./az-commit-and-push.sh [--path <project-dir>] [--branch <branch>]
#          [--message "Custom commit message"]
# ==============================================================================

set -euo pipefail

PROJECT_PATH="."
BRANCH="main"
COMMIT_MESSAGE="Deploy Phase 04 management infrastructure: VPN, Key Vault, DNS, monitoring"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    PROJECT_PATH="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --message) COMMIT_MESSAGE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

cd "$PROJECT_PATH"

echo "=== Pre-commit status ==="
git status

echo ""
echo "=== Pending changes in terraform.tfvars ==="
git diff terraform.tfvars 2>/dev/null || echo "(no changes or file not tracked yet)"

echo ""
echo "Staging files..."
git add terraform.tfvars 2>/dev/null || true
git add terraform/ 2>/dev/null || true
git add .

echo ""
echo "=== Staged changes ==="
git diff --cached --stat

echo ""
echo "Committing..."
git commit -m "$COMMIT_MESSAGE"

echo ""
echo "Pushing to origin/$BRANCH..."
git push origin "$BRANCH"

echo ""
echo "Push complete. Monitor your CI/CD pipeline for deployment status."

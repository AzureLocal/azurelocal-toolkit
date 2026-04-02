#!/usr/bin/env bash
# ==============================================================================
# Script:  az-bootstrap-cicd-sp.sh
# Purpose: Create the CI/CD service principal and configure Azure access
# Usage:   ./az-bootstrap-cicd-sp.sh
# Prereqs: Azure CLI authenticated (az login), Application Administrator role
# ==============================================================================

set -euo pipefail

# ── Variables ─────────────────────────────────────────────────────────────────
APP_NAME="azurelocal-cicd"
SUBSCRIPTION_IDS=("subscription-id-1" "subscription-id-2")  # Edit these

# ── Step 1: Create app registration and service principal ─────────────────────
az ad app create --display-name "$APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)

az ad sp create --id "$APP_ID"

SECRET=$(az ad app credential reset --id "$APP_ID" --years 2 --query "password" -o tsv)

TENANT_ID=$(az account show --query "tenantId" -o tsv)

echo "ARM_CLIENT_ID:     $APP_ID"
echo "ARM_CLIENT_SECRET: $SECRET"
echo "ARM_TENANT_ID:     $TENANT_ID"
echo ""
echo "IMPORTANT: Save ARM_CLIENT_SECRET now — it cannot be retrieved again."

# ── Step 2: Assign RBAC roles ─────────────────────────────────────────────────
for SUB_ID in "${SUBSCRIPTION_IDS[@]}"; do
  az role assignment create \
    --assignee "$APP_ID" \
    --role "Contributor" \
    --scope "/subscriptions/$SUB_ID"

  az role assignment create \
    --assignee "$APP_ID" \
    --role "User Access Administrator" \
    --scope "/subscriptions/$SUB_ID"
done

# ── Step 3: Register providers and features ───────────────────────────────────
for SUB_ID in "${SUBSCRIPTION_IDS[@]}"; do
  az account set --subscription "$SUB_ID"

  az provider register --namespace "Microsoft.Compute"

  az feature register \
    --namespace "Microsoft.Compute" \
    --name "EncryptionAtHost"
done

# ── Step 4: Add Microsoft Graph API permissions ───────────────────────────────
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
ROLE_MGMT_ID="9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8"

az ad app permission add \
  --id "$APP_ID" \
  --api "$GRAPH_APP_ID" \
  --api-permissions "$ROLE_MGMT_ID=Role"

# ── Step 5: Grant admin consent ───────────────────────────────────────────────
az ad app permission admin-consent --id "$APP_ID"

echo ""
echo "Bootstrap complete. Store credentials in your CI/CD platform (Task 05)."

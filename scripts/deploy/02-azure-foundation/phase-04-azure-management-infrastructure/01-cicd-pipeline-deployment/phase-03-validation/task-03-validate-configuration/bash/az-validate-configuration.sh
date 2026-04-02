#!/usr/bin/env bash
# ==============================================================================
# Script:  az-validate-configuration.sh
# Purpose: Validate Phase 04 management infrastructure configuration — Key Vault
#          secrets, diagnostic settings, and resource tags.
# Usage:   ./az-validate-configuration.sh
# Prereqs: az login; config/variables.yml present
# ==============================================================================

set -euo pipefail

CONFIG_FILE="./config/variables.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found at $CONFIG_FILE"
  exit 1
fi

get_yaml() { grep "^  $1:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"'; }

RESOURCE_GROUP=$(get_yaml "resource_group")
KEY_VAULT_NAME=$(get_yaml "key_vault_name")
LOG_ANALYTICS_WS=$(get_yaml "log_analytics_workspace_id")

ERRORS=0

echo "======================================================"
echo " Validating Phase 04 Management Infrastructure Config"
echo "======================================================"

# ── Key Vault: write a config-validation secret ───────────────────────────────
echo ""
echo "[1/4] Validating Key Vault access: $KEY_VAULT_NAME"

SECRET_NAME="config-validation-test"
SECRET_VALUE="validated-$(date +%Y%m%d%H%M%S)"

az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$SECRET_NAME" \
  --value "$SECRET_VALUE" \
  --output none

READ_BACK=$(az keyvault secret show \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$SECRET_NAME" \
  --query "value" -o tsv)

if [[ "$READ_BACK" == "$SECRET_VALUE" ]]; then
  echo "  [PASS] Key Vault read/write validated"
else
  echo "  [FAIL] Key Vault round-trip mismatch"
  ERRORS=$((ERRORS + 1))
fi

# ── Diagnostic settings ───────────────────────────────────────────────────────
echo ""
echo "[2/4] Checking diagnostic settings in resource group: $RESOURCE_GROUP"
DIAG_COUNT=$(az monitor diagnostic-settings list \
  --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP" \
  --query "length(value)" -o tsv 2>/dev/null || echo "0")

if [[ "$DIAG_COUNT" -gt 0 ]]; then
  echo "  [PASS] Found $DIAG_COUNT diagnostic setting(s)"
else
  echo "  [WARN] No diagnostic settings found on resource group"
fi

# ── Resource tags ──────────────────────────────────────────────────────────────
echo ""
echo "[3/4] Verifying resource tags in: $RESOURCE_GROUP"
az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --query '[].{Name:name, Tags:tags}' \
  -o table

# ── Log Analytics workspace ───────────────────────────────────────────────────
echo ""
echo "[4/4] Verifying Log Analytics workspace connectivity"
WS_STATE=$(az monitor log-analytics workspace show \
  --ids "$LOG_ANALYTICS_WS" \
  --query "provisioningState" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$WS_STATE" == "Succeeded" ]]; then
  echo "  [PASS] Log Analytics workspace provisioned"
else
  echo "  [FAIL] Log Analytics workspace state: $WS_STATE"
  ERRORS=$((ERRORS + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
if [[ $ERRORS -eq 0 ]]; then
  echo " CONFIGURATION VALIDATION PASSED (0 errors)"
else
  echo " CONFIGURATION VALIDATION FAILED ($ERRORS errors)"
  exit 1
fi
echo "======================================================"

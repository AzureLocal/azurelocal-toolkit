#!/usr/bin/env bash
# ==============================================================================
# Script:  az-verify-resources.sh
# Purpose: Verify that Phase 04 management infrastructure resources were
#          deployed successfully (VPN gateway, Key Vault secrets).
# Usage:   ./az-verify-resources.sh
# Prereqs: az login; variables loaded from config/variables.yml or env vars
# ==============================================================================

set -euo pipefail

CONFIG_FILE="./config/variables.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found at $CONFIG_FILE"
  exit 1
fi

get_yaml() { grep "^  $1:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"'; }

RESOURCE_GROUP=$(get_yaml "resource_group")
VPN_GATEWAY_NAME=$(get_yaml "vpn_gateway_name")
KEY_VAULT_NAME=$(get_yaml "key_vault_name")

ERRORS=0

echo "======================================================"
echo " Verifying Phase 04 Management Infrastructure"
echo "======================================================"

# ── VPN Gateway ───────────────────────────────────────────────────────────────
echo ""
echo "[1/3] Checking VPN Gateway: $VPN_GATEWAY_NAME"
VPN_PROV=$(az network vnet-gateway show \
  --name "$VPN_GATEWAY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "provisioningState" -o tsv 2>/dev/null || echo "Not Found")

if [[ "$VPN_PROV" == "Succeeded" ]]; then
  echo "  [PASS] VPN Gateway provisioning state: Succeeded"
else
  echo "  [FAIL] VPN Gateway state: $VPN_PROV"
  ERRORS=$((ERRORS + 1))
fi

# ── Key Vault: write test secret ──────────────────────────────────────────────
echo ""
echo "[2/3] Testing Key Vault write access: $KEY_VAULT_NAME"
TEST_SECRET_NAME="verify-deployment-test"
TEST_SECRET_VALUE="deployment-verified-$(date +%Y%m%d%H%M%S)"

az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$TEST_SECRET_NAME" \
  --value "$TEST_SECRET_VALUE" \
  --output none && echo "  [PASS] Secret write succeeded" \
  || { echo "  [FAIL] Secret write failed"; ERRORS=$((ERRORS + 1)); }

# ── Key Vault: read test secret ───────────────────────────────────────────────
echo ""
echo "[3/3] Testing Key Vault read access"
READ_VALUE=$(az keyvault secret show \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$TEST_SECRET_NAME" \
  --query "value" -o tsv 2>/dev/null || echo "")

if [[ "$READ_VALUE" == "$TEST_SECRET_VALUE" ]]; then
  echo "  [PASS] Secret read/write round-trip verified"
else
  echo "  [FAIL] Secret read returned unexpected value: $READ_VALUE"
  ERRORS=$((ERRORS + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
if [[ $ERRORS -eq 0 ]]; then
  echo " VERIFICATION PASSED (0 errors)"
else
  echo " VERIFICATION FAILED ($ERRORS errors)"
  exit 1
fi
echo "======================================================"

#!/usr/bin/env bash
# ==============================================================================
# Script:  az-create-subscriptions.sh
# Purpose: Create Azure subscriptions and associate them to management groups.
#          Supports Enterprise Agreement (EA) and Microsoft Customer Agreement (MCA).
# Usage:   ./az-create-subscriptions.sh --agreement ea|mca
# ==============================================================================

set -euo pipefail

AGREEMENT="ea"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agreement) AGREEMENT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Load config values ────────────────────────────────────────────────────────
CONFIG_FILE="./config/variables.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found at $CONFIG_FILE"
  exit 1
fi

# Parse required values from YAML (simple grep-based; adjust if using yq)
get_yaml() { grep "^  $1:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"'; }

TENANT_ID=$(get_yaml "tenant_id")
PLATFORM_MG=$(get_yaml "platform_mg_name")
LANDING_ZONE_MG=$(get_yaml "landing_zone_mg_name")
SANDBOX_MG=$(get_yaml "sandbox_mg_name")

# ── Get billing scope ─────────────────────────────────────────────────────────
if [[ "$AGREEMENT" == "ea" ]]; then
  echo "Retrieving EA enrollment account..."
  ENROLLMENT_ACCOUNT=$(az billing enrollment-account list \
    --query "[0].name" -o tsv)
  BILLING_SCOPE="/providers/Microsoft.Billing/enrollmentAccounts/${ENROLLMENT_ACCOUNT}"
elif [[ "$AGREEMENT" == "mca" ]]; then
  echo "Retrieving MCA billing profile..."
  BILLING_ACCOUNT=$(az billing account list \
    --query "[0].name" -o tsv)
  BILLING_PROFILE=$(az billing profile list \
    --account-name "$BILLING_ACCOUNT" \
    --query "[0].name" -o tsv)
  INVOICE_SECTION=$(az billing invoice section list \
    --account-name "$BILLING_ACCOUNT" \
    --profile-name "$BILLING_PROFILE" \
    --query "[0].name" -o tsv)
  BILLING_SCOPE="/providers/Microsoft.Billing/billingAccounts/${BILLING_ACCOUNT}/billingProfiles/${BILLING_PROFILE}/invoiceSections/${INVOICE_SECTION}"
else
  echo "ERROR: --agreement must be 'ea' or 'mca'"
  exit 1
fi

echo "Using billing scope: $BILLING_SCOPE"

# ── Subscription definitions ─────────────────────────────────────────────────
declare -A SUB_MG
SUB_MG["identity"]="$PLATFORM_MG"
SUB_MG["management"]="$PLATFORM_MG"
SUB_MG["connectivity"]="$PLATFORM_MG"
SUB_MG["corp"]="$LANDING_ZONE_MG"
SUB_MG["online"]="$LANDING_ZONE_MG"

declare -A SUB_DISPLAY
SUB_DISPLAY["identity"]="Identity Subscription"
SUB_DISPLAY["management"]="Management Subscription"
SUB_DISPLAY["connectivity"]="Connectivity Subscription"
SUB_DISPLAY["corp"]="Corp Landing Zone"
SUB_DISPLAY["online"]="Online Landing Zone"

# ── Create subscriptions ──────────────────────────────────────────────────────
for SUB_KEY in identity management connectivity corp online; do
  DISPLAY=${SUB_DISPLAY[$SUB_KEY]}
  MG=${SUB_MG[$SUB_KEY]}

  echo ""
  echo "Creating subscription: $DISPLAY..."
  SUB_ID=$(az account create \
    --display-name "$DISPLAY" \
    --billing-scope "$BILLING_SCOPE" \
    --query "subscriptionId" -o tsv)

  echo "  Created: $SUB_ID"
  echo "  Associating to management group: $MG..."

  az account management-group subscription add \
    --name "$MG" \
    --subscription "$SUB_ID"

  echo "  Done."
done

echo ""
echo "All subscriptions created and associated to management groups."

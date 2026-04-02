#!/usr/bin/env bash
# ==============================================================================
# Script:  az-test-connectivity.sh
# Purpose: Test VPN, BGP, and DNS connectivity for Phase 04 management
#          infrastructure.
# Usage:   ./az-test-connectivity.sh
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
VPN_GATEWAY_NAME=$(get_yaml "vpn_gateway_name")
VPN_CONNECTION_NAME=$(get_yaml "vpn_connection_name")
ON_PREM_HOST=$(get_yaml "on_prem_test_host")
DNS_SERVER=$(get_yaml "dns_server")
TEST_FQDN=$(get_yaml "test_fqdn")

ERRORS=0

echo "======================================================"
echo " Testing Phase 04 Management Infrastructure Connectivity"
echo "======================================================"

# ── VPN connection status ────────────────────────────────────────────────────
echo ""
echo "[1/4] VPN Connection status: $VPN_CONNECTION_NAME"
VPN_STATUS=$(az network vpn-connection show \
  --name "$VPN_CONNECTION_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "connectionStatus" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$VPN_STATUS" == "Connected" ]]; then
  echo "  [PASS] VPN connection status: Connected"
else
  echo "  [FAIL] VPN connection status: $VPN_STATUS"
  ERRORS=$((ERRORS + 1))
fi

# ── BGP peer status ───────────────────────────────────────────────────────────
echo ""
echo "[2/4] BGP peer status on gateway: $VPN_GATEWAY_NAME"
BGP_OUTPUT=$(az network vnet-gateway list-bgp-peer-status \
  --name "$VPN_GATEWAY_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "value[].{Peer:neighbor, State:connectedDuration, Routes:routesReceived}" \
  -o table 2>/dev/null || echo "BGP query failed")

echo "$BGP_OUTPUT"
if echo "$BGP_OUTPUT" | grep -qi "Connected\|[0-9]*\.[0-9]*"; then
  echo "  [PASS] BGP peers reachable"
else
  echo "  [WARN] Could not confirm BGP peer status"
fi

# ── Ping on-prem host ─────────────────────────────────────────────────────────
echo ""
echo "[3/4] Ping on-premises host: $ON_PREM_HOST"
if ping -c 3 -W 5 "$ON_PREM_HOST" &>/dev/null; then
  echo "  [PASS] Host $ON_PREM_HOST is reachable"
else
  echo "  [FAIL] Host $ON_PREM_HOST is not reachable"
  ERRORS=$((ERRORS + 1))
fi

# ── DNS resolution ────────────────────────────────────────────────────────────
echo ""
echo "[4/4] DNS resolution via $DNS_SERVER for $TEST_FQDN"
RESOLVED=$(nslookup "$TEST_FQDN" "$DNS_SERVER" 2>/dev/null | grep -E "^Address:" | tail -1 || echo "")

if [[ -n "$RESOLVED" ]]; then
  echo "  [PASS] $TEST_FQDN resolved: $RESOLVED"
else
  echo "  [FAIL] DNS resolution failed for $TEST_FQDN via $DNS_SERVER"
  ERRORS=$((ERRORS + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
if [[ $ERRORS -eq 0 ]]; then
  echo " CONNECTIVITY TESTS PASSED (0 errors)"
else
  echo " CONNECTIVITY TESTS FAILED ($ERRORS errors)"
  exit 1
fi
echo "======================================================"

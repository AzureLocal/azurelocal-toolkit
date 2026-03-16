#!/usr/bin/env bash
# az-deploy-cluster.sh
# Validates or deploys an Azure Local cluster via ARM template using Azure CLI.
#
# Config-driven script (Option 4 — Azure CLI in Bash).
# Reads values from infrastructure.yml via yq, generates parameters,
# then runs az deployment group create.
#
# Usage:
#   ./az-deploy-cluster.sh --config configs/infrastructure.yml --auth-type LocalIdentity --mode Validate
#   ./az-deploy-cluster.sh --config configs/infrastructure.yml --auth-type AD --mode Deploy
#
# Requirements: az cli, yq, jq
#
# Author:  Azure Local Cloud AzureLocalCloud
# Version: 1.0.0

set -euo pipefail

TEMPLATE_URI="https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json"
CONFIG_PATH=""
AUTH_TYPE="LocalIdentity"
MODE="Validate"
PARAMS_FILE=""

usage() {
    echo "Usage: $0 --config <path> --auth-type <AD|LocalIdentity> --mode <Validate|Deploy> [--params <file>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)     CONFIG_PATH="$2"; shift 2 ;;
        --auth-type)  AUTH_TYPE="$2"; shift 2 ;;
        --mode)       MODE="$2"; shift 2 ;;
        --params)     PARAMS_FILE="$2"; shift 2 ;;
        *)            usage ;;
    esac
done

[[ -z "$CONFIG_PATH" ]] && { echo "ERROR: --config is required"; usage; }

# Read values from infrastructure.yml
SUBSCRIPTION_ID=$(yq -r '.azure_platform.azure_tenants[0].aztenant_subscription_id' "$CONFIG_PATH")
RESOURCE_GROUP=$(yq -r '.compute.azure_local.resource_group' "$CONFIG_PATH")

echo "Subscription:   $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Auth Type:      $AUTH_TYPE"
echo "Mode:           $MODE"

az account set --subscription "$SUBSCRIPTION_ID"

# Generate parameters if not provided
if [[ -z "$PARAMS_FILE" ]]; then
    AUTH_SUFFIX="local-identity"
    [[ "$AUTH_TYPE" == "AD" ]] && AUTH_SUFFIX="ad"
    PARAMS_FILE="$(dirname "$CONFIG_PATH")/azuredeploy.parameters.${AUTH_SUFFIX}.generated.json"

    pwsh -File "$(dirname "$0")/../../powershell/../../../../../../../configs/Generate-AzureLocal-Parameters.ps1" \
        -ConfigPath "$CONFIG_PATH" \
        -AuthType "$AUTH_TYPE" \
        -OutputPath "$PARAMS_FILE"
fi

# Set deploymentMode
jq --arg mode "$MODE" '.parameters.deploymentMode.value = $mode' "$PARAMS_FILE" > "${PARAMS_FILE}.tmp"
mv "${PARAMS_FILE}.tmp" "$PARAMS_FILE"

# Deploy
DEPLOYMENT_NAME="azl-$(echo "$MODE" | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d%H%M%S)"
echo "Deploying: $DEPLOYMENT_NAME"

az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-uri "$TEMPLATE_URI" \
    --parameters "@${PARAMS_FILE}" \
    --verbose

echo ""
if [[ "$MODE" == "Validate" ]]; then
    echo "Validation complete. Re-run with --mode Deploy to deploy."
else
    echo "Deployment initiated. Monitor via Azure Portal or Monitor-Deployment.ps1."
fi

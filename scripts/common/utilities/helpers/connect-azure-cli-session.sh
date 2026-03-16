#!/bin/bash
# =============================================================================
# Connect-AzureCliSession.sh
# =============================================================================
#
# SYNOPSIS:
#   Establishes an Azure CLI session for Azure Local deployment.
#
# DESCRIPTION:
#   Connects to Azure using Azure CLI (az login) and sets the subscription context.
#   Standalone authentication helper — no Key Vault or infrastructure.yml dependencies.
#
#   Supports three modes:
#   1. Interactive (default) — prompts for Tenant/Subscription IDs if not provided
#   2. Parameterized — pass --tenant-id and --subscription-id flags
#   3. Config-based — pass --config pointing to infrastructure.yml (requires yq)
#
# USAGE:
#   # Interactive — prompted for values
#   ./connect-azure-cli-session.sh
#
#   # With parameters
#   ./connect-azure-cli-session.sh --tenant-id "00000000-..." --subscription-id "11111111-..."
#
#   # Device code flow for headless sessions
#   ./connect-azure-cli-session.sh --tenant-id "00000000-..." --subscription-id "11111111-..." --device-code
#
#   # Read values from infrastructure.yml (requires yq)
#   ./connect-azure-cli-session.sh --config "../../configs/infrastructure.yml"
#
# PREREQUISITES:
#   - Azure CLI (az) 2.50+
#   - Optional: yq (for --config mode)
#
# NOTES:
#   Author       : Azure Local Cloud AzureLocalCloud
#   Created      : 2026-03-02
#   Version      : 1.0.0
#   Repository   : AzureLocalCloud-docs-azl-toolkit
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="connect-azure-cli-session"
SCRIPT_VERSION="1.0.0"
TENANT_ID=""
SUBSCRIPTION_ID=""
DEVICE_CODE=false
CONFIG_PATH=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Info] $*"; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [Success] \033[0;32m$*\033[0m"; }
log_warning() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [Warning] \033[0;33m$*\033[0m"; }
log_error()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [Error] \033[0;31m$*\033[0m" >&2; }

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --tenant-id ID          Microsoft Entra ID tenant ID (GUID)
  --subscription-id ID    Azure subscription ID (GUID)
  --device-code           Use device code flow (headless/SSH sessions)
  --config PATH           Path to infrastructure.yml (requires yq)
  -h, --help              Show this help message

If --tenant-id or --subscription-id are not provided (and --config is not used),
you will be prompted to enter them interactively.
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant-id)       TENANT_ID="$2"; shift 2 ;;
        --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
        --device-code)     DEVICE_CODE=true; shift ;;
        --config)          CONFIG_PATH="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# -----------------------------------------------------------------------------
# GUID validation
# -----------------------------------------------------------------------------
validate_guid() {
    local value="$1" label="$2"
    if [[ ! "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        log_error "Invalid $label format. Expected a GUID, got: $value"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Prerequisite check
# -----------------------------------------------------------------------------
log_info "[$SCRIPT_NAME v$SCRIPT_VERSION] Starting Azure CLI session setup"

if ! command -v az &>/dev/null; then
    log_error "Azure CLI (az) not found. Install from: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

AZ_VERSION=$(az version --output tsv --query '"azure-cli"' 2>/dev/null || echo "unknown")
log_info "Azure CLI version: $AZ_VERSION"

# -----------------------------------------------------------------------------
# Configuration resolution
# -----------------------------------------------------------------------------
if [[ -n "$CONFIG_PATH" ]]; then
    if [[ ! -f "$CONFIG_PATH" ]]; then
        log_error "Config file not found: $CONFIG_PATH"
        exit 1
    fi

    if ! command -v yq &>/dev/null; then
        log_error "yq is required for --config mode. Install from: https://github.com/mikefarah/yq"
        exit 1
    fi

    log_info "Loading configuration from: $CONFIG_PATH"

    if [[ -z "$TENANT_ID" ]]; then
        TENANT_ID=$(yq '.azure.tenant_id' "$CONFIG_PATH" 2>/dev/null || echo "")
        if [[ -n "$TENANT_ID" && "$TENANT_ID" != "null" ]]; then
            log_info "TenantId loaded from config: $TENANT_ID"
        else
            TENANT_ID=""
        fi
    fi

    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        SUBSCRIPTION_ID=$(yq '.azure.subscription_id' "$CONFIG_PATH" 2>/dev/null || echo "")
        if [[ -n "$SUBSCRIPTION_ID" && "$SUBSCRIPTION_ID" != "null" ]]; then
            log_info "SubscriptionId loaded from config: $SUBSCRIPTION_ID"
        else
            SUBSCRIPTION_ID=""
        fi
    fi
fi

# Prompt for missing values
if [[ -z "$TENANT_ID" ]]; then
    read -rp "Enter Microsoft Entra ID Tenant ID: " TENANT_ID
fi
validate_guid "$TENANT_ID" "Tenant ID"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
    read -rp "Enter Azure Subscription ID: " SUBSCRIPTION_ID
fi
validate_guid "$SUBSCRIPTION_ID" "Subscription ID"

# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------
log_info "Connecting to Azure (Tenant: $TENANT_ID)..."

LOGIN_ARGS=("login" "--tenant" "$TENANT_ID")
if [[ "$DEVICE_CODE" == true ]]; then
    LOGIN_ARGS+=("--use-device-code")
    log_warning "Using device code authentication — follow the instructions displayed"
fi

if ! az "${LOGIN_ARGS[@]}" >/dev/null 2>&1; then
    log_error "az login failed"
    exit 1
fi
log_success "Authentication successful"

# -----------------------------------------------------------------------------
# Set subscription context
# -----------------------------------------------------------------------------
log_info "Setting subscription context: $SUBSCRIPTION_ID"

if ! az account set --subscription "$SUBSCRIPTION_ID" 2>&1; then
    log_error "Failed to set subscription context. Verify the ID and your access."
    exit 1
fi
log_success "Subscription context set successfully"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
log_success "Session verified:"
echo ""
az account show --output table
echo ""
log_info "Azure CLI session is ready. You may now run deployment commands."
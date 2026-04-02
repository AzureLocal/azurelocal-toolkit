<#
.SYNOPSIS
    Add infrastructure credentials to Azure Key Vault.

.DESCRIPTION
    Interactively prompts for credentials and stores them in Azure Key Vault.
    Skips secrets that already exist unless -Force is specified.

.PARAMETER Solution
    Solution name to load configuration from (azure-local, sofs-azure-local, etc.)

.PARAMETER KeyVaultName
    Name of the Azure Key Vault. If not specified, loads from solution.yaml

.PARAMETER Force
    Overwrite existing secrets

.EXAMPLE
    .\Add-KeyVaultCredentials.ps1 -Solution "azure-local"
    # Load Key Vault from solution config and add missing credentials

.EXAMPLE
    .\Add-KeyVaultCredentials.ps1 -KeyVaultName "kv-custom-vault"
    # Use a specific Key Vault name
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Solution name for config-driven execution")]
    [ValidateSet("azure-local", "azure-arc-servers")]
    [string]$Solution,

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,
    
    [switch]$Force
)

# Import config loader
$configLoaderPath = Join-Path $PSScriptRoot "..\helpers\config-loader.ps1"
. $configLoaderPath

# Load Key Vault name from solution config if not specified
if (-not $KeyVaultName) {
    if (-not $Solution) {
        Write-Host "✗ Either -Solution or -KeyVaultName must be specified" -ForegroundColor Red
        Write-Host "" 
        Write-Host "Examples:" -ForegroundColor Yellow
        Write-Host "  .\Add-KeyVaultCredentials.ps1 -Solution azure-local" -ForegroundColor Gray
        Write-Host "  .\Add-KeyVaultCredentials.ps1 -KeyVaultName kv-custom-vault" -ForegroundColor Gray
        exit 1
    }
    
    $config = Get-SolutionConfig -Solution $Solution
    $KeyVaultName = Get-PlatformKeyVault -Config $config
    
    if (-not $KeyVaultName) {
        Write-Host "✗ Could not load Key Vault name from solution config" -ForegroundColor Red
        Write-Host "  Expected path: azure_infrastructure.key_vaults.platform.name" -ForegroundColor Gray
        exit 1
    }
}

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Add Infrastructure Credentials to Key Vault               ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
if ($Solution) {
    Write-Host "Solution:  $Solution" -ForegroundColor White
}
Write-Host "Key Vault: $KeyVaultName" -ForegroundColor White
Write-Host ""

# Check Azure CLI login
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "✗ Not logged in to Azure CLI. Run: az login" -ForegroundColor Red
    exit 1
}
Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Gray
Write-Host ""

# Define credential groups
$credentialGroups = @(
    @{
        Group   = "iDRAC (Dell Server Management)"
        Secrets = @(
            @{ Name = "idrac-username"; Prompt = "iDRAC username"; Default = "root" },
            @{ Name = "idrac-password"; Prompt = "iDRAC password" }
        )
    },
    @{
        Group   = "Azure Local Nodes (Local Admin)"
        Secrets = @(
            @{ Name = "local-admin-username"; Prompt = "Local admin username"; Default = "Administrator" },
            @{ Name = "local-admin-password"; Prompt = "Local admin password" }
        )
    },
    @{
        Group   = "Windows VMs (Domain Admin)"
        Secrets = @(
            @{ Name = "Domain-Admin-Username"; Prompt = "Domain admin username"; Default = "MGMT\\azureadmin" },
            @{ Name = "Domain-Admin-Password"; Prompt = "Domain admin password" }
        )
    },
    @{
        Group   = "Linux VMs (SSH)"
        Secrets = @(
            @{ Name = "linux-admin-username"; Prompt = "Linux admin username"; Default = "azureuser" },
            @{ Name = "linux-admin-password"; Prompt = "Linux admin password (or SSH key)" }
        )
    },
    @{
        Group   = "Opengear Console Server"
        Secrets = @(
            @{ Name = "opengear-username"; Prompt = "Opengear username"; Default = "root" },
            @{ Name = "opengear-password"; Prompt = "Opengear password" }
        )
    },
    @{
        Group   = "EdgeRouter X (VPN Gateway)"
        Secrets = @(
            @{ Name = "edgerouter-username"; Prompt = "EdgeRouter username"; Default = "ubnt" },
            @{ Name = "edgerouter-password"; Prompt = "EdgeRouter password" }
        )
    },
    @{
        Group   = "Sodola Switch"
        Secrets = @(
            @{ Name = "sodola-username"; Prompt = "Sodola switch username"; Default = "admin" },
            @{ Name = "sodola-password"; Prompt = "Sodola switch password" }
        )
    },
    @{
        Group   = "UniFi Dream Machine"
        Secrets = @(
            @{ Name = "UDM-API-Key"; Prompt = "UDM API Key" }
        )
    }
)

$added = 0
$skipped = 0
$failed = 0

foreach ($group in $credentialGroups) {
    Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host " $($group.Group)" -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    
    foreach ($secret in $group.Secrets) {
        # Check if already exists
        $existing = az keyvault secret show --vault-name $KeyVaultName --name $secret.Name --query "value" -o tsv 2>$null
        
        if ($existing -and -not $Force) {
            Write-Host "  ✓ $($secret.Name) - already exists" -ForegroundColor Green
            $skipped++
            continue
        }
        
        # Prompt for value
        $promptText = "  $($secret.Prompt)"
        if ($secret.Default) {
            $promptText += " [$($secret.Default)]"
        }
        $promptText += ": "
        
        $value = Read-Host $promptText
        
        # Use default if empty
        if ([string]::IsNullOrWhiteSpace($value) -and $secret.Default) {
            $value = $secret.Default
        }
        
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "    ⚠ Skipped (no value)" -ForegroundColor Yellow
            $skipped++
            continue
        }
        
        # Add to Key Vault
        try {
            az keyvault secret set --vault-name $KeyVaultName --name $secret.Name --value $value -o none 2>$null
            Write-Host "    ✓ Added: $($secret.Name)" -ForegroundColor Green
            $added++
        }
        catch {
            Write-Host "    ✗ Failed: $($secret.Name) - $_" -ForegroundColor Red
            $failed++
        }
    }
    Write-Host ""
}

# Summary
Write-Host "═════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "═════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Added:   $added" -ForegroundColor Green
Write-Host "  Skipped: $skipped" -ForegroundColor Yellow
Write-Host "  Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" }else { "Gray" })
Write-Host ""

# List all secrets
Write-Host "All secrets in $KeyVaultName :" -ForegroundColor Cyan
az keyvault secret list --vault-name $KeyVaultName --query "[].name" -o tsv 2>$null | Sort-Object | ForEach-Object {
    Write-Host "  - $_" -ForegroundColor Gray
}
Write-Host ""

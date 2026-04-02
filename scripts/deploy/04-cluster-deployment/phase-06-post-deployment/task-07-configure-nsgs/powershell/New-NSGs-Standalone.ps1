<#
.SYNOPSIS
    Standalone script: Create and configure Network Security Groups with
    hardcoded definitions for Azure Local management, production, and AVD
    network segments.
.DESCRIPTION
    Run this script directly without a YAML config file. Edit the variables
    at the top to match your environment before executing.
    Requires the az CLI with the stack-hci-vm extension installed.
.NOTES
    For orchestrated/config-driven deployment, use Invoke-ConfigureNSGs-Orchestrated.ps1.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Environment variables — EDIT BEFORE RUNNING ───────────────────────────────
$ResourceGroup    = "rg-azlocal-network"
$Location         = "eastus"
$CustomLocation   = "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.ExtendedLocation/customLocations/<custom-location-name>"

# ── NSG definitions ───────────────────────────────────────────────────────────
$NSGs = @(
    @{
        Name  = "nsg-management"
        Rules = @(
            @{ Name = "Allow-RDP-Inbound";     Priority = 100; Direction = "Inbound";  Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "10.0.0.0/8";   DestPrefix = "*"; DestPort = "3389" }
            @{ Name = "Allow-WinRM-Inbound";   Priority = 110; Direction = "Inbound";  Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "10.0.0.0/8";   DestPrefix = "*"; DestPort = "5985-5986" }
            @{ Name = "Allow-HTTPS-Outbound";  Priority = 100; Direction = "Outbound"; Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "*";             DestPrefix = "Internet"; DestPort = "443" }
            @{ Name = "Deny-All-Inbound";      Priority = 4096; Direction = "Inbound"; Access = "Deny";  Protocol = "*";   SourcePrefix = "*";             DestPrefix = "*"; DestPort = "*" }
        )
    }
    @{
        Name  = "nsg-production"
        Rules = @(
            @{ Name = "Allow-Internal-Inbound"; Priority = 100; Direction = "Inbound";  Access = "Allow"; Protocol = "*";   SourcePrefix = "10.0.0.0/8";   DestPrefix = "*"; DestPort = "*" }
            @{ Name = "Allow-HTTPS-Outbound";   Priority = 100; Direction = "Outbound"; Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "*";             DestPrefix = "Internet"; DestPort = "443" }
            @{ Name = "Allow-DNS-Outbound";     Priority = 110; Direction = "Outbound"; Access = "Allow"; Protocol = "Udp"; SourcePrefix = "*";             DestPrefix = "*"; DestPort = "53" }
            @{ Name = "Deny-All-Inbound";       Priority = 4096; Direction = "Inbound"; Access = "Deny";  Protocol = "*";   SourcePrefix = "*";             DestPrefix = "*"; DestPort = "*" }
        )
    }
    @{
        Name  = "nsg-avd"
        Rules = @(
            @{ Name = "Allow-AVD-Inbound";     Priority = 100; Direction = "Inbound";  Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "WindowsVirtualDesktop"; DestPrefix = "*"; DestPort = "443" }
            @{ Name = "Allow-RDP-Gateway";     Priority = 110; Direction = "Inbound";  Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "10.0.0.0/8";            DestPrefix = "*"; DestPort = "3389" }
            @{ Name = "Allow-HTTPS-Outbound";  Priority = 100; Direction = "Outbound"; Access = "Allow"; Protocol = "Tcp"; SourcePrefix = "*";                      DestPrefix = "Internet"; DestPort = "443" }
            @{ Name = "Deny-All-Inbound";      Priority = 4096; Direction = "Inbound"; Access = "Deny";  Protocol = "*";   SourcePrefix = "*";                      DestPrefix = "*"; DestPort = "*" }
        )
    }
)

# ── Create NSGs and rules ─────────────────────────────────────────────────────
foreach ($nsg in $NSGs) {
    Write-Host "Processing NSG: $($nsg.Name)" -ForegroundColor Cyan

    if (-not ($PSCmdlet.ShouldProcess($nsg.Name, "Create NSG"))) { continue }

    $nsgExists = az stack-hci-vm network nsg show `
        --name            $nsg.Name `
        --resource-group  $ResourceGroup `
        --custom-location $CustomLocation `
        --query "name" -o tsv 2>$null

    if ($nsgExists) {
        Write-Host "  [SKIP] NSG '$($nsg.Name)' already exists." -ForegroundColor Yellow
    } else {
        Write-Host "  Creating NSG: $($nsg.Name)"
        az stack-hci-vm network nsg create `
            --name            $nsg.Name `
            --resource-group  $ResourceGroup `
            --custom-location $CustomLocation `
            --location        $Location `
            --output none
        Write-Host "  [CREATED]" -ForegroundColor Green
    }

    foreach ($rule in $nsg.Rules) {
        Write-Host "  Rule: $($rule.Name) (Priority $($rule.Priority))"
        az stack-hci-vm network nsg rule create `
            --nsg-name              $nsg.Name `
            --resource-group        $ResourceGroup `
            --custom-location       $CustomLocation `
            --name                  $rule.Name `
            --priority              $rule.Priority `
            --direction             $rule.Direction `
            --access                $rule.Access `
            --protocol              $rule.Protocol `
            --source-address-prefix $rule.SourcePrefix `
            --destination-address-prefix $rule.DestPrefix `
            --destination-port-range     $rule.DestPort `
            --output none
    }

    Write-Host "  [DONE] $($nsg.Name)" -ForegroundColor Green
}

Write-Host "`nNSG configuration complete." -ForegroundColor Cyan

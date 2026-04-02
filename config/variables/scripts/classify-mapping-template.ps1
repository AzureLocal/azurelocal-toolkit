#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$TemplateCsv = "E:\git\azurelocal-toolkit\config\variables\reports\canonical-mapping-template.csv",
    [string]$LegacyRootsPath = "E:\git\azurelocal-toolkit\config\variables\schema\legacy-compatible-roots.json",
    [string]$OutputCsv = "E:\git\azurelocal-toolkit\config\variables\reports\canonical-mapping-template-classified.csv",
    [string]$SummaryFile = "E:\git\azurelocal-toolkit\config\variables\reports\classification-summary.txt"
)

$ErrorActionPreference = "Stop"

foreach ($path in @($TemplateCsv, $LegacyRootsPath)) {
    if (-not (Test-Path $path)) {
        throw "Required file not found: $path"
    }
}

$canonicalRoots = @(
    "_metadata",
    "infrastructure_scenarios",
    "site",
    "environment",
    "tags",
    "azure_platform",
    "identity",
    "networking",
    "compute",
    "storage_accounts",
    "cluster_shared_volumes",
    "marketplace_images",
    "security",
    "operations",
    "devops"
)

$legacyRootsDoc = Get-Content -Path $LegacyRootsPath -Raw | ConvertFrom-Json
$legacyRoots = @($legacyRootsDoc.roots)

$rootMappings = @{
    "accounts" = "identity.accounts"
    "active_directory" = "identity.active_directory"
    "backup" = "operations.bcdr"
    "monitoring" = "operations.monitoring"
    "network" = "networking"
    "network_config" = "networking.onprem"
    "azure_local" = "compute.azure_local"
    "azure_vms" = "compute.azure_vms"
    "nodes" = "compute.nodes"
    "credentials" = "security.credentials"
    "key_vault" = "security.keyvault"
    "platform" = "azure_platform"
    "azure" = "azure_platform"
    "cluster" = "compute"
    "azure_infrastructure" = "azure_platform"
    "azure_resources" = "azure_platform"
}

$rows = Import-Csv -Path $TemplateCsv
$classified = foreach ($row in $rows) {
    $keyPath = [string]$row.key_path
    $root = ($keyPath -split '\.', 2)[0]

    $classification = "orphaned_candidate"
    $canonicalKeyPath = ""
    $notes = "Requires manual review"

    if ($canonicalRoots -contains $root) {
        $classification = "canonical_candidate"
        $canonicalKeyPath = $keyPath
        $notes = "Already under canonical root"
    }
    elseif ($legacyRoots -contains $root) {
        $classification = "alias_candidate"
        if ($rootMappings.ContainsKey($root)) {
            $suffix = if ($keyPath.Length -gt $root.Length) { $keyPath.Substring($root.Length) } else { "" }
            if ($suffix.StartsWith('.')) {
                $canonicalKeyPath = "$($rootMappings[$root])$suffix"
            }
            else {
                $canonicalKeyPath = $rootMappings[$root]
            }
            $notes = "Legacy compatibility root mapped to canonical prefix"
        }
        else {
            $notes = "Legacy compatibility root without automatic mapping"
        }
    }

    [PSCustomObject]@{
        repo = $row.repo
        file = $row.file
        key_path = $row.key_path
        canonical_key_path = $canonicalKeyPath
        classification = $classification
        notes = $notes
    }
}

$classified | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

$byClassification = $classified | Group-Object classification | Sort-Object Name
$lines = @()
$lines += "Classification Summary"
$lines += "Generated: $(Get-Date -Format s)"
$lines += "Input: $TemplateCsv"
$lines += "Output: $OutputCsv"
$lines += ""
$lines += "Counts by classification:"
foreach ($item in $byClassification) {
    $lines += "- $($item.Name): $($item.Count)"
}

$lines | Set-Content -Path $SummaryFile -Encoding UTF8

Write-Host "Wrote: $OutputCsv"
Write-Host "Wrote: $SummaryFile"
foreach ($item in $byClassification) {
    Write-Host "$($item.Name): $($item.Count)"
}

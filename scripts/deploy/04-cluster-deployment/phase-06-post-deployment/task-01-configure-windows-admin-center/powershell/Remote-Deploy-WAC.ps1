<#
.SYNOPSIS
    Remotely deploys and configures Windows Admin Center on the WAC VM.

.DESCRIPTION
    Uses Invoke-AzVMRunCommand to execute the deployment script on the WAC VM.

.EXAMPLE
    .\Remote-Deploy-WAC.ps1

.NOTES
    Runs the complete WAC deployment remotely on the WAC VM
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "=== Remote Windows Admin Center Deployment ===" -ForegroundColor Cyan

# Configuration
# TODO: Replace with solution config parameters
$subscriptionId = "YOUR_SUBSCRIPTION_ID"  # Replace with your subscription ID
$resourceGroup = "YOUR_RESOURCE_GROUP"    # Replace with your resource group
$vmName = "YOUR_WAC_VM_NAME"              # Replace with your WAC VM name
$tenantId = "YOUR_TENANT_ID"              # Replace with your tenant ID
$wacUrl = "https://YOUR_WAC_FQDN"         # Replace with your WAC URL

Write-Host "Target VM: $vmName" -ForegroundColor Gray
Write-Host "Resource Group: $resourceGroup" -ForegroundColor Gray
Write-Host ""

# Connect to Azure
Write-Host "Connecting to Azure..." -ForegroundColor Yellow
Connect-AzAccount -SubscriptionId $subscriptionId | Out-Null
Write-Host "✓ Connected to Azure" -ForegroundColor Green

Write-Host ""
Write-Host "Executing deployment on remote VM..." -ForegroundColor Yellow
Write-Host "This may take several minutes..." -ForegroundColor Gray

try {
    # Build script as array to avoid here-string issues
    $scriptLines = @(
        '$ErrorActionPreference = "Stop"'
        ''
        'Write-Host "=== Windows Admin Center Deployment (On VM) ===" -ForegroundColor Cyan'
        ''
        '# Check if already domain-joined'
        '$computerSystem = Get-WmiObject -Class Win32_ComputerSystem'
        'if ($computerSystem.PartOfDomain) {'
        '    Write-Host "✓ Already domain-joined: $($computerSystem.Domain)" -ForegroundColor Green'
        '} else {'
        '    Write-Host "[1/3] Joining domain..." -ForegroundColor Yellow'
        '    $domainName = "hybrid.mgmt"'
        '    $domainAdmin = "azurelocal\azureadmin"'
        '    $domainPassword = "!!AzureLocal2025!!"'
        '    '
        '    $securePassword = ConvertTo-SecureString $domainPassword -AsPlainText -Force'
        '    $credential = New-Object System.Management.Automation.PSCredential($domainAdmin, $securePassword)'
        '    '
        '    try {'
        '        Add-Computer -DomainName $domainName -Credential $credential -Restart:$false -Force'
        '        Write-Host "✓ Domain join successful - RESTART REQUIRED" -ForegroundColor Green'
        '        Write-Host "⚠ Please restart the server and run deployment again" -ForegroundColor Yellow'
        '        exit 0'
        '    }'
        '    catch {'
        '        Write-Host "✗ Domain join failed: $_" -ForegroundColor Red'
        '        exit 1'
        '    }'
        '}'
        ''
        '# Install WAC'
        'Write-Host "[2/3] Installing Windows Admin Center..." -ForegroundColor Yellow'
        '$installerUrl = "https://aka.ms/WACDownload"'
        '$installerPath = "$env:TEMP\WAC.msi"'
        ''
        'try {'
        '    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing'
        '    $installArgs = "/i `"$installerPath`" /quiet /norestart SME_PORT=443 SSL_CERTIFICATE_OPTION=generate"'
        '    Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait'
        '    Remove-Item $installerPath -Force'
        '    Start-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue'
        '    Write-Host "✓ WAC installed successfully" -ForegroundColor Green'
        '}'
        'catch {'
        '    Write-Host "✗ WAC installation failed: $_" -ForegroundColor Red'
        '    exit 1'
        '}'
        ''
        'Write-Host "[3/3] Verifying installation..." -ForegroundColor Yellow'
        '$wacService = Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue'
        'if ($wacService -and $wacService.Status -eq "Running") {'
        '    Write-Host "✓ WAC service is running" -ForegroundColor Green'
        '    Write-Host "✓ Access WAC at: https://localhost" -ForegroundColor Green'
        '} else {'
        '    Write-Host "⚠ WAC service is not running" -ForegroundColor Yellow'
        '}'
        ''
        'Write-Host "=== Deployment Complete ===" -ForegroundColor Green'
    )
    
    $remoteScript = $scriptLines -join "`n"
    
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $resourceGroup `
        -VMName $vmName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $remoteScript

    Write-Host ""
    Write-Host "=== Remote Execution Output ===" -ForegroundColor Cyan
    Write-Host $result.Value[0].Message -ForegroundColor White
    
    if ($result.Value[1].Message) {
        Write-Host ""
        Write-Host "=== Errors ===" -ForegroundColor Red
        Write-Host $result.Value[1].Message -ForegroundColor Red
    }
}
catch {
    Write-Error "Remote execution failed: $_"
    exit 1
}

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green

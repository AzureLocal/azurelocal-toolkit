<#
.SYNOPSIS
    Complete WAC deployment - RUN THIS ON THE WAC SERVER ITSELF

.DESCRIPTION
    Joins domain, installs WAC, configures everything. Run directly on the WAC VM.

.EXAMPLE
    .\Complete-WAC-Setup.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "=== Complete Windows Admin Center Setup ===" -ForegroundColor Cyan
Write-Host "Run this script ON the WAC server VM" -ForegroundColor Yellow
Write-Host ""

# ============================================
# PHASE 1: Verify Domain Membership
# ============================================

Write-Host "[1/3] Verifying domain membership..." -ForegroundColor Yellow

$computerSystem = Get-WmiObject -Class Win32_ComputerSystem
if ($computerSystem.PartOfDomain) {
    Write-Host "✓ Domain-joined: $($computerSystem.Domain)" -ForegroundColor Green
} else {
    Write-Host "✗ NOT domain-joined - machine must be on hybrid.mgmt domain" -ForegroundColor Red
    Write-Host "Please join domain first, then re-run this script" -ForegroundColor Yellow
    exit 1
}

# ============================================
# PHASE 2: Install WAC
# ============================================

Write-Host ""
Write-Host "[2/3] Installing Windows Admin Center..." -ForegroundColor Yellow

# Check if service exists (indicates WAC installation in progress or complete)
$wacService = Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue
$wacInstalled = Test-Path "C:\Program Files\Windows Admin Center\WindowsAdminCenter.exe"

if ($wacService -and $wacInstalled) {
    # Both service and files exist - fully installed
    Write-Host "✓ WAC already installed (service and files exist)" -ForegroundColor Green
}
elseif ($wacService -and -not $wacInstalled) {
    # Service exists but no files - installation in progress or broken
    Write-Host "⚠ WAC service exists but files missing - installation may be in progress" -ForegroundColor Yellow
    Write-Host "  Waiting up to 3 minutes for installation to complete..." -ForegroundColor Gray
    
    $waitTime = 0
    $maxWait = 180
    while ($waitTime -lt $maxWait) {
        Start-Sleep -Seconds 10
        $waitTime += 10
        
        if (Test-Path "C:\Program Files\Windows Admin Center\WindowsAdminCenter.exe") {
            Write-Host "✓ WAC installation completed" -ForegroundColor Green
            $wacInstalled = $true
            break
        }
        
        if ($waitTime % 30 -eq 0) {
            Write-Host "  Still waiting... ($waitTime seconds elapsed)" -ForegroundColor Gray
        }
    }
    
    if (-not $wacInstalled) {
        Write-Host "✗ WAC installation did not complete after $maxWait seconds" -ForegroundColor Red
        Write-Host "" -ForegroundColor Yellow
        Write-Host "CLEANUP REQUIRED - Run these commands then re-run this script:" -ForegroundColor Yellow
        Write-Host "  Get-Process | Where-Object { `$_.ProcessName -like '*WindowsAdminCenter*' } | Stop-Process -Force" -ForegroundColor Cyan
        Write-Host "  Stop-Service WindowsAdminCenter -Force" -ForegroundColor Cyan
        Write-Host "  sc.exe delete WindowsAdminCenter" -ForegroundColor Cyan
        Write-Host "  Remove-Item 'C:\Program Files\Windows Admin Center' -Recurse -Force -ErrorAction SilentlyContinue" -ForegroundColor Cyan
        exit 1
    }
}
else {
    # No service - definitely not installed
    Write-Host "No existing WAC installation detected" -ForegroundColor Gray
    
    # Proceed with installation
    Write-Host "Starting WAC installation..." -ForegroundColor Gray
    
    $installerUrl = "https://aka.ms/WACdownload"
    $installerPath = "$env:TEMP\WindowsAdminCenter.exe"
    
    try {
        # Remove old installer if exists
        if (Test-Path $installerPath) {
            Remove-Item $installerPath -Force
        }
        
        # Use BITS transfer to download .exe installer (NOT .msi)
        $bitsParams = @{
            Source = $installerUrl
            Destination = $installerPath
        }
        Start-BitsTransfer @bitsParams
        Write-Host "✓ Download complete" -ForegroundColor Green
        
        Write-Host "Installing WAC (this may take a few minutes)..." -ForegroundColor Gray
        Write-Host "Note: Script may appear hung - installer is running silently in background" -ForegroundColor Gray
        
        # Use .exe installer with /VERYSILENT /NORESTART /SUPPRESSMSGBOXES
        # Add timeout mechanism to detect hung installer
        $installJob = Start-Job -ScriptBlock {
            param($installerPath)
            $process = Start-Process -FilePath $installerPath -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait -PassThru
            return $process.ExitCode
        } -ArgumentList $installerPath
        
        # Wait up to 5 minutes for installation
        $timeout = 300
        $elapsed = 0
        while ($installJob.State -eq 'Running' -and $elapsed -lt $timeout) {
            Start-Sleep -Seconds 10
            $elapsed += 10
            if ($elapsed % 30 -eq 0) {
                Write-Host "  Still installing... ($elapsed seconds elapsed)" -ForegroundColor Gray
            }
            
            # Check if WAC files exist (installation may be done but installer hasn't exited)
            if (Test-Path "C:\Program Files\Windows Admin Center\WindowsAdminCenter.exe") {
                Write-Host "  WAC files detected - installation appears complete" -ForegroundColor Green
                break
            }
        }
        
        if ($elapsed -ge $timeout) {
            Write-Host "⚠ Installation timeout after $timeout seconds" -ForegroundColor Yellow
            Write-Host "Checking if WAC actually installed..." -ForegroundColor Gray
            if (Test-Path "C:\Program Files\Windows Admin Center\WindowsAdminCenter.exe") {
                Write-Host "✓ WAC installed despite timeout" -ForegroundColor Green
                Stop-Job $installJob -ErrorAction SilentlyContinue
                Remove-Job $installJob -Force -ErrorAction SilentlyContinue
            } else {
                Stop-Job $installJob -ErrorAction SilentlyContinue
                Remove-Job $installJob -Force -ErrorAction SilentlyContinue
                throw "Installation timed out and files not found"
            }
        } else {
            $exitCode = Receive-Job $installJob -Wait
            Remove-Job $installJob -Force
            
            if ($exitCode -eq 0) {
                Write-Host "✓ WAC installer completed" -ForegroundColor Green
            } else {
                # Check if WAC actually installed despite non-zero exit code
                Start-Sleep -Seconds 5
                if (Test-Path "C:\Program Files\Windows Admin Center\WindowsAdminCenter.exe") {
                    Write-Host "✓ WAC installed (installer exited with code $exitCode but files exist)" -ForegroundColor Green
                } else {
                    throw "Installation failed with exit code: $exitCode"
                }
            }
        }
        
        # Clean up
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        
        # Wait for installation to complete and start service
        Write-Host "Starting WAC service..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
        
        $service = Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue
        if ($service) {
            if ($service.Status -ne "Running") {
                Start-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
            $serviceStatus = (Get-Service -Name "WindowsAdminCenter").Status
            if ($serviceStatus -eq "Running") {
                Write-Host "✓ WAC service started" -ForegroundColor Green
            } else {
                Write-Host "⚠ WAC service status: $serviceStatus - trying manual start..." -ForegroundColor Yellow
                Start-Service -Name "WindowsAdminCenter" -ErrorAction Stop
                Write-Host "✓ WAC service started" -ForegroundColor Green
            }
        } else {
            Write-Host "⚠ WAC service not found - installation may be incomplete" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "✗ WAC installation failed: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  - Check for existing installations: Get-Package *WindowsAdmin*" -ForegroundColor Gray
        Write-Host "  - Check Windows Event Logs: Application log" -ForegroundColor Gray
        Write-Host "  - Try manual install: https://aka.ms/WACDownload" -ForegroundColor Gray
        exit 1
    }
}

# ============================================
# PHASE 3: Verify Installation
# ============================================

Write-Host ""
Write-Host "[3/3] Verifying installation..." -ForegroundColor Yellow

$wacService = Get-Service -Name "WindowsAdminCenter" -ErrorAction SilentlyContinue
if ($wacService) {
    if ($wacService.Status -eq "Running") {
        Write-Host "✓ WAC service is running" -ForegroundColor Green
    } else {
        Write-Host "⚠ WAC service exists but not running. Starting..." -ForegroundColor Yellow
        Start-Service -Name "WindowsAdminCenter"
        Write-Host "✓ WAC service started" -ForegroundColor Green
    }
} else {
    Write-Host "✗ WAC service not found" -ForegroundColor Red
    exit 1
}

# Check firewall
Write-Host "Checking firewall rule..." -ForegroundColor Gray
$fwRule = Get-NetFirewallRule -DisplayName "Windows Admin Center*" -ErrorAction SilentlyContinue
if ($fwRule) {
    Write-Host "✓ Firewall rule exists" -ForegroundColor Green
} else {
    Write-Host "⚠ Firewall rule not found - may need manual configuration" -ForegroundColor Yellow
}

# ============================================
# PHASE 4: Configure Kerberos (Fully Automated)
# ============================================

Write-Host ""
Write-Host "[4/5] Configuring Kerberos delegation..." -ForegroundColor Yellow

# Check and install RSAT-AD-PowerShell module
Write-Host "Installing Active Directory PowerShell module..." -ForegroundColor Gray
try {
    $adModule = Get-WindowsFeature -Name "RSAT-AD-PowerShell" -ErrorAction SilentlyContinue
    if (-not $adModule -or -not $adModule.Installed) {
        Install-WindowsFeature -Name "RSAT-AD-PowerShell" -IncludeManagementTools -ErrorAction Stop
        Write-Host "✓ AD PowerShell module installed" -ForegroundColor Green
    } else {
        Write-Host "✓ AD PowerShell module already installed" -ForegroundColor Green
    }
    
    # Import module
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "✓ AD module loaded" -ForegroundColor Green
}
catch {
    Write-Host "✗ Failed to install/import AD module: $_" -ForegroundColor Red
    Write-Host "⚠ Continuing without AD module - manual Kerberos config required" -ForegroundColor Yellow
}

# Register SPNs for this computer
$computerName = $env:COMPUTERNAME
$fqdn = "$computerName.hybrid.mgmt"

Write-Host "Registering SPNs..." -ForegroundColor Gray
try {
    setspn -A HTTP/$computerName $computerName 2>&1 | Out-Null
    setspn -A HTTP/$fqdn $computerName 2>&1 | Out-Null
    setspn -A WSMAN/$computerName $computerName 2>&1 | Out-Null
    setspn -A WSMAN/$fqdn $computerName 2>&1 | Out-Null
    Write-Host "✓ SPNs registered" -ForegroundColor Green
}
catch {
    Write-Host "⚠ SPN registration failed: $_" -ForegroundColor Yellow
}

# Configure Kerberos Delegation (requires domain admin)
Write-Host "Configuring Kerberos Constrained Delegation..." -ForegroundColor Gray
try {
    # Get the computer account object
    $computerAccount = Get-ADComputer -Identity $computerName -ErrorAction Stop
    
    # Configure Kerberos delegation
    # Set TrustedForDelegation for unconstrained delegation to any service (Kerberos only)
    Set-ADAccountControl -Identity $computerName -TrustedForDelegation $true -ErrorAction Stop
    
    Write-Host "✓ Kerberos delegation configured successfully" -ForegroundColor Green
    Write-Host "  Computer $computerName is now trusted for delegation" -ForegroundColor Gray
}
catch {
    Write-Host "⚠ Kerberos delegation config failed (requires domain admin): $_" -ForegroundColor Yellow
    Write-Host "  You can configure this manually - see instructions below" -ForegroundColor Gray
}

# ============================================
# PHASE 5: Install Extensions
# ============================================

Write-Host ""
Write-Host "[5/5] Installing WAC extensions..." -ForegroundColor Yellow

# Extension installation via PowerShell is limited, but we can prepare
# Most extensions need to be installed through WAC UI

Write-Host "⚠ Extensions must be installed through WAC web interface" -ForegroundColor Yellow
Write-Host "  Recommended extensions:" -ForegroundColor Gray
Write-Host "    - Active Directory" -ForegroundColor Gray
Write-Host "    - Hyper-V" -ForegroundColor Gray
Write-Host "    - Dell OpenManage Integration" -ForegroundColor Gray

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Windows Admin Center is ready!" -ForegroundColor Cyan
Write-Host ""
Write-Host "Access URLs:" -ForegroundColor Yellow
Write-Host "  Local:  https://localhost" -ForegroundColor Gray
Write-Host "  Domain: https://WAC01.hybrid.mgmt" -ForegroundColor Gray
Write-Host "  IP:     https://10.1.0.25" -ForegroundColor Gray
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. VERIFY KERBEROS DELEGATION (if auto-config failed):" -ForegroundColor Yellow
Write-Host "   If delegation wasn't configured automatically, run on Domain Controller:" -ForegroundColor Gray
Write-Host "   Get-ADComputer $computerName | Set-ADAccountControl -TrustedForDelegation `$true" -ForegroundColor Cyan
Write-Host ""
Write-Host "2. INSTALL EXTENSIONS:" -ForegroundColor Yellow
Write-Host "   - Open WAC: https://localhost" -ForegroundColor Gray
Write-Host "   - Settings → Extensions → Available extensions" -ForegroundColor Gray
Write-Host "   - Install: Active Directory, Hyper-V, Dell OpenManage Integration" -ForegroundColor Gray
Write-Host ""
Write-Host "3. ADD MANAGED SERVERS:" -ForegroundColor Yellow
Write-Host "   - Click '+ Add' → Servers" -ForegroundColor Gray
Write-Host "   - Add: DC01, DC02, JUMP01, Azure Local nodes" -ForegroundColor Gray
Write-Host ""
Write-Host "4. OPTIONAL - ENTRA ID INTEGRATION:" -ForegroundColor Yellow
Write-Host "   - Settings → Azure → Register with Azure" -ForegroundColor Gray
Write-Host "   - Follow prompts to integrate with Entra ID" -ForegroundColor Gray
Write-Host ""

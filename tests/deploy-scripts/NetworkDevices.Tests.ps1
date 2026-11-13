#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Stage 03 (on-premises readiness): Set-PowerSwitchEndpoint.ps1 (switches) and Test-OpengearVerification.ps1 (console servers) read network_devices[] and check, for
# each device of their type, the management address, the management port and that the password reference can be read. Test-Connection is mocked: no
# network, no device, no credential is used. The passwords are environment variables that the tests set and remove.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/NetworkDevices.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the state of the network.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock bodies read the parameters of the mocked cmdlet.')]
param()

BeforeDiscovery {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $onprem = [IO.Path]::Combine($repo, 'scripts', 'deploy', '03-onprem-readiness')
    $script:Case = @(
        @{ Label = 'Set-PowerSwitchEndpoint.ps1'; Type = 'switch'; Other = 'console_server'; Group = 'Set_PowerSwitchEndpoint_ps1'; Path = [IO.Path]::Combine($onprem, 'phase-03-network-infrastructure', 'task-02-dell-powerswitch-configuration', 'powershell', 'Set-PowerSwitchEndpoint.ps1') }
        @{ Label = 'Test-OpengearVerification.ps1'; Type = 'console_server'; Other = 'switch'; Group = 'Test_OpengearVerification_ps1'; Path = [IO.Path]::Combine($onprem, 'phase-02-enterprise-readiness', 'task-03-opengear-verification', 'powershell', 'Test-OpengearVerification.ps1') }
    )
}

Describe '<Label>' -ForEach $script:Case {
    BeforeAll {
        $script:Script = $Path
        $script:Type = $Type
        $script:Other = $Other
        $script:Group = $Group
        $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
        Import-Module powershell-yaml

        function New-Device([hashtable]$Override = @{}) {
            $d = [ordered]@{
                hostname = 'iic-dev01'; type = $script:Type; role = 'primary'; vendor = 'Dell'
                management = [ordered]@{ ip_address = '192.0.2.21'; protocol = 'ssh' }
                credentials = [ordered]@{ username = 'admin'; password = 'env://AZL_TEST_DEVICE_PASSWORD' }
            }
            foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $d.Remove($k) } else { $d[$k] = $Override[$k] } }
            $d
        }
        function New-InfraFile([object[]]$Devices = @((New-Device)), [switch]$NoDevices) {
            $doc = [ordered]@{ azure = [ordered]@{ location = 'westeurope' } }
            if (-not $NoDevices) { $doc.network_devices = @($Devices) }
            $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
            $file
        }
        function Invoke-Check([string]$File) {
            $global:LASTEXITCODE = $null
            $all = & $script:Script -InfrastructureFile $File 6>&1 3>&1 2>&1
            $code = $LASTEXITCODE
            [pscustomobject]@{
                ExitCode = $code
                Rows     = @($all | Where-Object { $_.PSObject.Properties['Device'] -and $_.PSObject.Properties['Action'] })
                Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
            }
        }
    }
    AfterAll { Remove-Item Env:AZL_TEST_DEVICE_PASSWORD -ErrorAction SilentlyContinue; Remove-Variable -Name AzlNdPing, AzlNdOpen, AzlNdPorts -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        $env:AZL_TEST_DEVICE_PASSWORD = [guid]::NewGuid().ToString()
        $global:AzlNdPing = $true
        $global:AzlNdOpen = $true
        $global:AzlNdPorts = [System.Collections.Generic.List[int]]::new()
        Mock Test-Connection {
            if ($TcpPort) { $global:AzlNdPorts.Add($TcpPort); return $global:AzlNdOpen }
            $global:AzlNdPing
        }
    }

    Context 'the checks' {
        It 'verifies a device that answers on its port and whose password can be read, and reports its hostname, role, vendor and address' {
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Rows[0].Device | Should -Be 'iic-dev01'
            $r.Rows[0].Role | Should -Be 'primary'
            $r.Rows[0].Vendor | Should -Be 'Dell'
            $r.Rows[0].Address | Should -Be '192.0.2.21'
            $r.Rows[0].Action | Should -Be 'Verified'
            $r.Rows[0].Management | Should -Be 'Open'
            $r.Rows[0].Login | Should -Be 'Readable'
            Should -Invoke Test-Connection -Times 1 -Exactly -ParameterFilter { $TargetName -eq '192.0.2.21' -and $TcpPort -eq 22 }
        }

        It 'takes the port from management.protocol: <Protocol> is <Port>' -ForEach @(
            @{ Protocol = 'ssh'; Port = 22 }, @{ Protocol = 'https'; Port = 443 }, @{ Protocol = 'telnet'; Port = 23 }
        ) {
            $null = Invoke-Check (New-InfraFile @((New-Device @{ management = [ordered]@{ ip_address = '192.0.2.21'; protocol = $Protocol } })))
            $global:AzlNdPorts | Should -Be @($Port)
        }

        It 'uses ssh when the file gives no protocol, and skips the TCP check for snmp, which is UDP' {
            $null = Invoke-Check (New-InfraFile @((New-Device @{ management = [ordered]@{ ip_address = '192.0.2.21' } })))
            $global:AzlNdPorts | Should -Be @(22)
            $global:AzlNdPorts.Clear()
            $r = Invoke-Check (New-InfraFile @((New-Device @{ management = [ordered]@{ ip_address = '192.0.2.21'; protocol = 'snmp' } })))
            $global:AzlNdPorts.Count | Should -Be 0
            $r.Rows[0].Management | Should -Be 'Skipped'
            $r.Rows[0].Action | Should -Be 'Verified'
        }

        It 'does not fail a device that does not answer a ping when its port is open' {
            $global:AzlNdPing = $false
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Ping | Should -Be 'NoAnswer'
            $r.Rows[0].Action | Should -Be 'Verified'
        }

        It 'skips a device of the other type, and does nothing when the file has none of this type' {
            $r = Invoke-Check (New-InfraFile @((New-Device @{ type = $script:Other })))
            $r.ExitCode | Should -Be 0
            $r.Text | Should -Match 'nothing to do'
            @($r.Rows).Count | Should -Be 0
            (Invoke-Check (New-InfraFile -NoDevices)).Text | Should -Match 'nothing to do'
            Should -Invoke Test-Connection -Times 0 -Exactly
        }

        It 'checks only the devices of its type when the file has both' {
            $r = Invoke-Check (New-InfraFile @((New-Device), (New-Device @{ hostname = 'iic-other01'; type = $script:Other })))
            @($r.Rows).Count | Should -Be 1
            $r.Rows[0].Device | Should -Be 'iic-dev01'
        }

        It 'skips a device whose address is dhcp or missing, without failing' {
            foreach ($management in ([ordered]@{ ip_address = 'dhcp' }), ([ordered]@{ protocol = 'ssh' })) {
                $r = Invoke-Check (New-InfraFile @((New-Device @{ management = $management })))
                $r.ExitCode | Should -Be 0 -Because $r.Text
                $r.Rows[0].Action | Should -Be 'Skipped'
            }
            Should -Invoke Test-Connection -Times 0 -Exactly
        }

        It 'never signs in, sends nothing but the ping and the connection, and never shows the password' {
            $secret = $env:AZL_TEST_DEVICE_PASSWORD
            $r = Invoke-Check (New-InfraFile)
            ($r.Text + ($r.Rows | ConvertTo-Json -Depth 4)) | Should -Not -Match ([regex]::Escape($secret))
            $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$null)
            $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
            $code | Should -Not -Match 'Invoke-RestMethod|Invoke-WebRequest|New-SSHSession|Invoke-Command|Get-Credential|Get-AzlSecretPlainText|Add-Content -LiteralPath \$logFile -Value \$secret'
        }
    }

    Context 'failures (exit 1)' {
        It 'fails a device whose management port is closed' {
            $global:AzlNdOpen = $false
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Action | Should -Be 'Failed'
            $r.Rows[0].Management | Should -Be 'Closed'
        }

        It 'fails a device whose password reference cannot be read, and says why without showing a value' {
            Remove-Item Env:AZL_TEST_DEVICE_PASSWORD
            $r = Invoke-Check (New-InfraFile)
            $r.ExitCode | Should -Be 1
            $r.Rows[0].Login | Should -Be 'NotReadable'
            $r.Rows[0].Detail | Should -Match 'password reference could not be read'
        }

        It 'reports a device with no credentials as NotListed, not as a failure' {
            $r = Invoke-Check (New-InfraFile @((New-Device @{ credentials = $null })))
            $r.ExitCode | Should -Be 0
            $r.Rows[0].Login | Should -Be 'NotListed'
        }

        It 'goes on after a failed device and reports each one' {
            $r = Invoke-Check (New-InfraFile @((New-Device @{ credentials = [ordered]@{ username = 'admin'; password = 'env://AZL_TEST_DEVICE_MISSING' } }), (New-Device @{ hostname = 'iic-dev02'; management = [ordered]@{ ip_address = '192.0.2.22' } })))
            $r.ExitCode | Should -Be 1
            ($r.Rows | Where-Object Device -EQ 'iic-dev01').Action | Should -Be 'Failed'
            ($r.Rows | Where-Object Device -EQ 'iic-dev02').Action | Should -Be 'Verified'
        }
    }

    Context 'a value in the file is not usable (exit 2, nothing checked)' {
        It 'refuses <Why>' -ForEach @(
            @{ Why = 'a device with no hostname'; Mutation = @{ hostname = $null } }
            @{ Why = 'an address that is not IPv4'; Mutation = @{ management = [ordered]@{ ip_address = 'switch.example'; protocol = 'ssh' } } }
            @{ Why = 'a management protocol that does not exist'; Mutation = @{ management = [ordered]@{ ip_address = '192.0.2.21'; protocol = 'ftp' } } }
        ) {
            $r = Invoke-Check (New-InfraFile @((New-Device $Mutation)))
            $r.ExitCode | Should -Be 2 -Because $r.Text
            Should -Invoke Test-Connection -Times 0 -Exactly
        }

        It 'refuses a hostname listed twice' {
            $r = Invoke-Check (New-InfraFile @((New-Device), (New-Device @{ management = [ordered]@{ ip_address = '192.0.2.22'; protocol = 'ssh' } })))
            $r.ExitCode | Should -Be 2
            Should -Invoke Test-Connection -Times 0 -Exactly
        }
    }

    Context 'the script text' {
        BeforeAll {
            $script:Text = Get-Content -LiteralPath $script:Script -Raw
            Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
            $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
        }

        It 'carries the standard header, never prompts and reads the secret through the resolver' {
            $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
            $script:Text | Should -Match 'Set-StrictMode -Version Latest'
            $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
            $script:Text | Should -Not -Match 'Read-Host|Get-Credential|\$Host\.UI\.Prompt|ConvertFrom-Yaml|\$ConfigPath|networking\.onprem'
            $script:Text | Should -Match 'Test-AzlSecretReference'
            $script:Text | Should -Match 'Import-AzlInfrastructure'
        }

        It 'has every parameter in the master registry (tools.arm_deployment.parameters)' {
            $own = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.[^.]+\.[^.]+$' -and $_.Path -match $script:Group })
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'InfrastructureFile'
            @($own | ForEach-Object { $_.Node['name'] }) | Should -Contain 'TimeoutSeconds'
            @(& (Join-Path $script:Repo 'config/variables/scripts/Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root (Split-Path -Parent $script:Script) -Registry $script:Registry) | Should -BeNullOrEmpty
        }

        It 'reads only registry keys that exist: <_>' -ForEach 'network_devices[].hostname', 'network_devices[].type', 'network_devices[].role', 'network_devices[].vendor', 'network_devices[].management.ip_address', 'network_devices[].management.protocol', 'network_devices[].credentials.username', 'network_devices[].credentials.password' {
            @($script:Registry | Where-Object Path -EQ $_).Count | Should -Be 1 -Because $_
        }
    }
}

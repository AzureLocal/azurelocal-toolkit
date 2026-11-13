#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06, task 09: Invoke-VerifyPostDeployment.ps1 compares the Azure VM images with the registered list storage.vm_images[] (it read the
# old key marketplace_images.images before). Every cluster, Azure and az CLI call is replaced by a stub function; nothing is contacted.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/VerifyPostDeployment.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build files in TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The az stub answers from a global, because a native command stub runs in its own scope.')]
param()

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Script = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-09-post-deployment-verification', 'powershell', 'Invoke-VerifyPostDeployment.ps1')
    Import-Module powershell-yaml

    function New-InfraFile {
        param([object[]]$VmImages, [switch]$OldKey)
        $doc = [ordered]@{
            cluster    = [ordered]@{ name = 'iic-azl-01' }
            azure      = [ordered]@{ subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group = 'rg-iic-azl-01' }
            networking = [ordered]@{ logical_networks = @() }
            # The script reads these two with plain property access, which fails under strict mode when the section is missing.
            management = [ordered]@{ wac = [ordered]@{ server_fqdn = '' } }
            nodes      = @()
        }
        if ($PSBoundParameters.ContainsKey('VmImages')) { $doc.storage = [ordered]@{ vm_images = @($VmImages) } }
        # The old key: it must be ignored, not read.
        if ($OldKey) { $doc.marketplace_images = [ordered]@{ images = @([ordered]@{ name = 'old-1' }, [ordered]@{ name = 'old-2' }, [ordered]@{ name = 'old-3' }) } }
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Get-Image([string]$Name) { [ordered]@{ name = $Name; os_type = 'Windows'; publisher = 'iic-publisher'; offer = 'iic-offer'; sku = 'iic-sku'; version = 'latest'; storage_path = 'iic-path' } }
    function Invoke-Verify {
        param([string]$File, [int]$Succeeded)
        $global:VerifyTest = @{ Succeeded = $Succeeded }
        $log = Join-Path $TestDrive "verify-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
        $failure = $null
        try { $null = & $script:Script -ConfigPath $File -Credential ([pscredential]::new('iic\lcm', (ConvertTo-SecureString 'x' -AsPlainText -Force))) -LogPath $log 6>&1 }
        catch { $failure = $_.Exception.Message }
        [pscustomobject]@{ Failure = $failure; Log = $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }) }
    }
    # The cluster and Azure side, as stubs.
    function Get-ClusterQuorum { param($Cluster, $ErrorAction) [pscustomobject]@{ QuorumType = 'NodeAndCloudWitness' } }
    function Get-Cluster { param($Name) [pscustomobject]@{ QuorumState = 'Normal' } }
    function Get-StoragePool { param($CimSession) [pscustomobject]@{ IsPrimordial = $false; HealthStatus = 'Healthy' } }
    function Get-ClusterSharedVolume { param($Cluster) @([pscustomobject]@{ Name = 'csv1'; State = 'Online' }) }
    function Test-NetConnection { param($ComputerName, $Port, $WarningAction) [pscustomobject]@{ TcpTestSucceeded = $true } }
    function az {
        $global:LASTEXITCODE = 0
        $text = "$args"
        if ($text -like '*image list*') { return (1..5 | ForEach-Object { [ordered]@{ name = "img-$_"; provisioningState = $(if ($_ -le $global:VerifyTest.Succeeded) { 'Succeeded' } else { 'Failed' }) } } | ConvertTo-Json -AsArray) }
        if ($text -like '*lnet list*') { return (ConvertTo-Json -AsArray @([ordered]@{ name = 'lnet-1'; provisioningState = 'Succeeded' })) }
    }
}

AfterAll { Remove-Variable -Name VerifyTest -Scope Global -ErrorAction SilentlyContinue }

Describe 'Invoke-VerifyPostDeployment.ps1 compares the Azure VM images with storage.vm_images[]' {
    It 'passes when every registered image Succeeded in Azure' {
        $r = Invoke-Verify (New-InfraFile -VmImages @((Get-Image 'iic-img-1'), (Get-Image 'iic-img-2'))) -Succeeded 5
        $r.Failure | Should -BeNullOrEmpty -Because $r.Log
        $r.Log | Should -Match 'All expected images Succeeded — 5/2'
    }
    It 'fails when fewer images Succeeded than the file lists' {
        $r = Invoke-Verify (New-InfraFile -VmImages @((Get-Image 'iic-img-1'), (Get-Image 'iic-img-2'), (Get-Image 'iic-img-3'))) -Succeeded 2
        $r.Failure | Should -Match 'check\(s\) failed'
        $r.Log | Should -Match '\[FAIL\].*All expected images Succeeded — 2/3'
    }
    It 'makes no comparison when the file lists no VM images, and does not fail on the missing key' {
        $r = Invoke-Verify (New-InfraFile) -Succeeded 5
        $r.Failure | Should -BeNullOrEmpty -Because $r.Log
        $r.Log | Should -Not -Match 'All expected images'
    }
    It 'does not read the old key marketplace_images.images' {
        $r = Invoke-Verify (New-InfraFile -OldKey) -Succeeded 0
        $r.Failure | Should -BeNullOrEmpty -Because $r.Log
        $r.Log | Should -Not -Match 'All expected images'
    }
    It 'reads one image given as a single item' {
        $r = Invoke-Verify (New-InfraFile -VmImages @(, (Get-Image 'iic-img-1'))) -Succeeded 1
        $r.Failure | Should -BeNullOrEmpty -Because $r.Log
        $r.Log | Should -Match 'All expected images Succeeded — 1/1'
    }
}

Describe 'Invoke-VerifyPostDeployment.ps1 counts one logical network and one image correctly' {
    It 'compares 1 of 1 for a file with one logical network, whatever az returns for it' {
        $file = New-InfraFile -VmImages @(, (Get-Image 'iic-img-1'))
        $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Yaml -Ordered
        $doc.networking.logical_networks = @([ordered]@{ name = 'iic-lnet-1' })
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $r = Invoke-Verify $file -Succeeded 1
        $r.Failure | Should -BeNullOrEmpty -Because $r.Log
        $r.Log | Should -Match 'All expected networks Succeeded — 1/1'
    }
}

Describe 'The post-deployment verification script reads no old-layout image key' {
    It 'the script mentions no marketplace_images in code' {
        foreach ($path in $script:Script) {
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$null)
            (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ') | Should -Not -Match 'marketplace_images'
        }
    }
}

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Phase 06 (post-deployment), task 06 (image downloads): New-VmImage.ps1 (Az.StackHCIVM) and New-VmImage.azcli.ps1 (Azure CLI) each run ALONE, with only
# their own parameters, and plan against the toolkit example file. Each checks its own preconditions from the file and from Azure (signed in, the right tenant,
# the Microsoft.EdgeMarketplace provider, the storage path of an image) and none needs the other. Every Az cmdlet and az is a fake, so no Azure is used, and a test
# fails when a plan creates an image. The file is config/variables/examples/infrastructure.example.yml, as it is (it lists no image), and with the values the
# task needs added in memory: the Azure ids, and one Windows Server image kept on the storage path of the example.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/post-deployment/VmImageScriptsPlanMode.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the fake Azure and collects the calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the commands.')]
param()

BeforeDiscovery {
    $script:Cases = @(
        @{ Name = 'New-VmImage.ps1'; Own = @('MaxWaitMinutes', 'PollSeconds') }
        @{ Name = 'New-VmImage.azcli.ps1'; Own = @('MaxWaitMinutes', 'PollSeconds') }
    )
}

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Example = [IO.Path]::Combine($repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')
    $task = [IO.Path]::Combine($repo, 'scripts', 'deploy', '04-cluster-deployment', 'phase-06-post-deployment', 'task-06-image-downloads')
    $script:Paths = @{
        'New-VmImage.ps1'       = [IO.Path]::Combine($task, 'powershell', 'New-VmImage.ps1')
        'New-VmImage.azcli.ps1' = [IO.Path]::Combine($task, 'azurecli', 'New-VmImage.azcli.ps1')
    }
    Import-Module powershell-yaml

    function az { }
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$Tenant) }
    function Get-AzResourceProvider { [CmdletBinding()] param([string]$ProviderNamespace) }
    function Get-AzStackHCIVMImage { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function New-AzStackHCIVMImage { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId, [string]$Location, [string]$CustomLocationId, [string]$OSType, [string]$Publisher, [string]$Offer, [string]$Sku, [string]$Version, [string]$StoragePathName, [hashtable]$Tag) }
    function Get-AzStackHCIVMStoragePath { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionId) }
    function Invoke-AzRestMethod { [CmdletBinding()] param([string]$Path, [string]$Method) }

    $global:AzlPlanTenant = [guid]::NewGuid().ToString()
    $global:AzlPlanSub = [guid]::NewGuid().ToString()

    function New-PlanFile {
        param([switch]$Values, [scriptblock]$Edit)
        $text = Get-Content -LiteralPath $script:Example -Raw
        if (-not $Values -and -not $Edit) {
            $file = Join-Path $TestDrive "example-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
            Set-Content -LiteralPath $file -Value $text
            return $file
        }
        $doc = ConvertFrom-Yaml -Ordered $text
        if ($Values) {
            $doc.azure.tenant_id = $global:AzlPlanTenant; $doc.azure.subscription_id = $global:AzlPlanSub
            $doc.storage.paths = @([ordered]@{ name = 'sp-workloads-01'; path = 'C:\ClusterStorage\vol-workloads-01\vms' })
            $doc.storage.vm_images = @([ordered]@{ name = 'img-iic-ws2025-azedition-g2'; os_type = 'Windows'; publisher = 'microsoftwindowsserver'; offer = 'windowsserver'; sku = '2025-datacenter-azure-edition'; version = '26100.4652.250808'; storage_path = 'sp-workloads-01' })
        }
        if ($Edit) { & $Edit $doc }
        $file = Join-Path $TestDrive "plan-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $file
    }
    function Reset-World {
        $global:AzlPlanCalls = [System.Collections.Generic.List[object]]::new()
        # The image: $null = not there; otherwise a state, and the states the next reads return (to show a download that progresses).
        $global:AzlPlanState = @{ Provider = 'Registered'; Image = $null; Progress = [System.Collections.Generic.Queue[string]]::new(); PathExists = $true }
    }
    function Invoke-Alone([string]$Script, [string]$File, [hashtable]$Extra = @{}) {
        $global:LASTEXITCODE = $null
        $all = & $Script -InfrastructureFile $File @Extra -WhatIf 6>&1 3>&1 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($all | Where-Object { $_.PSObject.Properties['Action'] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }
    function Get-Change { @($global:AzlPlanCalls | Where-Object { $_.Command -in 'New-AzStackHCIVMImage', 'stack-hci-vm image create', 'tag update' }) }
    # The state the next read of the image answers: the queued progress first, then the state itself.
    function Get-NextImageState { if ($global:AzlPlanState.Progress.Count -gt 0) { $global:AzlPlanState.Image = $global:AzlPlanState.Progress.Dequeue() }; $global:AzlPlanState.Image }
}

Describe 'The VM image scripts of phase 06 run alone in Plan mode' {
    AfterAll { Remove-Variable -Name AzlPlanTenant, AzlPlanSub, AzlPlanCalls, AzlPlanState -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Reset-World
        Mock Start-Sleep { }
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlPlanTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlPlanSub } } }
        Mock Set-AzContext { }
        Mock Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = $global:AzlPlanState.Provider } }
        Mock Get-AzStackHCIVMStoragePath { if (-not $global:AzlPlanState.PathExists) { throw "(ResourceNotFound) The Resource 'storagecontainers/$Name' was not found." }; [pscustomobject]@{ Name = $Name } }
        Mock Get-AzStackHCIVMImage {
            if ($null -eq $global:AzlPlanState.Image -and $global:AzlPlanState.Progress.Count -eq 0) { throw "(ResourceNotFound) The Resource 'marketplaceGalleryImages/$Name' was not found." }
            [pscustomobject]@{ Name = $Name; ProvisioningStatus = (Get-NextImageState); StatusProgressPercentage = '40'; VersionName = '26100.4652.250808'; IdentifierPublisher = 'microsoftwindowsserver'; IdentifierOffer = 'windowsserver'; IdentifierSku = '2025-datacenter-azure-edition'; OSType = 'Windows'; Tag = @{ Owner = 'platform-team@improbability.cloud' } }
        }
        Mock New-AzStackHCIVMImage { $global:AzlPlanCalls.Add([pscustomobject]@{ Command = 'New-AzStackHCIVMImage' }) }
        Mock az {
            $a = @($args | ForEach-Object { [string]$_ })
            $words = @(); foreach ($x in $a) { if ($x.StartsWith('-')) { break }; $words += $x }
            $command = $words -join ' '
            $global:AzlPlanCalls.Add([pscustomobject]@{ Command = $command; Arguments = $a })
            $fail = { param($code, $message) $global:LASTEXITCODE = $code; [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'az', 'NotSpecified', $null) }
            $global:LASTEXITCODE = 0
            switch ($command) {
                'account show' { return ('{"tenantId":"' + $global:AzlPlanTenant + '","id":"' + $global:AzlPlanSub + '"}') }
                'extension show' { return '{"name":"stack-hci-vm"}' }
                'provider show' { return $global:AzlPlanState.Provider }
                'stack-hci-vm storagepath show' {
                    if (-not $global:AzlPlanState.PathExists) { return (& $fail 3 "(ResourceNotFound) The Resource 'storagecontainers/x' was not found.") }
                    return '{"id":"/subscriptions/x/resourceGroups/rg/providers/Microsoft.AzureStackHCI/storageContainers/sp-workloads-01"}'
                }
                'stack-hci-vm image show' {
                    if ($null -eq $global:AzlPlanState.Image -and $global:AzlPlanState.Progress.Count -eq 0) { return (& $fail 3 "(ResourceNotFound) The Resource 'marketplaceGalleryImages/x' was not found.") }
                    return ('{"name":"x","tags":{"Owner":"platform-team@improbability.cloud"},"properties":{"provisioningState":"' + (Get-NextImageState) + '","status":{"progressPercentage":"40"},"version":{"name":"26100.4652.250808"},"identifier":{"publisher":"microsoftwindowsserver","offer":"windowsserver","sku":"2025-datacenter-azure-edition"},"osType":"Windows"}}')
                }
                default { return (& $fail 2 "unexpected az call: $command") }
            }
        }
    }

    Context '<Name>' -ForEach $script:Cases {
        BeforeAll { $script:This = $script:Paths[$Name] }

        It 'takes -InfrastructureFile as its only mandatory parameter, and -WhatIf and -LogPath' {
            $command = Get-Command -Name $script:This
            @($command.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [Parameter] -and $_.Mandatory } } | ForEach-Object Name) | Should -Be @('InfrastructureFile')
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('LogPath') | Should -BeTrue
            @($command.Parameters.Keys | Where-Object { $_ -notin [Management.Automation.Cmdlet]::CommonParameters -and $_ -notin [Management.Automation.Cmdlet]::OptionalCommonParameters -and $_ -notin 'InfrastructureFile', 'LogPath' } | Sort-Object) | Should -Be @($Own | Sort-Object)
        }

        It 'plans against the toolkit example as it is: the file lists no image, so exit 0 and nothing is asked of Azure' {
            $r = Invoke-Alone $script:This (New-PlanFile) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            $r.Text | Should -Match 'no storage\.vm_images'
            $global:AzlPlanCalls.Count | Should -Be 0
        }

        It 'plans against the example with the Azure ids and one image added, alone: exit 0, the image is only planned, the log is written' {
            $log = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{ LogPath = $log }
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('WouldCreate')
            Get-Change | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $log -Raw).Trim() | Should -Not -BeNullOrEmpty
        }

        It 'stops with exit code 2 on the all-zero placeholder subscription of the example when it lists an image, and sends nothing' {
            $file = New-PlanFile -Edit { param($doc) $doc.storage.vm_images = @([ordered]@{ name = 'img-x'; os_type = 'Windows'; publisher = 'p'; offer = 'o'; sku = 's'; version = '26100.1.1' }) }
            $r = Invoke-Alone $script:This $file @{}
            $r.ExitCode | Should -Be 2
            $global:AzlPlanCalls.Count | Should -Be 0
        }

        It 'fails (exit 1) when Microsoft.EdgeMarketplace is not registered, and creates nothing' {
            $global:AzlPlanState.Provider = 'NotRegistered'
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'EdgeMarketplace'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'fails (exit 1) when the storage path of the image is not in Azure yet, and creates nothing' {
            $global:AzlPlanState.PathExists = $false
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            $r.Text | Should -Match 'storage path'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'is idempotent: an image that Succeeded is AlreadyExists (and says when the tags differ), nothing is created' {
            $global:AzlPlanState.Image = 'Succeeded'
            $r = Invoke-Alone $script:This (New-PlanFile -Values -Edit { param($doc) $doc.tags.Project = 'a-tag-the-image-does-not-have' }) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('AlreadyExists')
            @($r.Rows)[0].Detail | Should -Match 'tags differ'
            Get-Change | Should -BeNullOrEmpty
        }

        It 'reports an image that is still downloading as InProgress under -WhatIf, with the percent, and does not wait' {
            $global:AzlPlanState.Image = 'Downloading'
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 0 -Because $r.Text
            @($r.Rows.Action) | Should -Be @('InProgress')
            @($r.Rows)[0].Detail | Should -Match '40 percent'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'fails (exit 1) for an image in the Failed state and never deletes or recreates it' {
            $global:AzlPlanState.Image = 'Failed'
            $r = Invoke-Alone $script:This (New-PlanFile -Values) @{}
            $r.ExitCode | Should -Be 1
            @($r.Rows.Action) | Should -Be @('Failed')
            Get-Change | Should -BeNullOrEmpty
        }
    }

    Context 'download progress and wait (not under -WhatIf)' {
        It '<Name> waits for an image an earlier run left downloading, prints the percent, and reports AlreadyExists when it ends Succeeded' -ForEach $script:Cases {
            $global:AzlPlanState.Image = 'Downloading'
            foreach ($next in 'Downloading', 'Succeeded') { $global:AzlPlanState.Progress.Enqueue($next) }
            $global:LASTEXITCODE = $null
            $all = & $script:Paths[$Name] -InfrastructureFile (New-PlanFile -Values) -PollSeconds 1 6>&1 3>&1 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ((@($all) | ForEach-Object { "$_" }) -join "`n")
            ((@($all) | ForEach-Object { "$_" }) -join "`n") | Should -Match "\[waiting\] 'img-iic-ws2025-azedition-g2': .*40 percent"
            Should -Invoke Start-Sleep -Times 1 -Exactly -Scope It
            @($all | Where-Object { $_.PSObject.Properties['Action'] }).Action | Should -Be @('AlreadyExists')
            Get-Change | Should -BeNullOrEmpty
        }

        It '<Name> reports InProgress (exit 0, not a failure) when the image is not Succeeded after -MaxWaitMinutes' -ForEach $script:Cases {
            $global:AzlPlanState.Image = 'Downloading'
            $global:LASTEXITCODE = $null
            $all = & $script:Paths[$Name] -InfrastructureFile (New-PlanFile -Values) -MaxWaitMinutes 0 6>&1 3>&1 2>&1
            $LASTEXITCODE | Should -Be 0
            @($all | Where-Object { $_.PSObject.Properties['Action'] }).Action | Should -Be @('InProgress')
        }

        It '<Name> fails (exit 1) when the download ends Failed while it waits' -ForEach $script:Cases {
            $global:AzlPlanState.Image = 'Downloading'
            $global:AzlPlanState.Progress.Enqueue('Downloading'); $global:AzlPlanState.Progress.Enqueue('Failed')
            $global:LASTEXITCODE = $null
            $all = & $script:Paths[$Name] -InfrastructureFile (New-PlanFile -Values) -PollSeconds 1 6>&1 3>&1 2>&1
            $LASTEXITCODE | Should -Be 1
        }
    }
}

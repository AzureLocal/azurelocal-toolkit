#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# scripts/common/discovery: Inventory-AzureTenant.ps1 (tenant from azure.tenant_id) and Get-OnPremInventory.ps1 (domain and OU from
# identity.active_directory) take a mandatory -InfrastructureFile, have no -Solution, never prompt and never sign in, and end with 0, 1 or 2.
# Get-TenantInfo.ps1 is removed: Inventory-AzureTenant.ps1 records the subscriptions and resource groups of the tenant too.
# Every Az and ActiveDirectory cmdlet is a stub with the cmdlet's parameters and is mocked: nothing reaches Azure or a domain. Ids are generated per run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/discovery/DiscoveryInventory.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body runs in the scope of the script under test; a global is how the test hands it the ids.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fakes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets they replace.')]
param()

BeforeDiscovery {
    $repoRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $folder = [IO.Path]::Combine($repoRoot, 'scripts', 'common', 'discovery')
    $script:Cases = @(
        @{ Name = 'Inventory-AzureTenant.ps1'; Path = [IO.Path]::Combine($folder, 'Inventory-AzureTenant.ps1'); Keys = @('azure.tenant_id') }
        @{ Name = 'Get-OnPremInventory.ps1'; Path = [IO.Path]::Combine($folder, 'Get-OnPremInventory.ps1'); Keys = @('scenario.identity', 'identity.active_directory.domain_fqdn', 'identity.active_directory.ou_path', 'identity.active_directory.domain_controllers') }
    )
}

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Folder = [IO.Path]::Combine($script:Repo, 'scripts', 'common', 'discovery')
    $script:Tenant = [IO.Path]::Combine($script:Folder, 'Inventory-AzureTenant.ps1')
    $script:OnPrem = [IO.Path]::Combine($script:Folder, 'Get-OnPremInventory.ps1')
    Import-Module powershell-yaml
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))

    function New-InfraFile([System.Collections.IDictionary]$Document) {
        $file = Join-Path $TestDrive "infra-$([guid]::NewGuid().ToString('N').Substring(0, 6)).yml"
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $Document)
        $file
    }
    function Invoke-Script([string]$Path, [hashtable]$Arguments) {
        $global:LASTEXITCODE = $null
        $all = & $Path @Arguments 6>&1 3>&1 2>&1
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Objects  = @($all | Where-Object { $_ -isnot [Management.Automation.InformationRecord] -and $_ -isnot [Management.Automation.WarningRecord] -and $_ -isnot [Management.Automation.ErrorRecord] })
            Text     = (@($all | Where-Object { $_ -is [Management.Automation.InformationRecord] -or $_ -is [Management.Automation.WarningRecord] -or $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n")
        }
    }

    # Stubs with the parameters the scripts use, so the mocks work whether or not the Az and ActiveDirectory modules are installed.
    function Get-AzContext { [CmdletBinding()] param() }
    function Set-AzContext { [CmdletBinding()] param([string]$SubscriptionId, [string]$TenantId, [string]$Tenant) }
    function Get-AzTenant { [CmdletBinding()] param([string]$TenantId) }
    function Get-AzSubscription { [CmdletBinding()] param([string]$TenantId, [string]$SubscriptionId) }
    function Get-AzManagementGroup { [CmdletBinding()] param([string]$GroupId, [switch]$Expand, [switch]$Recurse) }
    function Get-AzResourceProvider { [CmdletBinding()] param() }
    function Get-AzResourceGroup { [CmdletBinding()] param() }
    function Get-AzResource { [CmdletBinding()] param() }
    function Get-AzVirtualNetwork { [CmdletBinding()] param([string]$ResourceGroupName, [string]$Name) }
    function Get-AzVirtualNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName) }
    function Get-AzLocalNetworkGateway { [CmdletBinding()] param([string]$ResourceGroupName) }
    function Get-AzVirtualNetworkGatewayConnection { [CmdletBinding()] param([string]$ResourceGroupName) }
    function Get-AzRouteTable { [CmdletBinding()] param() }
    function Get-AzPublicIpAddress { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName) }
    function Get-AzVM { [CmdletBinding()] param([switch]$Status) }
    function Get-AzNetworkInterface { [CmdletBinding()] param([string]$Name, [string]$ResourceGroupName) }
    function Get-AzRoleAssignment { [CmdletBinding()] param() }
    function Get-AzPolicyAssignment { [CmdletBinding()] param() }
    function Get-ADComputer { [CmdletBinding()] param([string]$Filter, [string]$SearchBase, [string]$Server, [string[]]$Properties, [pscredential]$Credential) }
}

Describe 'the discovery scripts take the infrastructure file' {
    It 'Get-TenantInfo.ps1 is removed and nothing names it' {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Folder, 'Get-TenantInfo.ps1')) | Should -BeFalse
        $hits = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts')), ([IO.Path]::Combine($script:Repo, 'docs')), ([IO.Path]::Combine($script:Repo, 'pipelines')) -Recurse -File -Include '*.ps1', '*.psm1', '*.md', '*.yml' |
                Where-Object { $_.FullName -notmatch '[\\/]deferred[\\/]' } | Select-String -Pattern 'Get-TenantInfo' -SimpleMatch | ForEach-Object { "$($_.Path):$($_.LineNumber)" })
        $hits | Should -BeNullOrEmpty
    }

    It '<Name> takes a mandatory -InfrastructureFile with no default, and no -Solution, -TenantId, -Domain, -OUPath or -ConfigPath' -ForEach $script:Cases {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Contain 'InfrastructureFile'
        foreach ($gone in 'Solution', 'TenantId', 'Domain', 'OUPath', 'ConfigPath', 'ConfigFile') { $names | Should -Not -Contain $gone }
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InfrastructureFile' }
        $p.Attributes.NamedArguments.ArgumentName | Should -Contain 'Mandatory'
        $p.DefaultValue | Should -BeNullOrEmpty
    }

    It '<Name> has the standard header, never prompts, never signs in and reads no environment variable' -ForEach $script:Cases {
        $text = Get-Content -LiteralPath $Path -Raw
        $text | Should -Match '(?m)^#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        foreach ($c in 'Read-Host', 'Get-Credential', 'Connect-AzAccount', 'Disconnect-AzAccount', 'Install-Module') { $commands | Should -Not -Contain $c }
        $tokens = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$null)
        $code = (($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
        $code | Should -Not -Match '\$Host\.UI\.Prompt|\[Console\]::ReadLine|\$env:|variables\.yml|config-loader|hybrid\.mgmt|haas\.mgmt'
        $code | Should -Match 'Import-AzlInfrastructure -Path \$InfrastructureFile'
    }

    It '<Name> reads only registry keys that exist' -ForEach $script:Cases {
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($key in $Keys) {
            $text | Should -Match ([regex]::Escape("'$key'"))
            @($script:Registry | Where-Object Path -EQ $key).Count | Should -Be 1 -Because $key
        }
    }

    It '<Name> has every parameter in the master registry' -ForEach $script:Cases {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $file = [IO.Path]::GetFileName($Path)
        $groups = @($script:Registry | Where-Object { $_.Path -match '^tools\.[^.]+\.parameters\.[^.]+$' -and $_.Node -is [System.Collections.IDictionary] -and $_.Node.Contains('area') -and ([string]$_.Node['area']).EndsWith("discovery/$file") })
        $groups.Count | Should -BeGreaterThan 0
        $registered = @(foreach ($g in $groups) { foreach ($child in $g.Node['properties'].Values) { if ($child -is [System.Collections.IDictionary] -and $child.Contains('name')) { [string]$child['name'] } } })
        foreach ($n in $names) { $registered | Should -Contain $n -Because "-$n of $file" }
    }
}

Describe 'Inventory-AzureTenant.ps1' {
    BeforeAll {
        $global:AzlInvTenant = [guid]::NewGuid().ToString()
        $global:AzlInvSub = [guid]::NewGuid().ToString()
        $global:AzlInvHome = [guid]::NewGuid().ToString()
        function New-TenantFile([object]$TenantId = $global:AzlInvTenant) {
            $azure = [ordered]@{ location = 'westeurope' }
            if ($null -ne $TenantId) { $azure.tenant_id = $TenantId }
            New-InfraFile ([ordered]@{ azure = $azure })
        }
    }
    AfterAll { Remove-Variable -Name AzlInvTenant, AzlInvSub, AzlInvHome -Scope Global -ErrorAction SilentlyContinue }

    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $global:AzlInvTenant }; Subscription = [pscustomobject]@{ Id = $global:AzlInvHome }; Account = [pscustomobject]@{ Id = 'operator@improbability.cloud' } } }
        Mock Set-AzContext { }
        Mock Get-AzTenant { [pscustomobject]@{ Id = $global:AzlInvTenant; Name = 'Infinite Improbability Corp'; DefaultDomain = 'improbability.cloud'; TenantType = 'AAD' } }
        Mock Get-AzSubscription { @([pscustomobject]@{ Id = $global:AzlInvSub; Name = 'iic-sub-azl-01'; State = 'Enabled'; TenantId = $global:AzlInvTenant; Tags = @{} }) }
        Mock Get-AzManagementGroup {
            if ($GroupId) { return [pscustomobject]@{ Id = "/providers/Microsoft.Management/managementGroups/$GroupId"; Name = $GroupId; DisplayName = 'IIC'; TenantId = $global:AzlInvTenant; ParentId = $null; ParentName = $null; Children = @() } }
            @([pscustomobject]@{ Name = 'iic-mg-root'; Id = '/providers/Microsoft.Management/managementGroups/iic-mg-root' })
        }
        Mock Get-AzResourceProvider { @([pscustomobject]@{ ProviderNamespace = 'Microsoft.AzureStackHCI'; RegistrationState = 'Registered' }) }
        Mock Get-AzResourceGroup { @([pscustomobject]@{ ResourceGroupName = 'rg-iic-azl-01'; Location = 'westeurope'; ProvisioningState = 'Succeeded'; ResourceId = "/subscriptions/$global:AzlInvSub/resourceGroups/rg-iic-azl-01"; Tags = @{ owner = 'iic' } }) }
        Mock Get-AzResource {
            @(
                [pscustomobject]@{ ResourceId = "/subscriptions/$global:AzlInvSub/resourceGroups/rg-iic-azl-01/providers/Microsoft.AzureStackHCI/clusters/iic-azl-01"; Name = 'iic-azl-01'; ResourceType = 'Microsoft.AzureStackHCI/clusters'; ResourceGroupName = 'rg-iic-azl-01'; Location = 'westeurope'; Tags = @{ owner = 'iic' }; Kind = $null; Sku = $null; Properties = $null }
                [pscustomobject]@{ ResourceId = "/subscriptions/$global:AzlInvSub/resourceGroups/rg-iic-azl-01/providers/Microsoft.KeyVault/vaults/kv-iic-azl-01"; Name = 'kv-iic-azl-01'; ResourceType = 'Microsoft.KeyVault/vaults'; ResourceGroupName = 'rg-iic-azl-01'; Location = 'westeurope'; Tags = @{}; Kind = $null; Sku = $null; Properties = $null }
            )
        }
        foreach ($c in 'Get-AzVirtualNetwork', 'Get-AzVirtualNetworkGateway', 'Get-AzLocalNetworkGateway', 'Get-AzVirtualNetworkGatewayConnection', 'Get-AzRouteTable', 'Get-AzPublicIpAddress', 'Get-AzVM', 'Get-AzNetworkInterface', 'Get-AzRoleAssignment', 'Get-AzPolicyAssignment') {
            Mock $c { @() }
        }
    }

    It 'ends with exit code 2 and calls nothing in Azure when azure.tenant_id is <Case>' -ForEach @(
        @{ Case = 'missing'; Value = $null }
        @{ Case = 'not a GUID'; Value = 'iic-tenant' }
        @{ Case = 'the all-zero placeholder'; Value = '00000000-0000-0000-0000-000000000000' }
    ) {
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile $Value); OutputPath = (Join-Path $TestDrive 'out-bad') }
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'azure\.tenant_id'
        Should -Invoke Get-AzContext -Times 0 -Exactly
    }

    It 'ends with exit code 2 when the file cannot be read' {
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (Join-Path $TestDrive 'no-such-file.yml') }
        $r.ExitCode | Should -Be 2
        Should -Invoke Get-AzContext -Times 0 -Exactly
    }

    It 'does not sign in: exit code 1 with the command to run when there is no Azure context' {
        Mock Get-AzContext { $null }
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile) }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Connect-AzAccount -Tenant'
        Should -Invoke Get-AzSubscription -Times 0 -Exactly
    }

    It 'refuses a sign-in to another tenant (exit code 1)' {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = [guid]::NewGuid().ToString() }; Subscription = [pscustomobject]@{ Id = $global:AzlInvHome }; Account = [pscustomobject]@{ Id = 'x' } } }
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile) }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'azure\.tenant_id is'
        Should -Invoke Get-AzSubscription -Times 0 -Exactly
    }

    It 'writes the JSON and CSV files of the tenant in the file and puts the Az context back (exit code 0)' {
        $out = Join-Path $TestDrive 'out-ok'
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile); OutputPath = $out }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $json = Join-Path $out 'azure-inventory.json'
        Test-Path -LiteralPath $json | Should -BeTrue
        $doc = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        $doc.Metadata.TenantId | Should -Be $global:AzlInvTenant
        $doc.Tenant.DisplayName | Should -Be 'Infinite Improbability Corp'
        @($doc.Subscriptions).Count | Should -Be 1
        $doc.Subscriptions[0].AzureStackHCIProviderRegistered | Should -BeTrue
        @($doc.ResourceGroups).Count | Should -Be 1
        @($doc.Resources).Count | Should -Be 2
        @($doc.AzureLocal.Clusters).Count | Should -Be 1
        @($doc.Security.KeyVaults).Count | Should -Be 1
        @($doc.Errors).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $out 'azure-inventory_Subscriptions.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $out 'azure-inventory_AzureLocal_Clusters.csv') | Should -BeTrue
        $summary = @($r.Objects | Where-Object { $_.PSObject.Properties['Resources'] })
        $summary.Count | Should -Be 1
        $summary[0].Resources | Should -Be 2
        Should -Invoke Get-AzRoleAssignment -Times 0 -Exactly
        Should -Invoke Set-AzContext -ParameterFilter { $SubscriptionId -eq $global:AzlInvHome -and $Tenant -eq $global:AzlInvTenant } -Times 1 -Exactly
    }

    It 'records the role assignments only with -IncludeRBAC, and the JSON file only with -Format JSON' {
        $out = Join-Path $TestDrive 'out-rbac'
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile); OutputPath = $out; IncludeRBAC = $true; Format = 'JSON'; BaseName = 'iic-tenant' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Should -Invoke Get-AzRoleAssignment -Times 1 -Exactly
        Test-Path -LiteralPath (Join-Path $out 'iic-tenant.json') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $out -Filter '*.csv').Count | Should -Be 0
    }

    It 'ends with exit code 1 when a read fails, and still writes the file with the error listed' {
        Mock Get-AzResourceGroup { throw 'AuthorizationFailed: no read access' }
        $out = Join-Path $TestDrive 'out-partial'
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile); OutputPath = $out; Format = 'JSON' }
        $r.ExitCode | Should -Be 1
        $doc = Get-Content -LiteralPath (Join-Path $out 'azure-inventory.json') -Raw | ConvertFrom-Json
        @($doc.Errors | Where-Object Component -EQ 'ResourceGroups').Count | Should -Be 1
        @($doc.Errors)[0].ExceptionMessage | Should -Match 'AuthorizationFailed'
        Should -Invoke Set-AzContext -ParameterFilter { $SubscriptionId -eq $global:AzlInvHome -and $Tenant -eq $global:AzlInvTenant } -Times 1 -Exactly
    }

    It 'ends with exit code 1 when the account cannot list a subscription' {
        Mock Get-AzSubscription { @() }
        $r = Invoke-Script $script:Tenant @{ InfrastructureFile = (New-TenantFile); OutputPath = (Join-Path $TestDrive 'out-none') }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'cannot list the subscriptions'
        Should -Invoke Get-AzResource -Times 0 -Exactly
    }
}

Describe 'Get-OnPremInventory.ps1' {
    BeforeAll {
        function New-AdFile {
            param([string]$Identity = 'active_directory', [object]$Domain = 'iic.improbability.cloud', [object]$Ou = 'OU=AzureLocal,DC=iic,DC=improbability,DC=cloud', [object[]]$Controllers = @('192.0.2.10', '192.0.2.11'))
            $ad = [ordered]@{}
            if ($null -ne $Domain) { $ad.domain_fqdn = $Domain }
            if ($null -ne $Ou) { $ad.ou_path = $Ou }
            if ($Controllers) { $ad.domain_controllers = @($Controllers) }
            New-InfraFile ([ordered]@{ scenario = [ordered]@{ identity = $Identity }; identity = [ordered]@{ active_directory = $ad } })
        }
    }

    BeforeEach {
        Mock Get-ADComputer {
            @(
                [pscustomobject]@{ Name = 'iic-azl-n01'; DNSHostName = 'iic-azl-n01.iic.improbability.cloud'; OperatingSystem = 'Azure Stack HCI'; OperatingSystemVersion = '10.0 (26100)'; IPv4Address = '192.0.2.21'; Enabled = $true; LastLogonDate = [datetime]'2026-11-01T10:00:00'; ServicePrincipalName = @('HOST/iic-azl-n01'); DistinguishedName = 'CN=iic-azl-n01,OU=AzureLocal,DC=iic,DC=improbability,DC=cloud' }
                [pscustomobject]@{ Name = 'iic-azl-01'; DNSHostName = 'iic-azl-01.iic.improbability.cloud'; OperatingSystem = $null; OperatingSystemVersion = $null; IPv4Address = $null; Enabled = $true; LastLogonDate = $null; ServicePrincipalName = @('MSClusterVirtualServer/iic-azl-01', 'HOST/iic-azl-01'); DistinguishedName = 'CN=iic-azl-01,OU=AzureLocal,DC=iic,DC=improbability,DC=cloud' }
            )
        }
    }

    It 'lists the computer objects of the OU in the file, at the first domain controller, and marks the cluster name object (exit code 0)' {
        $r = Invoke-Script $script:OnPrem @{ InfrastructureFile = (New-AdFile) }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $rows = @($r.Objects | Where-Object { $_.PSObject.Properties['Kind'] })
        $rows.Count | Should -Be 2
        ($rows | Where-Object Name -EQ 'iic-azl-01').Kind | Should -Be 'ClusterName'
        ($rows | Where-Object Name -EQ 'iic-azl-n01').Kind | Should -Be 'Computer'
        Should -Invoke Get-ADComputer -Times 1 -Exactly -ParameterFilter { $SearchBase -eq 'OU=AzureLocal,DC=iic,DC=improbability,DC=cloud' -and $Server -eq '192.0.2.10' -and $Filter -eq '*' -and -not $Credential }
    }

    It 'queries the domain when the file lists no domain controller, as -Credential when given, and writes the JSON file' {
        $credential = [pscredential]::new('IIC\reader', (ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force))
        $out = Join-Path $TestDrive 'ad\inventory.json'
        $r = Invoke-Script $script:OnPrem @{ InfrastructureFile = (New-AdFile -Controllers @()); Credential = $credential; OutputPath = $out }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Should -Invoke Get-ADComputer -Times 1 -Exactly -ParameterFilter { $Server -eq 'iic.improbability.cloud' -and $Credential.UserName -eq 'IIC\reader' }
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $doc.OuPath | Should -Be 'OU=AzureLocal,DC=iic,DC=improbability,DC=cloud'
        @($doc.Computers).Count | Should -Be 1
        @($doc.Clusters).Count | Should -Be 1
    }

    It 'does nothing for a local identity instance (exit code 0, no query)' {
        $r = Invoke-Script $script:OnPrem @{ InfrastructureFile = (New-AdFile -Identity 'local_identity' -Domain $null -Ou $null) }
        $r.ExitCode | Should -Be 0
        $r.Text | Should -Match 'local_identity'
        Should -Invoke Get-ADComputer -Times 0 -Exactly
    }

    It 'ends with exit code 2 and queries nothing when <Case>' -ForEach @(
        @{ Case = 'the domain is missing'; Domain = $null; Ou = 'OU=AzureLocal,DC=iic,DC=improbability,DC=cloud'; Identity = 'active_directory'; Expect = 'domain_fqdn' }
        @{ Case = 'the OU is not a distinguished name'; Domain = 'iic.improbability.cloud'; Ou = 'AzureLocal'; Identity = 'active_directory'; Expect = 'ou_path' }
        @{ Case = 'scenario.identity is not set'; Domain = 'iic.improbability.cloud'; Ou = 'OU=AzureLocal,DC=iic,DC=improbability,DC=cloud'; Identity = ''; Expect = 'scenario\.identity' }
    ) {
        $r = Invoke-Script $script:OnPrem @{ InfrastructureFile = (New-AdFile -Identity $Identity -Domain $Domain -Ou $Ou) }
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match $Expect
        Should -Invoke Get-ADComputer -Times 0 -Exactly
    }

    It 'ends with exit code 1 when the query fails' {
        Mock Get-ADComputer { throw 'Unable to contact the server.' }
        $r = Invoke-Script $script:OnPrem @{ InfrastructureFile = (New-AdFile) }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'Unable to contact the server'
    }
}

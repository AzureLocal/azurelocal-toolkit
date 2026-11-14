#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The hard-coded values of the hardware discovery, Azure foundation, identity and Terraform rows of the variables research are gone: the scripts that a
# schema 5 script replaces are removed, a value Microsoft fixes is a named constant with its source, a value a deployment chooses is read from the file, and
# the Terraform variables that the generator feeds from the file have no literal default. Files are read as text (the PowerShell parser for scripts); nothing runs.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/deploy-scripts/HardcodedValuesFoundation.Tests.ps1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters mirror the cmdlets.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    function Get-RepoText([string]$Relative) { [IO.File]::ReadAllText([IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))) }
    function Get-CodeText([string]$Relative) {
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($script:Repo, $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)), [ref]$tokens, [ref]$null)
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
    # The body of one Terraform variable block.
    function Get-TfVariable([string]$Relative, [string]$Name) {
        $text = Get-RepoText $Relative
        $m = [regex]::Match($text, '(?ms)^variable\s+"' + [regex]::Escape($Name) + '"\s*\{.*?^\}')
        if (-not $m.Success) { throw "variable $Name not found in $Relative" }
        $m.Value
    }
}

Describe 'Scripts that a schema 5 script replaces are removed' {
    It 'is gone: <_>' -ForEach @(
        'scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/powershell/Set-RbacRoleAssignments.ps1'
        'scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/powershell/Test-RbacRoleAssignments.ps1'
        'scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/task-02-assign-rbac-roles/powershell/Set-RbacRoleAssignments.ps1'
        'scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn/powershell/New-DeploymentServicePrincipal.ps1'
        'scripts/common/service-principals/New-PipelineSP.ps1'
        'scripts/common/service-principals/New-ArcOnboardingSP.ps1'
        'scripts/common/utilities/tools/Add-KeyVaultCredentials.ps1'
        'scripts/deploy/03-onprem-readiness/phase-01-active-directory/task-03-dns-node-a-records/powershell/Set-DnsForwarding.ps1'
    ) {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $_.Replace('/', [IO.Path]::DirectorySeparatorChar))) | Should -BeFalse
    }
    It 'the schema 5 scripts that replace them are there' -ForEach @(
        'scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/task-02-assign-rbac-roles/powershell/Set-EntraGroupRoleAssignments.ps1'
        'scripts/deploy/02-azure-foundation/phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn/powershell/New-AutomationManagedIdentity.ps1'
    ) {
        Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $_.Replace('/', [IO.Path]::DirectorySeparatorChar))) | Should -BeTrue
    }
    It 'no live script or task catalogue entry names a removed script' {
        $offenders = foreach ($f in Get-ChildItem -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts')) -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Where-Object { $_.FullName -notmatch '[\\/]deferred[\\/]' }) {
            $code = Get-CodeText ($f.FullName.Substring($script:Repo.Length + 1).Replace('\', '/'))
            foreach ($name in 'New-PipelineSP', 'New-ArcOnboardingSP', 'New-DeploymentServicePrincipal', 'Set-DnsForwarding', 'Set-SecretToKeyVault', 'Set-ServicePrincipalToKeyVault', 'Get-ServicePrincipalFromKeyVault') {
                if ($code -match [regex]::Escape($name)) { "$($f.Name) names $name" }
            }
        }
        @($offenders) | Should -BeNullOrEmpty
    }
    It 'the phase 03 catalogue entry of the removed task folder is gone and the task folders are in the catalogue' {
        (Get-RepoText 'scripts/deploy/common/TaskCatalogue.psd1') | Should -Not -Match "Path = '02-azure-foundation/phase-03-rbac-permissions';"
    }
}

Describe 'keyvault-helper.ps1 writes no secret and names no secret' {
    It 'has no Key Vault call of its own, no sp-<name> convention and no literal provider' {
        $code = Get-CodeText 'scripts/common/utilities/helpers/keyvault-helper.ps1'
        $code | Should -Not -Match 'Set-AzKeyVaultSecret|Get-AzKeyVaultSecret|az\s+keyvault'
        $code | Should -Not -Match '"sp-|''sp-|-appid|-secret"'
        $code | Should -Not -Match '-Provider\s+keyvault'
    }
    It 'Get-SecretFromConfig builds the reference in the provider the file selects (no -Provider)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'utilities', 'helpers', 'keyvault-helper.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SecretFromConfig' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($fn.Extent.Text))
        function New-AzlSecretReference { [CmdletBinding()] param([string]$Name, [object]$Infrastructure, [string]$Provider, [string]$Vault) 'env://TEST_ONLY' }
        function Get-SecretFromUri { [CmdletBinding()] param([string]$Uri, [object]$Infrastructure, [switch]$AsPlainText) "read:$Uri" }
        Mock New-AzlSecretReference { 'env://TEST_ONLY' }
        Mock Get-SecretFromUri { "read:$Uri" }
        Get-SecretFromConfig -Config @{} -SecretName 'any-name' | Should -Be 'read:env://TEST_ONLY'
        Should -Invoke New-AzlSecretReference -Times 1 -Exactly -ParameterFilter { $Name -eq 'any-name' -and -not $Provider }
    }
}

Describe 'Constants Microsoft fixes are named, with their source' {
    It 'the VPN gateway script names the AZ SKU family, the gateway type and the route-based type' {
        $text = Get-RepoText 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-02-vpn-gateway/powershell/Deploy-VpnGateway.ps1'
        $text | Should -Match '(?m)^\$GatewayType = ''Vpn''\r?$'
        $text | Should -Match '(?m)^\$VpnType = ''RouteBased''\r?$'
        $text | Should -Match '(?m)^\$Generation1Sku = ''VpnGw1AZ''\r?$'
        $text | Should -Match 'Microsoft Learn: VPN Gateway SKU consolidation'
        (Get-CodeText 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-02-vpn-gateway/powershell/Deploy-VpnGateway.ps1') | Should -Not -Match "(?<!\$)GatewayType = 'Vpn'|(?<!\$)VpnType = 'RouteBased'|-eq 'VpnGw1AZ'"
    }
    It 'the Key Vault script names the SKU and says what fixes it' {
        $path = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-10-key-vault/powershell/Deploy-KeyVaults.ps1'
        (Get-RepoText $path) | Should -Match '(?m)^\$VaultSku = ''Standard''\r?$'
        (Get-RepoText $path) | Should -Match 'Azure Key Vault service tiers'
        (Get-CodeText $path) | Should -Not -Match "(?<![A-Za-z])Sku = 'Standard'"
    }
    It 'the iDRAC baseline attribute is a named constant in both scripts' -ForEach @(
        @{ Path = 'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-04-bios-and-idrac-settings-validation/powershell/Test-BiosIdracSettings.ps1' }
        @{ Path = 'scripts/deploy/04-cluster-deployment/phase-01-hardware-provisioning/task-05-bios-and-idrac-settings-remediation/powershell/Set-BiosIdracSettings.ps1' }
    ) {
        (Get-RepoText $Path) | Should -Match '(?m)^\$IdracIpmiLanAttribute = ''IPMILan\.1#Enable''\r?$'
        (Get-RepoText $Path) | Should -Match 'Dell iDRAC attribute\s+# registry'
    }
}

Describe 'The authoring template generates scripts that read registered keys' {
    It 'has no vault name, no platform.kv_platform key and no old-layout key path' {
        $text = Get-RepoText 'scripts/tools/authoring/New-ScriptFromTemplate.ps1'
        $text | Should -Not -Match 'kv-yourplatform|kv_platform|azure\.tenant\.id|azure\.subscriptions\.demo|\["subscriptions"\]\["demo"\]'
        $text | Should -Match 'key_vaults\[0\]\.name'
    }
}

Describe 'Terraform variables that the generator feeds from the file have no literal default' {
    It 'the environment: <Name>' -ForEach @(
        @{ Name = 'log_analytics_retention_days' }
        @{ Name = 'vm_admin_username' }
        @{ Name = 'windows_server_sku' }
    ) {
        (Get-TfVariable 'src/terraform/environments/azure-local/variables.tf' $Name) | Should -Not -Match '(?m)^\s*default\s*=(?!\s*null\s*$)'   # default = null means not set (Azure decides); a literal value is not allowed
    }
    It 'the modules: <File> <Name>' -ForEach @(
        @{ File = 'src/terraform/modules/monitoring/variables.tf'; Name = 'retention_days' }
        @{ File = 'src/terraform/modules/compute/variables.tf'; Name = 'admin_username' }
        @{ File = 'src/terraform/modules/compute/variables.tf'; Name = 'windows_server_sku' }
    ) {
        (Get-TfVariable $File $Name) | Should -Not -Match '(?m)^\s*default\s*=(?!\s*null\s*$)'   # default = null means not set (Azure decides); a literal value is not allowed
    }
    It 'the deployment principal roles, the NAT gateway and the gateway SKUs carry no deployment value' {
        foreach ($file in 'src/terraform/environments/azure-local/variables.tf', 'src/terraform/modules/networking/variables.tf', 'src/terraform/modules/identity/variables.tf') {
            $text = Get-RepoText $file
            $text | Should -Not -Match 'VpnGw\d|Contributor|User Access Administrator|Azure Stack HCI Administrator|Generation\d|optional\(string, "Standard"\)'
        }
        (Get-TfVariable 'src/terraform/modules/networking/variables.tf' 'nat_gateway_idle_timeout') | Should -Match 'default\s*=\s*null'
        (Get-TfVariable 'src/terraform/modules/networking/variables.tf' 'enable_nat_gateway') | Should -Match 'default\s*=\s*false'
    }
    It 'the generation follows the SKU in the module, as Microsoft documents' {
        $text = Get-RepoText 'src/terraform/modules/networking/main.tf'
        $text | Should -Match 'generation\s*=\s*var\.vpn_config\.sku == "VpnGw1AZ" \? "Generation1" : "Generation2"'
    }
    It 'the management group display names come from the file, not from the module' {
        $text = Get-RepoText 'src/terraform/modules/landing-zone/main.tf'
        $text | Should -Not -Match 'display_name\s*=\s*"'
        foreach ($role in 'identity', 'connectivity', 'management', 'security', 'landing_zones') { $text | Should -Match "var\.management_groups\.${role}_display_name" }
    }
    It 'the Key Vault network rules follow the allowed ranges, and the cluster vault keeps the Azure default' {
        $text = Get-RepoText 'src/terraform/modules/identity/main.tf'
        $text | Should -Match 'length\(var\.key_vault_allowed_ips\) > 0'
        $text | Should -Not -Match '(?m)^\s*network_acls\s*\{'
        $text | Should -Match 'local\.key_vault_sku'
        $text | Should -Not -Match 'sku_name\s*=\s*"'
    }
}

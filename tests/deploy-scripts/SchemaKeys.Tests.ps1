#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# infrastructure.yml (schema 5) is the one environment file. The keys of the earlier layouts (schema 4 and the toolkit's variables.yml:
# compute.azure_local.*, network_config.*, identity.accounts.*, azure_platform.*, cluster_arm_deployment.* and the others listed below)
# are gone from the schema, so no script under scripts/ may read them. Where a value has a schema 5 key, the scripts read that key;
# where several scripts read the same thing they use a reader of scripts/common/infrastructure/AzlInfrastructure.psm1
# (Get-AzlManagementNetwork, Get-AzlManagementNicName, Get-AzlArcGateway, Get-AzlClusterWitness, Get-AzlInfrastructureNode).
# Reads files only; nothing runs against Azure or a node.
# Run: Invoke-Pester ./tests/deploy-scripts/SchemaKeys.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $repo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $scripts = [System.IO.Path]::Combine($repo, 'scripts')
    $rel = { param($p) [System.IO.Path]::GetRelativePath($repo, $p).Replace('\', '/') }

    # The keys that are gone, with the schema 5 key a script reads instead.
    $script:Removed = @(
        @{ Id = 'compute.azure_local'; Regex = 'compute\.azure_local\b'; Now = 'cluster.name, azure.*, networking.management.* (Get-AzlManagementNetwork), networking.outbound.arc_gateway (Get-AzlArcGateway), cluster.witness (Get-AzlClusterWitness)' }
        @{ Id = 'network_config'; Regex = 'network_config\.'; Now = 'the management port of nodes[] (Get-AzlManagementNicName, Get-AzlManagementAdapter)' }
        @{ Id = 'identity.accounts'; Regex = 'identity\.accounts\b'; Now = 'identity.local_admin.*, identity.active_directory.lcm_user.*' }
        @{ Id = 'accounts.local_admin / accounts.lcm_admin'; Regex = '(?<!identity\.)\baccounts\.(local_admin|lcm_admin)\b'; Now = 'identity.local_admin.*, identity.active_directory.lcm_user.*' }
        @{ Id = 'azure_platform'; Regex = 'azure_platform\b'; Now = 'azure.tenant_id, subscription_id, location, resource_group' }
        @{ Id = 'azure.resource_group_name'; Regex = '\bazure\.resource_group_name\b'; Now = 'azure.resource_group' }
        @{ Id = 'cluster_arm_deployment'; Regex = 'cluster_arm_deployment\.'; Now = 'cluster.name, cluster.deployment_mode, identity.active_directory.domain_fqdn and ou_path, azure.hci_resource_provider_object_id' }
        @{ Id = 'identity.active_directory.fqdn'; Regex = 'identity\.active_directory\.fqdn\b'; Now = 'identity.active_directory.domain_fqdn' }
        @{ Id = 'identity.active_directory.ad_*'; Regex = 'identity\.active_directory\.ad_(domain_fqdn|netbios_name|ou_path|clusters_ou_path)\b'; Now = 'identity.active_directory.domain_fqdn, netbios_name, ou_path' }
        @{ Id = 'identity.active_directory.ntp_servers'; Regex = 'active_directory\.ntp_servers\b'; Now = 'networking.ntp_servers' }
        @{ Id = 'identity.azure_identity'; Regex = 'identity\.azure_identity\b'; Now = 'azure.tenant_id, azure.subscription_id' }
        @{ Id = 'identity.service_principal.client_id'; Regex = 'identity\.service_principal\.client_id\b'; Now = 'azure.automation_identity.client_id' }
        @{ Id = 'platform.cluster_name'; Regex = '(?<![\w])platform\.cluster_name\b'; Now = 'cluster.name' }
        @{ Id = 'security.keyvault.kv_azl'; Regex = 'security\.keyvault\.kv_azl\b'; Now = 'cluster.key_vault.name' }
        @{ Id = 'management_ip: / region: / arc_gateway_id: / spn_id: scraped from the text'; Regex = "Select-String\s+['""](management_ip|region|arc_gateway_id|spn_id):"; Now = 'ConvertFrom-Yaml and the readers of AzlInfrastructure.psm1' }
    )

    # Files that are not checked, with the reason. Out of scope for the move to schema 5 keys.
    $script:OutOfScope = @{
        'scripts/common/utilities/tools/Generate-ClusterConfigMD.ps1' =
        'reads per-node fields and many sections schema 5 has no key for (see tests/deploy-scripts/NodeLayout.Tests.ps1)'
        'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Invoke-SSHConnectivity-Orchestrated.ps1' =
        'reads the per-node field arc_resource_id (see tests/deploy-scripts/NodeLayout.Tests.ps1)'
        'scripts/lifecycle/operations/powershell/Invoke-NodeMaintenanceReboot.ps1' =
        'matches the target node by the per-node field fqdn (see tests/deploy-scripts/NodeLayout.Tests.ps1)'
    }

    # Reads that stay on a removed key, because schema 5 has no key for the value. One entry per file and key; the test for a left
    # read fails once the file no longer reads the key, so the entry goes when the file is fixed.
    $vmSwitch = 'compute.azure_local.vm_switch_name: the name of the virtual switch. Schema 5 has no key for it (it is found on the node and written back); the scripts fall back to finding it on the node'
    $rgRole = 'azure_platform.resource_groups.<role>: the resource group of a role (network, management, identity). Schema 5 has landing_zone.resource_groups[] with a free-text purpose, no role key; the script fails with "ResourceGroupName is required" unless the parameter is given'
    $left = @(
        @{ File = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Get-VirtualSwitchName.ps1'; Id = 'compute.azure_local'; Reason = $vmSwitch }
        @{ File = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Get-VirtualSwitchName-Standalone.ps1'; Id = 'compute.azure_local'; Reason = $vmSwitch }
        @{ File = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Invoke-DeploySDN-Orchestrated.ps1'; Id = 'compute.azure_local'; Reason = $vmSwitch }
        @{ File = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-02-vpn-gateway/powershell/New-VpnGateway.ps1'; Id = 'azure_platform'; Reason = $rgRole }
        @{ File = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-03-s2s-vpn-connection/powershell/New-VpnConnection.ps1'; Id = 'azure_platform'; Reason = $rgRole }
        @{ File = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-07-nat-gateway/powershell/New-NatGateway.ps1'; Id = 'azure_platform'; Reason = $rgRole }
        @{ File = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/task-12-configure-adds/powershell/New-DomainController.ps1'; Id = 'azure_platform'; Reason = $rgRole }
        @{ File = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/task-14-configure-ndm-server/powershell/New-NdmServer.ps1'; Id = 'azure_platform'; Reason = $rgRole }
    )

    $files = @(Get-ChildItem -LiteralPath $scripts -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
    $text = @{}
    foreach ($f in $files) { $text[(& $rel $f.FullName)] = [System.IO.File]::ReadAllText($f.FullName) }

    # For each removed key, the files to check: every script that is not out of scope and not left on that key on purpose.
    $script:KeyCase = @(foreach ($k in $script:Removed) {
            $leftFiles = @($left | Where-Object { $_.Id -eq $k.Id } | ForEach-Object { $_.File })
            $offender = @($text.Keys | Where-Object { -not $script:OutOfScope.ContainsKey($_) -and $_ -notin $leftFiles -and [regex]::IsMatch($text[$_], $k.Regex) } | Sort-Object)
            @{ Id = $k.Id; Now = $k.Now; Offender = $offender; Checked = $text.Count }
        })
    $script:LeftCase = @($left | ForEach-Object {
            $entry = $_
            $key = $script:Removed | Where-Object { $_.Id -eq $entry.Id } | Select-Object -First 1
            @{ File = $entry.File; Id = $entry.Id; Reason = $entry.Reason; Regex = $key.Regex; Path = (Join-Path $repo $entry.File) }
        })
    $script:OutCase = @($script:OutOfScope.Keys | Sort-Object | ForEach-Object { @{ File = $_; Reason = $script:OutOfScope[$_]; Path = (Join-Path $repo $_) } })
    $script:Count = $text.Count

    # Scripts that call a reader of AzlInfrastructure.psm1 must import it.
    $readers = 'Get-AzlInfrastructureNode|Get-AzlManagementNetwork|Get-AzlManagementNicName|Get-AzlArcGateway|Get-AzlClusterWitness'
    $script:CallerFile = @(
        $files | Where-Object { $_.FullName -notmatch '[\\/]common[\\/]infrastructure[\\/]' } | ForEach-Object {
            if ($text[(& $rel $_.FullName)] -match "\b($readers)\b") { @{ Path = $_.FullName; Relative = (& $rel $_.FullName) } }
        }
    )
}

Describe 'Schema 4 keys in the scripts' {
    It 'no script reads <Id> (<Checked> files checked)' -ForEach $script:KeyCase {
        $Offender | Should -BeNullOrEmpty -Because ("these files still read '$Id'; read $Now instead: " + ($Offender -join ', '))
    }

    It 'there are scripts to check' -ForEach @(@{ Count = $script:Count }) {
        $Count | Should -BeGreaterThan 300
    }

    It '<File> is left on purpose and still reads <Id>' -ForEach $script:LeftCase {
        Test-Path -LiteralPath $Path | Should -BeTrue -Because 'the file is on the list of reads left on purpose'
        [regex]::IsMatch([System.IO.File]::ReadAllText($Path), $Regex) | Should -BeTrue -Because 'the file was fixed: remove it from the list'
        $Reason | Should -Not -BeNullOrEmpty
    }

    It '<File> is out of scope and exists' -ForEach $script:OutCase {
        Test-Path -LiteralPath $Path | Should -BeTrue
        $Reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'Scripts that call a reader of AzlInfrastructure.psm1' {
    It '<Relative> imports AzlInfrastructure.psm1 from a path that exists' -ForEach $script:CallerFile {
        $text = Get-Content -LiteralPath $Path -Raw
        $match = [regex]::Match($text, "Import-Module \(\[IO\.Path\]::GetFullPath\(\[IO\.Path\]::Combine\(\`$PSScriptRoot, (?<parts>[^)]*)\)\)\)")
        $match.Success | Should -BeTrue -Because 'the script must import the module that defines the reader it calls'
        $parts = @([regex]::Matches($match.Groups['parts'].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
        $parts[-1] | Should -Be 'AzlInfrastructure.psm1'
        $segments = [string[]](@([System.IO.Path]::GetDirectoryName($Path)) + $parts)
        $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($segments))
        Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue -Because "$resolved must exist"
    }

    It '<Relative> declares a PowerShell version' -ForEach $script:CallerFile {
        (Get-Content -LiteralPath $Path -Raw) | Should -Match '(?m)^#Requires\s+-Version\s+\d'
    }
}

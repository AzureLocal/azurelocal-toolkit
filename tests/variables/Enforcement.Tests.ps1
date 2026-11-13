#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# No script carries a value a deployment chooses, and every key a script reads from the infrastructure file is registered.
# The test parses every .ps1 and .psm1 under scripts/ with the PowerShell parser (so comments and help text do not count) and fails on:
#   A  a key path read from the infrastructure file that is not in the master registry (Get-AzlInfrastructureValue, or the property and
#      indexer chains and reader commands the variable map recognises: config/variables/scripts/VariableMapScanner.psm1).
#   B  a hard-coded value of a kind a deployment chooses: an IPv4 address or CIDR, a GUID, a DNS domain or host name, an Azure region name,
#      a Key Vault name, an Azure resource name, a subscription, tenant or resource group literal.
#   C  a parameter whose non-empty default is such a value (the same kinds, plus a default for a parameter named like one of them).
#   D  a prompt (Read-Host, Get-Credential, $Host.UI.Prompt*, [Console]::ReadLine) in a script that has -InfrastructureFile.
# What is not a violation is written down twice over:
#   * values Microsoft or the protocol fixes are rule-level exceptions in this file, each with its reason (documentation, loopback,
#     link-local and mask addresses, the Azure platform address, Microsoft endpoints, built-in role IDs ...);
#   * everything else needs a line in tests/variables/enforcement-allowlist.psd1 (a reviewed exception, with a reason) or, for a legacy
#     script that is not migrated yet, in tests/variables/enforcement-baseline.psd1 (known debt: counted, printed, and not allowed to grow).
# A line in either file that no longer matches fails the test, so neither list can rot. A violation in neither file fails the test.
# Details: config/variables/README.md (No hard-coded values in scripts). Set AZL_ENFORCE_DUMP=<file.csv> to write every finding (before the two lists) to a file.
# Reads files only; nothing runs against Azure or a node.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/Enforcement.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Helpers build lists in memory.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:ScriptsRoot = [IO.Path]::Combine($script:Repo, 'scripts')
    $script:VariableScripts = [IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts')
    Import-Module ([IO.Path]::Combine($script:VariableScripts, 'VariableRegistry.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:VariableScripts, 'VariableMapScanner.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    $script:MapIndex = Get-MapIndex -Record $script:Registry

    # ------------------------------------------------------------------------------------------------------------------------------
    # Rule-level exceptions: values Microsoft or a protocol fixes. Not per file. Each has its reason; the self-tests below use them.
    # ------------------------------------------------------------------------------------------------------------------------------

    # Addresses that are not a deployment choice. The first match wins; Reason is the class named in the report.
    # Test gets the address: Number, Octet (4 numbers), Length (prefix length, -1 when none), Text (as written) and Whole (the whole string).
    $script:AddressException = @(
        @{ Reason = 'documentation range (RFC 5737)'; Test = { param($a) $o = $a.Octet; ($o[0] -eq 192 -and $o[1] -eq 0 -and $o[2] -eq 2) -or ($o[0] -eq 198 -and $o[1] -eq 51 -and $o[2] -eq 100) -or ($o[0] -eq 203 -and $o[1] -eq 0 -and $o[2] -eq 113) } }
        @{ Reason = 'loopback (127.0.0.0/8)'; Test = { param($a) $a.Octet[0] -eq 127 } }
        @{ Reason = 'link-local / APIPA (169.254.0.0/16), includes the instance metadata service 169.254.169.254'; Test = { param($a) $a.Octet[0] -eq 169 -and $a.Octet[1] -eq 254 } }
        @{ Reason = 'unspecified address 0.0.0.0, with or without a prefix length (all addresses, the default route)'; Test = { param($a) $a.Number -eq 0 } }
        @{ Reason = 'subnet mask or wildcard of a prefix length (255.x.x.x)'; Test = { param($a) $inv = (-bnot $a.Number) -band 4294967295; $a.Length -lt 0 -and $a.Octet[0] -eq 255 -and ($inv -band ($inv + 1)) -eq 0 } }
        @{ Reason = 'Azure platform virtual address 168.63.129.16 (DNS, DHCP, health probes; fixed by Microsoft)'; Test = { param($a) $a.Text -eq '168.63.129.16' } }
        @{ Reason = 'private address block definition (RFC 1918): the block itself, not an address in it'; Test = { param($a) $a.Text -in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' } }
        @{ Reason = 'shared address space (RFC 6598) and multicast block definitions'; Test = { param($a) $a.Text -in '100.64.0.0/10', '224.0.0.0/4' } }
        @{ Reason = 'range the Arc resource bridge reserves for Kubernetes (Microsoft Learn, Azure Local network considerations, Decision 8)'; Test = { param($a) $a.Text -in '10.244.0.0/16', '10.96.0.0/24', '10.96.0.0/12' } }
        @{ Reason = 'public DNS resolver Azure Local refuses (Learn: public DNS such as 8.8.8.8 is not supported); the list is how the checks recognise them'; Test = { param($a) $a.Text -in '8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220' } }
        @{ Reason = 'X.509 extension object identifier (2.5.29.17 subject alternative name, 2.5.29.37 enhanced key usage): fixed by the standard, not an address'; Test = { param($a) $a.Text -in '2.5.29.17', '2.5.29.37' } }
        @{ Reason = 'ARM deployment-parameters contentVersion: fixed by the schema, not an address'; Test = { param($a) $a.Whole -eq '1.0.0.0' } }
        @{ Reason = 'version part of a Windows capability name (OpenSSH.Server~~~~0.0.1.0): fixed by Microsoft, not an address'; Test = { param($a) $a.Whole.Contains('~~~~' + $a.Text) } }
    )

    # GUIDs Microsoft fixes: built-in Azure role definition IDs and first-party application IDs. Name = what it is.
    $script:KnownGuid = @{
        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' = 'Azure built-in role Owner'
        'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Azure built-in role Contributor'
        'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Azure built-in role Reader'
        '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' = 'Azure built-in role User Access Administrator'
        'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Azure built-in role Storage Blob Data Contributor'
        '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' = 'Azure built-in role Storage Blob Data Reader'
        'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' = 'Azure built-in role Storage Blob Data Owner'
        '4633458b-17de-408a-b874-0445c86b69e6' = 'Azure built-in role Key Vault Secrets User'
        'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' = 'Azure built-in role Key Vault Secrets Officer'
        '00482a5a-887f-4fb3-b363-3b7fe8e74483' = 'Azure built-in role Key Vault Administrator'
        '21090545-7ca7-4776-b22c-e363652d74d2' = 'Azure built-in role Key Vault Reader'
        '749f88d5-cbae-40b8-bcfc-e573ddc772fa' = 'Azure built-in role Monitoring Contributor'
        '92aaf0da-9dab-42b6-94a3-d43ce8d16293' = 'Azure built-in role Log Analytics Contributor'
        '73c42c96-874c-492b-b04d-ab87d138a893' = 'Azure built-in role Log Analytics Reader'
        'bda0d508-adf1-4af0-9c28-88919fc3ae06' = 'Azure built-in role Azure Stack HCI Administrator'
        'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7' = 'Azure built-in role Azure Connected Machine Onboarding'
        'cd570a14-e51a-42ad-bac8-bafd67325302' = 'Azure built-in role Azure Connected Machine Resource Administrator'
        '865ae368-6a45-4bd1-8fbf-0d5151f56fc1' = 'Azure built-in role Azure Stack HCI Device Management Role'
        '874d1c73-6003-4e60-a13a-cb31ea190a85' = 'Azure built-in role Azure Stack HCI VM Contributor'
        '00000003-0000-0000-c000-000000000000' = 'Microsoft Graph application ID'
        '00000002-0000-0000-c000-000000000000' = 'Azure Active Directory Graph application ID'
        '797f4846-ba00-4fd7-ba43-dac1f8f63013' = 'Azure Service Management API application ID'
        '1412d89f-b8a8-4111-b4fd-e82905cbd85d' = 'Microsoft.AzureStackHCI resource provider application ID (Microsoft Learn: deploy Azure Local with an ARM template)'
        '1f3afdf9-d0c9-4c3d-847f-89da613e70a8' = 'Azure built-in policy initiative Microsoft cloud security benchmark'
        '871b6d14-10aa-478d-b590-94f262ecfa99' = 'Azure built-in policy Require a tag on resources'
        'bf967a86-0de6-11d0-a285-00aa00302ce8' = 'Active Directory schema class Computer (schemaIDGUID)'
        '55c92734-d682-4d71-983e-d6ec3f16059f' = 'Windows operating system ApplicationId in SoftwareLicensingProduct'
        'e6cf1350-c01b-414d-a61f-263d14d133b4' = 'Windows Update category Critical Updates'
        '499b84ac-1321-427f-aa17-267ca6975798' = 'Azure DevOps resource application ID'
        '9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8' = 'Microsoft Graph app role RoleManagement.ReadWrite.Directory'
        'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd' = 'Azure DevOps branch policy type Minimum number of reviewers'
        'c6a1889d-b943-4856-b76f-9e46bb6b0df2' = 'Azure DevOps branch policy type Comment requirements'
        'fa4e907d-c16b-4a4c-9dfa-4916e5d171ab' = 'Azure DevOps branch policy type Require a merge strategy'
        '40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e' = 'Azure DevOps branch policy type Work item linking'
        'fd2167ab-b0be-447a-8ec8-39368250530e' = 'Azure DevOps branch policy type Required reviewers'
        '8c6f20a7-a545-4486-9777-f762fafe0d4d' = 'Azure DevOps approval check type'
        'fe1de3ee-a436-41b4-bb20-f6eb4cb879a7' = 'Azure DevOps task check type'
        '86b05a0c-73e6-4f7d-b3cf-e38f3b39a75b' = 'Azure DevOps evaluatebranchProtection task definition'
        'c632b3df-fb67-4d84-bdcf-b95ad541b5c8' = 'Microsoft-registered Azure VPN Client application ID of the Azure public cloud, the audience of Microsoft Entra ID sign-in on a VPN gateway (Microsoft Learn: Configure P2S VPN Gateway for Microsoft Entra ID authentication)'
    }

    # Names of Azure regions (the API names). A value that equals one, outside a comparison or a table of regions, is a default.
    $script:RegionName = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in 'eastus eastus2 eastus3 westus westus2 westus3 centralus northcentralus southcentralus westcentralus canadacentral canadaeast brazilsouth brazilsoutheast mexicocentral northeurope westeurope uksouth ukwest francecentral francesouth germanywestcentral germanynorth switzerlandnorth switzerlandwest norwayeast norwaywest swedencentral swedensouth polandcentral italynorth spaincentral austriaeast eastasia southeastasia japaneast japanwest koreacentral koreasouth australiaeast australiasoutheast australiacentral australiacentral2 centralindia southindia westindia jioindiawest jioindiacentral uaenorth uaecentral southafricanorth southafricawest qatarcentral israelcentral chilecentral indonesiacentral malaysiawest newzealandnorth taiwannorth'.Split(' ')) { [void]$script:RegionName.Add($r) }

    # DNS: domains that are not a deployment choice. A host name under one of these is fine, with one exception below.
    $script:DomainException = @(
        @{ Reason = 'the neutral example domain'; Pattern = '(^|\.)improbability\.cloud$' }
        @{ Reason = 'reserved for documentation (RFC 2606)'; Pattern = '(^|\.)example\.(com|net|org)$' }
        @{ Reason = 'Microsoft-owned endpoint'; Pattern = '(^|\.)(microsoft\.com|microsoftonline\.com|microsoftonline-p\.com|windows\.net|windowsazure\.com|azure\.com|azure\.net|azure-api\.net|azureedge\.net|azurefd\.net|azurewebsites\.net|trafficmanager\.net|microsoftmetrics\.com|msftcloudes\.com|msftconnecttest\.com|waconazure\.com|msauth\.net|msftauth\.net|live\.com|office\.com|office365\.com|office\.net|sharepoint\.com|onmicrosoft\.com|windows\.com|windowsupdate\.com|msftncsi\.com|aka\.ms|visualstudio\.com|powershellgallery\.com|nuget\.org|dot\.net)$' }
        @{ Reason = 'Microsoft container registry that Azure Local requires (Microsoft Learn: firewall requirements for Azure Local)'; Exact = $true; Pattern = '^(azurestackhci|hciarcvmscontainerregistry|kvamanagementoperator|azurearcfork8s|azurearcfork8sdev|linuxgeneva-microsoft|hybridaks|aszk8snetworking|ecpacr)\.azurecr\.io$' }
        @{ Reason = 'placeholder host in Microsoft''s firewall requirements table'; Exact = $true; Pattern = '^yourhcikeyvaultname\.vault\.azure\.net$' }
        @{ Reason = 'GitHub (Microsoft-owned) public endpoint'; Pattern = '(^|\.)(github\.com|githubusercontent\.com)$' }
        @{ Reason = 'certificate revocation (CRL, OCSP) endpoint of a public certificate authority, listed in Microsoft''s firewall requirements for Azure Local'; Pattern = '(^|\.)(digicert\.com|symantec\.com|symcd\.com|globalsign\.com)$' }
        @{ Reason = 'the AzureLocal project''s own documentation site'; Pattern = '^(azurelocal\.cloud|azurelocal\.github\.io)$' }
    )
    # A host under a Microsoft suffix that names a customer resource (storage account, vault, registry, tenant ...) is a resource name.
    $script:ResourceHost = @(
        '^(?<i>[^.]+)\.(blob|file|queue|table|dfs|web)\.core\.windows\.net$', '^(?<i>[^.]+)\.vault\.azure\.net$', '^(?<i>[^.]+)\.azurecr\.io$',
        '^(?<i>[^.]+)\.azurewebsites\.net$', '^(?<i>[^.]+)\.onmicrosoft\.com$', '^(?<i>[^.]+)\.sharepoint\.com$', '^(?<i>[^.]+)\.database\.windows\.net$'
    )

    # Resource name prefixes (Cloud Adoption Framework abbreviations) and the neutral example prefix. A whole string of the form prefix-something.
    $script:ResourceNamePattern = '^(?:rg|kv|vnet|snet|nsg|log|law|st|vm|nic|pip|lb|vgw|lgw|nat|agw|bas|fw|rt|afw|dcr|dce|acr|aks|appi|iic)-[a-z0-9][a-z0-9-]*$'
    # Parameters, variables and keys that hold a subscription, tenant, resource group or vault: a literal given to one is a value.
    $script:EnvironmentName = '^(subscription(_?id)?|tenant(_?id)?|resource_?group(_?name)?|(key_?)?vault(_?name)?)$'
    # Names of change kinds in the node configuration plan. They look like resource names (nic-*) and are not.
    $script:ResourceNameException = @{ 'nic-static' = 1; 'nic-vlan' = 1; 'nic-dns' = 1; 'nic-clean' = 1; 'nic-disable' = 1; 'nic-rename' = 1 }
    # Variables that hold the whole infrastructure file in the scripts; a chain from one of them is certainly a read of the file.
    $script:FileVariable = 'infrastructure', 'infra', 'inf', 'infradata', 'infrastructuredata', 'masterfile'
    $script:DomainTld = 'com|net|org|io|cloud|local|lan|corp|internal|edu|gov|mil|us|uk|de|ms|info|biz|test|localdomain|home|intranet|private'

    # ------------------------------------------------------------------------------------------------------------------------------
    # The scan
    # ------------------------------------------------------------------------------------------------------------------------------
    $script:L = 'System.Management.Automation.Language'

    function Get-EnfRelative([string]$Full) { [IO.Path]::GetRelativePath($script:Repo, $Full).Replace('\', '/') }

    function ConvertTo-EnfAddress {
        param([string]$Text)
        foreach ($m in [regex]::Matches($Text, '(?<![\w.])(?<ip>(?:\d{1,3}\.){3}\d{1,3})(?:/(?<len>\d{1,2}))?(?!\w|\.\d)')) {
            $octet = @($m.Groups['ip'].Value.Split('.') | ForEach-Object { [int]$_ })
            if (($octet | Where-Object { $_ -gt 255 })) { continue }
            $len = if ($m.Groups['len'].Success) { [int]$m.Groups['len'].Value } else { -1 }
            if ($len -gt 32) { continue }
            [pscustomobject]@{ Text = $m.Value; Whole = $Text.Trim(); Octet = $octet; Length = $len; Number = ([long]$octet[0] -shl 24) + ([long]$octet[1] -shl 16) + ([long]$octet[2] -shl 8) + [long]$octet[3] }
        }
    }

    function Get-EnfAddressException([object]$Address) {
        foreach ($e in $script:AddressException) { if (& $e.Test $Address) { return $e.Reason } }
        return $null
    }

    function Get-EnfListLiteral {
        # How a finding is written in the allow-list and the baseline. An address is masked (10.x.x.x/24): the lists never hold a
        # value that could be real. Everything else is written as found.
        param($Item)
        if ($Item.Kind -eq 'ipv4' -and $Item.Literal -match '^(?<first>\d+)\.\d+\.\d+\.\d+(?<len>/\d+)?$') { return "$($Matches['first']).x.x.x$($Matches['len'])" }
        return [string]$Item.Literal
    }

    function ConvertTo-EnfDomain {
        # Host names and domains in a text (variables in an expandable string are replaced by "zvarz" first).
        param([string]$Text)
        $pattern = '(?<![\w.$-])(?<h>(?:[a-z0-9_*](?:[a-z0-9_-]*[a-z0-9_])?\.)+(?:' + $script:DomainTld + '))(?![\w-]|\.[a-z0-9])'
        foreach ($m in [regex]::Matches($Text, $pattern, 'IgnoreCase')) {
            $h = $m.Groups['h'].Value
            $labels = $h.Split('.')
            if ($labels[0] -ieq 'System') { continue }                       # a .NET type: System.Net, System.IO
            if ($labels[-1] -cmatch '^[A-Z][a-z]+$') { continue }            # a type name: Microsoft.Net
            $h.ToLowerInvariant()
        }
    }

    function Get-EnfDomainVerdict([string]$HostName) {
        # Returns the reason class when allowed, $null when not, and 'RESOURCE' when it names a customer resource.
        foreach ($e in $script:DomainException) { if ($e.Exact -and $HostName -match $e.Pattern) { return $e.Reason } }
        foreach ($p in $script:ResourceHost) {
            $m = [regex]::Match($HostName, $p)
            if ($m.Success -and $m.Groups['i'].Value -notin 'zvarz', '*') { return 'RESOURCE' }
        }
        foreach ($e in $script:DomainException) { if (-not $e.Exact -and $HostName -match $e.Pattern) { return $e.Reason } }
        return $null
    }

    function Get-EnfSlot {
        # Where the string sits: the assignment, parameter default, hashtable entry, command argument or comparison that holds it.
        param($Node)
        $L = $script:L
        $child = $Node
        $parent = $Node.Parent
        $wrap = "$L.CommandExpressionAst", "$L.PipelineAst", "$L.ArrayLiteralAst", "$L.ArrayExpressionAst", "$L.ParenExpressionAst", "$L.ConvertExpressionAst", "$L.StatementBlockAst", "$L.UnaryExpressionAst"
        while ($null -ne $parent -and $parent.GetType().FullName -in $wrap) { $child = $parent; $parent = $parent.Parent }
        if ($null -eq $parent) { return @{ Kind = 'Other'; Name = $null } }
        switch -Wildcard ($parent.GetType().Name) {
            'AssignmentStatementAst' {
                if ([object]::ReferenceEquals($parent.Right, $child)) {
                    $left = $parent.Left
                    $name = if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) { $left.VariablePath.UserPath } elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst]) { [string]$left.Member } else { $left.Extent.Text }
                    return @{ Kind = 'Assign'; Name = ($name -replace '^.*:', '') }
                }
            }
            'ParameterAst' { return @{ Kind = 'Default'; Name = $parent.Name.VariablePath.UserPath } }
            'HashtableAst' {
                foreach ($pair in $parent.KeyValuePairs) {
                    if ([object]::ReferenceEquals($pair.Item2, $child) -or $pair.Item2.Extent.StartOffset -le $Node.Extent.StartOffset -and $pair.Item2.Extent.EndOffset -ge $Node.Extent.EndOffset) {
                        return @{ Kind = 'Entry'; Name = [string]$pair.Item1.Extent.Text.Trim("'", '"') }
                    }
                }
            }
            'CommandParameterAst' { return @{ Kind = 'Argument'; Name = $parent.ParameterName } }
            'CommandAst' {
                $i = $parent.CommandElements.IndexOf($child)
                if ($i -gt 0) {
                    $before = $parent.CommandElements[$i - 1]
                    if ($before -is [System.Management.Automation.Language.CommandParameterAst] -and $null -eq $before.Argument) { return @{ Kind = 'Argument'; Name = $before.ParameterName } }
                    if ($before -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $before.Value -match '^--?[A-Za-z][\w-]*$') { return @{ Kind = 'Argument'; Name = $before.Value.TrimStart('-') } }
                }
                return @{ Kind = 'Argument'; Name = $null }
            }
            'BinaryExpressionAst' { return @{ Kind = 'Comparison'; Name = $null } }
            'SwitchStatementAst' { return @{ Kind = 'Comparison'; Name = $null } }
        }
        return @{ Kind = 'Other'; Name = $null }
    }

    function Test-EnfInAttribute($Node) {
        $p = $Node.Parent
        while ($null -ne $p) { if ($p -is [System.Management.Automation.Language.AttributeBaseAst] -or $p -is [System.Management.Automation.Language.NamedAttributeArgumentAst]) { return $true }; $p = $p.Parent }
        return $false
    }

    function Test-EnfRegionTable($Node) {
        # An array of two or more region names, or a hashtable with two or more region names as keys, is a table of regions (a
        # supported-regions list, a region-to-code map), not a default.
        $L = 'System.Management.Automation.Language'
        $climb = "$L.CommandExpressionAst", "$L.PipelineAst", "$L.ArrayLiteralAst", "$L.ArrayExpressionAst", "$L.StatementBlockAst", "$L.HashtableAst", "$L.ParenExpressionAst"
        $p = $Node.Parent
        while ($null -ne $p -and $p.GetType().FullName -in $climb) {
            $n = 0
            if ($p -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                foreach ($e in $p.Elements) { if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $script:RegionName.Contains($e.Value)) { $n++ } }
            }
            elseif ($p -is [System.Management.Automation.Language.HashtableAst]) {
                foreach ($pair in $p.KeyValuePairs) { if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $script:RegionName.Contains($pair.Item1.Value)) { $n++ } }
            }
            if ($n -ge 2) { return $true }
            $p = $p.Parent
        }
        return $false
    }

    function Add-EnfFinding {
        param($List, [string]$File, [string]$Rule, [string]$Kind, [string]$Literal, [int]$Line)
        $List.Add([pscustomobject]@{ File = $File; Rule = $Rule; Kind = $Kind; Literal = $Literal; Line = $Line })
    }

    function Find-EnfStringViolation {
        # Rules B and C for one string.
        param($Node, [string]$File, $List)
        if (Test-EnfInAttribute $Node) { return }
        $text = if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { [regex]::Replace($Node.Value, '\$(\{[^}]*\}|\([^)]*\)|\w+(:\w+)?)', 'zvarz') } else { $Node.Value }
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        $slot = Get-EnfSlot $Node
        $rule = if ($slot.Kind -eq 'Default') { 'C' } else { 'B' }
        $line = $Node.Extent.StartLineNumber
        $found = $false

        foreach ($a in @(ConvertTo-EnfAddress $text)) {
            if (Get-EnfAddressException $a) { continue }
            Add-EnfFinding $List $File $rule 'ipv4' $a.Text $line; $found = $true
        }
        foreach ($m in [regex]::Matches($text, '(?<![0-9a-fA-F-])[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}(?![0-9a-fA-F-])')) {
            $g = $m.Value.ToLowerInvariant()
            if ($g -eq '00000000-0000-0000-0000-000000000000' -or $script:KnownGuid.ContainsKey($g)) { continue }
            Add-EnfFinding $List $File $rule 'guid' $g $line; $found = $true
        }
        foreach ($h in @(ConvertTo-EnfDomain $text)) {
            if ($h -cmatch '^[a-z_][a-z0-9_]*(\.[a-z0-9_]+)+$' -and -not (Get-EnfUnregisteredPath $h)) { continue }   # a registry key path such as scenario.cloud is not a host name
            $v = Get-EnfDomainVerdict $h
            if ($v -eq 'RESOURCE') { Add-EnfFinding $List $File $rule 'resource-host' $h $line; $found = $true; continue }
            if ($v) { continue }
            Add-EnfFinding $List $File $rule 'domain' $h $line; $found = $true
        }
        $trim = $text.Trim()
        if ($script:RegionName.Contains($trim) -and $slot.Kind -ne 'Comparison' -and -not (Test-EnfRegionTable $Node)) {
            Add-EnfFinding $List $File $rule 'region' $trim.ToLowerInvariant() $line; $found = $true
        }
        if ($trim -cmatch $script:ResourceNamePattern -and $script:ResourceNameException.Keys -notcontains $trim) {
            Add-EnfFinding $List $File $rule $(if ($trim -match '^kv-') { 'key-vault-name' } else { 'resource-name' }) $trim $line; $found = $true
        }
        # A literal handed to a parameter, variable or key that is a subscription, tenant, resource group or vault.
        if (-not $found -and $slot.Name -and $slot.Name -match $script:EnvironmentName -and $Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $trim -notmatch '^[<$@%{]' -and $trim -cmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -and $trim -cnotmatch '^[a-z_][a-z0-9_]*(\.[a-z0-9_]+)+$') {
            $kind = if ($slot.Name -match 'vault') { 'key-vault-name' } elseif ($slot.Name -match 'resource') { 'resource-group-name' } else { 'subscription-or-tenant' }
            Add-EnfFinding $List $File $rule $kind $trim $line
        }
    }

    function Find-EnfPrompt {
        # Rule D: a script with -InfrastructureFile never asks for a value.
        param($Ast, [string]$File, $List)
        $L = $script:L
        $hasParameter = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'InfrastructureFile' }, $true)).Count -gt 0
        if (-not $hasParameter) { return }
        foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if (-not $name) { continue }
            if ($name -ieq 'Read-Host') { Add-EnfFinding $List $File 'D' 'prompt' 'Read-Host' $c.Extent.StartLineNumber }
            elseif ($name -ieq 'Get-Credential') {
                $supplied = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^Cred' }).Count -gt 0
                if (-not $supplied) { Add-EnfFinding $List $File 'D' 'prompt' 'Get-Credential' $c.Extent.StartLineNumber }
            }
        }
        foreach ($m in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            $member = [string]$m.Member.Value
            $target = $m.Expression.Extent.Text
            if ($m.Static -and $target -match '^\[(System\.)?Console\]$' -and $member -in 'ReadLine', 'ReadKey') { Add-EnfFinding $List $File 'D' 'prompt' "[Console]::$member" $m.Extent.StartLineNumber }
            elseif (-not $m.Static -and $target -match '(?i)\$(host|psitem|_)?\.?(host\.)?ui(\.rawui)?$' -and $member -match '^(Prompt|ReadLine|ReadKey|ReadLineAsSecureString)') { Add-EnfFinding $List $File 'D' 'prompt' "`$Host.UI.$member" $m.Extent.StartLineNumber }
        }
    }

    function Find-EnfInfrastructureKey {
        # Rule A, part 1: Get-AzlInfrastructureValue with a literal path the registry does not have.
        param($Ast, [string]$File, $List)
        foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ([string]$c.GetCommandName() -ine 'Get-AzlInfrastructureValue') { continue }
            $pending = $null; $position = 0; $pathNode = $null
            foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($e.Argument) { if ($e.ParameterName -like 'P*') { $pathNode = $e.Argument } } else { $pending = $e.ParameterName }
                    continue
                }
                if ($pending) { if ($pending -like 'P*') { $pathNode = $e }; $pending = $null; continue }
                if ($position -eq 1) { $pathNode = $e }
                $position++
            }
            if ($null -eq $pathNode) { continue }
            $path = if ($pathNode -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $pathNode.Value }
            elseif ($pathNode -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $pathNode.Value.Substring(0, $pathNode.Value.IndexOf('$')).TrimEnd('.') }
            else { continue }
            $bad = Get-EnfUnregisteredPath $path
            if ($bad) { Add-EnfFinding $List $File 'A' 'unregistered-key' $bad $c.Extent.StartLineNumber }
        }
    }

    function Get-EnfUnregisteredPath {
        # $null when the dotted path is in the registry; otherwise the path up to and including the first segment that is not.
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $current = '@'
        foreach ($segment in $Path.Split('.')) {
            if ($segment -eq '') { return $null }
            $next = Join-MapPath -Index $script:MapIndex -Base $current -Member $segment
            if ($null -eq $next) { return $(if ($current -eq '@') { $segment } else { "$current.$segment" }) }
            $current = $next
        }
        return $null
    }

    function Test-EnfReadsInfrastructureFile($Ast) {
        # Evidence that the file loads the infrastructure file: a loader command, a reader of it, or a parameter named Infrastructure*.
        $loader = 'import-azlinfrastructure', 'convertfrom-yaml', 'read-infrastructurefile', 'read-azlsonarinfrastructurefile', 'read-azlyaml', 'get-ztpenvironment', 'read-ztpenvironment', 'convertfrom-azlsonaryaml', 'import-ztpenvironment', 'get-ztpenvironmentdata', 'get-azlinfrastructurevalue'
        $hit = $Ast.Find({ param($n)
                ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -and $n.GetCommandName().ToLowerInvariant() -in $loader) -or
                ($n -is [System.Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -like 'Infrastructure*')
            }, $true)
        return ($null -ne $hit)
    }

    function Get-EnfFinding {
        # All findings for the given files (full paths), before the allow-list and the baseline.
        param([string[]]$Path, [string]$Root)
        $list = [System.Collections.Generic.List[object]]::new()
        $evidence = @{}
        foreach ($p in $Path) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
            $file = [IO.Path]::GetRelativePath($Root, $p).Replace('\', '/')
            $evidence[$file] = Test-EnfReadsInfrastructureFile $ast
            foreach ($s in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
                Find-EnfStringViolation $s $file $list
            }
            Find-EnfPrompt $ast $file $list
            Find-EnfInfrastructureKey $ast $file $list
        }
        # Rule A, part 2: chains and reader commands, from the variable map's scanner.
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($existing in $list) { if ($existing.Rule -eq 'A') { [void]$seen.Add("$($existing.File)|$($existing.Line)|$($existing.Literal)") } }
        foreach ($r in @(Find-MapReader -Root $Root -File $Path -Index $script:MapIndex -ReportUnknown | Where-Object Mode -EQ 'unknown')) {
            if (-not $evidence[$r.File]) { continue }                      # the file never loads the infrastructure file: $config is something else
            if ($r.Path.EndsWith('.') -or $r.Path -cmatch '[A-Z]') { continue }   # built at run time, or a property of another object (registry keys are lower case)
            if (($r.Path.Split('.') | Where-Object { $_.StartsWith('_') -and $_ -ne '_metadata' })) { continue }   # a field the script adds itself
            # A variable named like the file (infra, infrastructure ...) or a reader command is certain. Another name ($config, $data, $node)
            # is trusted only when the path starts at a registered top-level key and is at least two keys deep and is not a node of nodes[].
            $certain = $r.Root -in $script:FileVariable -or $r.Root -in '(reader)', '(getter)'
            if (-not $certain -and ($r.Path.StartsWith('nodes[]') -or -not $r.Path.Contains('.'))) { continue }
            if ($seen.Add("$($r.File)|$($r.Line)|$($r.Path)")) { Add-EnfFinding $list $r.File 'A' 'unregistered-key' $r.Path $r.Line }
        }
        return $list.ToArray()
    }

    # What the lists match on: file, rule and the literal as the lists write it (an address is masked).
    function ConvertTo-EnfKey($Item) {
        $literal = if ($Item.PSObject.Properties['Kind']) { Get-EnfListLiteral $Item } else { [string]$Item.Literal }
        '{0}|{1}|{2}' -f $Item.File, $Item.Rule, $literal.ToLowerInvariant()
    }

    function Read-EnfList([string]$Name) {
        $p = [IO.Path]::Combine($PSScriptRoot, $Name)
        if (-not (Test-Path -LiteralPath $p)) { return @() }
        return @((Import-PowerShellDataFile -LiteralPath $p).Entries)
    }

    # ------------------------------------------------------------------------------------------------------------------------------
    # The repository
    # ------------------------------------------------------------------------------------------------------------------------------
    $script:Files = @(Get-ChildItem -LiteralPath $script:ScriptsRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Sort-Object FullName | ForEach-Object FullName)
    $script:Found = @(Get-EnfFinding -Path $script:Files -Root $script:Repo)
    $script:Allow = @(Read-EnfList 'enforcement-allowlist.psd1')
    $script:Baseline = @(Read-EnfList 'enforcement-baseline.psd1')
    if ($env:AZL_ENFORCE_DUMP) { $script:Found | Sort-Object File, Line | Export-Csv -LiteralPath $env:AZL_ENFORCE_DUMP -NoTypeInformation }

    $script:Group = @{}
    foreach ($f in $script:Found) { $k = ConvertTo-EnfKey $f; if (-not $script:Group.ContainsKey($k)) { $script:Group[$k] = [System.Collections.Generic.List[object]]::new() }; $script:Group[$k].Add($f) }
    $script:AllowKey = @{}; foreach ($e in $script:Allow) { $script:AllowKey[(ConvertTo-EnfKey $e)] = $e }
    $script:BaselineKey = @{}; foreach ($e in $script:Baseline) { $script:BaselineKey[(ConvertTo-EnfKey $e)] = $e }
    $script:New = @(foreach ($k in $script:Group.Keys) { if (-not $script:AllowKey.ContainsKey($k) -and -not $script:BaselineKey.ContainsKey($k)) { $script:Group[$k] } })
    $script:BaselinedCount = 0
    foreach ($k in $script:BaselineKey.Keys) { if ($script:Group.ContainsKey($k)) { $script:BaselinedCount += $script:Group[$k].Count } }
    $script:AllowedCount = 0
    foreach ($k in $script:AllowKey.Keys) { if ($script:Group.ContainsKey($k)) { $script:AllowedCount += $script:Group[$k].Count } }

    function Format-EnfFinding($Item) { '{0}:{1} rule {2} ({3}) {4}' -f $Item.File, $Item.Line, $Item.Rule, $Item.Kind, $Item.Literal }
    function Get-EnfSnippetFinding([string]$Code, [string]$Rule) {
        $tmp = Join-Path $TestDrive ('snippet-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($tmp, $Code)
        @(Get-EnfFinding -Path $tmp -Root $TestDrive | Where-Object { -not $Rule -or $_.Rule -eq $Rule })
    }

    Write-Host ("Enforcement: {0} scripts scanned; {1} findings = {2} allow-listed (reviewed), {3} baselined (legacy debt in {4} files, {5} entries), {6} new." -f
        $script:Files.Count, $script:Found.Count, $script:AllowedCount, $script:BaselinedCount, @($script:Baseline | ForEach-Object File | Sort-Object -Unique).Count, $script:Baseline.Count, $script:New.Count)
}

Describe 'The scan sees what it is meant to see' {
    It 'scans the scripts of the repository' {
        $script:Files.Count | Should -BeGreaterThan 400
    }

    It 'reads the registry' {
        $script:Registry.Count | Should -BeGreaterThan 1000
        Get-EnfUnregisteredPath 'networking.management.gateway' | Should -BeNullOrEmpty
        Get-EnfUnregisteredPath 'nodes.name' | Should -BeNullOrEmpty
        Get-EnfUnregisteredPath 'networking.management.gatway' | Should -Be 'networking.management.gatway'
        Get-EnfUnregisteredPath 'bogus_section.name' | Should -Be 'bogus_section'
    }

    It 'finds the debt it is told about: the scan has findings in the legacy scripts' {
        $script:Found.Count | Should -BeGreaterThan 0
    }
}

Describe 'Rule A: a script reads only keys of the infrastructure file that the registry has' {
    It 'has no new unregistered key' {
        $new = @($script:New | Where-Object Rule -EQ 'A' | Sort-Object File, Line | ForEach-Object { Format-EnfFinding $_ })
        $new | Should -BeNullOrEmpty -Because ("register the key in config/variables/schema/master-registry.yaml first, or fix the path in the script:`n" + ($new -join "`n"))
    }
    It 'sees a misspelled path given to Get-AzlInfrastructureValue' {
        $f = Get-EnfSnippetFinding "`$v = Get-AzlInfrastructureValue -Infrastructure `$infra -Path 'networking.management.gatway'" 'A'
        @($f).Count | Should -Be 1
        $f[0].Literal | Should -Be 'networking.management.gatway'
    }
    It 'sees a misspelled chain and an unknown key of a loaded file' {
        $f = Get-EnfSnippetFinding "`$infra = Import-AzlInfrastructure -Path 'x.yml'`n`$a = `$infra.cluster.nme`n`$b = `$infra.cluster.name`n`$c = `$infra.bogus_section" 'A'
        @($f.Literal | Sort-Object) | Should -Be @('bogus_section', 'cluster.nme')
    }
    It 'does not count an unknown property of a file that never loads the infrastructure file' {
        @(Get-EnfSnippetFinding "`$config = Get-Content x | ConvertFrom-Json`n`$config.cluster.nme" 'A').Count | Should -Be 0
    }
    It 'accepts a registered path built with a variable' {
        @(Get-EnfSnippetFinding "`$k = 'name'`nGet-AzlInfrastructureValue -Infrastructure `$infra -Path `"cluster.`$k`"" 'A').Count | Should -Be 0
    }
}

Describe 'Rule B: no hard-coded value of a kind a deployment chooses' {
    It 'has no new hard-coded value' {
        $new = @($script:New | Where-Object Rule -EQ 'B' | Sort-Object File, Line | ForEach-Object { Format-EnfFinding $_ })
        $new | Should -BeNullOrEmpty -Because ("read the value from the infrastructure file (Import-AzlInfrastructure, Get-AzlInfrastructureValue). A value Microsoft fixes is a rule-level exception in this test; anything else is a reviewed line in tests/variables/enforcement-allowlist.psd1:`n" + ($new -join "`n"))
    }

    Context 'addresses' {
        It 'flags <Code>' -ForEach @(
            @{ Code = "`$a = '10.20.30.40'"; Literal = '10.20.30.40' }
            @{ Code = "`$a = '172.16.5.9'"; Literal = '172.16.5.9' }
            @{ Code = "Test-Connection '192.168.1.10'"; Literal = '192.168.1.10' }
            @{ Code = "`$a = '10.1.0.0/16'"; Literal = '10.1.0.0/16' }
            @{ Code = "`$a = 'Gateway is 192.168.0.1 here'"; Literal = '192.168.0.1' }
            @{ Code = "`$a = `"http://10.9.9.9:8080/x`""; Literal = '10.9.9.9' }
        ) {
            $f = Get-EnfSnippetFinding $Code 'B'
            @($f.Literal) | Should -Be @($Literal)
        }
        It 'accepts <Code>: <Why>' -ForEach @(
            @{ Code = "`$a = '192.0.2.10'"; Why = 'documentation range' }
            @{ Code = "`$a = '198.51.100.0/24'"; Why = 'documentation range' }
            @{ Code = "`$a = '203.0.113.7'"; Why = 'documentation range' }
            @{ Code = "`$a = '127.0.0.1'"; Why = 'loopback' }
            @{ Code = "`$a = '169.254.169.254'"; Why = 'link-local (instance metadata)' }
            @{ Code = "`$a = '169.254.10.1'"; Why = 'APIPA' }
            @{ Code = "`$a = '0.0.0.0/0'"; Why = 'the default route' }
            @{ Code = "`$a = '255.255.255.0'"; Why = 'a mask' }
            @{ Code = "`$a = '255.255.240.0'"; Why = 'a mask' }
            @{ Code = "`$a = '168.63.129.16'"; Why = 'Azure platform address' }
            @{ Code = "`$a = '10.0.0.0/8'"; Why = 'the RFC 1918 block' }
            @{ Code = "`$a = '10.0.26100.1'"; Why = 'a build number, not an address' }
            @{ Code = "`$a = '1.2.3.4.5'"; Why = 'five parts, a version' }
            @{ Code = "# gateway 10.1.1.1`n`$a = 1"; Why = 'a comment' }
        ) {
            @(Get-EnfSnippetFinding $Code 'B').Count | Should -Be 0
        }
        It 'does not accept an address that only looks like a mask' {
            @(Get-EnfSnippetFinding "`$a = '255.0.255.0'" 'B').Count | Should -Be 1
        }
    }

    Context 'GUIDs' {
        It 'flags a GUID that is not all zeros and not Microsoft-fixed' {
            @((Get-EnfSnippetFinding "`$a = '3f2a1c9e-8b4d-4e6a-9c3b-5d7e1f0a2b4c'" 'B').Literal) | Should -Be @('3f2a1c9e-8b4d-4e6a-9c3b-5d7e1f0a2b4c')
            @(Get-EnfSnippetFinding "`$a = '11111111-1111-1111-1111-111111111111'" 'B').Count | Should -Be 1
        }
        It 'accepts the all-zero GUID and a built-in role definition ID' {
            @(Get-EnfSnippetFinding "`$a = '00000000-0000-0000-0000-000000000000'" 'B').Count | Should -Be 0
            @(Get-EnfSnippetFinding "`$a = 'b24988ac-6180-42a0-ab88-20f7382dd24c'" 'B').Count | Should -Be 0
        }
        It 'names every well-known GUID' {
            foreach ($k in $script:KnownGuid.Keys) { $k | Should -Match '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'; $script:KnownGuid[$k] | Should -Not -BeNullOrEmpty }
        }
    }

    Context 'DNS names' {
        It 'flags <Code>' -ForEach @(
            @{ Code = "`$a = 'dc01.corp.local'"; Literal = 'dc01.corp.local' }
            @{ Code = "`$a = 'user@fabrikam.com'"; Literal = 'fabrikam.com' }
            @{ Code = "`$a = 'https://git.contoso.net/repo'"; Literal = 'git.contoso.net' }
            @{ Code = "`$a = 'mystorage.blob.core.windows.net'"; Literal = 'mystorage.blob.core.windows.net' }
            @{ Code = "`$a = 'https://myvault.vault.azure.net/'"; Literal = 'myvault.vault.azure.net' }
            @{ Code = "`$a = 'contoso.onmicrosoft.com'"; Literal = 'contoso.onmicrosoft.com' }
        ) {
            @((Get-EnfSnippetFinding $Code 'B').Literal) | Should -Be @($Literal)
        }
        It 'accepts <Code>' -ForEach @(
            @{ Code = "`$a = 'dc01.improbability.cloud'" }
            @{ Code = "`$a = 'improbability.cloud'" }
            @{ Code = "`$a = 'admin@example.com'" }
            @{ Code = "`$a = 'host.example.org'" }
            @{ Code = "`$a = 'https://management.azure.com/subscriptions'" }
            @{ Code = "`$a = 'https://login.microsoftonline.com/common'" }
            @{ Code = "`$a = 'https://aka.ms/azurelocal'" }
            @{ Code = "`$a = '.blob.core.windows.net'" }
            @{ Code = "`$a = `"`$name.blob.core.windows.net`"" }
            @{ Code = "`$a = `"https://`$vault.vault.azure.net/`"" }
            @{ Code = "`$a = `"`$name.improbability.cloud`"" }
            @{ Code = "`$a = [System.IO.Path]::GetTempPath(); Add-Type -AssemblyName System.Net.Http" }
            @{ Code = "`$a = 'config.json'" }
        ) {
            @(Get-EnfSnippetFinding $Code 'B').Count | Should -Be 0
        }
    }

    Context 'regions, vaults, resource names and subscriptions' {
        It 'flags <Code>' -ForEach @(
            @{ Code = "`$loc = 'eastus'"; Literal = 'eastus' }
            @{ Code = "New-AzResourceGroup -Name x -Location 'westeurope'"; Literal = 'westeurope' }
            @{ Code = "`$p = @{ location = 'northeurope' }"; Literal = 'northeurope' }
            @{ Code = "az group create --location 'uksouth'"; Literal = 'uksouth' }
            @{ Code = "`$rg = 'rg-iic-mgmt-01'"; Literal = 'rg-iic-mgmt-01' }
            @{ Code = "`$n = 'vnet-hub-01'"; Literal = 'vnet-hub-01' }
            @{ Code = "Get-AzKeyVaultSecret -VaultName 'kv-iic-01' -Name x"; Literal = 'kv-iic-01' }
            @{ Code = "`$ResourceGroupName = 'MyGroup'"; Literal = 'MyGroup' }
            @{ Code = "`$p = @{ SubscriptionId = 'abc' }"; Literal = 'abc' }
            @{ Code = "Set-AzContext -SubscriptionId 'sub-one'"; Literal = 'sub-one' }
        ) {
            @((Get-EnfSnippetFinding $Code 'B').Literal) | Should -Be @($Literal)
        }
        It 'accepts <Code>' -ForEach @(
            @{ Code = "if (`$loc -eq 'eastus') { 1 }" }
            @{ Code = "`$ok = `$loc -in 'eastus', 'westeurope', 'uksouth'" }
            @{ Code = "`$regions = @('eastus', 'westeurope')" }
            @{ Code = "[ValidateSet('eastus', 'westus')][string]`$Location = `$null" }
            @{ Code = "`$rg = `$infra.azure.resource_group" }
            @{ Code = "`$ResourceGroupName = ''" }
            @{ Code = "`$p = @{ SubscriptionId = `$sub }" }
            @{ Code = "Write-Host 'eastus is a region'" }
        ) {
            @(Get-EnfSnippetFinding $Code 'B').Count | Should -Be (@{ 'Write-Host ''eastus is a region''' = 0 }[$Code] ?? 0)
        }
    }
}

Describe 'Rule C: no parameter defaults to an environment value' {
    It 'has no new such default' {
        $new = @($script:New | Where-Object Rule -EQ 'C' | Sort-Object File, Line | ForEach-Object { Format-EnfFinding $_ })
        $new | Should -BeNullOrEmpty -Because ("a parameter that sets an environment value has no default; the value comes from the infrastructure file:`n" + ($new -join "`n"))
    }
    It 'flags <Code>' -ForEach @(
        @{ Code = "param([string]`$Location = 'eastus')"; Literal = 'eastus' }
        @{ Code = "param([string]`$Server = 'dc01.corp.local')"; Literal = 'dc01.corp.local' }
        @{ Code = "param([string[]]`$Dns = @('10.0.0.4', '10.0.0.5'))"; Literal = '10.0.0.4' }
        @{ Code = "param([string]`$SubscriptionId = 'my-subscription')"; Literal = 'my-subscription' }
        @{ Code = "param([string]`$VaultName = 'vault1')"; Literal = 'vault1' }
        @{ Code = "param([string]`$ResourceGroupName = 'rg-iic-01')"; Literal = 'rg-iic-01' }
        @{ Code = "param([string]`$Tenant = '5a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d')"; Literal = '5a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d' }
    ) {
        $f = @(Get-EnfSnippetFinding $Code)
        $f[0].Rule | Should -Be 'C'
        $f[0].Literal | Should -Be $Literal
    }
    It 'accepts <Code>' -ForEach @(
        @{ Code = "param([string]`$Location)" }
        @{ Code = "param([string]`$Name = '')" }
        @{ Code = "param([int]`$Port = 5985)" }
        @{ Code = "param([string]`$Format = 'json')" }
        @{ Code = "param([string]`$Server = '192.0.2.10')" }
        @{ Code = "param([string]`$SubscriptionId = `$env:AZL_SUB)" }
        @{ Code = "param([ValidateSet('eastus', 'westus')][string]`$Location)" }
    ) {
        @(Get-EnfSnippetFinding $Code).Count | Should -Be 0
    }
}

Describe 'Rule D: a script that takes -InfrastructureFile never prompts' {
    It 'has no new prompt' {
        $new = @($script:New | Where-Object Rule -EQ 'D' | Sort-Object File, Line | ForEach-Object { Format-EnfFinding $_ })
        $new | Should -BeNullOrEmpty -Because ("a value comes from the infrastructure file, a secret from its reference; the script never asks:`n" + ($new -join "`n"))
    }
    It 'flags <Call> in a script with -InfrastructureFile' -ForEach @(
        @{ Call = 'Read-Host'; Body = "`$x = Read-Host 'Name'" }
        @{ Call = 'Get-Credential'; Body = "`$c = Get-Credential -UserName u" }
        @{ Call = '$Host.UI.PromptForChoice'; Body = "`$c = `$Host.UI.PromptForChoice('t', 'm', @(), 0)" }
        @{ Call = '[Console]::ReadLine'; Body = "`$c = [Console]::ReadLine()" }
    ) {
        $f = Get-EnfSnippetFinding "param([string]`$InfrastructureFile)`n$Body" 'D'
        @($f).Count | Should -Be 1
        $f[0].Literal | Should -Be $Call.Replace('PromptForChoice', 'PromptForChoice')
    }
    It 'leaves a script without -InfrastructureFile alone, and Get-Credential given a credential' {
        @(Get-EnfSnippetFinding "param([string]`$Name)`n`$x = Read-Host 'Name'" 'D').Count | Should -Be 0
        @(Get-EnfSnippetFinding "param([string]`$InfrastructureFile)`n`$c = Get-Credential -Credential `$existing" 'D').Count | Should -Be 0
        @(Get-EnfSnippetFinding "param([string]`$InfrastructureFile)`n# Read-Host is not used`n`$x = 1" 'D').Count | Should -Be 0
    }
}

Describe 'The allow-list (reviewed exceptions) and the baseline (known debt)' {
    It 'every allow-list entry has a file, a rule, a literal and a reason' {
        $bad = @($script:Allow | Where-Object { -not $_.File -or $_.Rule -notin 'A', 'B', 'C', 'D' -or -not $_.Literal -or [string]::IsNullOrWhiteSpace($_.Reason) })
        $bad | Should -BeNullOrEmpty
    }
    It 'every baseline entry has a file, a rule, a literal, a count and the reason' {
        $bad = @($script:Baseline | Where-Object { -not $_.File -or $_.Rule -notin 'A', 'B', 'C', 'D' -or -not $_.Literal -or [int]$_.Count -lt 1 -or $_.Reason -ne 'legacy script, not yet migrated' })
        $bad | Should -BeNullOrEmpty
    }
    It 'no entry appears twice, and nothing is both allow-listed and baselined' {
        $keys = @($script:Allow + $script:Baseline | ForEach-Object { ConvertTo-EnfKey $_ })
        @($keys | Group-Object | Where-Object Count -GT 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }
    It 'every entry names a script that exists' {
        $missing = @($script:Allow + $script:Baseline | Where-Object { -not (Test-Path -LiteralPath ([IO.Path]::Combine($script:Repo, $_.File))) } | ForEach-Object File)
        $missing | Should -BeNullOrEmpty
    }
    It 'no entry holds an address, an ID or a secret that could be real' {
        $bad = @($script:Allow + $script:Baseline | Where-Object {
                $l = [string]$_.Literal
                ($l -match '(?:\d{1,3}\.){3}\d{1,3}') -or
                ($l -match '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}' -and $l -ne '00000000-0000-0000-0000-000000000000' -and -not $script:KnownGuid.ContainsKey($l.ToLowerInvariant()))
            } | ForEach-Object { "$($_.File) $($_.Rule)" })
        $bad | Should -BeNullOrEmpty -Because 'the lists write an address masked (10.x.x.x/24) and never hold an ID that is not Microsoft-fixed: replace a real-looking value in the script with a neutral example'
    }
    It 'writes an address masked' {
        Get-EnfListLiteral ([pscustomobject]@{ Kind = 'ipv4'; Literal = '10.20.30.40/24' }) | Should -Be '10.x.x.x/24'
        Get-EnfListLiteral ([pscustomobject]@{ Kind = 'ipv4'; Literal = '172.16.5.9' }) | Should -Be '172.x.x.x'
        Get-EnfListLiteral ([pscustomobject]@{ Kind = 'domain'; Literal = 'git.example.test' }) | Should -Be 'git.example.test'
    }
    It 'every allow-list entry still matches a finding (a fixed exception is removed from the list)' {
        $stale = @($script:Allow | Where-Object { -not $script:Group.ContainsKey((ConvertTo-EnfKey $_)) } | ForEach-Object { "$($_.File) rule $($_.Rule) $($_.Literal)" })
        $stale | Should -BeNullOrEmpty -Because "these allow-list entries match nothing; remove them from tests/variables/enforcement-allowlist.psd1:`n$($stale -join "`n")"
    }
    It 'every baseline entry still matches exactly its count (fixed debt is taken out of the baseline)' {
        $off = @(foreach ($e in $script:Baseline) {
                $k = ConvertTo-EnfKey $e
                $n = if ($script:Group.ContainsKey($k)) { $script:Group[$k].Count } else { 0 }
                if ($n -ne [int]$e.Count) { "$($e.File) rule $($e.Rule) $($e.Literal): baseline says $($e.Count), found $n" }
            })
        $off | Should -BeNullOrEmpty -Because "lower the Count, or remove the entry, in tests/variables/enforcement-baseline.psd1 (more than the baseline is a new violation):`n$($off -join "`n")"
    }
    It 'has no new violation of any rule' {
        $new = @($script:New | Sort-Object File, Line | ForEach-Object { Format-EnfFinding $_ })
        $new | Should -BeNullOrEmpty
    }
    It 'prints the number of violations that remain' {
        Write-Host ("Enforcement: known debt = {0} violations in {1} scripts (tests/variables/enforcement-baseline.psd1); reviewed exceptions = {2} occurrences ({3} entries)." -f
            $script:BaselinedCount, @($script:Baseline | ForEach-Object File | Sort-Object -Unique).Count, $script:AllowedCount, $script:Allow.Count)
        $script:BaselinedCount | Should -BeGreaterOrEqual 0
    }
}

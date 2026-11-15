#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# No Terraform file carries a value a deployment chooses (owner directive D121: every value comes from the variable file generated from
# the master registry). The test reads every .tf, .tftpl and .tfvars.example under src/terraform (no Terraform binary needed) and fails on:
#   A  a variable with no registry entry in tools.terraform.variables or tools.cicd_infra.terraform_variables (its area is the file);
#   B  a variable default, or an optional() attribute default, that is not empty (null, "", [], {}, false, 0) and not the default of a
#      class c registry entry (a setting of the code itself);
#   C  a class b registry entry (a choice with no key: the generator skips it, so the code default would win);
#   D  a literal string, number or bool argument in a resource, data, module, locals, provider or backend block that is not a value
#      Microsoft or a protocol fixes: those are rule-level exceptions below, each with its reason (the style of Enforcement.Tests.ps1);
#   E  a hard-coded cloud DNS suffix (vault.azure.net, core.windows.net, ...) outside the default of a class c registry entry;
#   F  a value set in a .tfvars.example (an extra .tfvars file overrides the generated terraform.tfvars.json);
#   G  a class a variable of the cicd-infra environment whose infrastructure_key ConvertTo-AzlRunnerTerraformVariable does not read.
# Strings that are only punctuation or interpolation, comparison operands, descriptions and error messages are not values.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/variables/TerraformValues.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:TfRoot = [IO.Path]::Combine($script:Repo, 'src', 'terraform')
    Import-Module ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'scripts', 'VariableRegistry.psm1')) -Force
    $script:Registry = @(Get-RegistryVariable -Path ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')))
    $byPath = @{}; foreach ($r in $script:Registry) { $byPath[$r.Path] = $r }
    $script:Entries = @(foreach ($r in $script:Registry) {
            if ($r.Path -notmatch '^tools\.(terraform\.variables|cicd_infra\.terraform_variables)\.[^.]+\.[^.]+$') { continue }
            if ($r.Node -isnot [System.Collections.IDictionary] -or -not $r.Node.Contains('class')) { continue }
            $group = $byPath[$r.Path.Substring(0, $r.Path.LastIndexOf('.'))]
            [pscustomobject]@{ Path = $r.Path; Area = [string]$group.Node['area']; Name = [string]$r.Node['name']; Node = $r.Node }
        })
    $script:EntryIndex = @{}
    foreach ($e in $script:Entries) { $script:EntryIndex["$($e.Area)|$($e.Name)"] = $e }

    # ------------------------------------------------------------------------------------------------------------------------------
    # Rule-level exceptions (rule D): values that Microsoft, a protocol or the Terraform language fixes. Argument '*' is any argument.
    # Each has its reason; nothing here is a name, address, size, SKU or other choice of a deployment.
    # ------------------------------------------------------------------------------------------------------------------------------
    $script:LiteralException = @(
        @{ Argument = '*'; Pattern = '^(Standard|Static|Dynamic)$'; Reason = 'Public IPs of a VPN gateway, a Bastion host and a NAT gateway are Standard SKU and Static (Microsoft Learn: About active-active mode VPN gateways; About Azure Bastion configuration settings; Public IP addresses, SKU). A NIC address is Static when the file gives it, else Dynamic; a gateway''s private address is Dynamic.' }
        @{ Argument = 'type'; Pattern = '^(Vpn|IPsec|UserAssigned)$'; Reason = 'Resource kinds the module exists to create: a VPN gateway (not ExpressRoute), the IPsec type of a site-to-site connection, the user-assigned identity the runner signs in as.' }
        @{ Argument = 'vpn_type'; Pattern = '^RouteBased$'; Reason = 'Active-active and BGP need a route-based VPN (Microsoft Learn: About active-active mode VPN gateways); policy based is the legacy Basic SKU.' }
        @{ Argument = 'generation'; Pattern = '^Generation[12]$'; Reason = 'The VPN gateway generation follows the SKU (Microsoft Learn: VPN Gateway SKUs).' }
        @{ Argument = 'min_tls_version'; Pattern = '^TLS1_2$'; Reason = 'TLS 1.2 is the minimum Azure Storage supports (Microsoft Learn: Enforce a minimum required version of TLS for requests to a storage account).' }
        @{ Argument = 'container_access_type'; Pattern = '^private$'; Reason = 'The state container is never readable without sign-in.' }
        @{ Argument = 'default_action'; Pattern = '^Deny$'; Reason = 'The network rules exist to deny every address not listed.' }
        @{ Argument = 'key_vault_sku'; Pattern = '^standard$'; Reason = 'The vaults hold secrets only; premium adds HSM-protected keys (Microsoft Learn: Azure Key Vault service tiers).' }
        @{ Argument = 'removable_environment_classes'; Pattern = '^(lab|test|dev)$'; Reason = 'The rule of Deploy-KeyVaults.ps1 over the scenario.environment_class enum: purge protection off in lab, test and dev.' }
        @{ Argument = 'cluster_purge_protection_enabled'; Pattern = '^false$'; Reason = 'Microsoft''s Azure Local deployment template sets no purge protection on the cluster vault.' }
        @{ Argument = 'deployment_key_vault_roles'; Pattern = '^Key Vault (Data Access Administrator|Secrets Officer|Contributor)$'; Reason = 'The roles Microsoft Learn lists for the deploying identity (Assign required permissions for Azure Local deployment).' }
        @{ Argument = 'role'; Pattern = '^(Contributor|Role Based Access Control Administrator|Azure Connected Machine Resource Administrator|Key Vault Secrets User)$'; Reason = 'Azure built-in role names (Microsoft Learn: Azure built-in roles), the least each runner job needs.' }
        @{ Argument = 'rbac_condition'; Pattern = '(ActionMatches|ForAnyOfAnyValues:GuidEquals|\bAND\b|\bOR\b)'; Reason = 'ABAC condition syntax of constrained role assignment delegation (Microsoft Learn: Delegate Azure role assignment management with conditions).' }
        @{ Argument = 'subnet_id'; Pattern = '^(gateway|bastion)$'; Reason = 'The keys the generator gives the subnets Microsoft names GatewaySubnet and AzureBastionSubnet (a VPN gateway and Bastion need exactly those subnets).' }
        @{ Argument = 'condition_version'; Pattern = '^2\.0$'; Reason = 'The ABAC condition version Azure requires.' }
        @{ Argument = 'principal_type'; Pattern = '^ServicePrincipal$'; Reason = 'A managed identity is a service principal in Entra ID.' }
        @{ Argument = 'skip_service_principal_aad_check'; Pattern = '^true$'; Reason = 'The identity is created in the same run and may not have replicated yet; its type is known.' }
        @{ Argument = 'name'; Pattern = '^default$'; Reason = 'A subscription has one Defender for Cloud security contact and its name is always default (Microsoft Learn: Microsoft.Security securityContacts).' }
        @{ Argument = 'enabled'; Pattern = '^true$'; Reason = 'The action group exists to send notifications; a disabled one sends none.' }
        @{ Argument = '*'; Pattern = '^(MicrosoftWindowsServer|WindowsServer)$'; Reason = 'Publisher and offer of the Windows Server Marketplace images (Microsoft Learn: Find and use Azure Marketplace VM images).' }
        @{ Argument = 'create_option'; Pattern = '^Empty$'; Reason = 'A new, empty data disk; the bootstrap initialises it.' }
        @{ Argument = 'lun'; Pattern = '^0$'; Reason = 'The one data disk of the VM.' }
        @{ Argument = 'primary'; Pattern = '^true$'; Reason = 'The only NIC and IP configuration of a scale set profile are the primary ones.' }
        @{ Argument = 'special'; Pattern = '^true$'; Reason = 'The password policy has a minimum of special characters, which needs special characters on.' }
        @{ Argument = '*'; Pattern = '^(Inbound|Outbound|Allow|Deny|Tcp|Icmp)$'; Reason = 'Values of the NSG rule direction, access and protocol fields.' }
        @{ Argument = '*'; Pattern = '^(Internet|AzureCloud)$'; Reason = 'Azure service tags (Microsoft Learn: Virtual network service tags).' }
        @{ Argument = '*'; Pattern = '^168\.63\.129\.16$'; Reason = 'The Azure platform address: DNS, the wireserver and health probes (Microsoft Learn: What is IP address 168.63.129.16?).' }
        @{ Argument = '*'; Pattern = '^(22|80|443|445|3389)$'; Reason = 'Ports fixed by the protocols: SSH, HTTP, HTTPS, SMB, RDP.' }
        @{ Argument = 'key'; Pattern = '^(deny_inbound_internet|allow_outbound_azure_platform|allow_outbound_https_azure_cloud|deny_outbound_other|allow_outbound_https_internet|allow_outbound_http_internet|allow_outbound_lab_tcp|allow_outbound_lab_icmp|allow_inbound_bmc_smb|allow_inbound_admin)$'; Reason = 'Keys of nsg_rule_settings (class c), the role of each rule in the code.' }
        @{ Argument = '*'; Pattern = '^/(subscriptions|resourceGroups|providers/Microsoft\.Management/managementGroups)/$|^/subscriptions/|/resourceGroups/'; Reason = 'Azure resource ID grammar (/subscriptions/<id>/resourceGroups/<name>, /providers/Microsoft.Management/managementGroups/<name>).' }
        @{ Argument = 'mg_id_prefix'; Pattern = '^/providers/Microsoft\.Management/managementGroups/$'; Reason = 'The ID of a management group is fixed by its name.' }
        @{ Argument = '*'; Pattern = '^/templates/(bootstrap-linux\.sh|bootstrap-windows\.ps1|cloud-init\.yaml)\.tftpl$'; Reason = 'Template files of the module itself.' }
        @{ Argument = '*'; Pattern = '^\\r$'; Reason = 'Carriage return removed from the Linux bootstrap (a shell script must have LF line ends).' }
        @{ Argument = 'create|update'; Pattern = '^m$'; Reason = 'The minutes unit of a Terraform timeout.' }
        @{ Argument = 'platform'; Pattern = '^azure_devops$'; Reason = 'azdo is accepted as an alias of the platform value azure_devops (the enum of devops.platform).' }
        @{ Argument = 'short_name'; Pattern = '^/\[\^A-Za-z0-9\]/$|^12$'; Reason = 'The Azure limit of an action group short name: letters and digits, at most 12 characters (the rule of Deploy-ActionGroup.ps1).' }
    )

    # Hard-coded cloud DNS suffixes (rule E): each depends on the cloud.
    $script:CloudSuffix = '(vault\.azure\.net|vault\.usgovcloudapi\.net|vault\.azure\.cn|core\.windows\.net|core\.usgovcloudapi\.net|core\.chinacloudapi\.cn|management\.azure\.com|management\.usgovcloudapi\.net|login\.microsoftonline\.com|login\.microsoftonline\.us|database\.windows\.net|azurecr\.io)'

    # ------------------------------------------------------------------------------------------------------------------------------
    # A small reader of HCL: comments out, blocks, variables, literals.
    # ------------------------------------------------------------------------------------------------------------------------------
    function Get-TfvRelative([string]$Full) { [IO.Path]::GetRelativePath($script:Repo, $Full).Replace('\', '/') }

    function Remove-TfvComment([string]$Text) {
        # Comments become spaces (line numbers stay); strings and heredocs are kept.
        $sb = [System.Text.StringBuilder]::new($Text)
        $i = 0; $n = $Text.Length
        while ($i -lt $n) {
            $c = $Text[$i]
            if ($c -eq '"') { $i++; while ($i -lt $n -and $Text[$i] -ne '"') { if ($Text[$i] -eq '\') { $i++ }; $i++ }; $i++; continue }
            if ($c -eq '<' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '<' -and $Text.Substring($i) -match '^<<-?([A-Z]+)\n') {
                $tag = $Matches[1]; $end = [regex]::Match($Text.Substring($i), "\n\s*$tag\s*(\n|$)")
                $i += $(if ($end.Success) { $end.Index + $end.Length } else { $n }); continue
            }
            if ($c -eq '#' -or ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/')) { while ($i -lt $n -and $Text[$i] -ne "`n") { $sb[$i] = ' '; $i++ }; continue }
            if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') { while ($i -lt $n -and -not ($Text[$i] -eq '*' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/')) { if ($Text[$i] -ne "`n") { $sb[$i] = ' ' }; $i++ }; if ($i -lt $n) { $sb[$i] = ' '; $sb[$i + 1] = ' ' }; $i += 2; continue }
            $i++
        }
        $sb.ToString()
    }

    function Get-TfvClose([string]$Text, [int]$Open) {
        $depth = 0; $i = $Open
        while ($i -lt $Text.Length) {
            $c = $Text[$i]
            if ($c -eq '"') { $i++; while ($i -lt $Text.Length -and $Text[$i] -ne '"') { if ($Text[$i] -eq '\') { $i++ }; $i++ }; $i++; continue }
            if ($c -in '(', '[', '{') { $depth++ } elseif ($c -in ')', ']', '}') { $depth--; if ($depth -eq 0) { return $i } }
            $i++
        }
        throw "unbalanced bracket at $Open"
    }

    function Get-TfvLine([string]$Text, [int]$Index) { ([regex]::Matches($Text.Substring(0, $Index), "`n")).Count + 1 }

    function Read-TfvFile([string]$Path) { (Remove-TfvComment ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")) }

    function Get-TfvSplitAttribute([string]$Body) {
        # "name = expr" items at depth 0 of a body (newline or comma separated).
        $items = [System.Collections.Generic.List[object]]::new()
        $i = 0
        while ($i -lt $Body.Length) {
            $m = [regex]::Match($Body.Substring($i), '^[\s,]*("?[A-Za-z_][A-Za-z0-9_-]*"?)\s*=(?!=)\s*')
            if (-not $m.Success) { $j = $Body.IndexOfAny([char[]]"`n,", $i); if ($j -lt 0) { break }; $i = $j + 1; continue }
            $start = $i + $m.Length; $j = $start
            while ($j -lt $Body.Length -and $Body[$j] -ne "`n" -and $Body[$j] -ne ',') {
                if ($Body[$j] -in '(', '[', '{') { $j = (Get-TfvClose $Body $j) + 1; continue }
                if ($Body[$j] -eq '"') { $k = $j + 1; while ($Body[$k] -ne '"') { if ($Body[$k] -eq '\') { $k++ }; $k++ }; $j = $k + 1; continue }
                $j++
            }
            $items.Add([pscustomobject]@{ Name = $m.Groups[1].Value.Trim('"'); Expr = $Body.Substring($start, $j - $start).Trim(); Offset = $start })
            $i = $j + 1
        }
        $items
    }

    function Get-TfvVariable([string]$Path) {
        # Each variable: name, line, default (text or $null), optional attribute defaults (one level, then nested objects).
        $text = Read-TfvFile $Path
        foreach ($m in [regex]::Matches($text, '(?m)^variable\s+"([^"]+)"\s*\{')) {
            $open = $m.Index + $m.Length - 1
            $close = Get-TfvClose $text $open
            $body = $text.Substring($open + 1, $close - $open - 1)
            $type = ''; $default = $null
            foreach ($it in (Get-TfvSplitAttribute $body)) { if ($it.Name -eq 'type') { $type = $it.Expr } elseif ($it.Name -eq 'default') { $default = $it.Expr } }
            [pscustomobject]@{ Name = $m.Groups[1].Value; Line = (Get-TfvLine $text $m.Index); Default = $default; Optional = @(Get-TfvOptional $type $m.Groups[1].Value) }
        }
    }

    function Get-TfvOptional([string]$Type, [string]$Prefix) {
        # optional(type, default) attributes of the object types in $Type, named prefix.attribute (nested objects prefix.a.b).
        $om = [regex]::Match($Type, '^(?:(?:map|list|set)\()?object\(\{')
        if (-not $om.Success) { return }
        $open = $om.Index + $om.Length - 1
        $body = $Type.Substring($open + 1, (Get-TfvClose $Type $open) - $open - 1)
        foreach ($a in (Get-TfvSplitAttribute $body)) {
            $expr = $a.Expr
            $inner = $expr
            $opt = [regex]::Match($expr, '^optional\((.*)\)$', 'Singleline')
            if ($opt.Success) {
                $inner = $opt.Groups[1].Value
                $depth = 0; $cut = -1
                for ($i = 0; $i -lt $inner.Length; $i++) { $c = $inner[$i]; if ($c -in '(', '[', '{') { $depth++ } elseif ($c -in ')', ']', '}') { $depth-- } elseif ($c -eq ',' -and $depth -eq 0) { $cut = $i; break } }
                if ($cut -ge 0) { [pscustomobject]@{ Name = "$Prefix.$($a.Name)"; Default = ($inner.Substring($cut + 1).Trim() -replace '\s+', ' ') }; $inner = $inner.Substring(0, $cut).Trim() }
            }
            Get-TfvOptional $inner "$Prefix.$($a.Name)"
        }
    }

    function Test-TfvEmpty([string]$Expr) {
        # null, "", [], {}, false, 0, and an object or list of nothing but those.
        $e = ($Expr -replace '\s+', ' ').Trim()
        if ($e -in 'null', '""', '[]', '{}', 'false', '0') { return $true }
        if ($e -match '^\{(.*)\}$') { $parts = @(Get-TfvSplitAttribute ($Matches[1] -replace ' ([A-Za-z_][A-Za-z0-9_]* =)', "`n`$1")); return ($parts.Count -gt 0 -and @($parts | Where-Object { -not (Test-TfvEmpty $_.Expr) }).Count -eq 0) }
        return $false
    }

    function ConvertTo-TfvComparable($Value) { ((([string]$Value) -replace '\s+', ' ') -replace ',\s*', ',' -replace '"', '' -replace '\\\\', '\').Trim() }

    function Get-TfvLiteral([string]$Path) {
        # Literal values in the blocks that make resources: resource, data, module, locals, provider and terraform { backend }.
        $text = Read-TfvFile $Path
        $file = Get-TfvRelative $Path
        $found = [System.Collections.Generic.List[object]]::new()
        foreach ($m in [regex]::Matches($text, '(?m)^(resource|data|module|locals|provider|terraform)\b[^{\n]*\{')) {
            $open = $m.Index + $m.Length - 1
            $close = Get-TfvClose $text $open
            $kind = $m.Groups[1].Value
            $bodyStart = $open + 1; $body = $text.Substring($bodyStart, $close - $open - 1)
            if ($kind -eq 'terraform') {
                $b = [regex]::Match($body, '(?m)^\s*backend\s+"[^"]+"\s*\{')
                if (-not $b.Success) { continue }
                $bo = $bodyStart + $b.Index + $b.Length - 1
                $bodyStart = $bo + 1; $body = $text.Substring($bodyStart, (Get-TfvClose $text $bo) - $bo - 1)
            }
            Find-TfvLiteralIn $text $bodyStart $body $file $kind $found
        }
        $found
    }

    function Find-TfvLiteralIn([string]$Text, [int]$Start, [string]$Body, [string]$File, [string]$Kind, $Found) {
        foreach ($it in (Get-TfvSplitAttribute $Body)) {
            if ($Kind -eq 'module' -and $it.Name -in 'source', 'providers') { continue }
            if ($Kind -eq 'provider' -and $it.Name -eq 'alias') { continue }   # a name of the configuration, not a value
            if ($it.Name -in 'description', 'error_message', 'condition', 'depends_on', 'provider', 'for_each', 'count') { if ($it.Name -notin 'for_each', 'count') { continue } }
            $expr = $it.Expr
            $line = Get-TfvLine $Text ($Start + $it.Offset)
            # a nested block or object: recurse into it
            if ($expr -match '^\{') {
                $inner = $expr.Substring(1, $expr.Length - 2)
                Find-TfvLiteralIn $Text ($Start + $it.Offset + 1) $inner $File $Kind $Found
                continue
            }
            # a whole-value number or bool
            if ($expr -match '^-?\d+(\.\d+)?$' -or $expr -in 'true', 'false') { if ($it.Name -notin 'for_each', 'count') { $Found.Add([pscustomobject]@{ File = $File; Line = $line; Argument = $it.Name; Literal = $expr }) }; continue }
            Find-TfvString $expr $it.Name $File $line $Found
            # objects inside lists or calls: their attributes
            foreach ($om in [regex]::Matches($expr, '\{')) {
                $o = $om.Index
                if ($o -gt 0 -and $expr[$o - 1] -eq '$') { continue }
                try { $c = Get-TfvClose $expr $o } catch { continue }
                $inner = $expr.Substring($o + 1, $c - $o - 1)
                if ($inner -match '^\s*for\s') { continue }
                foreach ($sub in (Get-TfvSplitAttribute $inner)) {
                    if ($sub.Name -in 'description', 'error_message') { continue }
                    if ($sub.Expr -match '^-?\d+(\.\d+)?$' -or $sub.Expr -in 'true', 'false') { $Found.Add([pscustomobject]@{ File = $File; Line = $line; Argument = $sub.Name; Literal = $sub.Expr }) }
                }
            }
        }
    }

    function Find-TfvString([string]$Expr, [string]$Argument, [string]$File, [int]$Line, $Found) {
        # Each "..." in the expression, with ${...} and %{...} removed, that is not only punctuation and is not compared (==, !=).
        $i = 0
        while ($i -lt $Expr.Length) {
            if ($Expr[$i] -ne '"') { $i++; continue }
            $j = $i + 1; $sb = [System.Text.StringBuilder]::new()
            while ($j -lt $Expr.Length -and $Expr[$j] -ne '"') {
                if ($Expr[$j] -eq '\') { [void]$sb.Append($Expr.Substring($j, 2)); $j += 2; continue }
                if (($Expr[$j] -eq '$' -or $Expr[$j] -eq '%') -and $j + 1 -lt $Expr.Length -and $Expr[$j + 1] -eq '{') { $j = (Get-TfvClose $Expr ($j + 1)) + 1; [void]$sb.Append([char]1); continue }
                [void]$sb.Append($Expr[$j]); $j++
            }
            $before = $Expr.Substring(0, $i).TrimEnd(); $after = $Expr.Substring([Math]::Min($j + 1, $Expr.Length)).TrimStart()
            $compared = $before -match '(==|!=)$' -or $after -match '^(==|!=)'
            $isKey = $after -match '^=(?!=)'
            # the argument is the nearest "name =" before the string with no comma or line break between (an attribute of an object
            # literal inside the expression), else the argument of the block
            $own = [regex]::Match($before, '([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)\s*[^=,\n]*$')
            $arg = if ($own.Success) { $own.Groups[1].Value } else { $Argument }
            if ($arg -in 'description', 'error_message') { $i = $j + 1; continue }
            foreach ($part in ($sb.ToString() -split [char]1)) {
                if ($compared -or $isKey) { continue }
                if (($part -replace '[\s/\-_.:,*%{}()\[\]@!#=+|;''<>?^$]', '') -eq '') { continue }
                $Found.Add([pscustomobject]@{ File = $File; Line = $Line; Argument = $arg; Literal = $part })
            }
            $i = $j + 1
        }
    }

    function Get-TfvException($Finding) {
        foreach ($e in $script:LiteralException) {
            if ($e.Argument -ne '*' -and $Finding.Argument -notmatch "^($($e.Argument))$") { continue }
            if ($Finding.Literal -match $e.Pattern) { return $e.Reason }
        }
        return $null
    }

    $script:TfFiles = @(Get-ChildItem -LiteralPath $script:TfRoot -Recurse -File -Include *.tf | Where-Object { $_.FullName -notmatch '[\\/]\.terraform[\\/]' } | Sort-Object FullName | ForEach-Object FullName)
    $script:Variables = @(foreach ($f in $script:TfFiles) { foreach ($v in @(Get-TfvVariable $f)) { $v | Add-Member -NotePropertyName File -NotePropertyValue (Get-TfvRelative $f) -PassThru } })
    $script:Literals = @(foreach ($f in $script:TfFiles) { Get-TfvLiteral $f })
    function Format-TfvFinding($f) { '{0}:{1} {2} = {3}' -f $f.File, $f.Line, $f.Argument, $f.Literal }
}

Describe 'The reader of the Terraform files sees what it is meant to see' {
    It 'reads the variables and the literals of src/terraform' {
        $script:TfFiles.Count | Should -BeGreaterThan 20
        $script:Variables.Count | Should -BeGreaterThan 150
        @($script:Variables | Where-Object { $_.Name -eq 'default_images' }).Count | Should -Be 1
    }
    It 'finds a literal argument, a literal in a list and a literal number, and skips comments, comparisons and descriptions' {
        $tmp = Join-Path $TestDrive 'probe.tf'
        Set-Content -LiteralPath $tmp -Value @'
resource "x" "y" {
  # sku = "Hidden"
  name        = "fixed-name"
  sku         = var.a == "Compared" ? var.b : var.c
  description = "Some prose."
  ports       = ["8443"]
  days        = 30
  tags        = { Owner = "team-a" }
}
'@
        $found = @(Get-TfvLiteral $tmp)
        @($found.Literal | Sort-Object) | Should -Be @('30', '8443', 'fixed-name', 'team-a')
    }
    It 'tells an empty default from a value' {
        foreach ($e in 'null', '""', '[]', '{}', 'false', '0', '{ name = "" }') { Test-TfvEmpty $e | Should -BeTrue -Because $e }
        foreach ($e in '"tfstate"', '30', 'true', '["22"]', '{ name = "x" }') { Test-TfvEmpty $e | Should -BeFalse -Because $e }
    }
    It 'gives every exception a reason' {
        foreach ($e in $script:LiteralException) { $e.Reason | Should -Not -BeNullOrEmpty; { [regex]::new($e.Pattern) } | Should -Not -Throw }
    }
}

Describe 'Rule A: every Terraform variable is registered' {
    It 'has a registry entry for every variable of every .tf file' {
        $missing = @($script:Variables | Where-Object { -not $script:EntryIndex.ContainsKey("$($_.File)|$($_.Name)") } | ForEach-Object { "$($_.File):$($_.Line) $($_.Name)" })
        $missing | Should -BeNullOrEmpty -Because 'register it under tools.terraform.variables (or tools.cicd_infra.terraform_variables) with the area of its file'
    }
}

Describe 'Rule B: a default is empty or the default of a class c entry' {
    It 'has no variable default that is a choice of a deployment' {
        $bad = foreach ($v in $script:Variables) {
            if ($null -eq $v.Default -or (Test-TfvEmpty $v.Default)) { continue }
            $e = $script:EntryIndex["$($v.File)|$($v.Name)"]
            if (-not $e -or $e.Node['class'] -ne 'c') { "$($v.File):$($v.Line) $($v.Name) = $($v.Default) (class $(if ($e) { $e.Node['class'] } else { 'none' }))"; continue }
            if ((ConvertTo-TfvComparable $e.Node['default']) -ne (ConvertTo-TfvComparable $v.Default)) { "$($v.File):$($v.Line) $($v.Name) = $($v.Default), the registry says $($e.Node['default'])" }
        }
        @($bad) | Should -BeNullOrEmpty -Because 'a default that is a choice of a deployment comes from a key of infrastructure.yml (the generator writes its registry default); a setting of the code is class c with the same default'
    }
    It 'has no optional() attribute default that is a choice of a deployment' {
        $bad = foreach ($v in $script:Variables) {
            foreach ($o in $v.Optional) {
                if (Test-TfvEmpty $o.Default) { continue }
                $e = $script:EntryIndex["$($v.File)|$($o.Name)"]
                if (-not $e -or $e.Node['class'] -ne 'c') { "$($v.File) $($o.Name) = $($o.Default) (class $(if ($e) { $e.Node['class'] } else { 'none' }))"; continue }
                if ((ConvertTo-TfvComparable $e.Node['default']) -ne (ConvertTo-TfvComparable $o.Default)) { "$($v.File) $($o.Name) = $($o.Default), the registry says $($e.Node['default'])" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Rule C: no class b entry is left' {
    It 'has no class b entry in tools.terraform.variables or tools.cicd_infra.terraform_variables' {
        @($script:Entries | Where-Object { $_.Node['class'] -eq 'b' } | ForEach-Object { $_.Path }) | Should -BeNullOrEmpty -Because 'the generator skips class b, so the code default would win: give the value a key of infrastructure.yml (class a) or make it a setting of the code (class c)'
    }
}

Describe 'Rule D: no literal value of a deployment in a resource, module, locals, provider or backend block' {
    It 'has no literal that is not fixed by Microsoft, a protocol or the language' {
        $bad = @($script:Literals | Where-Object { -not (Get-TfvException $_) } | ForEach-Object { Format-TfvFinding $_ })
        $bad | Should -BeNullOrEmpty -Because 'make it a variable fed from a key of infrastructure.yml, or a class c variable with its default in the registry; a value Microsoft fixes is a rule-level exception in this test, with its reason'
    }
    It 'uses every exception (a stale one would hide nothing and rot)' {
        $unused = @($script:LiteralException | Where-Object { $e = $_; -not @($script:Literals | Where-Object { ($e.Argument -eq '*' -or $_.Argument -match "^($($e.Argument))$") -and $_.Literal -match $e.Pattern }).Count } | ForEach-Object { $_.Reason })
        $unused | Should -BeNullOrEmpty
    }
}

Describe 'Rule E: no hard-coded cloud DNS suffix' {
    It 'has none in a .tf, .tftpl or .tfvars.example file, except as the default of a class c entry' {
        $classC = @($script:Entries | Where-Object { $_.Node['class'] -eq 'c' -and $_.Node.Contains('default') } | ForEach-Object { ConvertTo-TfvComparable $_.Node['default'] })
        $bad = foreach ($f in @(Get-ChildItem -LiteralPath $script:TfRoot -Recurse -File -Include *.tf, *.tftpl, *.tfvars.example | Where-Object { $_.FullName -notmatch '[\\/]\.terraform[\\/]' })) {
            $text = if ($f.Extension -eq '.tf') { Read-TfvFile $f.FullName } else { ((Get-Content -LiteralPath $f.FullName) | ForEach-Object { if ($_ -match '^\s*#') { '' } else { $_ } }) -join "`n" }
            $n = 0
            foreach ($line in ($text -split "`n")) {
                $n++
                foreach ($m in [regex]::Matches($line, $script:CloudSuffix)) {
                    $q = [regex]::Match($line, '"([^"]*' + [regex]::Escape($m.Value) + '[^"]*)"')
                    if ($f.Extension -eq '.tf' -and $q.Success -and $classC -contains (ConvertTo-TfvComparable $q.Groups[1].Value)) { continue }
                    "$(Get-TfvRelative $f.FullName):$n $($m.Value)"
                }
            }
        }
        @($bad) | Should -BeNullOrEmpty -Because 'the suffix depends on the cloud: take it from a variable'
    }
}

Describe 'Rule F: the .tfvars.example files set nothing' {
    It '<_> holds comments only' -ForEach @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($PSScriptRoot, '..', '..', 'src', 'terraform')) -Recurse -File -Filter *.tfvars.example | ForEach-Object FullName) {
        @(Get-Content -LiteralPath $_ | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=' }) | Should -BeNullOrEmpty -Because 'a value in an extra .tfvars file overrides the generated terraform.tfvars.json'
    }
}

Describe 'Rule G: the cicd-infra variables read the keys the registry names' {
    BeforeAll {
        $module = [IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$tokens, [ref]$errors)
        $functions = @{}
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$f.Name] = $f }
        # ConvertTo-AzlRunnerTerraformVariable, every module function it calls (transitively), and ConvertTo-AzlCicdSetting, which builds its input.
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($n in 'ConvertTo-AzlRunnerTerraformVariable', 'ConvertTo-AzlCicdSetting') { $queue.Enqueue($n) }
        while ($queue.Count) {
            $n = $queue.Dequeue()
            if (-not $seen.Add($n) -or -not $functions.ContainsKey($n)) { continue }
            foreach ($c in $functions[$n].FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) { $name = $c.GetCommandName(); if ($name -and $functions.ContainsKey($name)) { $queue.Enqueue($name) } }
        }
        $script:ReadSegments = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($n in $seen) {
            if (-not $functions.ContainsKey($n)) { continue }
            foreach ($s in $functions[$n].FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $x -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
                foreach ($seg in ([string]$s.Value -split '[.\[\]]')) { if ($seg) { [void]$script:ReadSegments.Add($seg) } }
            }
        }
        $script:CicdEntries = @($script:Entries | Where-Object { $_.Area -eq 'src/terraform/environments/cicd-infra/variables.tf' })
    }
    It 'builds every class a variable of the environment with ConvertTo-AzlRunnerTerraformVariable (form cicd_runners)' {
        @($script:CicdEntries | Where-Object { $_.Node['class'] -eq 'a' -and $_.Node['source'] -eq 'infrastructure' -and $_.Node['form'] -ne 'cicd_runners' } | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }
    It 'reads every segment of every key a class a entry names' {
        $bad = foreach ($e in @($script:CicdEntries | Where-Object { $_.Node['class'] -eq 'a' -and $_.Node.Contains('infrastructure_key') })) {
            foreach ($k in @($e.Node['infrastructure_key'])) {
                $segments = @(([string]$k -replace '\[[^\]]*\]', '') -split '\.')
                $missing = @($segments | Where-Object { -not $script:ReadSegments.Contains($_) })
                if ($missing.Count) { "$($e.Name): $k ($($missing -join ', ') never read)" }
            }
        }
        @($bad) | Should -BeNullOrEmpty -Because 'the registry entry names a key that ConvertTo-AzlRunnerTerraformVariable does not read, so the value would not come from the file'
    }
    It 'writes the new runner and network keys of the file into the variables' {
        Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'cicd-infra', 'AzlCicdInfra.psm1')) -Force
        $doc = ConvertFrom-Yaml (Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')) -Raw) -Ordered
        $doc.devops.Remove('api_token')
        $z = $doc.devops.runners[1]
        $z.admin_username = 'iicadmin'; $z.os_disk_type = 'StandardSSD_LRS'; $z.os_disk_caching = 'ReadOnly'; $z.data_disk_caching = 'None'; $z.encryption_at_host = $true
        $z.zones = @('1'); $z.os_disk_size_gb = 256; $z.image = [ordered]@{ publisher = 'MicrosoftWindowsServer'; offer = 'WindowsServer'; sku = '2022-datacenter-azure-edition' }
        $z.windows_admin_password_secret = 'keyvault://kv-iic-mgmt-01/runner-ztp-local-admin'
        $doc.devops.runner_network.allow_internet_http = $false; $doc.devops.runner_network.allow_icmp = $false; $doc.devops.runner_network.reachable_tcp_ports = @('22', '5986')
        $doc.devops.runner_access.additional_role_assignments = @([ordered]@{ name = 'monitoring'; scope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-iic-mgmt-01'; role_definition_name = 'Reader' })
        $v = ConvertTo-AzlRunnerTerraformVariable -Settings (ConvertTo-AzlCicdSetting -Infrastructure $doc)
        $v.ztp_runner.admin_username | Should -Be 'iicadmin'
        $v.ztp_runner.os_disk_type | Should -Be 'StandardSSD_LRS'
        $v.ztp_runner.os_disk_caching | Should -Be 'ReadOnly'
        $v.ztp_runner.data_disk_caching | Should -Be 'None'
        $v.ztp_runner.encryption_at_host | Should -BeTrue
        $v.ztp_runner.zones | Should -Be @('1')
        $v.ztp_runner.os_disk_size_gb | Should -Be 256
        $v.ztp_runner.image.sku | Should -Be '2022-datacenter-azure-edition'
        $v.ztp_runner.image.version | Should -Be 'latest' -Because 'the registry default of devops.runners[].image.version'
        $v.ztp_runner.nsg_name | Should -Be 'nsg-iic-runner-ztp-01'
        $v.ztp_runner.identity_name | Should -Be 'id-iic-runner-ztp-01'
        $v.ztp_runner.count | Should -Be 1
        $v.windows_admin_password_secret_name | Should -Be 'runner-ztp-local-admin'
        $v.github_ztp_runner_group | Should -Be 'azurelocal-ztp'
        $v.allow_internet_http | Should -BeFalse
        $v.allow_icmp | Should -BeFalse
        $v.allow_internet_https | Should -BeTrue -Because 'the registry default of devops.runner_network.allow_internet_https'
        $v.reachable_tcp_ports | Should -Be @('22', '5986')
        $v.additional_role_assignments.monitoring.role_definition_name | Should -Be 'Reader'
        $v.hub_peering.spoke_name | Should -Be 'peer-vnet-iic-devops-01-to-hub'
        $v.hub_peering.allow_gateway_transit | Should -BeTrue -Because 'the hub network of the example allows gateway transit'
        $v.linux_runner.admin_username | Should -Be 'runneradmin' -Because 'the registry default of devops.runners[].admin_username'
        $v.linux_runner.Contains('os_disk_size_gb') | Should -BeFalse -Because 'not set: the module takes the size of the OS'
    }
}

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The Terraform variables (src/terraform) and the Ansible variables (src/ansible) are registered in the master registry, and each one
# says where it comes from: a key of infrastructure.yml (class a), a choice that has no key yet (b), a setting of the code (c) or a
# feature that is out of scope (d). config/variables/scripts/New-IacVariableFiles.ps1 writes the variable files from infrastructure.yml.
# No Terraform binary and no Ansible are needed: variables.tf is read with a regular expression.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Scripts = Join-Path $script:Repo 'config\variables\scripts'
    $script:Generator = Join-Path $script:Scripts 'New-IacVariableFiles.ps1'
    $script:Example = Join-Path $script:Repo 'config\variables\examples\infrastructure.example.yml'
    Import-Module (Join-Path $script:Scripts 'VariableRegistry.psm1') -Force
    $script:Registry = @(Get-RegistryVariable -Path (Join-Path $script:Repo 'config\variables\schema\master-registry.yaml'))
    $script:RegistryPaths = [System.Collections.Generic.HashSet[string]]::new([string[]]$script:Registry.Path)
    $script:ByPath = @{}
    foreach ($r in $script:Registry) { $script:ByPath[$r.Path] = $r }

    # Registered variables: leaf entries (they have a name and a class) of the Terraform and Ansible sections.
    $script:Entries = @(
        foreach ($r in $script:Registry) {
            if ($r.Path -notmatch '^tools\.(terraform\.variables|ansible\.variables|cicd_infra\.terraform_variables|cicd_infra\.ansible_variables)\.[^.]+\.[^.]+$') { continue }
            if ($r.Node -isnot [System.Collections.IDictionary] -or -not $r.Node.Contains('name')) { continue }
            $group = $script:ByPath[$r.Path.Substring(0, $r.Path.LastIndexOf('.'))]
            [pscustomobject]@{ Path = $r.Path; Area = [string]$group.Node['area']; Name = [string]$r.Node['name']; Node = $r.Node; Root = ([string]$r.Node['name'] -split '\.')[0] }
        }
    )
    $script:IacEntries = @($script:Entries | Where-Object { $_.Node.Contains('class') })

    function Get-TfVariableName([string]$Path) {
        $text = [IO.File]::ReadAllText($Path)
        @([regex]::Matches($text, '(?m)^variable\s+"([^"]+)"\s*\{') | ForEach-Object { $_.Groups[1].Value })
    }
    function Get-RelativePath([string]$Path) { $Path.Substring($script:Repo.Length + 1).Replace('\', '/') }
    function ConvertTo-ComparableDefault($Value) {
        $t = [string]$Value
        $t = $t -replace '^"(.*)"$', '$1' -replace '\\\\', '\' -replace ',\s+', ','
        $t.Trim()
    }

    function Invoke-Generator {
        param([string]$InfrastructureFile = $script:Example, [string]$OutputDirectory, [string[]]$Argument = @())
        $out = & pwsh -NoProfile -File $script:Generator -InfrastructureFile $InfrastructureFile -OutputDirectory $OutputDirectory @Argument 2>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out }
    }
    function Get-FileHash256([string]$Directory) {
        if (-not (Test-Path $Directory)) { return @{} }
        $h = @{}
        foreach ($f in Get-ChildItem $Directory -Recurse -File) { $h[$f.FullName.Substring($Directory.Length)] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        $h
    }

    # One full run for the checks of the output.
    $script:Run = Join-Path $TestDrive 'full'
    $script:RunResult = Invoke-Generator -OutputDirectory $script:Run
}

Describe 'Every Terraform variable is registered' {
    It 'the variables of <_> are registered, and every registered variable is declared' -ForEach @(
        'src/terraform/environments/azure-local/variables.tf', 'src/terraform/environments/cicd-infra/variables.tf', 'src/terraform/backend/variables.tf',
        'src/terraform/modules/landing-zone/variables.tf', 'src/terraform/modules/networking/variables.tf', 'src/terraform/modules/identity/variables.tf',
        'src/terraform/modules/monitoring/variables.tf', 'src/terraform/modules/security/variables.tf', 'src/terraform/modules/compute/variables.tf',
        'src/terraform/modules/cicd-runner/variables.tf'
    ) {
        $declared = @(Get-TfVariableName (Join-Path $script:Repo $_) | Sort-Object -Unique)
        $file = $_
        $registered = @($script:Entries | Where-Object { $_.Area -eq $file } | ForEach-Object { $_.Root } | Sort-Object -Unique)
        $declared.Count | Should -BeGreaterThan 0
        @($declared | Where-Object { $_ -notin $registered }) | Should -BeNullOrEmpty -Because "declared in $file but not registered under tools.terraform.variables"
        @($registered | Where-Object { $_ -notin $declared }) | Should -BeNullOrEmpty -Because "registered for $file but not declared there"
    }

    It 'finds every variables.tf under src/terraform (a new one must be listed above)' {
        $found = @(Get-ChildItem (Join-Path $script:Repo 'src\terraform') -Recurse -Filter variables.tf -File | Where-Object { $_.FullName -notmatch '\\\.terraform\\' } | ForEach-Object { Get-RelativePath $_.FullName })
        $found.Count | Should -Be 10
    }

    It 'the backend settings of the cicd-infra example are the registered ones' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Repo 'src\terraform\environments\cicd-infra\backend.hcl.example'))
        $inFile = @([regex]::Matches($text, '(?m)^(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $registered = @($script:Entries | Where-Object { $_.Area -like '*cicd-infra/backend.hcl.example' } | ForEach-Object { $_.Name -replace '^backend\.', '' } | Sort-Object)
        $registered | Should -Be $inFile
    }

    It 'a variable the registry does not know is found (the check itself works)' {
        $registered = @($script:Entries | Where-Object { $_.Area -eq 'src/terraform/backend/variables.tf' } | ForEach-Object { $_.Root })
        'not_a_registered_variable' | Should -Not -BeIn $registered
    }
}

Describe 'Every Ansible variable is registered' {
    It 'the variables of <_> are registered' -ForEach @(
        'src/ansible/roles/ad-preparation/defaults/main.yml', 'src/ansible/roles/arc-registration/defaults/main.yml', 'src/ansible/roles/cicd_runner/defaults/main.yml',
        'src/ansible/roles/cicd_runner/vars/main.yml', 'src/ansible/roles/domain-controller/defaults/main.yml', 'src/ansible/roles/monitoring-agents/defaults/main.yml',
        'src/ansible/roles/os-configuration/defaults/main.yml', 'src/ansible/roles/syslog-receiver/defaults/main.yml', 'src/ansible/roles/wac-server/defaults/main.yml',
        'src/ansible/inventory/group_vars/all.yml'
    ) {
        $file = $_
        $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $script:Repo $file)))
        $declared = @(if ($doc) { $doc.Keys | Sort-Object })
        $registered = @($script:Entries | Where-Object { $_.Area -eq $file } | ForEach-Object { $_.Root } | Sort-Object -Unique)
        # a role default that the generator also writes to group_vars/all.yml is registered once, with the area of the role default
        $writtenToGroupVars = @($script:Entries | Where-Object { $_.Node.Contains('target') -and $_.Node['target'] -eq 'group_vars' } | ForEach-Object { $_.Root } | Sort-Object -Unique)
        $known = if ($file -like '*group_vars*') { @($registered) + @($writtenToGroupVars) } else { $registered }
        @($declared | Where-Object { $_ -notin $known }) | Should -BeNullOrEmpty -Because "declared in $file but not registered under tools.ansible.variables"
        if ($file -like '*group_vars*') {
            # a group variable that the example does not produce must be a secret, a run-time value or optional
            $absent = @($registered | Where-Object { $_ -notin $declared })
            foreach ($name in $absent) {
                $e = $script:Entries | Where-Object { $_.Area -eq $file -and $_.Name -eq $name } | Select-Object -First 1
                ($e.Node['source'] -in 'secret', 'runtime') -or $e.Node['required'] -eq 'N' | Should -BeTrue -Because "$name is registered for group_vars/all.yml but the example file does not write it"
            }
        }
        else {
            @($registered | Where-Object { $_ -notin $declared }) | Should -BeNullOrEmpty -Because "registered for $file but not declared there"
        }
    }

    It 'finds every defaults, vars and group_vars file under src/ansible (a new one must be listed above)' {
        $found = @(Get-ChildItem (Join-Path $script:Repo 'src\ansible') -Recurse -Include main.yml, all.yml -File | Where-Object { $_.DirectoryName -match 'defaults$|vars$' } | ForEach-Object { Get-RelativePath $_.FullName })
        $found.Count | Should -Be 10
    }

    It 'the host variables are read by a role task' {
        $tasks = [IO.File]::ReadAllText((Join-Path $script:Repo 'src\ansible\roles\os-configuration\tasks\main.yml'))
        foreach ($e in @($script:Entries | Where-Object { $_.Node.Contains('target') -and $_.Node['target'] -eq 'host_vars' })) { $tasks | Should -Match ([regex]::Escape($e.Name)) }
    }

    It 'the registered default of a role default is the default in the file' {
        foreach ($e in @($script:IacEntries | Where-Object { $_.Area -like 'src/ansible/roles/*' -and $_.Node.Contains('default') })) {
            $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $script:Repo $e.Area)))
            $v = $doc[$e.Name]
            $text = if ($v -is [bool]) { $v.ToString().ToLowerInvariant() } elseif ($v -is [System.Collections.IDictionary] -or $v -is [System.Collections.IList]) { $v | ConvertTo-Json -Compress -Depth 8 } else { [string]$v }
            (ConvertTo-ComparableDefault $e.Node['default']) | Should -BeExactly (ConvertTo-ComparableDefault $text) -Because "$($e.Name) in $($e.Area)"
        }
    }

    It 'a setting that Terraform and Ansible both have has the same default in both' {
        foreach ($e in @($script:IacEntries | Where-Object { $_.Node.Contains('same_as') })) {
            $other = $script:ByPath[[string]$e.Node['same_as']]
            $other | Should -Not -BeNullOrEmpty -Because "same_as of $($e.Name) names a path that is not in the registry"
            $mine = if ($e.Node.Contains('default')) { ConvertTo-ComparableDefault $e.Node['default'] } else { '' }
            $theirs = if ($other.Node.Contains('default')) { ConvertTo-ComparableDefault $other.Node['default'] } else { '' }
            $mine | Should -BeExactly $theirs -Because "$($e.Name) and $($e.Node['same_as'])"
        }
    }

    It 'the collections of the cicd_runner role are the ones of requirements.yml' {
        $required = @((ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $script:Repo 'src\ansible\collections\requirements.yml')))).collections | ForEach-Object { $_.name } | Sort-Object)
        $role = @((ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $script:Repo 'src\ansible\roles\cicd_runner\defaults\main.yml')))).cicd_runner_ansible_collections | Sort-Object)
        $role | Should -Be $required
    }
}

Describe 'Each registered variable says where it comes from' {
    It 'has a class, a source and what they need' {
        $problems = foreach ($e in $script:IacEntries) {
            $n = $e.Node
            $cls = [string]$n['class']; $src = [string]$n['source']
            if ($cls -notin 'a', 'b', 'c', 'd') { "$($e.Path): class '$cls'" }
            if ($src -notin 'infrastructure', 'tool', 'secret', 'runtime') { "$($e.Path): source '$src'" }
            # an object that is built from its attributes (subscriptions, vpn_config) has no key of its own; its attributes have
            $hasAttributes = @($script:IacEntries | Where-Object { $_.Area -eq $e.Area -and $_.Name.StartsWith("$($e.Name).") }).Count -gt 0
            if ($cls -eq 'a' -and $src -in 'infrastructure', 'secret' -and -not $n.Contains('infrastructure_key') -and -not $n.Contains('passed_from') -and -not $hasAttributes) { "$($e.Path): class a without infrastructure_key" }
            if ($cls -eq 'b' -and -not $n.Contains('proposed_key') -and -not $n.Contains('passed_from')) { "$($e.Path): class b without proposed_key" }
            if ($cls -in 'b', 'c', 'd' -and $src -ne 'tool') { "$($e.Path): class $cls with source $src" }
            if ($cls -eq 'c' -and -not $n.Contains('default') -and -not $n.Contains('passed_from')) { "$($e.Path): class c without a default" }
            if ($cls -eq 'd' -and -not $n.Contains('out_of_scope')) { "$($e.Path): class d without out_of_scope" }
            if ($src -in 'secret', 'runtime' -and $n.Contains('default') -and (ConvertTo-ComparableDefault $n['default']) -ne '') { "$($e.Path): a secret or run-time variable has a default value" }
            if (-not $n.Contains('target')) { "$($e.Path): no target" }
            elseif ($n['target'] -notin 'tfvars', 'backend_hcl', 'group_vars', 'host_vars', 'inventory', 'none') { "$($e.Path): target '$($n['target'])'" }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'names only keys that exist in the registry, and a proposed key is not one yet' {
        $problems = foreach ($e in $script:IacEntries) {
            foreach ($k in @(if ($e.Node.Contains('infrastructure_key')) { $e.Node['infrastructure_key'] })) {
                $path = ($k -replace '\[[^\]]*\]', '[]') -replace '\[\]$', ''
                if (-not $script:RegistryPaths.Contains($path)) { "$($e.Path): $k is not a registry path" }
            }
            if ($e.Node.Contains('proposed_key')) {
                $path = (([string]$e.Node['proposed_key']) -replace '\[[^\]]*\]', '[]') -replace '\[\]$', ''
                if ($script:RegistryPaths.Contains($path)) { "$($e.Path): proposed key $($e.Node['proposed_key']) exists already; make the variable class a" }
            }
            if ($e.Node.Contains('passed_from') -and -not $script:ByPath.ContainsKey([string]$e.Node['passed_from'])) { "$($e.Path): passed_from names a path that is not in the registry" }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'a key a Terraform or Ansible variable reads is tagged used_by terraform or ansible' {
        $problems = foreach ($e in $script:IacEntries) {
            $tool = if ($e.Path -like 'tools.ansible.*') { 'ansible' } else { 'terraform' }
            foreach ($k in @(if ($e.Node.Contains('infrastructure_key')) { $e.Node['infrastructure_key'] })) {
                $path = ($k -replace '\[[^\]]*\]', '[]') -replace '\[\]$', ''
                $r = $script:ByPath[$path]
                if ($r -and @($r.UsedBy -split '\|') -notcontains $tool) { "$path is read by $tool ($($e.Name)) but used_by lacks $tool" }
            }
        }
        @($problems | Sort-Object -Unique) | Should -BeNullOrEmpty
    }

    It 'the forms the registry names are forms of the generator' {
        $forms = @(& pwsh -NoProfile -File $script:Generator -ListForm)
        $named = @($script:IacEntries | Where-Object { $_.Node.Contains('form') } | ForEach-Object { [string]$_.Node['form'] } | Sort-Object -Unique)
        @($named | Where-Object { $_ -notin $forms }) | Should -BeNullOrEmpty
    }

    It 'the new keys of 5.6.17 are read by the generator and carry that version' {
        foreach ($p in 'landing_zone.management_groups[].role', 'azure.automation_identity.object_id') {
            $script:ByPath[$p].Since | Should -Be '5.6.17'
            $script:ByPath[$p].UsedBy | Should -Match 'terraform'
        }
    }

    It 'the out-of-scope features are not in the code any more (Windows Admin Center is listed, nothing else)' {
        @($script:IacEntries | Where-Object { $_.Node['class'] -eq 'd' } | ForEach-Object { [string]$_.Node['out_of_scope'] } | Sort-Object -Unique) | Should -Be @('Windows Admin Center')
        foreach ($gone in 'dcr_performance_counters', 'dcr_event_logs', 'ama_extension_version', 'enable_cluster_alerts', 'alert_scopes') {
            @($script:Entries | Where-Object { $_.Name -eq $gone }).Count | Should -Be 0 -Because $gone
        }
        (Get-Content (Join-Path $script:Repo 'src\terraform\modules\monitoring\main.tf') -Raw) | Should -Not -Match 'azurerm_monitor_metric_alert'
        (Get-Content (Join-Path $script:Repo 'src\ansible\roles\monitoring-agents\tasks\main.yml') -Raw) | Should -Not -Match 'dataCollectionRules'
    }
}

Describe 'The generator, run on the example file' {
    It 'finishes with exit code 0 and writes every file' {
        $script:RunResult.Exit | Should -Be 0 -Because $script:RunResult.Output
        foreach ($rel in 'terraform\azure-local\terraform.tfvars.json', 'terraform\azure-local\backend.hcl', 'terraform\backend\terraform.tfvars.json', 'terraform\cicd-infra\terraform.tfvars.json', 'terraform\cicd-infra\backend.hcl', 'ansible\inventory\group_vars\all.yml', 'ansible\inventory\hosts.yml') {
            Join-Path $script:Run $rel | Should -Exist
        }
        @(Get-ChildItem (Join-Path $script:Run 'ansible\inventory\host_vars') -Filter *.yml).Count | Should -Be 2
    }

    It 'writes valid JSON, and only variables the environment declares' {
        foreach ($target in @{ Folder = 'azure-local'; Tf = 'src\terraform\environments\azure-local\variables.tf' }, @{ Folder = 'backend'; Tf = 'src\terraform\backend\variables.tf' }, @{ Folder = 'cicd-infra'; Tf = 'src\terraform\environments\cicd-infra\variables.tf' }) {
            $json = Get-Content (Join-Path $script:Run "terraform\$($target.Folder)\terraform.tfvars.json") -Raw | ConvertFrom-Json -AsHashtable
            $declared = @(Get-TfVariableName (Join-Path $script:Repo $target.Tf))
            @($json.Keys | Where-Object { $_ -notin $declared }) | Should -BeNullOrEmpty -Because $target.Folder
            # every variable without a default is written, or is a secret or run-time value
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo $target.Tf))
            foreach ($name in $declared) {
                $block = [regex]::Match($text, "(?ms)^variable\s+`"$name`"\s*\{.*?^\}").Value
                if ($block -notmatch '(?m)^\s+default\s*=') {
                    $e = $script:Entries | Where-Object { $_.Area -like "*$($target.Tf.Replace('\','/'))" -and $_.Name -eq $name } | Select-Object -First 1
                    if ($e.Node['source'] -notin 'secret', 'runtime') { $json.Keys | Should -Contain $name -Because "$name has no default in $($target.Tf)" }
                }
            }
        }
    }

    It 'writes valid YAML for group_vars and host_vars, with the values of the file' {
        $vars = ConvertFrom-Yaml (Get-Content (Join-Path $script:Run 'ansible\inventory\group_vars\all.yml') -Raw)
        $vars.cluster_name | Should -Be 'iic-azl-01'
        $vars.ad_domain_fqdn | Should -Be 'improbability.cloud'
        $vars.onprem_vlans.management.gateway | Should -Be '192.0.2.1'
        $vars.domain_admin_username | Should -Be 'IIC\lcm-iic-azl-01'
        $vars.Contains('domain_admin_password') | Should -BeFalse
        $vars.Contains('spn_client_secret') | Should -BeFalse
        $hostVars = ConvertFrom-Yaml (Get-Content (Join-Path $script:Run 'ansible\inventory\host_vars\iic-azl-n01.yml') -Raw)
        $hostVars.mgmt_ip | Should -Be '192.0.2.11'
    }

    It 'writes the shape the Terraform modules need' {
        $tf = Get-Content (Join-Path $script:Run 'terraform\azure-local\terraform.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
        $tf.subnets.Keys | Should -Contain 'gateway'
        $tf.subnets.Keys | Should -Contain 'bastion'
        $tf.management_groups.root_name | Should -Be 'mg-iic'
        $tf.org_code | Should -Be 'iic'
        $tf.enable_vpn_gateway | Should -BeTrue
        $tf.vpn_config.local_gateway_ip | Should -Be '203.0.113.1'
        # every management VM sits in a subnet that exists
        foreach ($vm in $tf.management_vms.Values) { $tf.subnets.Keys | Should -Contain $vm.subnet_key }
        # every resource group the modules look up is one the landing zone creates
        foreach ($k in 'hub_resource_group_name', 'monitoring_resource_group_name', 'identity_resource_group_name', 'compute_resource_group_name') { $tf.resource_groups.Keys | Should -Contain $tf[$k] }
        $backend = Get-Content (Join-Path $script:Run 'terraform\azure-local\backend.hcl') -Raw
        $backend | Should -Match 'key = "azure-local.tfstate"'
    }

    It 'writes no secret and no secret reference, and says how the code gets it' {
        $all = (Get-ChildItem $script:Run -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $all | Should -Not -Match '(keyvault|env|file|command)://'
        $note = Get-Content (Join-Path $script:Run 'terraform\azure-local\not-written.txt') -Raw
        $note | Should -Match 'TF_VAR_vm_admin_password'
        $note | Should -Match 'TF_VAR_vpn_shared_key'
        (Get-Content (Join-Path $script:Run 'ansible\inventory\group_vars\all.yml') -Raw) | Should -Match '# domain_admin_password: not written'
    }

    It 'never writes a plain secret value of the file either' {
        $text = [IO.File]::ReadAllText($script:Example)
        $text = $text -replace 'keyvault://kv-iic-mgmt-01/vm-admin-password', 'Plain-Secret-Value-One-1' -replace 'keyvault://kv-iic-mgmt-01/vpn-shared-key', 'Plain-Secret-Value-Two-2' -replace 'keyvault://kv-iic-mgmt-01/lcm-password', 'Plain-Secret-Value-Three-3'
        $file = Join-Path $TestDrive 'plain.yml'
        Set-Content -LiteralPath $file -Value $text
        $out = Join-Path $TestDrive 'plain'
        $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory $out
        $r.Exit | Should -Be 0 -Because $r.Output
        $all = (Get-ChildItem $out -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $all | Should -Not -Match 'Plain-Secret-Value'
    }

    It 'is idempotent: a second run changes nothing' {
        $before = Get-FileHash256 $script:Run
        $r = Invoke-Generator -OutputDirectory $script:Run
        $r.Exit | Should -Be 0 -Because $r.Output
        $after = Get-FileHash256 $script:Run
        ($after.Keys | Sort-Object) | Should -Be ($before.Keys | Sort-Object)
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because $k }
        $r.Output | Should -Match 'unchanged'
        $r.Output | Should -Not -Match '\[(written|updated)\]'
    }

    It 'writes the same files as the committed group_vars/all.yml' {
        $generated = (Get-Content (Join-Path $script:Run 'ansible\inventory\group_vars\all.yml') -Raw).Replace("`r`n", "`n")
        $committed = (Get-Content (Join-Path $script:Repo 'src\ansible\inventory\group_vars\all.yml') -Raw).Replace("`r`n", "`n")
        $committed | Should -BeExactly $generated
    }

    It 'writes the Ansible inventory: the nodes and the Windows machines with their addresses, in the groups of the playbooks, and the connection settings from the registry' {
        $inventory = ConvertFrom-Yaml (Get-Content (Join-Path $script:Run 'ansible\inventory\hosts.yml') -Raw)
        $children = $inventory.all.children
        @($children.cluster_nodes.hosts.Keys | Sort-Object) | Should -Be @('iic-azl-n01', 'iic-azl-n02')
        $children.cluster_nodes.hosts['iic-azl-n01'].ansible_host | Should -Be '192.0.2.11'
        $children.domain_controllers.hosts['iic-dc01'].ansible_host | Should -Match '^\d+\.\d+\.\d+\.\d+$'
        @($children.windows.children.Keys) | Should -Contain 'cluster_nodes'
        $children.windows.vars.ansible_connection | Should -Be 'winrm'
        $children.windows.vars.ansible_winrm_transport | Should -Be 'kerberos'
        $children.windows.vars.ansible_winrm_server_cert_validation | Should -Be 'ignore'
        $children.windows.vars.ansible_port | Should -Be 5986
        $children.windows.vars.ansible_port | Should -BeOfType [int]
        (Get-Content (Join-Path $script:Run 'ansible\inventory\hosts.yml') -Raw) | Should -Not -Match 'password|secret|keyvault://'
    }

    It 'leaves a Linux machine out of the inventory and says so, and refuses a machine with no address' {
        $text = [IO.File]::ReadAllText($script:Example)
        $withLinux = $text -replace '(?m)^(\s+)os: "windows_server_2025"(.*)$', '$1os: ubuntu_2404$2'
        $withLinux | Should -Not -Be $text   # the example has a Windows machine to turn into a Linux one
        if ($true) {
            $file = Join-Path $TestDrive 'linux.yml'
            Set-Content -LiteralPath $file -Value $withLinux
            $out = Join-Path $TestDrive 'linux'
            $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory $out -Argument @('-Target', 'Ansible')
            $r.Exit | Should -Be 0 -Because $r.Output
            (Get-Content (Join-Path $out 'ansible\inventory\hosts.yml') -Raw) | Should -Match 'Not listed \(Linux'
        }
        $noAddress = $text -replace '(?m)^(\s+)private_ip: .*$', ''
        $file2 = Join-Path $TestDrive 'noaddress.yml'
        Set-Content -LiteralPath $file2 -Value $noAddress
        $out2 = Join-Path $TestDrive 'noaddress'
        $r2 = Invoke-Generator -InfrastructureFile $file2 -OutputDirectory $out2 -Argument @('-Target', 'Ansible')
        $r2.Exit | Should -Be 2 -Because $r2.Output
        $r2.Output | Should -Match 'private_ip'
        Test-Path $out2 | Should -BeFalse
    }

    It 'writes landing_zone.network_security_groups[] as the Terraform variable nsgs, one value in each rule field, and refuses a rule with a list of several' {
        $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText($script:Example)) -Ordered
        $rule = [ordered]@{ name = 'allow-rdp'; priority = 100; direction = 'Inbound'; access = 'Allow'; protocol = 'Tcp'; source_address_prefixes = @('192.0.2.0/24'); destination_port_ranges = @('3389') }
        $doc.landing_zone.network_security_groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @($rule) })
        $file = Join-Path $TestDrive 'nsg.yml'
        Set-Content -LiteralPath $file -Value (ConvertTo-Yaml $doc)
        $out = Join-Path $TestDrive 'nsg'
        $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory $out -Argument @('-Target', 'AzureLocal')
        $r.Exit | Should -Be 0 -Because $r.Output
        $json = Get-Content (Join-Path $out 'terraform\azure-local\terraform.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
        @($json.nsgs).Count | Should -Be 1
        $json.nsgs[0].name | Should -Be 'nsg-iic-mgmt-01'
        $json.nsgs[0].rules[0].source_address_prefix | Should -Be '192.0.2.0/24'
        $json.nsgs[0].rules[0].destination_port_range | Should -Be '3389'
        $json.nsgs[0].rules[0].source_port_range | Should -Be '*'
        $json.nsgs[0].rules[0].destination_address_prefix | Should -Be '*'
        $json.nsgs[0].rules[0].priority | Should -Be 100

        $rule.destination_port_ranges = @('3389', '443')
        $doc.landing_zone.network_security_groups = @([ordered]@{ name = 'nsg-iic-mgmt-01'; rules = @($rule) })
        $file2 = Join-Path $TestDrive 'nsg2.yml'
        Set-Content -LiteralPath $file2 -Value (ConvertTo-Yaml $doc)
        $out2 = Join-Path $TestDrive 'nsg2'
        $r2 = Invoke-Generator -InfrastructureFile $file2 -OutputDirectory $out2 -Argument @('-Target', 'AzureLocal')
        $r2.Exit | Should -Be 2 -Because $r2.Output
        $r2.Output | Should -Match 'destination_port_ranges lists 2 values'
        Test-Path $out2 | Should -BeFalse
    }

    It 'plans and writes nothing under -WhatIf' {
        $out = Join-Path $TestDrive 'whatif'
        $r = Invoke-Generator -OutputDirectory $out -Argument @('-WhatIf')
        $r.Exit | Should -Be 0 -Because $r.Output
        Test-Path $out | Should -BeFalse
        $r.Output | Should -Match 'planned'
    }

    It 'stops with exit code 2 and writes nothing when a value is missing' {
        $text = [IO.File]::ReadAllText($script:Example) -replace '(?m)^  name: "iic-azl-01" # up to 15 characters', '  # name removed'
        $file = Join-Path $TestDrive 'missing.yml'
        Set-Content -LiteralPath $file -Value $text
        $out = Join-Path $TestDrive 'missing'
        $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory $out -Argument @('-Target', 'Ansible')
        $r.Exit | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'cluster_name'
        Test-Path $out | Should -BeFalse
    }

    It 'stops with exit code 2 when a secret reference stands where a value is needed' {
        $text = [IO.File]::ReadAllText($script:Example) -replace '(?m)^  location: "eastus".*$', '  location: "keyvault://kv-iic-mgmt-01/location"'
        $file = Join-Path $TestDrive 'secretvalue.yml'
        Set-Content -LiteralPath $file -Value $text
        $out = Join-Path $TestDrive 'secretvalue'
        $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory $out -Argument @('-Target', 'Ansible')
        $r.Exit | Should -Be 2 -Because $r.Output
        Test-Path $out | Should -BeFalse
    }

    It 'skips a target whose section is missing when the target is not named, and stops when it is' {
        $text = [IO.File]::ReadAllText($script:Example)
        $text = $text.Substring(0, $text.IndexOf('landing_zone:')) + $text.Substring($text.IndexOf('# Part 1 of the implementation steps'))
        $text = $text -replace 'hub_peering: \{ enabled: true[^}]*\}', 'hub_peering: { enabled: false }'
        $file = Join-Path $TestDrive 'nolanding.yml'
        Set-Content -LiteralPath $file -Value $text
        $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory (Join-Path $TestDrive 'nolanding')
        $r.Exit | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Skipped: AzureLocal'
        Join-Path $TestDrive 'nolanding\terraform\azure-local' | Should -Not -Exist
        $r = Invoke-Generator -InfrastructureFile $file -OutputDirectory (Join-Path $TestDrive 'nolanding2') -Argument @('-Target', 'AzureLocal')
        $r.Exit | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'landing_zone'
    }

    It 'exits with 2 when the infrastructure file cannot be read' {
        $r = Invoke-Generator -InfrastructureFile (Join-Path $TestDrive 'does-not-exist.yml') -OutputDirectory (Join-Path $TestDrive 'nofile')
        $r.Exit | Should -Be 2
    }

    It 'reads only keys that exist in the registry' {
        $keys = @(& pwsh -NoProfile -File $script:Generator -ListKey)
        $keys.Count | Should -BeGreaterThan 50
        @($keys | Where-Object { -not $script:RegistryPaths.Contains($_) }) | Should -BeNullOrEmpty
    }

    It 'builds the cicd-infra variables only from variables the registry lists' {
        $tf = Get-Content (Join-Path $script:Run 'terraform\cicd-infra\terraform.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
        $tf.Keys | Should -Contain 'linux_runner'
        $tf.Keys | Should -Not -Contain 'admin_ssh_public_key'
    }
}

Describe 'The generator script follows the script standard' {
    BeforeAll { $script:Text = [IO.File]::ReadAllText($script:Generator) }

    It 'has the standard header' {
        $script:Text | Should -Match '(?m)^#Requires -Version 7\.0'
        $script:Text | Should -Match '(?m)^Set-StrictMode -Version Latest'
        $script:Text | Should -Match "(?m)^\`$ErrorActionPreference = 'Stop'"
        $script:Text | Should -Match 'SupportsShouldProcess'
    }

    It 'asks nothing, signs in nowhere and reads no secret' {
        $script:Text | Should -Not -Match 'Read-Host|Get-Credential|Connect-AzAccount|Get-AzlSecret|Resolve-AzlSecret|Invoke-WebRequest|Invoke-RestMethod'
    }

    It 'carries no value of an environment (no GUID, no address, no organisation name)' {
        $code = ($script:Text -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $help = $script:Text.Substring(0, $script:Text.IndexOf('#>'))
        $code = $code.Replace($help, '')
        $code | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $code | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        $code | Should -Not -Match '(?i)improbability|contoso|tierpoint|\biic\b'
    }

    It 'has every parameter registered' {
        $problems = @(& (Join-Path $script:Scripts 'Test-ToolParameterRegistration.ps1') -Tool arm_deployment -Root $script:Scripts -Registry $script:Registry)
        @($problems | Where-Object { $_.Script -like '*New-IacVariableFiles.ps1' }) | Should -BeNullOrEmpty
        $registered = @($script:Registry | Where-Object { $_.Path -match '^tools\.arm_deployment\.parameters\.config_variables_scripts_New_IacVariableFiles_ps1\.[^.]+$' }).Count
        $registered | Should -BeGreaterOrEqual 8
    }
}

Describe 'The Terraform code, when Terraform is installed' {
    It 'is formatted (terraform fmt -check)' -Skip:(-not ($env:AZL_CHECK_TERRAFORM -eq '1' -and (Get-Command terraform -ErrorAction SilentlyContinue))) {
        $out = & terraform fmt -check -recursive (Join-Path $script:Repo 'src\terraform') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
    }
}

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Owner directive D121: no deployment value is written into the Ansible code. Every value comes from a variable file that
# config/variables/scripts/New-IacVariableFiles.ps1 writes from infrastructure.yml, or is a setting of the code registered in
# the master registry (class c) with the same default as the role.
#
# The test reads every role, playbook, inventory, configuration and script file of src/ansible (comment lines
# excepted: they are documentation) and fails on a deployment-choice literal: an IPv4 address outside the documentation
# ranges, a distinguished name or the name of an organization, a cloud DNS suffix or endpoint, a version pin or 'latest'
# (outside a role default that is registered class c), and a URL whose host is not a vendor download address. It also fails
# on a role default with no registry entry and on a registry default that differs from the role default. A value fixed by
# Windows, Azure, Ansible or a protocol is allowed only through the reviewed list below, each line with its reason; an entry
# of the list that no line needs any more fails too, so the list stays small.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester blocks.')]
param()

BeforeDiscovery {
    $script:Roots = 'src/ansible'
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', 'fixtures', 'ForbiddenTokens.ps1'))
    Import-Module (Join-Path $script:Repo 'config\variables\scripts\VariableRegistry.psm1') -Force
    $script:Registry = @(Get-RegistryVariable -Path (Join-Path $script:Repo 'config\variables\schema\master-registry.yaml'))
    $byPath = @{}
    foreach ($r in $script:Registry) { $byPath[$r.Path] = $r }
    # The registered Ansible variables: tools.ansible.variables and tools.cicd_infra.ansible_variables.
    $script:Entries = @(
        foreach ($r in $script:Registry) {
            if ($r.Path -notmatch '^tools\.(ansible\.variables|cicd_infra\.ansible_variables)\.[^.]+\.[^.]+$') { continue }
            if ($r.Node -isnot [System.Collections.IDictionary] -or -not $r.Node.Contains('name')) { continue }
            $group = $byPath[$r.Path.Substring(0, $r.Path.LastIndexOf('.'))]
            [pscustomobject]@{ Path = $r.Path; Area = [string]$group.Node['area']; Name = [string]$r.Node['name']; Node = $r.Node }
        }
    )

    # Every file of the two trees that git tracks or would track (a generated inventory in the tree is ignored by git).
    $script:Files = @(& git -C $script:Repo ls-files --cached --others --exclude-standard -- 'src/ansible' |
            Where-Object { $_ -match '\.(ya?ml|cfg|j2|ps1|example)$' -and (Test-Path -LiteralPath (Join-Path $script:Repo $_)) } | Sort-Object -Unique)

    # The generated examples: New-IacVariableFiles.ps1 writes them from config/variables/examples/infrastructure.example.yml, and
    # tests/variables/IacVariables.Tests.ps1 fails when they differ from its output. Their values are the example file's.
    $script:Generated = @('src/ansible/inventory/hosts.yml.example', 'src/ansible/inventory/cicd-runners.yml.example')

    # Hosts a URL may name: the vendors' own download and API addresses (not a choice of the deployment).
    $script:VendorHosts = @(
        'github.com'                           # GitHub releases of the runner, Bicep, Git for Windows, PowerShell
        'api.github.com'                       # GitHub REST API: the runner registration token, the release of a version
        'releases.hashicorp.com'               # Terraform releases
        'gitlab-runner-downloads.s3.amazonaws.com' # GitLab Runner releases
        'download.agent.dev.azure.com'         # Azure Pipelines agent releases
        'packages.microsoft.com'               # Microsoft Linux package repositories (PowerShell, Azure CLI)
        'aka.ms'                               # Microsoft download short links (Azure CLI, Windows Admin Center)
        'localhost'                            # the machine itself
        '169.254.169.254'                      # Azure Instance Metadata Service
    )

    # The reviewed list: a line of File (a wildcard) that matches Pattern is allowed. Reason says why the value is fixed.
    $script:Allow = @(
        @{ File = 'src/ansible/roles/cicd_runner/tasks/*.yml'; Pattern = '169\.254\.169\.254'; Reason = 'The Azure Instance Metadata Service address, fixed by Azure (https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service).' }
        @{ File = 'src/ansible/roles/cicd_runner/tasks/*.yml'; Pattern = 'api-version=7\.4'; Reason = 'The version of the Key Vault REST API the request is written for (protocol).' }
        @{ File = 'src/ansible/roles/cicd_runner/tasks/*-azure-devops.yml'; Pattern = 'download\.agent\.dev\.azure\.com|azure-pipelines-agent/releases/latest'; Reason = 'The Azure Pipelines agent download address; releases/latest is asked only when cicd_runner_azure_devops_agent_version (class c) is empty.' }
        @{ File = 'src/ansible/roles/cicd_runner/tasks/windows.yml'; Pattern = "else \{ 'latest' \}"; Reason = 'The GitHub release of Git for Windows and PowerShell: latest only when the class c version variable is empty.' }
        @{ File = 'src/ansible/roles/syslog-receiver/tasks/main.yml'; Pattern = '127\.0\.0\.1'; Reason = 'The loopback address (protocol): messages of the receiver itself are not written to the device logs.' }
        @{ File = '*.ps1'; Pattern = '^\s*Set-StrictMode -Version Latest$'; Reason = 'The PowerShell script standard (Set-StrictMode -Version Latest), not a version of a tool.' }
        @{ File = 'src/ansible/collections/requirements.yml'; Pattern = 'version: ">='; Reason = 'The lowest version of each collection the roles need (Ansible Galaxy requirement), not a pin.' }
        @{ File = '*/roles/*/meta/main.yml'; Pattern = 'min_ansible_version:'; Reason = 'Ansible Galaxy metadata: the lowest Ansible version the role supports.' }
    )

    $script:Checks = [ordered]@{
        'an IPv4 address outside the documentation ranges' = { param($Line) foreach ($m in [regex]::Matches($Line, '(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])')) { $a = $m.Value; if ($a -notmatch '^(192\.0\.2|198\.51\.100|203\.0\.113)\.') { return $a } } }
        'a distinguished name or the name of an organization' = { param($Line) if ($Line -match '(?i)\b(OU|DC|CN)=[A-Za-z0-9]|improbability|contoso|fabrikam|\biic\b') { return $Matches[0] }; $hit = @(Find-AzlForbiddenToken $Line); if ($hit.Count) { return ($hit -join ', ') } }
        'a cloud DNS suffix or endpoint' = { param($Line) if ($Line -match '(?i)vault\.azure\.net|vault\.usgovcloudapi\.net|management\.(azure\.com|usgovcloudapi\.net)|login\.microsoftonline\.(com|us)|\.azure\.(com|us)\b|\.windows\.net\b|usgovcloudapi\.net|168\.63\.129\.16|\bAzure(Cloud|USGovernment)\b') { return $Matches[0] } }
        'a version pin or latest' = { param($Line) if ($Line -match '(?i)(version["'']?\s*[:=]\s*["'']?(>=|==)?\s*\d+\.\d+|==\s*\d+\.\d+|-(Required)?Version\s+\d+\.\d+|\blatest\b)') { return $Matches[0] } }
        'a URL to a host that is not a vendor download address' = { param($Line) foreach ($m in [regex]::Matches($Line, 'https?://([^/\s''"`)\]}]+)')) { $h = $m.Groups[1].Value; if ($h -match '\{\{|\$|<') { continue }; if (($h -replace ':\d+$', '') -notin $script:VendorHosts) { return $m.Value } } }
    }

    function Test-Allowed([string]$File, [string]$Line) {
        foreach ($a in $script:Allow) { if ($File -like $a.File -and $Line -match $a.Pattern) { return $a } }
        $null
    }

    # The literals of one text: File, Line number, Check, Value. Comment lines are documentation and are not read.
    function Get-Literal([string]$File, [string]$Text) {
        $n = 0
        foreach ($line in ($Text -split "`r?`n")) {
            $n++
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            # a trailing comment is documentation too
            $code = $line -replace '\s+#\s.*$', ''
            foreach ($c in $script:Checks.Keys) {
                $hit = & $script:Checks[$c] $code
                if ($hit) { [pscustomobject]@{ File = $File; Line = $n; Check = $c; Value = [string]$hit; Text = $line.Trim() } }
            }
        }
    }

    function ConvertTo-ComparableDefault($Value) {
        if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
        if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Collections.IList]) { return (ConvertTo-Json -InputObject $Value -Compress -Depth 8) -replace ',\s+', ',' }
        $t = [string]$Value
        $t = $t -replace '^"(.*)"$', '$1' -replace '\\\\', '\' -replace ',\s+', ','
        $t.Trim()
    }

    # role defaults: file -> parsed map
    $script:Defaults = [ordered]@{}
    foreach ($f in @($script:Files | Where-Object { $_ -match '/roles/[^/]+/defaults/main\.yml$' })) {
        $doc = ConvertFrom-Yaml ([IO.File]::ReadAllText((Join-Path $script:Repo $f))) -Ordered
        $script:Defaults[$f] = if ($doc) { $doc } else { [ordered]@{} }
    }

    $script:Found = @(
        foreach ($f in $script:Files) {
            if ($f -in $script:Generated) { continue }
            $isDefaults = $f -match '/roles/[^/]+/defaults/main\.yml$'
            foreach ($hit in @(Get-Literal $f ([IO.File]::ReadAllText((Join-Path $script:Repo $f))))) {
                $allowed = Test-Allowed $f $hit.Text
                if ($allowed) { $hit | Add-Member -NotePropertyName Allowed -NotePropertyValue $allowed; $hit; continue }
                # a role default may carry a value (a version, a vendor address) when the registry has it as a setting of the code
                if ($isDefaults -and $hit.Text -match '^([a-z_][a-z0-9_]*):') {
                    $name = $Matches[1]
                    $e = @($script:Entries | Where-Object { $_.Area -eq $f -and $_.Name -eq $name })
                    if ($e.Count -and [string]$e[0].Node['class'] -in 'c', 'd') { $hit | Add-Member -NotePropertyName Allowed -NotePropertyValue @{ Reason = "class $($e[0].Node['class']) registered default" }; $hit; continue }
                }
                $hit | Add-Member -NotePropertyName Allowed -NotePropertyValue $null
                $hit
            }
        }
    )
}

Describe 'The Ansible code holds no deployment value (D121)' {
    It 'reads the files of src/ansible' {
        $script:Files.Count | Should -BeGreaterThan 30
        $script:Files | Should -Contain 'src/ansible/ansible.cfg'
        $script:Files | Should -Contain 'src/ansible/roles/azurelocal_os_configuration/defaults/main.yml'
        $script:Defaults.Count | Should -BeGreaterThan 7
    }

    It 'has no deployment-choice literal outside the reviewed list' {
        $bad = @($script:Found | Where-Object { -not $_.Allowed } | ForEach-Object { "$($_.File):$($_.Line) $($_.Check) '$($_.Value)': $($_.Text)" })
        $bad | Should -BeNullOrEmpty
    }

    It 'gives every entry of the reviewed list a reason, and every entry is still needed' {
        foreach ($a in $script:Allow) {
            $a.Reason | Should -Not -BeNullOrEmpty
            @($script:Found | Where-Object { $_.Allowed -and $_.Allowed.Contains('File') -and $_.Allowed.File -eq $a.File -and $_.Allowed.Pattern -eq $a.Pattern }).Count | Should -BeGreaterThan 0 -Because "the allow-list entry $($a.File) /$($a.Pattern)/ is not used by any line"
        }
    }

    It 'registers every variable of every role default (<_>)' -ForEach @(
        'src/ansible/roles/ad-preparation/defaults/main.yml', 'src/ansible/roles/arc-registration/defaults/main.yml', 'src/ansible/roles/cicd_runner/defaults/main.yml',
        'src/ansible/roles/domain-controller/defaults/main.yml', 'src/ansible/roles/monitoring-agents/defaults/main.yml', 'src/ansible/roles/syslog-receiver/defaults/main.yml',
        'src/ansible/roles/wac-server/defaults/main.yml', 'src/ansible/roles/azurelocal_os_configuration/defaults/main.yml'
    ) {
        $file = $_
        $script:Defaults.Contains($file) | Should -BeTrue
        foreach ($name in @($script:Defaults[$file].Keys)) {
            $e = @($script:Entries | Where-Object { $_.Area -eq $file -and $_.Name -eq $name })
            $e.Count | Should -Be 1 -Because "$name of $file must have one registry entry"
            $n = $e[0].Node
            $n.Contains('class') | Should -BeTrue -Because "$name of $file has no class"
            $n.Contains('source') | Should -BeTrue -Because "$name of $file has no source"
            $n.Contains('target') | Should -BeTrue -Because "$name of $file has no target"
        }
    }

    It 'lists every role default file (a new one must be listed above)' {
        $script:Defaults.Count | Should -Be 8
    }

    It 'gives each role default the default of its registry entry, and a setting of the code (class c) always has one' {
        $bad = foreach ($file in $script:Defaults.Keys) {
            foreach ($name in @($script:Defaults[$file].Keys)) {
                $e = @($script:Entries | Where-Object { $_.Area -eq $file -and $_.Name -eq $name }) | Select-Object -First 1
                if (-not $e) { continue }
                $n = $e.Node
                $role = ConvertTo-ComparableDefault $script:Defaults[$file][$name]
                if ($n.Contains('default')) {
                    $reg = ConvertTo-ComparableDefault $n['default']
                    if ($reg -cne $role) { "${file}: $name is '$role' in the role and '$reg' in the registry" }
                }
                elseif ($n['class'] -eq 'c') { "${file}: $name is class c without a registry default" }
                elseif ($n['source'] -notin 'secret', 'runtime' -and $role -notin '', '[]', '{}') { "${file}: $name has the role default '$role' and no registry default" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'says for every entry of a role default where it is read (read_at names the line of the variable)' {
        $bad = foreach ($e in @($script:Entries | Where-Object { $_.Area -match '/roles/[^/]+/(defaults|vars)/main\.yml$' })) {
            if ([string]$e.Node['read_at'] -notmatch '^(.+):(\d+)$') { "$($e.Path): read_at '$($e.Node['read_at'])' has no line"; continue }
            $lines = [IO.File]::ReadAllLines((Join-Path $script:Repo $Matches[1]))
            if ($lines[[int]$Matches[2] - 1] -notmatch "^$([regex]::Escape($e.Name)):") { "$($e.Path): line $($Matches[2]) of $($Matches[1]) is not $($e.Name)" }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'runs only the OS configuration route of the role azurelocal_os_configuration: no node configuration role in src/ansible, and no second Ansible tree' {
        Test-Path (Join-Path $script:Repo 'ansible') | Should -BeFalse
        Test-Path (Join-Path $script:Repo 'src\ansible\roles\os-configuration') | Should -BeFalse
        $playbook = [IO.File]::ReadAllText((Join-Path $script:Repo 'src\ansible\playbooks\02-os-configuration.yml'))
        $playbook | Should -Match '(?m)^\s*- role: azurelocal_os_configuration\s*$'
        $playbook | Should -Not -Match 'role:\s*os-configuration\s*$'
    }

    It 'sets no become method for every host in ansible.cfg (runas would apply to the Linux runners)' {
        [IO.File]::ReadAllText((Join-Path $script:Repo 'src\ansible\ansible.cfg')) | Should -Not -Match '(?m)^\s*become_(method|user)\s*='
    }

    It 'generates no password in a role and stores none' {
        foreach ($f in @($script:Files | Where-Object { $_ -match '/tasks/.*\.yml$' })) {
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo $f))
            $text | Should -Not -Match "lookup\('ansible\.builtin\.password'" -Because $f
            $text | Should -Not -Match 'azure_rm_keyvaultsecret:' -Because "$f writes a secret to Key Vault"
        }
    }
}

Describe 'The literal check itself works' {
    It 'finds <Check> in a sample line' -ForEach @(
        @{ Check = 'an IPv4 address outside the documentation ranges'; Sample = '    ansible_host: 10.1.2.3' }
        @{ Check = 'a distinguished name or the name of an organization'; Sample = '    path: "OU=Servers,{{ ad_domain_dn }}"' }
        @{ Check = 'a cloud DNS suffix or endpoint'; Sample = '    keyvault_uri: "https://{{ key_vault_name }}.vault.azure.net"' }
        @{ Check = 'a version pin or latest'; Sample = '      - ansible-core==2.17.0' }
        @{ Check = 'a URL to a host that is not a vendor download address'; Sample = '    url: https://example.org/tool.zip' }
    ) {
        $hits = @(Get-Literal 'sample.yml' $Sample)
        @($hits | Where-Object { $_.Check -eq $Check }).Count | Should -Be 1
    }

    It 'does not flag a documentation address, a templated value or a comment' {
        @(Get-Literal 'sample.yml' "    ansible_host: 192.0.2.11`n    url: `"https://{{ host }}/x`"`n# https://example.org 10.1.2.3 vault.azure.net").Count | Should -Be 0
    }
}

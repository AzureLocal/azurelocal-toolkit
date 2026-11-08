#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The Solution Builder Extension (SBE) is OPT-IN. The pipelines (GitHub Actions, GitLab CI, Azure DevOps), the Ansible role and the
# toolkit's scripts never turn an SBE on and never write a delivery setting into a file: delivery happens only when the operator
# sets hardware.sbe.delivery (winrm_copy or node_pull) in infrastructure.yml. Static checks; nothing is run.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/pipelines/SbeOptIn.Tests.ps1

BeforeAll {
    $repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Repo = $repo
    $script:Automation = @(
        foreach ($dir in 'pipelines', 'ansible') {
            Get-ChildItem -LiteralPath (Join-Path $repo $dir) -Recurse -File | Where-Object { $_.Extension -in '.yml', '.yaml', '.example', '.j2' -or $_.Name -like '*.yml.*' }
        }
    )
}

Describe 'Pipelines and the Ansible role do not enable an SBE' {
    It 'finds the automation files it checks' {
        $script:Automation.Count | Should -BeGreaterThan 8
    }
    It 'sets no hardware.sbe value, delivery route, bundle or pull address in <_>' -ForEach @(
        'pipelines/github/os-configuration.yml', 'pipelines/gitlab/os-configuration.gitlab-ci.yml', 'pipelines/azure-devops/os-configuration.yml',
        'pipelines/azure-devops/arm-deployment.yml', 'pipelines/github-actions/arm-deployment.yml',
        'ansible/os-configuration/roles/azurelocal_os_configuration/defaults/main.yml', 'ansible/os-configuration/inventory/hosts.yml.example'
    ) {
        $text = Get-Content -LiteralPath (Join-Path $script:Repo $_) -Raw
        $text | Should -Not -Match '(?im)^\s*(?!#)[^#\r\n]*\b(winrm_copy|node_pull)\b\s*$' -Because 'a pipeline never picks a delivery route'
        $text | Should -Not -Match '(?i)\b(SideloadSbe|sbe_bundle|sbe_delivery|node_pull_url|bundle_path)\b\s*[:=]'
        $text | Should -Not -Match '(?im)^\s*sbe\s*:'
    }
    It 'defaults the step list to the steps of each node''s method, and the Sbe step is then a no-op without hardware.sbe' {
        $defaults = Get-Content -LiteralPath (Join-Path $script:Repo 'ansible/os-configuration/roles/azurelocal_os_configuration/defaults/main.yml') -Raw
        $defaults | Should -Match 'azurelocal_os_configuration_steps:\s*\[\]'
        $ado = Get-Content -LiteralPath (Join-Path $script:Repo 'pipelines/azure-devops/os-configuration.yml') -Raw
        $ado | Should -Match "(?s)- name: steps.*?default: all"
        $ado | Should -Match 'hardware\.sbe\.delivery'
    }
    It 'says in the Ansible README that the SBE is opt-in' {
        (Get-Content -LiteralPath (Join-Path $script:Repo 'ansible/os-configuration/README.md') -Raw) | Should -Match 'opt-in'
    }
}

Describe 'The toolkit never writes a delivery setting or an SBE block into a file' {
    It 'has no script that assigns hardware.sbe or one of its keys' {
        $files = Get-ChildItem -LiteralPath (Join-Path $script:Repo 'scripts') -Recurse -File -Include '*.ps1', '*.psm1'
        $hits = foreach ($f in $files) {
            $n = 0
            foreach ($line in [IO.File]::ReadLines($f.FullName)) {
                $n++
                if ($line -match '^\s*#') { continue }
                # An assignment whose target is the SBE block or one of its delivery keys, for example $infra.hardware.sbe = ... or $sbe['delivery'] = ...
                $target = '^\s*\$[\w.\[\]''"]*'
                if ($line -match "(?i)${target}(hardware\.sbe|\['hardware'\]\.sbe|\['hardware'\]\['sbe'\])\s*=[^=~]" -or $line -match "(?i)${target}\bsbe\b[\w.\[\]'`"]*(delivery|node_pull_url|bundle_path)[\w\]'`"]*\s*=[^=~]") {
                    "$($f.FullName.Substring($script:Repo.Length + 1)):${n}: $($line.Trim())"
                }
            }
        }
        @($hits) | Should -BeNullOrEmpty -Because "an SBE and its delivery are set by the operator, never by a script: $(@($hits) -join ' || ')"
    }
}

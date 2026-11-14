#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# The SBE partner credentials (hardware.sbe.partner_credentials[]). Microsoft's template (azuredeploy.json, variable answerfileSBESecrets and the resource
# of type Microsoft.KeyVault/vaults/secrets) takes each entry of partnerCredentiallist as { secretName, secretValue } and writes secretValue into the
# cluster Key Vault. In the toolkit the value is a secret reference all the way to the request body: never in the parameter set, the parameter file,
# the hash of the deployment name, the output, the report or the events. No Azure call, no node: the resolver and the Azure calls are mocks.
# Run: Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests/arm-deployment/ArmDeployment.PartnerCredentials.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock script blocks keep the signature of the real command.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scopes.')]
param()

BeforeAll {
    $script:Repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'infrastructure', 'AzlInfrastructure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'azure-local', 'AzlAzure.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force
    Import-Module powershell-yaml
    . ([IO.Path]::Combine($PSScriptRoot, 'ArmDeploymentRun.Helpers.ps1'))
    $script:Fixture = [IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    $script:CompleteSbe = [IO.Path]::Combine($script:Repo, 'tests', 'fixtures', 'sbe', 'hardware.sbe.complete.yml')
    $script:Catalog = Get-AzlArmTemplateCatalog
    $script:TemplateFile = Join-Path $TestDrive 'template.json'
    '{ "parameters": {}, "resources": [] }' | Set-Content -LiteralPath $script:TemplateFile
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }

    # Values the "resolver" hands out. They must never show up anywhere but in the request body.
    $script:ValueOne = 'Vend0r-Secret-One-4711!'
    $script:ValueTwo = 'Vend0r-Secret-Two-0815!'
    $script:RefOne = 'keyvault://kv-iic-mgmt-01/sbe-partner-01'
    $script:RefTwo = 'env://IIC_SBE_PARTNER_02'

    function Get-InfraWithSbe {
        $i = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        $i.hardware = (ConvertFrom-Yaml -Ordered (Get-Content -LiteralPath $script:CompleteSbe -Raw)).hardware
        $i
    }
    function Get-InfraWithCredentials {
        $i = Get-InfraWithSbe
        $i.hardware.sbe['partner_credentials'] = @(
            [ordered]@{ secret_name = 'sbe-iic-partner-01'; secret = $script:RefOne },
            [ordered]@{ secret_name = 'sbe-iic-partner-02'; secret = $script:RefTwo })
        $i
    }
    function New-CredentialSet([System.Collections.IDictionary]$Infrastructure = (Get-InfraWithCredentials)) {
        $set = New-AzlArmParameterSet -Infrastructure $Infrastructure -AllowUnresolvedSanLun -Catalog $script:Catalog -Mode Validate
        $set.Parameters['infraVolLunId'] = 'UID-INFRA'; $set.Parameters['infraPerfLunId'] = 'UID-PERF'
        $set
    }
}

Describe 'The parameter set holds a reference, never a value' {
    It 'every entry is secretName and a secret reference, and the set passes the template check' {
        $set = New-CredentialSet
        $list = @($set.Parameters.partnerCredentiallist)
        $list.Count | Should -Be 2
        $list[0].secretName | Should -Be 'sbe-iic-partner-01'
        $list[0].secretValue.KeyVault | Should -Be $script:RefOne
        $list[1].secretName | Should -Be 'sbe-iic-partner-02'
        $list[1].secretValue.KeyVault | Should -Be $script:RefTwo
        @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $script:Catalog.templates[$set.Template.Name].parameters) | Should -BeNullOrEmpty
    }
    It 'an entry without a secret is an input error that names the entry' {
        foreach ($missing in @($null, '', '   ')) {
            $i = Get-InfraWithSbe
            $entry = [ordered]@{ secret_name = 'sbe-iic-partner-01' }
            if ($null -ne $missing) { $entry['secret'] = $missing }
            $i.hardware.sbe['partner_credentials'] = @($entry, [ordered]@{ secret_name = 'sbe-iic-partner-02'; secret = $script:RefTwo })
            { New-AzlArmParameterSet -Infrastructure $i -AllowUnresolvedSanLun -Catalog $script:Catalog } | Should -Throw "*partner_credentials entry 'sbe-iic-partner-01' has no secret*"
        }
    }
    It 'a plain value in secret is refused, and the message does not repeat it' {
        $i = Get-InfraWithSbe
        $i.hardware.sbe['partner_credentials'] = @([ordered]@{ secret_name = 'sbe-iic-partner-01'; secret = $script:ValueOne }, [ordered]@{ secret_name = 'sbe-iic-partner-02'; secret = $script:RefTwo })
        $message = ''
        try { $null = New-AzlArmParameterSet -Infrastructure $i -AllowUnresolvedSanLun -Catalog $script:Catalog } catch { $message = $_.Exception.Message }
        $message | Should -Match 'holds a value .*not a secret reference'
        $message | Should -Not -Match ([regex]::Escape($script:ValueOne))
    }
    It 'is checked by Test-AzlArmParameterSet inside the list too: a value or a missing reference is a problem, and no problem text repeats the value' {
        $set = New-CredentialSet
        $definitions = $script:Catalog.templates[$set.Template.Name].parameters
        $set.Parameters['partnerCredentiallist'] = @([ordered]@{ secretName = 'sbe-iic-partner-01'; secretValue = $script:ValueOne }, [ordered]@{ secretName = 'sbe-iic-partner-02' }, [ordered]@{ secretName = 'sbe-iic-partner-03'; secretValue = [ordered]@{ KeyVault = $script:RefOne } })
        $problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $definitions)
        $problems | Should -Contain "partnerCredentiallist[0].secretValue holds a value ($($script:ValueOne.Length) characters); a secret must be a secret reference (keyvault://, env://, file:// or command://)."
        ($problems -join '|') | Should -Match 'partnerCredentiallist\[1\]\.secretValue has no secret reference'
        ($problems -join '|') | Should -Not -Match 'partnerCredentiallist\[2\]'
        ($problems -join '|') | Should -Not -Match ([regex]::Escape($script:ValueOne))
    }
    It 'sends no partner list at all without an SBE version, even when the file names credentials (the template default is the empty list)' {
        $i = Import-AzlInfrastructure -Path $script:Fixture -SkipValidation
        $i.hardware.sbe['partner_credentials'] = @([ordered]@{ secret_name = 'sbe-iic-partner-01'; secret = $script:RefOne }, [ordered]@{ secret_name = 'sbe-iic-partner-02'; secret = $script:RefTwo })
        $set = New-AzlArmParameterSet -Infrastructure $i -AllowUnresolvedSanLun -Catalog $script:Catalog
        $set.Parameters.Contains('partnerCredentiallist') | Should -BeFalse
        @(Get-AzlArmNestedSecret -Parameters $set.Parameters).Count | Should -Be 0
    }
    It 'sends an empty list when an SBE is configured and the file names no credential' {
        $set = New-CredentialSet (Get-InfraWithSbe)
        @($set.Parameters.partnerCredentiallist).Count | Should -Be 0
    }
}

Describe 'The parameter file never holds the value' {
    It 'Placeholder writes secretValue as null and keeps secretName' {
        $set = New-CredentialSet
        $text = ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure (Get-InfraWithCredentials) -SecretMode Placeholder
        $list = @(($text | ConvertFrom-Json -AsHashtable -Depth 20).parameters.partnerCredentiallist.value)
        $list.Count | Should -Be 2
        $list[0].secretName | Should -Be 'sbe-iic-partner-01'
        $list[0].ContainsKey('secretValue') | Should -BeTrue
        $list[0].secretValue | Should -BeNullOrEmpty
        $list[1].secretName | Should -Be 'sbe-iic-partner-02'
        $list[1].secretValue | Should -BeNullOrEmpty
        $text | Should -Not -Match ([regex]::Escape($script:RefOne))
    }
    It 'Placeholder writes null even when a hand-built set holds a plain value' {
        $set = New-CredentialSet
        $set.Parameters['partnerCredentiallist'] = @([ordered]@{ secretName = 'sbe-iic-partner-01'; secretValue = $script:ValueOne })
        $text = ConvertTo-AzlArmParameterFile -ParameterSet $set
        $text | Should -Not -Match ([regex]::Escape($script:ValueOne))
        (($text | ConvertFrom-Json -AsHashtable -Depth 20).parameters.partnerCredentiallist.value[0]).secretValue | Should -BeNullOrEmpty
    }
    It 'an empty list stays an empty list' {
        $set = New-CredentialSet (Get-InfraWithSbe)
        $json = ConvertTo-AzlArmParameterFile -ParameterSet $set | ConvertFrom-Json -AsHashtable -Depth 20
        @($json.parameters.partnerCredentiallist.value).Count | Should -Be 0
    }
    It 'KeyVaultReference refuses when partner credentials exist, and says what to do' {
        $set = New-CredentialSet
        { ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure (Get-InfraWithCredentials) -SecretMode KeyVaultReference } | Should -Throw '*cannot read a Key Vault reference inside an array*Use -SecretMode Placeholder and run the deployment from the toolkit, which reads the value on this machine*'
        { ConvertTo-AzlArmParameterFile -ParameterSet $set -SecretMode KeyVaultReference } | Should -Throw '*Use -SecretMode Placeholder*'
    }
}

Describe 'Invoke-AzlArmDeployment sends secretName and the resolved secretValue' {
    BeforeAll {
        $script:Template = [pscustomobject]@{ resources = @([pscustomobject]@{ type = 'microsoft.azurestackhci/clusters/deploymentSettings'; apiVersion = '2026-04-01-preview' }) }
        $script:Values = @{ 'sbe-partner-01' = $script:ValueOne; 'IIC_SBE_PARTNER_02' = $script:ValueTwo }
        function New-Resolver {
            $calls = [System.Collections.Generic.List[string]]::new()
            $values = $script:Values
            $block = { param($Ref) $calls.Add($Ref); $values[$Ref.Split('/')[-1]] ?? 'value-of-other' }.GetNewClosure()
            [pscustomobject]@{ Block = $block; Calls = $calls }
        }
    }
    BeforeEach { Mock -ModuleName AzlArmDeployment Start-Sleep {} }
    It 'resolves a keyvault:// and an env:// reference with the resolver into the request body, in memory, and leaves the set alone' {
        $set = New-CredentialSet
        $resolver = New-Resolver
        $calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { $calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body }); $null }
        $r = Invoke-AzlArmDeployment -ParameterSet $set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $resolver.Block -NoWait
        $put = @($calls | Where-Object Method -eq 'PUT')
        $put.Count | Should -Be 1
        $sent = @($put[0].Body.properties.parameters.partnerCredentiallist.value)
        $sent.Count | Should -Be 2
        $sent[0].secretName | Should -Be 'sbe-iic-partner-01'
        $sent[0].secretValue | Should -Be $script:ValueOne
        $sent[1].secretName | Should -Be 'sbe-iic-partner-02'
        $sent[1].secretValue | Should -Be $script:ValueTwo
        $resolver.Calls | Should -Contain $script:RefOne
        $resolver.Calls | Should -Contain $script:RefTwo
        # What the call returns and the set it was given never hold the value.
        ($r | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($script:ValueOne))
        ($set | ConvertTo-Json -Depth 20) | Should -Not -Match ([regex]::Escape($script:ValueOne))
        ($set | ConvertTo-Json -Depth 20) | Should -Not -Match ([regex]::Escape($script:ValueTwo))
        $set.Parameters.partnerCredentiallist[0].secretValue.KeyVault | Should -Be $script:RefOne
    }
    It 'a single credential is still a JSON array in the body' {
        $i = Get-InfraWithSbe
        $i.hardware.sbe['partner_credentials'] = @([ordered]@{ secret_name = 'sbe-iic-partner-01'; secret = $script:RefOne })
        $set = New-CredentialSet $i
        $resolver = New-Resolver
        $calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { $calls.Add([pscustomobject]@{ Method = $Method; Body = $Body }); $null }
        $null = Invoke-AzlArmDeployment -ParameterSet $set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver $resolver.Block -NoWait
        $body = ($calls | Where-Object Method -eq 'PUT').Body | ConvertTo-Json -Depth 50 -Compress
        $body | Should -Match '"partnerCredentiallist":\{"value":\[\{"secretName":"sbe-iic-partner-01","secretValue":"'
    }
    It 'sends an empty list as an empty array' {
        $set = New-CredentialSet (Get-InfraWithSbe)
        $calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { $calls.Add([pscustomobject]@{ Method = $Method; Body = $Body }); $null }
        $null = Invoke-AzlArmDeployment -ParameterSet $set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver (New-Resolver).Block -NoWait
        (($calls | Where-Object Method -eq 'PUT').Body | ConvertTo-Json -Depth 50 -Compress) | Should -Match '"partnerCredentiallist":\{"value":\[\]\}'
    }
    It 'sends nothing when a set holds a plain value, and the message does not repeat it' {
        $set = New-CredentialSet
        $set.Parameters['partnerCredentiallist'] = @([ordered]@{ secretName = 'sbe-iic-partner-01'; secretValue = $script:ValueOne })
        $calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { $calls.Add([pscustomobject]@{ Method = $Method }); $null }
        $message = ''
        try { $null = Invoke-AzlArmDeployment -ParameterSet $set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver (New-Resolver).Block -NoWait } catch { $message = $_.Exception.Message }
        $message | Should -Match 'is not a secret reference\. Nothing was sent'
        $message | Should -Not -Match ([regex]::Escape($script:ValueOne))
        @($calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
    It 'sends nothing when a reference resolves to an empty value' {
        $set = New-CredentialSet
        $calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName AzlArmDeployment Invoke-AzlArm { $calls.Add([pscustomobject]@{ Method = $Method }); $null }
        { Invoke-AzlArmDeployment -ParameterSet $set -Template $script:Template -SubscriptionId 's' -ResourceGroup 'r' -Mode Validate -SecretResolver { param($Ref) '' } -NoWait } | Should -Throw '*resolved to an empty value*'
        @($calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }
}

Describe 'No place that serializes the parameter set shows a value' {
    It 'the parameter hash does not change with the value and holds no value, even for a hand-built plain value' {
        $set = New-CredentialSet
        $hash = Get-AzlArmParameterHash -ParameterSet $set
        $hash | Should -Match '^[0-9a-f]{12}$'
        $a = New-CredentialSet; $a.Parameters['partnerCredentiallist'] = @([ordered]@{ secretName = 'sbe-iic-partner-01'; secretValue = $script:ValueOne })
        $b = New-CredentialSet; $b.Parameters['partnerCredentiallist'] = @([ordered]@{ secretName = 'sbe-iic-partner-01'; secretValue = $script:ValueTwo })
        Get-AzlArmParameterHash -ParameterSet $a | Should -Be (Get-AzlArmParameterHash -ParameterSet $b)
        # A different reference is a different deployment; a different secret name too.
        $c = New-CredentialSet; $c.Parameters['partnerCredentiallist'][0].secretValue = [ordered]@{ KeyVault = 'keyvault://kv-iic-mgmt-01/sbe-partner-09' }
        Get-AzlArmParameterHash -ParameterSet $c | Should -Not -Be $hash
    }
    It 'the display copy keeps references and masks a value' {
        $set = New-CredentialSet
        $set.Parameters['partnerCredentiallist'] = @([ordered]@{ secretName = 'sbe-iic-partner-01'; secretValue = $script:ValueOne }, [ordered]@{ secretName = 'sbe-iic-partner-02'; secretValue = [ordered]@{ KeyVault = $script:RefTwo } })
        $set.Parameters['localAdminPassword'] = $script:ValueTwo
        $text = Get-AzlArmDisplayParameter -Parameters $set.Parameters | ConvertTo-Json -Depth 20
        $text | Should -Not -Match ([regex]::Escape($script:ValueOne))
        $text | Should -Not -Match ([regex]::Escape($script:ValueTwo))
        $text | Should -Match ([regex]::Escape($script:RefTwo))
    }
    It 'the parameter-source table says the list holds secret references and shows no value' {
        $set = New-CredentialSet
        $md = Format-AzlArmParameterSource -ParameterSet $set
        $md | Should -Match '\| partnerCredentiallist \| `hardware\.sbe\.partner_credentials` .*list; each secretValue is a secret reference'
        $md | Should -Not -Match ([regex]::Escape($script:RefOne))
    }
    It 'a whole run reads the values for the submit only: no file, event or result holds them, and the deployment name is the hash' {
        $infra = Get-TestInfra
        $infra.hardware['sbe'] = [ordered]@{ publisher = 'Dell'; family = '16G-45n0c-Intel'; version = '5.0.2609.1611'; partner_credentials = @([ordered]@{ secret_name = 'sbe-iic-partner-01'; secret = $script:RefOne }, [ordered]@{ secret_name = 'sbe-iic-partner-02'; secret = 'keyvault://kv-iic-mgmt-01/sbe-partner-02' }) }
        $w = Get-FakeWorld
        # The fake Azure echoes the value in a failing step, as a real error text could: the report must hide it.
        $failed = Get-TestState -Validation 'Failed' -ValidationSteps @(Get-TestStep '0.1' 'Validate environment' 'Error' 0 @("The secret $($script:ValueOne) was refused") '2026-11-07T12:12:00Z')
        $w.After['validate'] = @($failed); $w.ArmAfter['validate'] = @([pscustomobject]@{ ProvisioningState = 'Succeeded'; Error = ''; Timestamp = '' })
        $sent = [System.Collections.Generic.List[string]]::new()
        $submit = {
            param($Arguments)
            foreach ($slot in @(Get-AzlArmNestedSecret -Parameters $Arguments.ParameterSet.Parameters)) { $sent.Add([string](& $Arguments.SecretResolver $slot.Value.KeyVault)) }
            $w.SubmitCalls.Add([pscustomobject]@{ Mode = $Arguments.Mode; DeploymentName = $Arguments.DeploymentName; SkipValidationCheck = $false; SecretKeys = @(); Time = $w.Clock.Time })
            $w.Submitted = $true; $w.Polls = 0; $w.LastMode = $Arguments.Mode.ToLowerInvariant()
        }.GetNewClosure()
        $one = $script:ValueOne
        $getSecret = { param($Reference) $one }.GetNewClosure()
        $dir = Join-Path $TestDrive 'partner-run'
        $r = Invoke-TestRun -World $w -Mode Validate -Infra $infra -Dir $dir -Override @{ Submit = $submit; GetSecret = $getSecret }
        $w.SubmitCalls.Count | Should -Be 1
        $sent.Count | Should -Be 2
        $sent[0] | Should -Be $script:ValueOne
        $w.SubmitCalls[0].DeploymentName | Should -Match '^azl-validate-[0-9a-f]{12}$'
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File)
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) { (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match ([regex]::Escape($script:ValueOne)) -Because $f.Name }
        ($r | ConvertTo-Json -Depth 12) | Should -Not -Match ([regex]::Escape($script:ValueOne))
        $parameterFile = @($files | Where-Object { $_.Name -like '*.parameters.json' })
        $parameterFile.Count | Should -Be 1
        $written = (Get-Content -LiteralPath $parameterFile[0].FullName -Raw) | ConvertFrom-Json -AsHashtable -Depth 20
        @($written.parameters.partnerCredentiallist.value).Count | Should -Be 2
        $written.parameters.partnerCredentiallist.value[0].secretName | Should -Be 'sbe-iic-partner-01'
        $written.parameters.partnerCredentiallist.value[0].secretValue | Should -BeNullOrEmpty
        $written.parameters.partnerCredentiallist.value[1].secretValue | Should -BeNullOrEmpty
    }
}

Describe 'The registry, the example and the script text' {
    BeforeAll {
        $script:Registry = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'schema', 'master-registry.yaml')) -Raw
        $script:Module = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'scripts', 'common', 'arm-deployment', 'AzlArmDeployment.psm1')) -Raw
    }
    It 'the registry gives partner_credentials a required secret_name and a required, sensitive secret reference' {
        $yaml = ConvertFrom-Yaml -Ordered $script:Registry
        $items = $yaml.hardware.properties.sbe.properties.partner_credentials.items
        $items.properties.Keys | Should -Be @('secret_name', 'secret')
        $items.properties.secret_name.required | Should -BeTrue
        $items.properties.secret.required | Should -BeTrue
        $items.properties.secret.sensitive | Should -BeTrue
        $items.properties.secret.format | Should -Be 'kv_ref'
        $items.properties.secret.description | Should -Match 'plain array'
        $items.properties.secret.description | Should -Match 'visible in the deployment''s input parameters in Azure'
        $items.properties.secret.description | Should -Match 'only when the hardware vendor''s SBE requires it'
        $items.properties.secret_name.example | Should -Be 'sbe-iic-partner-01'
    }
    It 'the example file shows secret_name and secret, with reference forms only' {
        $text = Get-Content -LiteralPath ([IO.Path]::Combine($script:Repo, 'config', 'variables', 'examples', 'infrastructure.example.yml')) -Raw
        $text | Should -Match '(?m)^\s*#\s+- secret_name: sbe-iic-partner-01\r?\n\s*#\s+secret: keyvault://kv-iic-mgmt-01/sbe-partner-01'
    }
    It 'the module never writes, prints or logs a partner secret value' {
        # The module holds no output of a value: the only place that reads one is the request body.
        $script:Module | Should -Not -Match 'Write-Host'
        $script:Module | Should -Not -Match '(?i)Write-(Verbose|Debug|Information|Output)[^\r\n]*secretValue'
        ([regex]::Matches($script:Module, '& \$SecretResolver')).Count | Should -Be 2
    }
}

<#
.SYNOPSIS
    ARM Validate and Deploy of an Azure Local instance from infrastructure.yml with the Azure CLI: az deployment group validate, then az deployment group create.

.DESCRIPTION
    The Azure CLI variant of the ARM deployment of the cluster deployment phase (Invoke-AzureLocalArmDeployment.ps1), for a host that has the Azure CLI
    and not the Az PowerShell modules. The two task scripts of phase 05 (active-directory and local-identity, task 01, Initiate deployment via ARM
    template) call this script with the identity of their folder.

    It reuses the toolkit's ARM deployment code, scripts/common/arm-deployment/AzlArmDeployment.psm1 and AzlArmDeploymentRun.psm1, for everything that is
    not a call to Azure: which Microsoft quickstart template fits the design (Select-AzlArmTemplate), the missing-value check (Test-AzlArmRequiredKey), the
    parameter set built from infrastructure.yml, the ZTP handoff and the OS configuration report (New-AzlArmParameterSet), its check against the template
    (Test-AzlArmParameterSet), the parameter file (ConvertTo-AzlArmParameterFile), the deployment names (<prefix>-validate-<hash> and <prefix>-deploy-<hash>)
    and the run settings (Get-AzlArmRunSetting: timeouts and polling). Only the Azure calls are az commands.

    Order, the same as the PowerShell run:
      1. Read the file, pick the template, generate and check the parameters. Exit code 2 on a missing value. Nothing has gone to Azure.
      2. Sign-in and tenant check (az account show).
      3. The state of the instance (az rest, deploymentSettings/default). Mode Validate is refused when a deployment is running or done, and when the
         instance is in a failed deployment state (Microsoft: another Validate resets the system properties and can break license sync) unless
         -AllowRevalidate. Mode Deploy is refused unless the instance validated successfully (or a deployment already started), and a failed deployment
         is resubmitted only with -Resume. The words of the status (Success, InProgress, Failed ...) are read with ConvertTo-AzlArmStepStatus of
         AzlArmDeploymentRun.psm1, the same as the PowerShell run. A status that cannot be read, or that is none of those words, counts as still running:
         the script ends with success only when Azure reports an explicit success, else it fails, or times out.
      4. Pre-flight: az deployment group validate with the template and the parameter file. Nothing is created.
      5. Submit: az deployment group create --no-wait with deploymentMode Validate or Deploy, then wait for the outcome (az deployment group show, and
         the validation or deployment status of the instance) up to the timeout of the run settings (validateTimeoutMinutes 90, deployTimeoutMinutes 360).
         A deployment of the same name that is running is attached to; one that succeeded is not submitted again; a failed Deploy is resubmitted only with -Resume.
         The deployment name is <prefix>-validate-<hash> or <prefix>-deploy-<hash>; the hash covers the parameters and the identity of the template (its address, or
         the SHA-256 of the file of -TemplateFile), so a changed template is never taken for the earlier, succeeded deployment.
    -WhatIf does steps 1 to 4 and says what it would submit.

    Secrets. The local administrator's password and the LCM user's password go to Azure as Key Vault references in the parameter file (Azure Resource
    Manager reads the vault itself; the vault needs "Azure Resource Manager for template deployment" enabled, and the signed-in account needs to be
    allowed to use the secrets). No secret value is read, written or put on a command line by this script. A secret that is not a keyvault:// reference
    (env://, file://, command://) cannot be handed to Azure this way, so the script stops with exit code 2 and names the PowerShell script, which reads
    it on this machine. SBE partner credentials are refused the same way. The parameter file has no secret value in it.

    The template is Microsoft's, read by Azure from its address (az deployment group ... --template-uri); -TemplateFile uses a local copy instead. The
    run setting deploymentSettingsApiVersion, which patches the api-version of the template's deploymentSettings resource in the PowerShell run, is not
    applied here: the template is used as Microsoft publishes it.

    The script does not sign in: run az login --tenant <azure.tenant_id> first. It does not change the Azure CLI default subscription: every call carries
    --subscription. Two calls (az rest and az ad sp show) have no subscription parameter that selects the tenant: they use the default sign-in context of the
    Azure CLI, so the script first checks that the tenant of the plain "az account show" is azure.tenant_id, and stops with exit code 1 when it is not.

    Values come only from infrastructure.yml (read through Import-AzlInfrastructure and the ARM deployment modules): azure.tenant_id,
    azure.subscription_id, azure.resource_group, azure.hci_resource_provider_object_id, cluster.name, scenario.identity and every key that
    config/azure/arm-templates/parameter-sources.json lists for the chosen template.

    Characters az.cmd cannot carry. On Windows az is a batch file (az.cmd): cmd.exe reads & | < > ^ in an argument as operators, and %NAME% as a variable, and
    a double quote or a line break breaks the argument (Microsoft Learn: Considerations for running the Azure CLI in a PowerShell scripting language). The
    script therefore refuses, with exit code 2 and before it calls Azure (also under -WhatIf), a value of the file (a name, a tag key or value, a display name,
    an e-mail address ...) that holds one of & | < > ^ % " or a line break. Every az call is checked again, in the one function that starts az; the check
    names the position of the argument, never the value.

    Exit codes: 0 the requested step succeeded (or planned under -WhatIf, or submitted with -NoWait); 1 a precondition, the pre-flight, the validation or
    the deployment failed, or the wait timed out; 2 a value in the file is missing or unusable, or the identity of the file is not the one this task is for.

.PARAMETER InfrastructureFile
    The master infrastructure.yml (schema 5).

.PARAMETER HandoffFile
    azurelocal-ztp's ztp-handoff.json (schema 2): the Arc machine resource IDs and the solution build. Optional.

.PARAMETER OsConfigurationReport
    The OS configuration report: its report.json, a node-level report, or its report directory. Gives the adapter names and the SAN disks. Optional.

.PARAMETER Mode
    Validate (default): submit the validation (deploymentMode Validate). Deploy: submit the deployment (deploymentMode Deploy, 2.5 to 3 hours); it needs a
    successful Validate of the same parameters.

.PARAMETER ExpectedIdentity
    active_directory or local_identity. The two task scripts pass the identity of their folder; the script stops with exit code 2 when scenario.identity
    of the file is the other one. Empty: no check.

.PARAMETER ReportDirectory
    Where the parameter file goes. Default: a folder in the temp directory. Keep it out of the repository. The path must hold none of & | < > ^ % " or a
    line break (az.cmd would read it as an operator or a variable): the script stops with exit code 2 before it writes the file.

.PARAMETER TemplateFile
    A local copy of the quickstart template, instead of the address in the template catalog.

.PARAMETER TimeoutMinutes
    The longest time to wait for the outcome. Default: the run setting validateTimeoutMinutes (Validate) or deployTimeoutMinutes (Deploy).

.PARAMETER NoWait
    Submit and return. The deployment keeps running in Azure; run the script again to attach to it.

.PARAMETER Resume
    Resubmit a failed Deploy. Without it a failed Deploy is refused.

.PARAMETER AllowRevalidate
    Allow Validate on an instance in a failed deployment state. Microsoft says not to; for support-guided recovery only.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./Invoke-AzureLocalArmDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Validate -WhatIf

    Generates and checks the parameters, runs the pre-flight validation and submits nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./Invoke-AzureLocalArmDeployment.azcli.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Deploy
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [string]$HandoffFile,
    [string]$OsConfigurationReport,
    [ValidateSet('Validate', 'Deploy')][string]$Mode = 'Validate',
    [ValidateSet('', 'active_directory', 'local_identity')][string]$ExpectedIdentity = '',
    [string]$ReportDirectory,
    [string]$TemplateFile,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes,
    [switch]$NoWait,
    [switch]$Resume,
    [switch]$AllowRevalidate,
    [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

$common = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'common'))
Import-Module ([IO.Path]::Combine($common, 'infrastructure', 'AzlInfrastructure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-cli', 'AzlAzureCliArgument.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'azure-local', 'AzlAzure.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'AzlArmDeployment.psm1')) -Force
Import-Module ([IO.Path]::Combine($common, 'arm-deployment', 'AzlArmDeploymentRun.psm1')) -Force

$Guid = '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
$NotFound = 'NotFound|could not be found|was not found|does not exist|\b404\b'
# The api-version of the Microsoft.AzureStackHCI deploymentSettings resource this script reads. Fixed by the Azure API (Microsoft Learn, Microsoft.AzureStackHCI
# clusters/deploymentSettings, 2026-10-01 is in the 2610 view); the same version AzlArmDeployment.psm1 reads with.
$HciApiVersion = '2026-10-01'
# The application ID of the Azure Local resource provider's service principal (Microsoft publishes it; it is the same in every tenant).
$HciResourceProviderAppId = '1412d89f-b8a8-4111-b4fd-e82905cbd85d'


function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }
function Get-Text([string]$Path) { ([string](Get-AzlInfrastructureValue -Infrastructure $infra -Path $Path)).Trim() }
function Get-Prop($Object, [string[]]$Path) {
    $node = $Object
    foreach ($part in $Path) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) { if ($node.Contains($part)) { $node = $node[$part] } else { return $null } }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.PSObject.Properties[$part].Value }
        else { return $null }
    }
    $node
}

# The one place the Azure CLI is called. Arguments go as an array, never as a command string. Returns the exit code, stdout and stderr.
function Invoke-AzCli([string[]]$Arguments) {
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $Arguments
    if ($unsafe) { Exit-InputProblem $unsafe }
    $all = @(& az @Arguments 2>&1)
    $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
    $out = (@($all | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    $err = (@($all | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err; Detail = $(if ($err) { $err.Trim() } else { $out.Trim() }) }
}
function ConvertFrom-AzJson([string]$Text) { if ($Text -and $Text.Trim()) { $Text | ConvertFrom-Json -Depth 50 } }

# The instance as the deployment tool sees it: the provisioning state and the validation and deployment status of deploymentSettings/default. $null when
# the resource does not exist yet.
function Get-InstanceState {
    $url = "/subscriptions/$subscriptionId/resourceGroups/$group/providers/Microsoft.AzureStackHCI/clusters/$clusterName/deploymentSettings/default?api-version=$HciApiVersion"
    $r = Invoke-AzCli @('rest', '--method', 'get', '--url', $url, '--output', 'json', '--only-show-errors')
    if ($r.ExitCode -ne 0) {
        if ($r.Detail -match $NotFound) { return $null }
        throw "The state of the instance could not be read: $($r.Detail)"
    }
    $j = ConvertFrom-AzJson $r.Output
    $failedStep = {
        param($steps)
        foreach ($s in @($steps)) {
            if ($null -eq $s) { continue }
            if ([string](Get-Prop $s @('status')) -in 'Error', 'Failed') { "$(Get-Prop $s @('name')): $(@(Get-Prop $s @('exception')) -join ' ')" }
            & $failedStep (Get-Prop $s @('steps'))
        }
    }
    $validation = Get-Prop $j @('properties', 'reportedProperties', 'validationStatus')
    $deployment = Get-Prop $j @('properties', 'reportedProperties', 'deploymentStatus')
    [pscustomobject]@{
        ProvisioningState = [string](Get-Prop $j @('properties', 'provisioningState'))
        ValidationStatus  = [string](Get-Prop $validation @('status'))
        DeploymentStatus  = [string](Get-Prop $deployment @('status'))
        FailedSteps       = @(@(& $failedStep (Get-Prop $validation @('steps'))) + @(& $failedStep (Get-Prop $deployment @('steps'))) | Where-Object { $_ })
    }
}
# Every status decision goes through the toolkit's reading of the status words (notstarted, running, success, error, skipped, unknown), as the PowerShell run does.
function Test-Success([string]$Status) { (ConvertTo-AzlArmStepStatus $Status) -eq 'success' }

# ---- 1. the values, the template and the parameters. No call to Azure.
try { $infra = Import-AzlInfrastructure -Path $InfrastructureFile -SkipValidation }
catch { Exit-InputProblem "Cannot read the infrastructure file: $($_.Exception.Message)" }

$tenantId = Get-Text 'azure.tenant_id'
$subscriptionId = Get-Text 'azure.subscription_id'
$group = Get-Text 'azure.resource_group'
$clusterName = Get-Text 'cluster.name'
$identity = Get-Text 'scenario.identity'
if ($tenantId -notmatch $Guid) { Exit-InputProblem 'azure.tenant_id is missing or is not a GUID. It is the tenant the sign-in must belong to.' }
if ($subscriptionId -notmatch $Guid -or $subscriptionId -eq [guid]::Empty.ToString()) { Exit-InputProblem 'azure.subscription_id is missing, not a GUID or the all-zero placeholder.' }
if (-not $group) { Exit-InputProblem 'azure.resource_group is missing. The instance is deployed there.' }
if (-not $clusterName) { Exit-InputProblem 'cluster.name is missing in the infrastructure file.' }
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ 'azure.resource_group' = $group; 'cluster.name' = $clusterName }); if ($problem) { Exit-InputProblem $problem }
if ($ExpectedIdentity -and $identity -ne $ExpectedIdentity) { Exit-InputProblem "This task is for scenario.identity $ExpectedIdentity, but the file says '$identity'. Use the task of the other identity, or correct the file." }
if ($TemplateFile -and -not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) { Exit-InputProblem "Template file not found: $TemplateFile" }

try {
    $settings = Get-AzlArmRunSetting -Infrastructure $infra
    $template = Select-AzlArmTemplate -Infrastructure $infra
    $keyProblems = @(Test-AzlArmRequiredKey -Infrastructure $infra -TemplateName $template.Name)
    if ($keyProblems.Count) { Exit-InputProblem ("$($keyProblems.Count) required value(s) are missing:`n" + ($keyProblems -join "`n")) }
    $handoff = $null
    if ($HandoffFile) {
        if (-not (Test-Path -LiteralPath $HandoffFile -PathType Leaf)) { Exit-InputProblem "Handoff file not found: $HandoffFile" }
        $handoff = Read-AzlHandoff -Path $HandoffFile
    }
    $osReport = if ($OsConfigurationReport) { Read-AzlArmOsReport -Path $OsConfigurationReport } else { $null }
}
catch { Exit-InputProblem "The parameters can't be generated: $($_.Exception.Message)" }

# ---- 2. preconditions that read Azure
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, then run az login --tenant <azure.tenant_id>. Or use Invoke-AzureLocalArmDeployment.ps1.' }
$account = Invoke-AzCli @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors')
if ($account.ExitCode -ne 0) { Exit-Failed "Not signed in to the Azure CLI for subscription $subscriptionId. Run az login --tenant <azure.tenant_id>. $($account.Detail)" }
$accountInfo = ConvertFrom-AzJson $account.Output
if ([string](Get-Prop $accountInfo @('tenantId')) -ne $tenantId) { Exit-Failed "The Azure CLI is signed in to tenant $(Get-Prop $accountInfo @('tenantId')), but azure.tenant_id is $tenantId. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }
# az rest and az ad sp show use the default sign-in context, not the subscription named above: the tenant of the plain az account show has to be the one of the file.
$defaultAccount = Invoke-AzCli @('account', 'show', '--output', 'json', '--only-show-errors')
if ($defaultAccount.ExitCode -ne 0) { Exit-Failed "The default sign-in context of the Azure CLI could not be read. Run az login --tenant <azure.tenant_id>. $($defaultAccount.Detail)" }
$defaultTenant = [string](Get-Prop (ConvertFrom-AzJson $defaultAccount.Output) @('tenantId'))
if ($defaultTenant -ne $tenantId) { Exit-Failed "The default sign-in context of the Azure CLI is tenant $defaultTenant, but azure.tenant_id is $tenantId, and az rest and az ad sp show use that context. Sign in to the right tenant (az login --tenant <azure.tenant_id>)." }

try {
    $arguments = @{ Infrastructure = $infra; Handoff = $handoff; Mode = $Mode }
    if ($osReport) { $arguments.AdapterMap = Get-AzlAdapterMapFromReport -Report $osReport; $arguments.AdapterMapSource = $OsConfigurationReport; $arguments.NodeReport = @($osReport.nodes) }
    if (-not (Get-AzlInfrastructureValue -Infrastructure $infra -Path 'azure.hci_resource_provider_object_id')) {
        $sp = Invoke-AzCli @('ad', 'sp', 'show', '--id', $HciResourceProviderAppId, '--query', 'id', '--output', 'tsv', '--only-show-errors')
        if ($sp.ExitCode -ne 0 -or -not $sp.Output.Trim()) { Exit-Failed "The service principal of the Azure Local resource provider ($HciResourceProviderAppId) was not found in this tenant. Register Microsoft.AzureStackHCI, or set azure.hci_resource_provider_object_id. $($sp.Detail)" }
        $arguments.HciResourceProviderObjectId = $sp.Output.Trim()
    }
    $set = New-AzlArmParameterSet @arguments
    $catalog = Get-AzlArmTemplateCatalog
    $problems = @(Test-AzlArmParameterSet -ParameterSet $set -TemplateParameters $catalog.templates[$set.Template.Name].parameters -Deploy:($Mode -eq 'Deploy'))
    if ($problems.Count) { Exit-InputProblem ("$($problems.Count) problem(s) in the parameter set:`n" + ($problems -join "`n")) }
    $parameterJson = ConvertTo-AzlArmParameterFile -ParameterSet $set -Infrastructure $infra -SecretMode KeyVaultReference
}
catch { Exit-InputProblem "The parameters can't be generated: $($_.Exception.Message) If a secret is not a keyvault:// reference, use Invoke-AzureLocalArmDeployment.ps1, which reads it on this machine." }
# The identity of the template goes into the hash, so a template that changed is not taken for the deployment that succeeded with the old one.
$templateIdentity = if ($TemplateFile) { 'sha256:' + (Get-FileHash -LiteralPath $TemplateFile -Algorithm SHA256).Hash } else { [string]$template.Uri }
$hash = Get-AzlArmParameterHash -ParameterSet $set -TemplateIdentity $templateIdentity
$deploymentName = "$($settings.deploymentNamePrefix)-$($Mode.ToLowerInvariant())-$hash"
foreach ($warning in $set.Warnings) { Write-Warning $warning }

if (-not $ReportDirectory) { $ReportDirectory = Join-Path ([IO.Path]::GetTempPath()) "$($settings.reportDirectoryPrefix)-$clusterName" }
$parameterFile = Join-Path $ReportDirectory "$clusterName.$($Mode.ToLowerInvariant()).parameters.json"
# The path goes to az as "@<path>" (and the local template as a path): refuse a character az.cmd cannot carry before anything is written.
$problem = Get-AzlAzureCliValueProblem -Value ([ordered]@{ '-ReportDirectory (or the temp directory), so the parameter file' = $parameterFile; '-TemplateFile' = $(if ($TemplateFile) { (Resolve-Path -LiteralPath $TemplateFile).ProviderPath } else { '' }) })
if ($problem) { Exit-InputProblem $problem }
$null = New-Item -ItemType Directory -Force -Path $ReportDirectory -WhatIf:$false
Set-Content -LiteralPath $parameterFile -Value $parameterJson -Encoding utf8NoBOM -WhatIf:$false
$templateArguments = if ($TemplateFile) { @('--template-file', (Resolve-Path -LiteralPath $TemplateFile).ProviderPath) } else { @('--template-uri', [string]$template.Uri) }
$scopeArguments = @('--subscription', $subscriptionId, '--resource-group', $group)
Write-Line "ARM $Mode of '$clusterName' in '$group': template $($template.Name), $($set.Parameters.Count) parameters, deployment $deploymentName"
Write-Line "Parameter file: $parameterFile (no secret value in it)"

# ---- 3. the state of the instance
try { $before = Get-InstanceState }
catch { Exit-Failed $_.Exception.Message }
$beforeDeployment = if ($before) { ConvertTo-AzlArmStepStatus $before.DeploymentStatus } else { 'notstarted' }
$beforeValidation = if ($before) { ConvertTo-AzlArmStepStatus $before.ValidationStatus } else { 'notstarted' }
$beforeFailed = [bool]($before -and ($before.ProvisioningState -eq 'Failed' -or $beforeDeployment -eq 'error'))
if ($Mode -eq 'Validate' -and $beforeDeployment -eq 'success') { Exit-Failed "The instance $clusterName is already deployed. Nothing to validate." }
if ($Mode -eq 'Validate' -and $beforeDeployment -eq 'running') { Exit-Failed "A deployment of the instance $clusterName is running. Wait for it, or run -Mode Deploy to attach to it." }
if ($Mode -eq 'Validate' -and $beforeFailed -and -not $AllowRevalidate) {
    Exit-Failed "The instance $clusterName is in a failed deployment state (provisioning $($before.ProvisioningState), deployment $($before.DeploymentStatus)). Microsoft: don't run Validate again after a failed deployment; it resets the system properties and can break license sync. Fix the cause and redeploy with -Mode Deploy, or get support's guidance (-AllowRevalidate)."
}
if ($Mode -eq 'Deploy') {
    # As the PowerShell run: a deployment that already started (running, failed or done) needs no new validation.
    $resuming = $beforeDeployment -in 'error', 'running', 'success'
    if ($beforeValidation -ne 'success' -and -not $resuming) {
        Exit-Failed "No successful validation to deploy from (validation status '$(if ($before) { $before.ValidationStatus } else { 'no cluster resource' })'). Run -Mode Validate first and let it succeed."
    }
    if ($beforeDeployment -eq 'success') { Write-Line "The instance $clusterName is already deployed; nothing to do."; exit 0 }
    if ($beforeFailed -and -not $Resume) { Exit-Failed "The last deployment of the instance $clusterName failed. Read the failing step, fix the cause, then run -Mode Deploy -Resume." }
}

# ---- 4. the pre-flight: Azure checks the template and the parameters, creates nothing
$preflight = Invoke-AzCli (@('deployment', 'group', 'validate') + $scopeArguments + @('--name', $deploymentName) + $templateArguments + @('--parameters', "@$parameterFile", '--output', 'json', '--only-show-errors'))
if ($preflight.ExitCode -ne 0) { Exit-Failed "The pre-flight validation (az deployment group validate) failed: $($preflight.Detail)" }
Write-Line 'Pre-flight validation passed.'

# ---- 5. submit and wait
$existing = Invoke-AzCli (@('deployment', 'group', 'show') + $scopeArguments + @('--name', $deploymentName, '--query', 'properties.provisioningState', '--output', 'tsv', '--only-show-errors'))
if ($existing.ExitCode -ne 0 -and $existing.Detail -notmatch $NotFound) { Exit-Failed "The deployment $deploymentName could not be read: $($existing.Detail)" }
$existingState = if ($existing.ExitCode -eq 0) { $existing.Output.Trim() } else { '' }
$submit = $true
$existingKind = ConvertTo-AzlArmStepStatus $existingState
if ($existingKind -eq 'success') {
    Write-Line "Deployment $deploymentName already Succeeded with these parameters. Nothing to submit."
    $submit = $false
}
elseif ($existingState -and $existingKind -ne 'error') {
    Write-Line "Deployment $deploymentName is $existingState. Attaching to it."
    $submit = $false
}
elseif ($existingKind -eq 'error' -and $Mode -eq 'Deploy' -and -not $Resume) {
    Exit-Failed "Deployment $deploymentName is $existingState. A failed Deploy is resubmitted only with -Resume: read the failure first (az deployment group show, and the deployment steps of the instance)."
}

if ($submit) {
    if (-not $PSCmdlet.ShouldProcess("cluster '$clusterName' in resource group '$group'", "Submit the ARM $Mode deployment $deploymentName")) {
        Write-Line "WhatIf: nothing was submitted. $Mode would be submitted as $deploymentName."
        exit 0
    }
    $create = Invoke-AzCli (@('deployment', 'group', 'create') + $scopeArguments + @('--name', $deploymentName) + $templateArguments + @('--parameters', "@$parameterFile", '--no-wait', '--output', 'none', '--only-show-errors'))
    if ($create.ExitCode -ne 0) { Exit-Failed "The submission failed: $($create.Detail)" }
    Write-Line "Submitted deployment $deploymentName."
}
elseif ($WhatIfPreference) { Write-Line "WhatIf: nothing was submitted."; exit 0 }
if ($NoWait) { Write-Line 'Not waiting (-NoWait). Run the script again to attach.'; exit 0 }

$limit = if ($TimeoutMinutes) { $TimeoutMinutes } elseif ($Mode -eq 'Validate') { $settings.validateTimeoutMinutes } else { $settings.deployTimeoutMinutes }
$deadline = (Get-Date).AddMinutes($limit)
$delay = [double]$settings.pollSeconds
$state = ''
$errorText = ''
$outcome = ''      # '' while the work goes on, then Succeeded or Failed
$after = $null
do {
    Start-Sleep -Seconds $delay
    $delay = [math]::Min([double]$settings.pollMaxSeconds, $delay * $settings.pollFactor)
    $show = Invoke-AzCli (@('deployment', 'group', 'show') + $scopeArguments + @('--name', $deploymentName, '--output', 'json', '--only-show-errors'))
    if ($show.ExitCode -ne 0) { Write-Verbose "Could not read the deployment: $($show.Detail)"; continue }
    $info = ConvertFrom-AzJson $show.Output
    $state = [string](Get-Prop $info @('properties', 'provisioningState'))
    $errorText = [string](Get-Prop $info @('properties', 'error', 'message'))
    $kind = ConvertTo-AzlArmStepStatus $state
    if ($kind -eq 'error') { $outcome = 'Failed' }
    elseif ($kind -eq 'success') {
        # The ARM deployment can be done while the instance still validates or deploys: the status of deploymentSettings says when the work is done. A status that
        # cannot be read, is empty or is not a known word counts as still running, never as success.
        $after = $null
        try { $after = Get-InstanceState } catch { Write-Verbose "Could not read the instance: $($_.Exception.Message)" }
        $workKind = if ($after) { ConvertTo-AzlArmStepStatus $(if ($Mode -eq 'Validate') { $after.ValidationStatus } else { $after.DeploymentStatus }) } else { 'unreadable' }
        if ($workKind -eq 'success') { $outcome = 'Succeeded' }
        elseif ($workKind -eq 'error') { $outcome = 'Failed' }
        else { $state = 'Running' }
    }
    Write-Line "Deployment $deploymentName is $state."
} while (-not $outcome -and (Get-Date) -lt $deadline)

if (-not $outcome) { Exit-Failed "Deployment $deploymentName is still $state after $limit minute(s), without an explicit success. This script stops waiting; check it in the portal, or run it again to attach." }
if ($outcome -eq 'Succeeded') {
    Write-Line "ARM $Mode succeeded."
    Write-Line $(if ($Mode -eq 'Validate') { 'Next: run the script with -Mode Deploy after the approval.' } else { 'Next: run the post-deployment checks (phase 06).' })
    exit 0
}
if (-not $after) { try { $after = Get-InstanceState } catch { Write-Verbose $_.Exception.Message } }
$work = if ($after) { if ($Mode -eq 'Validate') { $after.ValidationStatus } else { $after.DeploymentStatus } } else { '' }
$reason = if ($errorText) { $errorText } elseif ((ConvertTo-AzlArmStepStatus $state) -eq 'success') { "the status of the instance is '$work'" } else { "the deployment is $state" }
Write-Error "ARM $Mode failed: $reason" -ErrorAction Continue
if ($after) { foreach ($step in $after.FailedSteps) { Write-Error "  failed step: $step" -ErrorAction Continue } }
exit 1

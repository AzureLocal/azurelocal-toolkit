#Requires -Version 7.0
<#
.SYNOPSIS
    The CI/CD infrastructure of automation / 01-cicd-infra (tasks 01 to 06) for GitHub, GitLab and Azure DevOps.

.DESCRIPTION
    Every task script in scripts/deploy/01-cicd-infra calls one function here, so the three platforms and the standalone and
    orchestrated variants share one implementation. All inputs come from the devops, azure, key_vaults and landing_zone
    sections of infrastructure.yml (schema 5.5). No secret is a parameter: platform tokens come from the environment
    (GH_TOKEN, GITLAB_TOKEN, AZURE_DEVOPS_EXT_PAT) or from devops.api_token, a keyvault:// reference.

    ConvertTo-AzlCicdSetting      infrastructure.yml (as a hashtable) to the settings every task reads
    Get-AzlCicdSetting            Read, validate and convert an infrastructure.yml file
    Invoke-AzlCicdBootstrap        Task 01: app registration, service principal, federated credentials, roles, providers
    New-AzlCicdProject             Task 02: the repository or project, from the template
    Set-AzlCicdProjectSetting     Task 03: branch protection, approvals, merge and security settings
    New-AzlCicdEnvironment         Task 04: environments with approval gates
    Set-AzlCicdVariable            Task 05: ARM_* secrets and variables per environment, and the Azure DevOps service connection
    Invoke-AzlCicdRunnerDeployment Task 06: terraform init, validate, plan and, only with -Apply, apply of the cicd-infra environment

    Every function that changes something supports -WhatIf: it reads what exists and reports what it would do. Each is
    idempotent: it creates what is missing and leaves the rest. Native tools and REST calls go through Invoke-AzlNative and
    Invoke-AzlRest, which the tests replace.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Token = $null
$script:LogPath = ''

# ---------------------------------------------------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------------------------------------------------

function Write-AzlCicdLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN' { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line }
}

function Initialize-AzlCicdLog {
    <# Sets the log file: LogPath, else logs/<TaskName>/<timestamp>.log in the repository. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskName, [string]$LogPath = '')
    if (-not $LogPath) {
        $LogPath = Join-Path (Join-Path (Join-Path $PSScriptRoot '..\..\..') 'logs') (Join-Path $TaskName ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.log'))
    }
    $parent = Split-Path -Path $LogPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $script:LogPath = $LogPath
    return $LogPath
}

function Invoke-AzlNative {
    <#
    .SYNOPSIS
        Runs a native command and returns ExitCode and Output. Arguments are never logged, so a secret in one cannot leak.
        Throws on a non-zero exit unless -AllowFailure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$InputText,
        [switch]$AllowFailure,
        [string]$WorkingDirectory
    )
    $command = Get-Command -Name $FilePath -ErrorAction SilentlyContinue
    if (-not $command) { throw "'$FilePath' was not found in PATH." }
    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        $global:LASTEXITCODE = 0
        $output = if ($PSBoundParameters.ContainsKey('InputText')) { $InputText | & $command.Source @ArgumentList 2>&1 } else { & $command.Source @ArgumentList 2>&1 }
        $code = $LASTEXITCODE
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
    $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        $shown = if ($text.Length -gt 600) { $text.Substring(0, 600) + '...' } else { $text }
        throw "$FilePath exited with code $code. $shown"
    }
    [pscustomobject]@{ ExitCode = $code; Output = $text.Trim() }
}

function Invoke-AzlRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [object]$Body,
        [switch]$AllowNotFound
    )
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw
    }
}

function Get-AzlValue {
    [CmdletBinding()]
    param([object]$Node, [Parameter(Mandatory)][string]$Path, [object]$Default = $null)
    $current = $Node
    foreach ($part in $Path.Split('.')) {
        if ($current -is [System.Collections.IDictionary] -and $current.Contains($part)) { $current = $current[$part] } else { return $Default }
    }
    if ($null -eq $current -or ($current -is [string] -and [string]::IsNullOrWhiteSpace($current))) { return $Default }
    return $current
}

function Get-AzlList {
    # Emits the items (nothing for null); callers wrap the call in @().
    param([object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) { return $Value }
    return $Value
}

function Get-AzlKeyVaultSecretValue {
    <# Reads a keyvault://<vault>/<secret> reference with the Azure CLI. The value is returned, never logged. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference)
    if ($Reference -notmatch '^keyvault://([^/]+)/(.+)$') { throw "'$Reference' is not a keyvault://<vault>/<secret> reference." }
    $result = Invoke-AzlNative -FilePath az -ArgumentList @('keyvault', 'secret', 'show', '--vault-name', $Matches[1], '--name', $Matches[2], '--query', 'value', '-o', 'tsv')
    return $result.Output
}

function Format-AzlResult {
    param([string]$Task, [string]$Action, [string]$Target, [ValidateSet('Created', 'Exists', 'Updated', 'Planned', 'Skipped', 'Done')][string]$Status, [string]$Detail = '')
    [pscustomobject]@{ Task = $Task; Action = $Action; Target = $Target; Status = $Status; Detail = $Detail }
}

# ---------------------------------------------------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------------------------------------------------

function ConvertTo-AzlCicdSetting {
    <#
    .SYNOPSIS
        Converts a loaded infrastructure.yml (a hashtable) to the settings that tasks 01 to 06 read, with defaults applied.
    .PARAMETER Infrastructure
        The file as a hashtable (Import-AzlInfrastructure, or the CONFIGURATION region of a standalone script).
    .PARAMETER Platform
        Overrides devops.platform.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [string]$Platform = '')

    $devops = Get-AzlValue $Infrastructure 'devops'
    if ($devops -isnot [System.Collections.IDictionary]) { throw 'The infrastructure file has no devops section. See config/infrastructure/infrastructure.example.yml.' }
    $platform = if ($Platform) { $Platform } else { [string](Get-AzlValue $devops 'platform') }
    if ($platform -notin @('github', 'gitlab', 'azure_devops')) { throw "devops.platform must be github, gitlab or azure_devops (got '$platform')." }

    $defaultUrl = @{ github = 'https://github.com'; gitlab = 'https://gitlab.com'; azure_devops = 'https://dev.azure.com' }[$platform]
    $url = ([string](Get-AzlValue $devops 'url' $defaultUrl)).TrimEnd('/')
    $organization = [string](Get-AzlValue $devops 'organization')
    $project = [string](Get-AzlValue $devops 'project')
    $scmUrl = switch ($platform) {
        'gitlab' { $url }
        default { if ($organization -and -not $url.EndsWith("/$organization")) { "$url/$organization" } else { $url } }
    }

    $subscriptions = @(Get-AzlList (Get-AzlValue $Infrastructure 'landing_zone.subscriptions') | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { [pscustomobject]@{ Name = [string]$_['name']; Id = [string]$_['id']; Role = [string]$_['role'] } }
        })
    $azureSubscription = [string](Get-AzlValue $Infrastructure 'azure.subscription_id')
    $devopsSubscriptionName = [string](Get-AzlValue $devops 'subscription')
    $devopsSubscription = $subscriptions | Where-Object { $_.Name -eq $devopsSubscriptionName -and $_.Id } | Select-Object -First 1
    if (-not $devopsSubscription) { $devopsSubscription = $subscriptions | Where-Object { $_.Role -eq 'devops' -and $_.Id } | Select-Object -First 1 }
    $devopsSubscriptionId = if ($devopsSubscription) { $devopsSubscription.Id } else { $azureSubscription }

    $roleSubscriptions = @(@($azureSubscription, $devopsSubscriptionId) + @($subscriptions | Where-Object { $_.Role -in @('azure_local', 'devops', 'management', 'connectivity') -and $_.Id } | ForEach-Object { $_.Id }) |
            Where-Object { $_ } | Select-Object -Unique)

    $keyVaults = @(Get-AzlList (Get-AzlValue $Infrastructure 'key_vaults') | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { [pscustomobject]@{ Name = [string]$_['name']; SubscriptionId = [string]$_['subscription_id']; ResourceGroup = [string]$_['resource_group'] } }
        })

    $environments = @(Get-AzlList (Get-AzlValue $devops 'environments') | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                [pscustomobject]@{
                    Name             = [string]$_['name']
                    ApprovalRequired = [bool](Get-AzlValue $_ 'approval_required' $false)
                    Approvers        = @(Get-AzlList (Get-AzlValue $_ 'approvers') | Where-Object { $_ })
                    WaitMinutes      = [int](Get-AzlValue $_ 'wait_minutes' 0)
                    Branch           = [string](Get-AzlValue $_ 'deployment_branch' 'main')
                }
            }
        })

    $runners = @(Get-AzlList (Get-AzlValue $devops 'runners') | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) {
                $os = [string]$_['os_type']
                [pscustomobject]@{
                    Name               = [string]$_['name']
                    OsType             = $os
                    Purpose            = [string](Get-AzlValue $_ 'purpose' 'general')
                    Count              = [int](Get-AzlValue $_ 'count' 1)
                    ComputeType        = [string](Get-AzlValue $_ 'compute_type' 'vm')
                    Size               = [string](Get-AzlValue $_ 'size' $(if ($os -eq 'windows') { 'Standard_D4s_v5' } else { 'Standard_D2s_v5' }))
                    Labels             = @(Get-AzlList (Get-AzlValue $_ 'labels') | Where-Object { $_ })
                    RegistrationSecret = [string](Get-AzlValue $_ 'registration_secret')
                    Pool               = [string](Get-AzlValue $_ 'pool')
                    PrivateIps         = @(Get-AzlList (Get-AzlValue $_ 'private_ips') | Where-Object { $_ })
                    SubnetName         = [string](Get-AzlValue $_ 'subnet.name')
                    SubnetPrefix       = [string](Get-AzlValue $_ 'subnet.prefix')
                    DataDiskGb         = [int](Get-AzlValue $_ 'data_disk_gb' 0)
                }
            }
        })

    $auth = Get-AzlValue $devops 'authentication' @{}
    [ordered]@{
        Platform             = $platform
        Url                  = $url
        Organization         = $organization
        Project              = $project
        ScmUrl               = $scmUrl
        ApiTokenReference    = [string](Get-AzlValue $devops 'api_token')
        TenantId             = [string](Get-AzlValue $Infrastructure 'azure.tenant_id')
        Location             = [string](Get-AzlValue $Infrastructure 'azure.location' 'eastus')
        AzureSubscriptionId  = $azureSubscription
        AzureResourceGroup   = [string](Get-AzlValue $Infrastructure 'azure.resource_group')
        AppName              = [string](Get-AzlValue $Infrastructure 'azure.automation_identity.name' 'azurelocal-cicd')
        AppClientId          = [string](Get-AzlValue $Infrastructure 'azure.automation_identity.client_id')
        Subscriptions        = $subscriptions
        RoleSubscriptionIds  = $roleSubscriptions
        DevopsSubscriptionId = $devopsSubscriptionId
        DevopsResourceGroup  = [string](Get-AzlValue $devops 'resource_group')
        CreateResourceGroup  = [bool](Get-AzlValue $devops 'create_resource_group' $false)
        KeyVaults            = $keyVaults
        Tags                 = (Get-AzlValue $Infrastructure 'tags' @{})
        LandingNetworks      = @(Get-AzlList (Get-AzlValue $Infrastructure 'landing_zone.networks') | Where-Object { $_ -is [System.Collections.IDictionary] })
        Repository           = [pscustomobject]@{
            Name          = [string](Get-AzlValue $devops 'repository.name' $project)
            Template      = [string](Get-AzlValue $devops 'repository.template')
            Visibility    = [string](Get-AzlValue $devops 'repository.visibility' 'private')
            DefaultBranch = [string](Get-AzlValue $devops 'repository.default_branch' 'main')
        }
        Settings             = [pscustomobject]@{
            RequiredApprovals    = [int](Get-AzlValue $devops 'settings.required_approvals' 2)
            Reviewers            = [string](Get-AzlValue $devops 'settings.reviewers')
            SquashOnly           = [bool](Get-AzlValue $devops 'settings.squash_only' $true)
            SecretScanning       = [bool](Get-AzlValue $devops 'settings.secret_scanning' $true)
            ResolveConversations = [bool](Get-AzlValue $devops 'settings.resolve_conversations' $true)
            StatusChecks         = @(Get-AzlList (Get-AzlValue $devops 'settings.required_status_checks') | Where-Object { $_ })
        }
        Environments         = $environments
        Authentication       = [pscustomobject]@{
            Method                  = [string](Get-AzlValue $auth 'method' 'oidc')
            ClientSecretReference   = [string](Get-AzlValue $auth 'client_secret')
            Roles                   = @(Get-AzlList (Get-AzlValue $auth 'roles' @('Contributor', 'User Access Administrator')) | Where-Object { $_ })
            GrantGraphRoleManagement = [bool](Get-AzlValue $auth 'grant_graph_role_management' $false)
            RegisterEncryptionAtHost = [bool](Get-AzlValue $auth 'register_encryption_at_host' $true)
        }
        Runners              = $runners
        RunnerNetwork        = (Get-AzlValue $devops 'runner_network' @{})
        RunnerAccess         = (Get-AzlValue $devops 'runner_access' @{})
        State                = (Get-AzlValue $devops 'state' @{})
    }
}

function Get-AzlCicdSetting {
    <#
    .SYNOPSIS
        Reads infrastructure.yml, validates it (Test-AzlInfrastructure) and returns the CI/CD settings.
    #>
    [CmdletBinding()]
    param([string]$InfrastructureFile = '', [string]$Platform = '')
    $modulePath = Join-Path $PSScriptRoot '..\infrastructure\AzlInfrastructure.psm1'
    Import-Module $modulePath -Force
    if (-not $InfrastructureFile) {
        $InfrastructureFile = @($env:AZL_INFRASTRUCTURE_FILE, '.\infrastructure.yml', '.\config\infrastructure.yml') |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $InfrastructureFile) { throw 'No infrastructure file given. Pass -InfrastructureFile, or set AZL_INFRASTRUCTURE_FILE.' }
    }
    $infra = Import-AzlInfrastructure -Path $InfrastructureFile
    return ConvertTo-AzlCicdSetting -Infrastructure $infra -Platform $Platform
}

function Resolve-AzlCicdInput {
    <#
    .SYNOPSIS
        The settings for a task script: from infrastructure.yml when a file is given or found, else from the script's
        CONFIGURATION region (same keys as the file).
    #>
    [CmdletBinding()]
    param([string]$InfrastructureFile = '', [string]$Platform = '', [System.Collections.IDictionary]$Configuration)
    $file = $InfrastructureFile
    if (-not $file) {
        $file = @($env:AZL_INFRASTRUCTURE_FILE, '.\infrastructure.yml', '.\config\infrastructure.yml') |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    }
    if ($file) {
        Write-AzlCicdLog "Reading $file"
        return Get-AzlCicdSetting -InfrastructureFile $file -Platform $Platform
    }
    if ($Configuration -and (Get-AzlValue $Configuration 'devops.platform')) {
        Write-AzlCicdLog 'No infrastructure file found; using the CONFIGURATION region of the script.'
        return ConvertTo-AzlCicdSetting -Infrastructure $Configuration -Platform $Platform
    }
    throw 'No infrastructure file. Pass -InfrastructureFile, set AZL_INFRASTRUCTURE_FILE, or fill in the CONFIGURATION region of the script.'
}

function Resolve-AzlCicdToken {
    <# The platform token: the environment first, then devops.api_token. Null means the CLI's own sign-in is used. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $names = @{ github = @('GH_TOKEN', 'GITHUB_TOKEN'); gitlab = @('GITLAB_TOKEN', 'GITLAB_PRIVATE_TOKEN'); azure_devops = @('AZURE_DEVOPS_EXT_PAT') }[$Settings.Platform]
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    if ($Settings.ApiTokenReference) {
        $value = Get-AzlKeyVaultSecretValue -Reference $Settings.ApiTokenReference
        if (-not $value) { throw "The Key Vault secret $($Settings.ApiTokenReference) is empty." }
        return $value
    }
    if ($Settings.Platform -eq 'gitlab') { throw 'GitLab needs a token: set GITLAB_TOKEN, or devops.api_token to a keyvault:// reference.' }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# Platform calls
# ---------------------------------------------------------------------------------------------------------------------

function Invoke-AzlGitHub {
    # gh reads GH_TOKEN from the environment, which Use-AzlCicdSession sets for the duration of a task.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList, [string]$InputText, [switch]$AllowFailure)
    $params = @{ FilePath = 'gh'; ArgumentList = $ArgumentList; AllowFailure = $AllowFailure }
    if ($PSBoundParameters.ContainsKey('InputText')) { $params.InputText = $InputText }
    return Invoke-AzlNative @params
}

function Invoke-AzlGitLab {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [object]$Body, [switch]$AllowNotFound)
    $params = @{ Method = $Method; Uri = "$($Settings.Url)/api/v4/$Path"; Headers = @{ 'PRIVATE-TOKEN' = $script:Token }; AllowNotFound = $AllowNotFound }
    if ($null -ne $Body) { $params.Body = $Body }
    return Invoke-AzlRest @params
}

function Get-AzlAdoHeader {
    if ($script:Token) {
        $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:Token)"))
        return @{ Authorization = "Basic $pair" }
    }
    # 499b84ac-... is the Azure DevOps resource; the signed-in az account is enough.
    $access = Invoke-AzlNative -FilePath az -ArgumentList @('account', 'get-access-token', '--resource', '499b84ac-1321-427f-aa17-267ca6975798', '--query', 'accessToken', '-o', 'tsv')
    return @{ Authorization = "Bearer $($access.Output)" }
}

function Invoke-AzlAdo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Uri, [object]$Body, [switch]$AllowNotFound)
    $params = @{ Method = $Method; Uri = $Uri; Headers = (Get-AzlAdoHeader); AllowNotFound = $AllowNotFound }
    if ($null -ne $Body) { $params.Body = $Body }
    return Invoke-AzlRest @params
}

function Use-AzlCicdSession {
    <# Resolves the platform token and, for the CLIs, exports it to this process only. Call Close-AzlCicdSession in a finally. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $script:Token = Resolve-AzlCicdToken -Settings $Settings
    $script:SavedEnv = @{ GH_TOKEN = $env:GH_TOKEN; AZURE_DEVOPS_EXT_PAT = $env:AZURE_DEVOPS_EXT_PAT }
    if ($script:Token) {
        if ($Settings.Platform -eq 'github') { $env:GH_TOKEN = $script:Token }
        if ($Settings.Platform -eq 'azure_devops') { $env:AZURE_DEVOPS_EXT_PAT = $script:Token }
    }
}

function Close-AzlCicdSession {
    [CmdletBinding()]
    param()
    if ($script:SavedEnv) {
        $env:GH_TOKEN = $script:SavedEnv.GH_TOKEN
        $env:AZURE_DEVOPS_EXT_PAT = $script:SavedEnv.AZURE_DEVOPS_EXT_PAT
    }
    $script:Token = $null
}

# ---------------------------------------------------------------------------------------------------------------------
# Task 01: bootstrap
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlAdoOrganizationId {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $data = Invoke-AzlAdo -Method GET -Uri "$($Settings.ScmUrl)/_apis/connectionData?api-version=7.1-preview"
    return [string]$data.instanceId
}

function Get-AzlFederatedCredentialPlan {
    <# The federated credentials the platform needs: name, issuer, subject. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $repo = $Settings.Repository.Name
    $branch = $Settings.Repository.DefaultBranch
    switch ($Settings.Platform) {
        'github' {
            $issuer = 'https://token.actions.githubusercontent.com'
            $prefix = "repo:$($Settings.Organization)/$repo"
            @([pscustomobject]@{ Name = "github-branch-$branch"; Issuer = $issuer; Subject = "${prefix}:ref:refs/heads/$branch" },
                [pscustomobject]@{ Name = 'github-pull-request'; Issuer = $issuer; Subject = "${prefix}:pull_request" }) +
            @($Settings.Environments | ForEach-Object { [pscustomobject]@{ Name = "github-env-$($_.Name)"; Issuer = $issuer; Subject = "${prefix}:environment:$($_.Name)" } })
        }
        'gitlab' {
            @([pscustomobject]@{ Name = "gitlab-branch-$branch"; Issuer = $Settings.Url; Subject = "project_path:$($Settings.Organization)/${repo}:ref_type:branch:ref:$branch" })
        }
        'azure_devops' {
            $orgId = Get-AzlAdoOrganizationId -Settings $Settings
            $orgName = ($Settings.ScmUrl -split '/')[-1]
            @([pscustomobject]@{ Name = 'azuredevops-service-connection'; Issuer = "https://vstoken.dev.azure.com/$orgId"; Subject = "sc://$orgName/$($Settings.Project)/AzureLocal-ServiceConnection" })
        }
    }
}

function Invoke-AzlCicdBootstrap {
    <#
    .SYNOPSIS
        Task 01. Creates the app registration and service principal, its federated credentials (OIDC) or a client secret
        (stored only in Key Vault), the role assignments, and the provider and feature registrations.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $task = '01-bootstrap'
    $results = [System.Collections.Generic.List[object]]::new()
    Use-AzlCicdSession -Settings $Settings
    try {
        $appName = $Settings.AppName

        # App registration
        $found = Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'list', '--display-name', $appName, '--query', '[].appId', '-o', 'json')
        $appIds = @($found.Output | ConvertFrom-Json)
        if ($appIds.Count -gt 1) { throw "More than one app registration is named '$appName'. Remove the extra ones, or set azure.automation_identity.client_id." }
        $appId = if ($Settings.AppClientId) { $Settings.AppClientId } elseif ($appIds.Count -eq 1) { [string]$appIds[0] } else { '' }
        if ($appId) {
            $results.Add((Format-AzlResult $task 'App registration' $appName 'Exists' $appId))
        }
        elseif ($PSCmdlet.ShouldProcess($appName, 'Create the app registration')) {
            $appId = (Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'create', '--display-name', $appName, '--query', 'appId', '-o', 'tsv')).Output
            $results.Add((Format-AzlResult $task 'App registration' $appName 'Created' $appId))
        }
        else {
            $results.Add((Format-AzlResult $task 'App registration' $appName 'Planned'))
        }

        # Service principal
        $spObjectId = ''
        if ($appId) {
            $sp = Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFailure
            if ($sp.ExitCode -eq 0 -and $sp.Output) {
                $spObjectId = $sp.Output
                $results.Add((Format-AzlResult $task 'Service principal' $appName 'Exists' $spObjectId))
            }
            elseif ($PSCmdlet.ShouldProcess($appName, 'Create the service principal')) {
                $spObjectId = (Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'sp', 'create', '--id', $appId, '--query', 'id', '-o', 'tsv')).Output
                $results.Add((Format-AzlResult $task 'Service principal' $appName 'Created' $spObjectId))
            }
            else {
                $results.Add((Format-AzlResult $task 'Service principal' $appName 'Planned'))
            }
        }

        # Sign-in: federated credentials, or a client secret that goes to Key Vault only
        if ($Settings.Authentication.Method -eq 'oidc') {
            $existing = @()
            if ($appId) {
                $list = Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'federated-credential', 'list', '--id', $appId, '--query', '[].name', '-o', 'json')
                $existing = @($list.Output | ConvertFrom-Json)
            }
            foreach ($credential in @(Get-AzlFederatedCredentialPlan -Settings $Settings)) {
                if ($credential.Name -in $existing) {
                    $results.Add((Format-AzlResult $task 'Federated credential' $credential.Name 'Exists' $credential.Subject))
                }
                elseif ($appId -and $PSCmdlet.ShouldProcess($credential.Name, "Create the federated credential for $($credential.Subject)")) {
                    $file = Join-Path ([IO.Path]::GetTempPath()) ("azl-fic-{0}.json" -f [guid]::NewGuid())
                    try {
                        [ordered]@{ name = $credential.Name; issuer = $credential.Issuer; subject = $credential.Subject; audiences = @('api://AzureADTokenExchange') } |
                            ConvertTo-Json | Set-Content -LiteralPath $file -Encoding utf8
                        Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'federated-credential', 'create', '--id', $appId, '--parameters', $file) | Out-Null
                    }
                    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
                    $results.Add((Format-AzlResult $task 'Federated credential' $credential.Name 'Created' $credential.Subject))
                }
                else {
                    $results.Add((Format-AzlResult $task 'Federated credential' $credential.Name 'Planned' $credential.Subject))
                }
            }
        }
        else {
            $reference = $Settings.Authentication.ClientSecretReference
            if (-not $reference) { throw 'devops.authentication.method is client_secret, so devops.authentication.client_secret must be a keyvault:// reference.' }
            $vault, $secretName = ($reference -replace '^keyvault://', '').Split('/', 2)
            $present = Invoke-AzlNative -FilePath az -ArgumentList @('keyvault', 'secret', 'show', '--vault-name', $vault, '--name', $secretName, '--query', 'id', '-o', 'tsv') -AllowFailure
            if ($present.ExitCode -eq 0) {
                $results.Add((Format-AzlResult $task 'Client secret' $reference 'Exists' 'Not rotated. Delete the Key Vault secret to issue a new one.'))
            }
            elseif ($appId -and $PSCmdlet.ShouldProcess($reference, 'Create a client secret and store it in Key Vault')) {
                $file = Join-Path ([IO.Path]::GetTempPath()) ("azl-sec-{0}.txt" -f [guid]::NewGuid())
                try {
                    $value = (Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'credential', 'reset', '--id', $appId, '--append', '--years', '2', '--query', 'password', '-o', 'tsv')).Output
                    Set-Content -LiteralPath $file -Value $value -NoNewline -Encoding utf8
                    $value = $null
                    Invoke-AzlNative -FilePath az -ArgumentList @('keyvault', 'secret', 'set', '--vault-name', $vault, '--name', $secretName, '--file', $file, '--encoding', 'utf-8', '--output', 'none') | Out-Null
                }
                finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
                $results.Add((Format-AzlResult $task 'Client secret' $reference 'Created' 'Stored in Key Vault. Never printed.'))
            }
            else {
                $results.Add((Format-AzlResult $task 'Client secret' $reference 'Planned'))
            }
        }

        # Roles and registrations on each subscription
        foreach ($subscriptionId in $Settings.RoleSubscriptionIds) {
            $scope = "/subscriptions/$subscriptionId"
            $assigned = @()
            if ($spObjectId) {
                $list = Invoke-AzlNative -FilePath az -ArgumentList @('role', 'assignment', 'list', '--assignee', $spObjectId, '--scope', $scope, '--query', '[].roleDefinitionName', '-o', 'json')
                $assigned = @($list.Output | ConvertFrom-Json)
            }
            foreach ($role in $Settings.Authentication.Roles) {
                if ($role -in $assigned) {
                    $results.Add((Format-AzlResult $task 'Role assignment' "$role on $scope" 'Exists'))
                }
                elseif ($spObjectId -and $PSCmdlet.ShouldProcess("$role on $scope", 'Assign the role to the service principal')) {
                    Invoke-AzlNative -FilePath az -ArgumentList @('role', 'assignment', 'create', '--assignee-object-id', $spObjectId, '--assignee-principal-type', 'ServicePrincipal', '--role', $role, '--scope', $scope, '--output', 'none') | Out-Null
                    $results.Add((Format-AzlResult $task 'Role assignment' "$role on $scope" 'Created'))
                }
                else {
                    $results.Add((Format-AzlResult $task 'Role assignment' "$role on $scope" 'Planned'))
                }
            }
            if ($Settings.Authentication.RegisterEncryptionAtHost) {
                $state = Invoke-AzlNative -FilePath az -ArgumentList @('feature', 'show', '--namespace', 'Microsoft.Compute', '--name', 'EncryptionAtHost', '--subscription', $subscriptionId, '--query', 'properties.state', '-o', 'tsv') -AllowFailure
                if ($state.Output -eq 'Registered') {
                    $results.Add((Format-AzlResult $task 'Feature' "Microsoft.Compute/EncryptionAtHost in $subscriptionId" 'Exists'))
                }
                elseif ($PSCmdlet.ShouldProcess("Microsoft.Compute and EncryptionAtHost in $subscriptionId", 'Register the provider and the feature')) {
                    Invoke-AzlNative -FilePath az -ArgumentList @('provider', 'register', '--namespace', 'Microsoft.Compute', '--subscription', $subscriptionId) | Out-Null
                    Invoke-AzlNative -FilePath az -ArgumentList @('feature', 'register', '--namespace', 'Microsoft.Compute', '--name', 'EncryptionAtHost', '--subscription', $subscriptionId, '--output', 'none') | Out-Null
                    $results.Add((Format-AzlResult $task 'Feature' "Microsoft.Compute/EncryptionAtHost in $subscriptionId" 'Created' 'Registering. It can take a few minutes.'))
                }
                else {
                    $results.Add((Format-AzlResult $task 'Feature' "Microsoft.Compute/EncryptionAtHost in $subscriptionId" 'Planned'))
                }
            }
        }

        # Optional, high privilege
        if ($Settings.Authentication.GrantGraphRoleManagement) {
            if ($appId -and $PSCmdlet.ShouldProcess($appName, 'Add RoleManagement.ReadWrite.Directory and grant admin consent')) {
                Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'permission', 'add', '--id', $appId, '--api', '00000003-0000-0000-c000-000000000000', '--api-permissions', '9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8=Role') | Out-Null
                Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'permission', 'admin-consent', '--id', $appId) | Out-Null
                $results.Add((Format-AzlResult $task 'Graph permission' 'RoleManagement.ReadWrite.Directory' 'Done'))
            }
            else {
                $results.Add((Format-AzlResult $task 'Graph permission' 'RoleManagement.ReadWrite.Directory' 'Planned'))
            }
        }
        if ($appId) { Write-AzlCicdLog "Set azure.automation_identity.client_id to $appId in infrastructure.yml (task 05 reads it). It is an identifier, not a secret." }
    }
    finally { Close-AzlCicdSession }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# Task 02: the project
# ---------------------------------------------------------------------------------------------------------------------

function New-AzlCicdProject {
    <# Task 02. Creates the repository or project from the template, private. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $task = '02-create-project'
    $results = [System.Collections.Generic.List[object]]::new()
    $repo = $Settings.Repository
    Use-AzlCicdSession -Settings $Settings
    try {
        switch ($Settings.Platform) {
            'github' {
                $slug = "$($Settings.Organization)/$($repo.Name)"
                $view = Invoke-AzlGitHub -ArgumentList @('repo', 'view', $slug, '--json', 'name') -AllowFailure
                if ($view.ExitCode -eq 0) {
                    $results.Add((Format-AzlResult $task 'Repository' $slug 'Exists'))
                }
                elseif ($PSCmdlet.ShouldProcess($slug, "Create the $($repo.Visibility) repository$(if ($repo.Template) { " from template $($repo.Template)" })")) {
                    $arguments = @('repo', 'create', $slug, "--$($repo.Visibility)")
                    if ($repo.Template) { $arguments += @('--template', $repo.Template) } else { $arguments += @('--add-readme') }
                    Invoke-AzlGitHub -ArgumentList $arguments | Out-Null
                    $results.Add((Format-AzlResult $task 'Repository' $slug 'Created'))
                }
                else { $results.Add((Format-AzlResult $task 'Repository' $slug 'Planned')) }
            }
            'gitlab' {
                $path = "$($Settings.Organization)/$($repo.Name)"
                $encoded = [uri]::EscapeDataString($path)
                $project = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$encoded" -AllowNotFound
                if ($project) {
                    $results.Add((Format-AzlResult $task 'Project' $path 'Exists' "id $($project.id)"))
                }
                elseif ($PSCmdlet.ShouldProcess($path, "Create the $($repo.Visibility) project$(if ($repo.Template) { " from template $($repo.Template)" })")) {
                    $namespaces = @(Invoke-AzlGitLab -Settings $Settings -Method GET -Path "namespaces?search=$([uri]::EscapeDataString($Settings.Organization))")
                    $namespace = $namespaces | Where-Object { $_.full_path -eq $Settings.Organization } | Select-Object -First 1
                    if (-not $namespace) { throw "The GitLab group or namespace '$($Settings.Organization)' was not found (devops.organization)." }
                    $body = [ordered]@{ name = $repo.Name; path = $repo.Name; namespace_id = $namespace.id; visibility = $repo.Visibility; default_branch = $repo.DefaultBranch }
                    if ($repo.Template) {
                        $template = if ($repo.Template -match '^\d+$') { [int]$repo.Template } else { (Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$([uri]::EscapeDataString($repo.Template))").id }
                        $body.template_project_id = $template
                        $body.use_custom_template = $true
                    }
                    else { $body.initialize_with_readme = $true }
                    $created = Invoke-AzlGitLab -Settings $Settings -Method POST -Path 'projects' -Body $body
                    $results.Add((Format-AzlResult $task 'Project' $path 'Created' "id $($created.id)"))
                }
                else { $results.Add((Format-AzlResult $task 'Project' $path 'Planned')) }
            }
            'azure_devops' {
                $org = $Settings.ScmUrl
                $project = Invoke-AzlAdo -Method GET -Uri "$org/_apis/projects/$([uri]::EscapeDataString($Settings.Project))?api-version=7.1" -AllowNotFound
                if ($project) {
                    $results.Add((Format-AzlResult $task 'Project' $Settings.Project 'Exists'))
                }
                elseif ($PSCmdlet.ShouldProcess($Settings.Project, 'Create the private Azure DevOps project')) {
                    $process = (Invoke-AzlAdo -Method GET -Uri "$org/_apis/process/processes?api-version=7.1").value | Where-Object { $_.name -eq 'Agile' } | Select-Object -First 1
                    $body = @{ name = $Settings.Project; visibility = 'private'; capabilities = @{ versioncontrol = @{ sourceControlType = 'Git' }; processTemplate = @{ templateTypeId = $process.id } } }
                    Invoke-AzlAdo -Method POST -Uri "$org/_apis/projects?api-version=7.1" -Body $body | Out-Null
                    $results.Add((Format-AzlResult $task 'Project' $Settings.Project 'Created' 'Project creation completes in the background.'))
                }
                else { $results.Add((Format-AzlResult $task 'Project' $Settings.Project 'Planned')) }

                if ($repo.Template) {
                    $repos = Invoke-AzlAdo -Method GET -Uri "$org/$([uri]::EscapeDataString($Settings.Project))/_apis/git/repositories?api-version=7.1" -AllowNotFound
                    $target = if ($repos) { @($repos.value) | Where-Object { $_.name -eq $repo.Name } | Select-Object -First 1 } else { $null }
                    $hasContent = $target -and $target.PSObject.Properties['size'] -and [int64]$target.size -gt 0
                    if ($hasContent) {
                        $results.Add((Format-AzlResult $task 'Template import' $repo.Name 'Exists' 'The repository already has content.'))
                    }
                    elseif ($target -and $PSCmdlet.ShouldProcess($repo.Name, "Import $($repo.Template)")) {
                        $body = @{ parameters = @{ gitSource = @{ url = $repo.Template } } }
                        Invoke-AzlAdo -Method POST -Uri "$org/$([uri]::EscapeDataString($Settings.Project))/_apis/git/repositories/$($target.id)/importRequests?api-version=7.1" -Body $body | Out-Null
                        $results.Add((Format-AzlResult $task 'Template import' $repo.Name 'Created' 'Import runs in the background.'))
                    }
                    else { $results.Add((Format-AzlResult $task 'Template import' $repo.Name 'Planned')) }
                }
            }
        }
    }
    finally { Close-AzlCicdSession }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# Task 03: project settings
# ---------------------------------------------------------------------------------------------------------------------

function Set-AzlCicdProjectSetting {
    <# Task 03. Branch protection, approvals, merge rules and security settings. Safe to run again: it applies the same state. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $task = '03-configure-project'
    $results = [System.Collections.Generic.List[object]]::new()
    $s = $Settings.Settings
    $branch = $Settings.Repository.DefaultBranch
    Use-AzlCicdSession -Settings $Settings
    try {
        switch ($Settings.Platform) {
            'github' {
                $slug = "$($Settings.Organization)/$($Settings.Repository.Name)"
                $protection = [ordered]@{
                    required_status_checks          = $(if ($s.StatusChecks.Count -gt 0) { [ordered]@{ strict = $true; contexts = @($s.StatusChecks) } } else { $null })
                    enforce_admins                  = $true
                    required_pull_request_reviews   = [ordered]@{ dismiss_stale_reviews = $true; require_code_owner_reviews = $false; required_approving_review_count = $s.RequiredApprovals }
                    restrictions                    = $null
                    required_conversation_resolution = $s.ResolveConversations
                    allow_force_pushes              = $false
                    allow_deletions                 = $false
                }
                if ($PSCmdlet.ShouldProcess("$slug/$branch", 'Set branch protection')) {
                    Invoke-AzlGitHub -ArgumentList @('api', '-X', 'PUT', "repos/$slug/branches/$branch/protection", '--input', '-') -InputText ($protection | ConvertTo-Json -Depth 8) | Out-Null
                    $results.Add((Format-AzlResult $task 'Branch protection' "$slug/$branch" 'Updated' "approvals $($s.RequiredApprovals)"))
                }
                else { $results.Add((Format-AzlResult $task 'Branch protection' "$slug/$branch" 'Planned' "approvals $($s.RequiredApprovals)")) }

                $repoSettings = [ordered]@{
                    allow_squash_merge     = $true
                    allow_merge_commit     = -not $s.SquashOnly
                    allow_rebase_merge     = -not $s.SquashOnly
                    delete_branch_on_merge = $true
                }
                if ($s.SecretScanning) {
                    $repoSettings.security_and_analysis = [ordered]@{ secret_scanning = @{ status = 'enabled' }; secret_scanning_push_protection = @{ status = 'enabled' } }
                }
                if ($PSCmdlet.ShouldProcess($slug, 'Set merge options and secret scanning')) {
                    Invoke-AzlGitHub -ArgumentList @('api', '-X', 'PATCH', "repos/$slug", '--input', '-') -InputText ($repoSettings | ConvertTo-Json -Depth 8) | Out-Null
                    $results.Add((Format-AzlResult $task 'Repository settings' $slug 'Updated' "squash only: $($s.SquashOnly); secret scanning: $($s.SecretScanning)"))
                }
                else { $results.Add((Format-AzlResult $task 'Repository settings' $slug 'Planned')) }
                if ($s.Reviewers) {
                    $results.Add((Format-AzlResult $task 'Reviewers' $s.Reviewers 'Skipped' 'Add a CODEOWNERS file naming the team (* @team); GitHub assigns reviewers from it.'))
                }
            }
            'gitlab' {
                $encoded = [uri]::EscapeDataString("$($Settings.Organization)/$($Settings.Repository.Name)")
                $project = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$encoded"
                $id = $project.id
                $update = [ordered]@{
                    merge_method                                     = 'rebase_merge'
                    squash_option                                    = $(if ($s.SquashOnly) { 'always' } else { 'default_off' })
                    only_allow_merge_if_pipeline_succeeds            = $true
                    only_allow_merge_if_all_discussions_are_resolved = $s.ResolveConversations
                    remove_source_branch_after_merge                 = $true
                }
                if ($PSCmdlet.ShouldProcess("project $id", 'Set merge options')) {
                    Invoke-AzlGitLab -Settings $Settings -Method PUT -Path "projects/$id" -Body $update | Out-Null
                    $results.Add((Format-AzlResult $task 'Merge options' "project $id" 'Updated'))
                }
                else { $results.Add((Format-AzlResult $task 'Merge options' "project $id" 'Planned')) }

                $protectedBody = [ordered]@{ name = $branch; push_access_level = 0; merge_access_level = 30; allow_force_push = $false }
                $current = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$id/protected_branches/$([uri]::EscapeDataString($branch))" -AllowNotFound
                if ($PSCmdlet.ShouldProcess("$branch of project $id", 'Protect the branch: no direct push, merge by developers and maintainers')) {
                    if ($current) { Invoke-AzlGitLab -Settings $Settings -Method DELETE -Path "projects/$id/protected_branches/$([uri]::EscapeDataString($branch))" | Out-Null }
                    Invoke-AzlGitLab -Settings $Settings -Method POST -Path "projects/$id/protected_branches" -Body $protectedBody | Out-Null
                    $results.Add((Format-AzlResult $task 'Protected branch' $branch $(if ($current) { 'Updated' } else { 'Created' })))
                }
                else { $results.Add((Format-AzlResult $task 'Protected branch' $branch 'Planned')) }

                $rules = @(Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$id/approval_rules")
                $rule = $rules | Where-Object { $_.name -eq 'CI/CD' } | Select-Object -First 1
                $ruleBody = [ordered]@{ name = 'CI/CD'; approvals_required = $s.RequiredApprovals }
                if ($s.Reviewers) {
                    $group = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "groups/$([uri]::EscapeDataString($s.Reviewers))" -AllowNotFound
                    if ($group) { $ruleBody.group_ids = @($group.id) } else { Write-AzlCicdLog "The GitLab group '$($s.Reviewers)' was not found; the approval rule has no approver group." -Level WARN }
                }
                if ($PSCmdlet.ShouldProcess("project $id", "Set the approval rule CI/CD to $($s.RequiredApprovals)")) {
                    if ($rule) { Invoke-AzlGitLab -Settings $Settings -Method PUT -Path "projects/$id/approval_rules/$($rule.id)" -Body $ruleBody | Out-Null }
                    else { Invoke-AzlGitLab -Settings $Settings -Method POST -Path "projects/$id/approval_rules" -Body $ruleBody | Out-Null }
                    $results.Add((Format-AzlResult $task 'Approval rule' 'CI/CD' $(if ($rule) { 'Updated' } else { 'Created' }) "approvals $($s.RequiredApprovals)"))
                }
                else { $results.Add((Format-AzlResult $task 'Approval rule' 'CI/CD' 'Planned')) }

                if ($s.SecretScanning) {
                    $pushRule = [ordered]@{ prevent_secrets = $true; deny_delete_tag = $true; member_check = $true; commit_committer_check = $true; reject_unsigned_commits = $true; max_file_size = 1 }
                    if ($PSCmdlet.ShouldProcess("project $id", 'Set push rules')) {
                        $existingRule = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$id/push_rule" -AllowNotFound
                        try {
                            Invoke-AzlGitLab -Settings $Settings -Method $(if ($existingRule) { 'PUT' } else { 'POST' }) -Path "projects/$id/push_rule" -Body $pushRule | Out-Null
                            $results.Add((Format-AzlResult $task 'Push rules' "project $id" $(if ($existingRule) { 'Updated' } else { 'Created' })))
                        }
                        catch {
                            Write-AzlCicdLog 'GitLab refused the push rules (they need GitLab Premium). Continuing.' -Level WARN
                            $results.Add((Format-AzlResult $task 'Push rules' "project $id" 'Skipped' 'Needs GitLab Premium.'))
                        }
                    }
                    else { $results.Add((Format-AzlResult $task 'Push rules' "project $id" 'Planned')) }
                }
            }
            'azure_devops' {
                $org = $Settings.ScmUrl
                $projectPath = [uri]::EscapeDataString($Settings.Project)
                $repoInfo = Invoke-AzlAdo -Method GET -Uri "$org/$projectPath/_apis/git/repositories/$([uri]::EscapeDataString($Settings.Repository.Name))?api-version=7.1"
                $scope = @(@{ repositoryId = $repoInfo.id; refName = "refs/heads/$branch"; matchKind = 'Exact' })
                $existing = @((Invoke-AzlAdo -Method GET -Uri "$org/$projectPath/_apis/policy/configurations?repositoryId=$($repoInfo.id)&refName=refs/heads/$branch&api-version=7.1").value)
                $policies = @(
                    @{ Name = 'Minimum reviewers'; Type = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'; Settings = @{ minimumApproverCount = $s.RequiredApprovals; creatorVoteCounts = $false; allowDownvotes = $false; resetOnSourcePush = $true; requireVoteOnLastIteration = $false; blockLastPusherVote = $true } }
                    @{ Name = 'Comment resolution'; Type = 'c6a1889d-b943-4856-b76f-9e46bb6b0df2'; Settings = @{}; Enabled = $s.ResolveConversations }
                    @{ Name = 'Merge strategy'; Type = 'fa4e907d-c16b-4a4c-9dfa-4916e5d171ab'; Settings = @{ allowSquash = $true; allowNoFastForward = (-not $s.SquashOnly); allowRebase = (-not $s.SquashOnly); allowRebaseMerge = (-not $s.SquashOnly) } }
                    @{ Name = 'Linked work items'; Type = '40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e'; Settings = @{} }
                )
                foreach ($policy in $policies) {
                    $enabled = if ($policy.ContainsKey('Enabled')) { [bool]$policy.Enabled } else { $true }
                    $body = [ordered]@{ isEnabled = $enabled; isBlocking = $true; type = @{ id = $policy.Type }; settings = ($policy.Settings + @{ scope = $scope }) }
                    $current = $existing | Where-Object { $_.type.id -eq $policy.Type } | Select-Object -First 1
                    if ($PSCmdlet.ShouldProcess("$($Settings.Repository.Name)/$branch", "Set the $($policy.Name) policy")) {
                        if ($current) { Invoke-AzlAdo -Method PUT -Uri "$org/$projectPath/_apis/policy/configurations/$($current.id)?api-version=7.1" -Body $body | Out-Null }
                        else { Invoke-AzlAdo -Method POST -Uri "$org/$projectPath/_apis/policy/configurations?api-version=7.1" -Body $body | Out-Null }
                        $results.Add((Format-AzlResult $task $policy.Name "$($Settings.Repository.Name)/$branch" $(if ($current) { 'Updated' } else { 'Created' })))
                    }
                    else { $results.Add((Format-AzlResult $task $policy.Name "$($Settings.Repository.Name)/$branch" 'Planned')) }
                }
                if ($s.Reviewers) {
                    $reviewerId = Resolve-AzlAdoIdentity -Settings $Settings -Name $s.Reviewers
                    $type = 'fd2167ab-b0be-447a-8ec8-39368250530e'
                    $body = [ordered]@{ isEnabled = $true; isBlocking = $true; type = @{ id = $type }; settings = @{ requiredReviewerIds = @($reviewerId); filenamePatterns = @('*'); addedFilesOnly = $false; message = 'Required reviewers for the deployment repository'; scope = $scope } }
                    $current = $existing | Where-Object { $_.type.id -eq $type } | Select-Object -First 1
                    if ($PSCmdlet.ShouldProcess($s.Reviewers, 'Set the automatic reviewers policy')) {
                        if ($current) { Invoke-AzlAdo -Method PUT -Uri "$org/$projectPath/_apis/policy/configurations/$($current.id)?api-version=7.1" -Body $body | Out-Null }
                        else { Invoke-AzlAdo -Method POST -Uri "$org/$projectPath/_apis/policy/configurations?api-version=7.1" -Body $body | Out-Null }
                        $results.Add((Format-AzlResult $task 'Automatic reviewers' $s.Reviewers $(if ($current) { 'Updated' } else { 'Created' })))
                    }
                    else { $results.Add((Format-AzlResult $task 'Automatic reviewers' $s.Reviewers 'Planned')) }
                }
                if ($s.SecretScanning) {
                    $results.Add((Format-AzlResult $task 'Secret scanning' $Settings.Project 'Skipped' 'Turn on GitHub Advanced Security for Azure DevOps in the project settings; there is no policy to set here.'))
                }
            }
        }
    }
    finally { Close-AzlCicdSession }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# Task 04: environments
# ---------------------------------------------------------------------------------------------------------------------

function Resolve-AzlAdoIdentity {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Name)
    $orgName = ($Settings.ScmUrl -split '/')[-1]
    $uri = "https://vssps.dev.azure.com/$orgName/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($Name))&queryMembership=None&api-version=7.1-preview.1"
    $found = @((Invoke-AzlAdo -Method GET -Uri $uri).value)
    if ($found.Count -eq 0) { throw "No Azure DevOps user or group matches '$Name'." }
    return [string]$found[0].id
}

function New-AzlCicdEnvironment {
    <# Task 04. Creates each environment, with its approval gate and the branch it deploys from. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $task = '04-create-environments'
    $results = [System.Collections.Generic.List[object]]::new()
    if ($Settings.Environments.Count -eq 0) { Write-AzlCicdLog 'devops.environments is empty, so no environment is created.' -Level WARN; return @() }
    Use-AzlCicdSession -Settings $Settings
    try {
        foreach ($environment in $Settings.Environments) {
            $name = $environment.Name
            switch ($Settings.Platform) {
                'github' {
                    $slug = "$($Settings.Organization)/$($Settings.Repository.Name)"
                    $body = [ordered]@{ wait_timer = $environment.WaitMinutes; deployment_branch_policy = [ordered]@{ protected_branches = $false; custom_branch_policies = $true } }
                    if ($environment.ApprovalRequired -and $environment.Approvers.Count -gt 0) {
                        $reviewers = foreach ($approver in $environment.Approvers) {
                            if ($approver -match '^([^/]+)/([^/]+)$') {
                                $team = (Invoke-AzlGitHub -ArgumentList @('api', "orgs/$($Matches[1])/teams/$($Matches[2])")).Output | ConvertFrom-Json
                                [ordered]@{ type = 'Team'; id = $team.id }
                            }
                            else {
                                $user = (Invoke-AzlGitHub -ArgumentList @('api', "users/$approver")).Output | ConvertFrom-Json
                                [ordered]@{ type = 'User'; id = $user.id }
                            }
                        }
                        $body.reviewers = @($reviewers)
                    }
                    $present = Invoke-AzlGitHub -ArgumentList @('api', "repos/$slug/environments/$name", '--silent') -AllowFailure
                    if ($PSCmdlet.ShouldProcess("$slug environment $name", 'Create or update the environment')) {
                        Invoke-AzlGitHub -ArgumentList @('api', '-X', 'PUT', "repos/$slug/environments/$name", '--input', '-') -InputText ($body | ConvertTo-Json -Depth 8) | Out-Null
                        $policies = (Invoke-AzlGitHub -ArgumentList @('api', "repos/$slug/environments/$name/deployment-branch-policies")).Output | ConvertFrom-Json
                        if (-not (@($policies.branch_policies) | Where-Object { $_.name -eq $environment.Branch })) {
                            Invoke-AzlGitHub -ArgumentList @('api', '-X', 'POST', "repos/$slug/environments/$name/deployment-branch-policies", '--input', '-') -InputText (@{ name = $environment.Branch; type = 'branch' } | ConvertTo-Json) | Out-Null
                        }
                        $results.Add((Format-AzlResult $task 'Environment' $name $(if ($present.ExitCode -eq 0) { 'Updated' } else { 'Created' }) "approval: $($environment.ApprovalRequired); branch: $($environment.Branch)"))
                    }
                    else { $results.Add((Format-AzlResult $task 'Environment' $name 'Planned')) }
                }
                'gitlab' {
                    $encoded = [uri]::EscapeDataString("$($Settings.Organization)/$($Settings.Repository.Name)")
                    $id = (Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$encoded").id
                    $found = @(Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$id/environments?name=$([uri]::EscapeDataString($name))") | Where-Object { $_.name -eq $name }
                    if ($found) { $results.Add((Format-AzlResult $task 'Environment' $name 'Exists')) }
                    elseif ($PSCmdlet.ShouldProcess("project $id environment $name", 'Create the environment')) {
                        Invoke-AzlGitLab -Settings $Settings -Method POST -Path "projects/$id/environments" -Body @{ name = $name } | Out-Null
                        $results.Add((Format-AzlResult $task 'Environment' $name 'Created'))
                    }
                    else { $results.Add((Format-AzlResult $task 'Environment' $name 'Planned')) }

                    if ($environment.ApprovalRequired) {
                        $protected = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$id/protected_environments/$([uri]::EscapeDataString($name))" -AllowNotFound
                        if ($protected) { $results.Add((Format-AzlResult $task 'Protected environment' $name 'Exists')) }
                        elseif ($PSCmdlet.ShouldProcess("environment $name", 'Protect the environment with an approval')) {
                            $rules = foreach ($approver in $environment.Approvers) {
                                $user = @(Invoke-AzlGitLab -Settings $Settings -Method GET -Path "users?username=$([uri]::EscapeDataString($approver))") | Select-Object -First 1
                                if ($user) { [ordered]@{ user_id = $user.id; required_approvals = 1 } }
                                else {
                                    $group = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "groups/$([uri]::EscapeDataString($approver))" -AllowNotFound
                                    if ($group) { [ordered]@{ group_id = $group.id; required_approvals = 1 } } else { Write-AzlCicdLog "No GitLab user or group '$approver'." -Level WARN }
                                }
                            }
                            $body = [ordered]@{ name = $name; deploy_access_levels = @(@{ access_level = 40 }) }
                            if (@($rules).Count -gt 0) { $body.approval_rules = @($rules) } else { $body.required_approval_count = 1 }
                            try {
                                Invoke-AzlGitLab -Settings $Settings -Method POST -Path "projects/$id/protected_environments" -Body $body | Out-Null
                                $results.Add((Format-AzlResult $task 'Protected environment' $name 'Created'))
                            }
                            catch {
                                Write-AzlCicdLog "GitLab refused the approval on '$name' (approvals on protected environments need GitLab Premium)." -Level WARN
                                $results.Add((Format-AzlResult $task 'Protected environment' $name 'Skipped' 'Needs GitLab Premium.'))
                            }
                        }
                        else { $results.Add((Format-AzlResult $task 'Protected environment' $name 'Planned')) }
                    }
                }
                'azure_devops' {
                    $base = "$($Settings.ScmUrl)/$([uri]::EscapeDataString($Settings.Project))/_apis"
                    $found = @((Invoke-AzlAdo -Method GET -Uri "$base/distributedtask/environments?name=$([uri]::EscapeDataString($name))&api-version=7.1").value) | Where-Object { $_.name -eq $name } | Select-Object -First 1
                    $environmentId = if ($found) { $found.id } else { $null }
                    if ($found) { $results.Add((Format-AzlResult $task 'Environment' $name 'Exists')) }
                    elseif ($PSCmdlet.ShouldProcess("environment $name", 'Create the environment')) {
                        $environmentId = (Invoke-AzlAdo -Method POST -Uri "$base/distributedtask/environments?api-version=7.1" -Body @{ name = $name }).id
                        $results.Add((Format-AzlResult $task 'Environment' $name 'Created'))
                    }
                    else { $results.Add((Format-AzlResult $task 'Environment' $name 'Planned')) }

                    if ($environmentId) {
                        $checks = @((Invoke-AzlAdo -Method GET -Uri "$base/pipelines/checks/configurations?resourceType=environment&resourceId=$environmentId&`$expand=settings&api-version=7.1-preview.1").value)
                        $resource = @{ type = 'environment'; id = [string]$environmentId; name = $name }
                        if ($environment.ApprovalRequired) {
                            if ($checks | Where-Object { $_.type.name -eq 'Approval' }) { $results.Add((Format-AzlResult $task 'Approval check' $name 'Exists')) }
                            elseif ($PSCmdlet.ShouldProcess("environment $name", 'Add the approval check')) {
                                $approverIds = foreach ($approver in $environment.Approvers) { @{ id = (Resolve-AzlAdoIdentity -Settings $Settings -Name $approver) } }
                                $body = [ordered]@{ type = @{ id = '8C6F20A7-A545-4486-9777-F762FAFE0D4D'; name = 'Approval' }; settings = @{ approvers = @($approverIds); executionOrder = 1; minRequiredApprovers = 1; requesterCannotBeApprover = $false }; resource = $resource; timeout = 4320 }
                                Invoke-AzlAdo -Method POST -Uri "$base/pipelines/checks/configurations?api-version=7.1-preview.1" -Body $body | Out-Null
                                $results.Add((Format-AzlResult $task 'Approval check' $name 'Created' '72 hour timeout'))
                            }
                            else { $results.Add((Format-AzlResult $task 'Approval check' $name 'Planned')) }
                        }
                        if ($checks | Where-Object { $_.type.name -eq 'Task Check' -and $_.settings.displayName -eq 'Branch control' }) {
                            $results.Add((Format-AzlResult $task 'Branch control' $name 'Exists'))
                        }
                        elseif ($PSCmdlet.ShouldProcess("environment $name", "Allow deployments from refs/heads/$($environment.Branch) only")) {
                            $body = [ordered]@{
                                type     = @{ id = 'fe1de3ee-a436-41b4-bb20-f6eb4cb879a7'; name = 'Task Check' }
                                settings = @{ definitionRef = @{ id = '86b05a0c-73e6-4f7d-b3cf-e38f3b39a75b'; name = 'evaluatebranchProtection'; version = '0.0.1' }; displayName = 'Branch control'; inputs = @{ allowedBranches = "refs/heads/$($environment.Branch)"; ensureProtectionOfBranch = 'false'; allowUnknownStatusBranch = 'false' } }
                                resource = $resource
                                timeout  = 1440
                            }
                            Invoke-AzlAdo -Method POST -Uri "$base/pipelines/checks/configurations?api-version=7.1-preview.1" -Body $body | Out-Null
                            $results.Add((Format-AzlResult $task 'Branch control' $name 'Created' "refs/heads/$($environment.Branch)"))
                        }
                        else { $results.Add((Format-AzlResult $task 'Branch control' $name 'Planned')) }
                    }
                }
            }
        }
    }
    finally { Close-AzlCicdSession }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# Task 05: variables
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlCicdVariablePlan {
    <# The variables for one environment: name, value, secret. The client secret, if used, is read from Key Vault only here. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [string]$ClientId, [switch]$IncludeSecretValue)
    $plan = [System.Collections.Generic.List[object]]::new()
    $plan.Add([pscustomobject]@{ Name = 'ARM_TENANT_ID'; Value = $Settings.TenantId; Secret = $true; Sensitive = $false })
    $plan.Add([pscustomobject]@{ Name = 'ARM_SUBSCRIPTION_ID'; Value = $Settings.AzureSubscriptionId; Secret = $true; Sensitive = $false })
    $plan.Add([pscustomobject]@{ Name = 'ARM_CLIENT_ID'; Value = $ClientId; Secret = $true; Sensitive = $false })
    if ($Settings.Authentication.Method -eq 'oidc') {
        $plan.Add([pscustomobject]@{ Name = 'ARM_USE_OIDC'; Value = 'true'; Secret = $false; Sensitive = $false })
    }
    elseif ($IncludeSecretValue) {
        $plan.Add([pscustomobject]@{ Name = 'ARM_CLIENT_SECRET'; Value = (Get-AzlKeyVaultSecretValue -Reference $Settings.Authentication.ClientSecretReference); Secret = $true; Sensitive = $true })
    }
    else {
        $plan.Add([pscustomobject]@{ Name = 'ARM_CLIENT_SECRET'; Value = $null; Secret = $true; Sensitive = $true })
    }
    $state = $Settings.State
    foreach ($pair in @(@('TF_BACKEND_RG', 'resource_group'), @('TF_BACKEND_SA', 'storage_account'), @('TF_BACKEND_CONTAINER', 'container'))) {
        $value = [string](Get-AzlValue $state $pair[1])
        if ($value) { $plan.Add([pscustomobject]@{ Name = $pair[0]; Value = $value; Secret = $false; Sensitive = $false }) }
    }
    return $plan.ToArray()
}

function Set-AzlCicdVariable {
    <# Task 05. ARM_* values per environment; for Azure DevOps also the workload identity service connection. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [string]$ClientId = '')
    $task = '05-configure-variables'
    $results = [System.Collections.Generic.List[object]]::new()
    if (-not $ClientId) { $ClientId = $Settings.AppClientId }
    if (-not $ClientId) {
        $found = Invoke-AzlNative -FilePath az -ArgumentList @('ad', 'app', 'list', '--display-name', $Settings.AppName, '--query', '[].appId', '-o', 'json')
        $ids = @($found.Output | ConvertFrom-Json)
        if ($ids.Count -ne 1) { throw "Could not find exactly one app registration named '$($Settings.AppName)'. Run task 01, or set azure.automation_identity.client_id." }
        $ClientId = [string]$ids[0]
    }
    $scopes = @($Settings.Environments | ForEach-Object { $_.Name })
    if ($scopes.Count -eq 0) { $scopes = @('') }
    Use-AzlCicdSession -Settings $Settings
    try {
        $withSecret = ($Settings.Authentication.Method -eq 'client_secret') -and $PSCmdlet.ShouldProcess('Key Vault', 'Read the client secret to store it as a masked variable')
        $variables = Get-AzlCicdVariablePlan -Settings $Settings -ClientId $ClientId -IncludeSecretValue:$withSecret
        foreach ($scope in $scopes) {
            $label = if ($scope) { $scope } else { 'repository' }
            foreach ($variable in $variables) {
                if ($null -eq $variable.Value) { $results.Add((Format-AzlResult $task 'Variable' "$($variable.Name) ($label)" 'Planned' 'Value is read from Key Vault when applied.')); continue }
                switch ($Settings.Platform) {
                    'github' {
                        $slug = "$($Settings.Organization)/$($Settings.Repository.Name)"
                        $arguments = @('secret', 'set', $variable.Name, '--repo', $slug)
                        if ($scope) { $arguments += @('--env', $scope) }
                        if ($variable.Secret) {
                            if ($PSCmdlet.ShouldProcess("$($variable.Name) ($label)", 'Set the secret')) {
                                # The client secret goes through stdin so it is never on a command line. The IDs are identifiers.
                                if ($variable.Sensitive) { Invoke-AzlGitHub -ArgumentList $arguments -InputText ([string]$variable.Value) | Out-Null }
                                else { Invoke-AzlGitHub -ArgumentList ($arguments + @('--body', [string]$variable.Value)) | Out-Null }
                                $results.Add((Format-AzlResult $task 'Secret' "$($variable.Name) ($label)" 'Updated'))
                            }
                            else { $results.Add((Format-AzlResult $task 'Secret' "$($variable.Name) ($label)" 'Planned')) }
                        }
                        else {
                            $arguments = @('variable', 'set', $variable.Name, '--repo', $slug, '--body', [string]$variable.Value)
                            if ($scope) { $arguments += @('--env', $scope) }
                            if ($PSCmdlet.ShouldProcess("$($variable.Name) ($label)", 'Set the variable')) {
                                Invoke-AzlGitHub -ArgumentList $arguments | Out-Null
                                $results.Add((Format-AzlResult $task 'Variable' "$($variable.Name) ($label)" 'Updated'))
                            }
                            else { $results.Add((Format-AzlResult $task 'Variable' "$($variable.Name) ($label)" 'Planned')) }
                        }
                    }
                    'gitlab' {
                        $encoded = [uri]::EscapeDataString("$($Settings.Organization)/$($Settings.Repository.Name)")
                        $id = (Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$encoded").id
                        $environmentScope = if ($scope) { $scope } else { '*' }
                        $query = "filter[environment_scope]=$([uri]::EscapeDataString($environmentScope))"
                        $current = Invoke-AzlGitLab -Settings $Settings -Method GET -Path "projects/$id/variables/$($variable.Name)?$query" -AllowNotFound
                        $body = [ordered]@{ key = $variable.Name; value = [string]$variable.Value; masked = $variable.Secret; environment_scope = $environmentScope; protected = $false }
                        if ($PSCmdlet.ShouldProcess("$($variable.Name) ($label)", 'Set the CI/CD variable')) {
                            if ($current) { Invoke-AzlGitLab -Settings $Settings -Method PUT -Path "projects/$id/variables/$($variable.Name)?$query" -Body $body | Out-Null }
                            else { Invoke-AzlGitLab -Settings $Settings -Method POST -Path "projects/$id/variables" -Body $body | Out-Null }
                            $results.Add((Format-AzlResult $task 'Variable' "$($variable.Name) ($label)" $(if ($current) { 'Updated' } else { 'Created' }) $(if ($variable.Secret) { 'masked' } else { '' })))
                        }
                        else { $results.Add((Format-AzlResult $task 'Variable' "$($variable.Name) ($label)" 'Planned')) }
                    }
                    'azure_devops' { }
                }
            }
            if ($Settings.Platform -eq 'azure_devops') {
                $base = "$($Settings.ScmUrl)/$([uri]::EscapeDataString($Settings.Project))/_apis"
                $groupName = if ($scope) { "azure-credentials-$scope" } else { 'azure-credentials' }
                $projectInfo = Invoke-AzlAdo -Method GET -Uri "$($Settings.ScmUrl)/_apis/projects/$([uri]::EscapeDataString($Settings.Project))?api-version=7.1"
                $values = [ordered]@{}
                foreach ($variable in $variables) {
                    if ($null -ne $variable.Value) { $values[$variable.Name] = @{ value = [string]$variable.Value; isSecret = $variable.Secret } }
                }
                $body = [ordered]@{ name = $groupName; type = 'Vsts'; variables = $values; variableGroupProjectReferences = @(@{ name = $groupName; projectReference = @{ id = $projectInfo.id; name = $Settings.Project } }) }
                $current = @((Invoke-AzlAdo -Method GET -Uri "$base/distributedtask/variablegroups?groupName=$([uri]::EscapeDataString($groupName))&api-version=7.1").value) | Where-Object { $_.name -eq $groupName } | Select-Object -First 1
                if ($PSCmdlet.ShouldProcess($groupName, 'Create or update the variable group')) {
                    if ($current) { Invoke-AzlAdo -Method PUT -Uri "$base/distributedtask/variablegroups/$($current.id)?api-version=7.1" -Body $body | Out-Null }
                    else { Invoke-AzlAdo -Method POST -Uri "$base/distributedtask/variablegroups?api-version=7.1" -Body $body | Out-Null }
                    $results.Add((Format-AzlResult $task 'Variable group' $groupName $(if ($current) { 'Updated' } else { 'Created' })))
                }
                else { $results.Add((Format-AzlResult $task 'Variable group' $groupName 'Planned')) }
            }
        }

        if ($Settings.Platform -eq 'azure_devops' -and $Settings.Authentication.Method -eq 'oidc') {
            $connection = 'AzureLocal-ServiceConnection'
            $base = "$($Settings.ScmUrl)/$([uri]::EscapeDataString($Settings.Project))/_apis"
            $existing = @((Invoke-AzlAdo -Method GET -Uri "$base/serviceendpoint/endpoints?endpointNames=$connection&api-version=7.1").value) | Select-Object -First 1
            if ($existing) { $results.Add((Format-AzlResult $task 'Service connection' $connection 'Exists')) }
            elseif ($PSCmdlet.ShouldProcess($connection, 'Create the workload identity federation service connection')) {
                $projectInfo = Invoke-AzlAdo -Method GET -Uri "$($Settings.ScmUrl)/_apis/projects/$([uri]::EscapeDataString($Settings.Project))?api-version=7.1"
                $subscriptionName = (Invoke-AzlNative -FilePath az -ArgumentList @('account', 'show', '--subscription', $Settings.AzureSubscriptionId, '--query', 'name', '-o', 'tsv')).Output
                $body = [ordered]@{
                    name                             = $connection
                    type                             = 'azurerm'
                    url                              = 'https://management.azure.com/'
                    isShared                         = $false
                    authorization                    = @{ scheme = 'WorkloadIdentityFederation'; parameters = @{ tenantid = $Settings.TenantId; serviceprincipalid = $ClientId } }
                    data                             = @{ environment = 'AzureCloud'; scopeLevel = 'Subscription'; subscriptionId = $Settings.AzureSubscriptionId; subscriptionName = $subscriptionName; creationMode = 'Manual' }
                    serviceEndpointProjectReferences = @(@{ projectReference = @{ id = $projectInfo.id; name = $Settings.Project }; name = $connection })
                }
                Invoke-AzlAdo -Method POST -Uri "$($Settings.ScmUrl)/_apis/serviceendpoint/endpoints?api-version=7.1" -Body $body | Out-Null
                $results.Add((Format-AzlResult $task 'Service connection' $connection 'Created' 'Workload identity federation: no secret.'))
            }
            else { $results.Add((Format-AzlResult $task 'Service connection' $connection 'Planned')) }
        }
    }
    finally { Close-AzlCicdSession }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# Task 06: runners (Terraform)
# ---------------------------------------------------------------------------------------------------------------------

function Get-AzlVaultResourceId {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [Parameter(Mandatory)][string]$Name)
    $vault = $Settings.KeyVaults | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $vault) { throw "Key Vault '$Name' is not listed in key_vaults." }
    return "/subscriptions/$($vault.SubscriptionId)/resourceGroups/$($vault.ResourceGroup)/providers/Microsoft.KeyVault/vaults/$($vault.Name)"
}

function ConvertTo-AzlRunnerTerraformVariable {
    <#
    .SYNOPSIS
        Maps devops.runners, runner_network and runner_access to the variables of src/terraform/environments/cicd-infra.
        Holds names and IDs only: no secret.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings, [string]$AdminSshPublicKey = '')
    $runners = @($Settings.Runners)
    if ($runners.Count -eq 0) { throw 'devops.runners is empty. Describe the runners in infrastructure.yml, or pass -VarFile.' }
    $linux = @($runners | Where-Object { $_.OsType -eq 'linux' })
    $ztp = @($runners | Where-Object { $_.Purpose -eq 'ztp' })
    if ($linux.Count -gt 1 -or $ztp.Count -gt 1 -or @($runners | Where-Object { $_.OsType -eq 'windows' -and $_.Purpose -ne 'ztp' }).Count -gt 0) {
        throw 'Task 06 deploys one Linux general pool and at most one Windows ztp runner. Use src/terraform/modules/cicd-runner directly for more.'
    }
    if (-not $Settings.DevopsResourceGroup) { throw 'devops.resource_group is not set.' }
    $net = $Settings.RunnerNetwork
    $access = $Settings.RunnerAccess

    $secretRefs = @($runners | ForEach-Object { $_.RegistrationSecret } | Where-Object { $_ } | Select-Object -Unique)
    if ($secretRefs.Count -eq 0) { throw 'A runner needs registration_secret.' }
    $parsed = @($secretRefs | ForEach-Object {
            if ($_ -notmatch '^keyvault://([^/]+)/(.+)$') { throw "registration_secret '$_' is not a keyvault:// reference." }
            [pscustomobject]@{ Vault = $Matches[1]; Secret = $Matches[2]; Reference = $_ }
        })
    $vaults = @($parsed.Vault | Select-Object -Unique)
    if ($vaults.Count -gt 1) { throw "All runners must read their registration secret from one vault (found: $($vaults -join ', '))." }
    $secretOf = { param($r) if ($r.RegistrationSecret) { ($r.RegistrationSecret -replace '^keyvault://[^/]+/', '') } else { $parsed[0].Secret } }

    $subscriptionId = $Settings.AzureSubscriptionId
    $resourceGroups = @(Get-AzlList (Get-AzlValue $access 'resource_groups' @($Settings.AzureResourceGroup)) | Where-Object { $_ })
    [string[]]$scopes = @($resourceGroups | ForEach-Object { "/subscriptions/$subscriptionId/resourceGroups/$_" })
    $readerNames = @(Get-AzlList (Get-AzlValue $access 'key_vaults' @($Settings.KeyVaults | ForEach-Object { $_.Name })) | Where-Object { $_ -and $_ -ne $vaults[0] })

    $hub = Get-AzlValue $net 'hub_peering' @{}
    $hubEnabled = [bool](Get-AzlValue $hub 'enabled' $false)
    $hubId = [string](Get-AzlValue $hub 'hub_vnet_id')
    $hubSubscriptionId = $null
    if ($hubEnabled -and -not $hubId) {
        $network = $Settings.LandingNetworks | Where-Object { $_['name'] -eq (Get-AzlValue $hub 'hub_network') } | Select-Object -First 1
        if (-not $network) { throw 'hub_peering is enabled, but neither hub_vnet_id nor a hub_network from landing_zone.networks resolves.' }
        $hubSubscription = $Settings.Subscriptions | Where-Object { $_.Name -eq $network['subscription'] } | Select-Object -First 1
        if (-not $hubSubscription -or -not $hubSubscription.Id) { throw "The subscription '$($network['subscription'])' of the hub network has no id in landing_zone.subscriptions." }
        $hubId = "/subscriptions/$($hubSubscription.Id)/resourceGroups/$($network['resource_group'])/providers/Microsoft.Network/virtualNetworks/$($network['name'])"
    }
    if ($hubId -match '^/subscriptions/([^/]+)/') { $hubSubscriptionId = $Matches[1] }

    [string[]]$rbacScopes = if ([bool](Get-AzlValue $access 'rbac_administrator' $true)) { $scopes } else { @() }
    [string[]]$arcScopes = if ([bool](Get-AzlValue $access 'arc_run_command' $true)) { $scopes } else { @() }
    $variables = [ordered]@{
        tenant_id             = $Settings.TenantId
        subscription_id       = $Settings.DevopsSubscriptionId
        location              = $Settings.Location
        resource_group_name   = $Settings.DevopsResourceGroup
        create_resource_group = $Settings.CreateResourceGroup
        tags                  = $Settings.Tags
        platform              = $Settings.Platform
        scm_url               = $Settings.ScmUrl
        registration_secret   = [ordered]@{
            key_vault_id   = Get-AzlVaultResourceId -Settings $Settings -Name $vaults[0]
            key_vault_name = $vaults[0]
            secret_name    = if ($linux.Count -gt 0) { & $secretOf $linux[0] } else { $parsed[0].Secret }
            ztp_secret_name = if ($ztp.Count -gt 0) { & $secretOf $ztp[0] } else { '' }
        }
        vnet_name             = [string](Get-AzlValue $net 'vnet_name')
        vnet_address_space    = @(Get-AzlList (Get-AzlValue $net 'address_space'))
        dns_servers           = @(Get-AzlList (Get-AzlValue $net 'dns_servers'))
        reachable_cidrs       = @(Get-AzlList (Get-AzlValue $net 'reachable_cidrs'))
        bmc_cidrs             = @(Get-AzlList (Get-AzlValue $net 'bmc_cidrs'))
        admin_source_cidrs    = @(Get-AzlList (Get-AzlValue $net 'admin_source_cidrs'))
        hub_peering           = [ordered]@{
            enabled             = $hubEnabled
            hub_vnet_id         = $hubId
            use_remote_gateways = [bool](Get-AzlValue $hub 'use_remote_gateways' $true)
            create_hub_side     = [bool](Get-AzlValue $hub 'create_hub_side' $true)
        }
        contributor_scopes    = $scopes
        rbac_administrator_scopes = $rbacScopes
        rbac_administrator_delegable_role_ids = @(Get-AzlList (Get-AzlValue $access 'rbac_delegable_role_ids'))
        arc_machine_scopes    = $arcScopes
        key_vault_reader_ids  = @($readerNames | ForEach-Object { Get-AzlVaultResourceId -Settings $Settings -Name $_ })
        admin_ssh_public_key  = $AdminSshPublicKey
    }
    if ($hubSubscriptionId) { $variables.hub_subscription_id = $hubSubscriptionId }
    if ($Settings.Platform -eq 'github') {
        if ($linux.Count -gt 0 -and $linux[0].Pool) { $variables.github_runner_group = $linux[0].Pool }
    }
    if ($Settings.Platform -eq 'azure_devops') {
        if ($linux.Count -gt 0 -and $linux[0].Pool) { $variables.azure_devops_pool = $linux[0].Pool }
        if ($ztp.Count -gt 0 -and $ztp[0].Pool) { $variables.azure_devops_ztp_pool = $ztp[0].Pool }
    }

    if ($linux.Count -gt 0) {
        $l = $linux[0]
        $variables.linux_runner = [ordered]@{ enabled = $true; name_prefix = $l.Name; count = $l.Count; compute_type = $l.ComputeType; vm_size = $l.Size; private_ip_addresses = @($l.PrivateIps); extra_labels = @($l.Labels) }
        $variables.linux_subnet = [ordered]@{ name = $l.SubnetName; address_prefix = $l.SubnetPrefix }
    }
    else { $variables.linux_runner = [ordered]@{ enabled = $false } }
    if ($ztp.Count -gt 0) {
        $z = $ztp[0]
        $variables.ztp_runner = [ordered]@{ enabled = $true; name_prefix = $z.Name; vm_size = $z.Size; data_disk_size_gb = $z.DataDiskGb; private_ip_addresses = @($z.PrivateIps); extra_labels = @($z.Labels) }
        $variables.ztp_subnet = [ordered]@{ name = $z.SubnetName; address_prefix = $z.SubnetPrefix }
    }
    else { $variables.ztp_runner = [ordered]@{ enabled = $false } }
    return $variables
}

function Get-AzlTerraformBackendArgument {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $state = $Settings.State
    $account = [string](Get-AzlValue $state 'storage_account')
    if (-not $account) { throw 'devops.state.storage_account is not set. Set it, pass -BackendConfigFile, or use -BackendFalse.' }
    $pairs = [ordered]@{
        resource_group_name  = [string](Get-AzlValue $state 'resource_group')
        storage_account_name = $account
        container_name       = [string](Get-AzlValue $state 'container' 'tfstate')
        key                  = [string](Get-AzlValue $state 'key' 'cicd-infra.tfstate')
        use_azuread_auth     = 'true'
    }
    if (Get-AzlValue $state 'subscription_id') { $pairs.subscription_id = [string](Get-AzlValue $state 'subscription_id') }
    return @($pairs.GetEnumerator() | ForEach-Object { "-backend-config=$($_.Key)=$($_.Value)" })
}

function Invoke-AzlCicdRunnerDeployment {
    <#
    .SYNOPSIS
        Task 06. terraform init, validate and plan for src/terraform/environments/cicd-infra; apply only with -Apply.
    .DESCRIPTION
        Without -Apply nothing in Azure changes. The plan is saved to a file and applied from that file, so what you
        reviewed is what runs. -VarFile uses a prepared terraform.tfvars (kept outside the repository) instead of
        building the variables from infrastructure.yml.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [System.Collections.IDictionary]$Settings,
        [string]$TerraformDirectory,
        [string]$VarFile = '',
        [string]$BackendConfigFile = '',
        [switch]$BackendFalse,
        [string]$WorkingDirectory = '',
        [string]$AdminSshPublicKeyPath = '',
        [switch]$NoLock,
        [string]$PlanFile = '',
        [switch]$Apply
    )
    $task = '06-deploy-runners'
    $results = [System.Collections.Generic.List[object]]::new()
    if (-not $TerraformDirectory) { $TerraformDirectory = Join-Path $PSScriptRoot '..\..\..\src\terraform\environments\cicd-infra' }
    $TerraformDirectory = (Resolve-Path -LiteralPath $TerraformDirectory).Path
    if (-not $WorkingDirectory) { $WorkingDirectory = Join-Path ([IO.Path]::GetTempPath()) 'azl-cicd-infra' }
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null }

    $init = @('init', '-input=false', '-no-color')
    if ($BackendFalse) { $init += '-backend=false' }
    elseif ($BackendConfigFile) { $init += "-backend-config=$((Resolve-Path -LiteralPath $BackendConfigFile).Path)" }
    else {
        if (-not $Settings) { throw 'Pass -BackendConfigFile, -BackendFalse, or -Settings with devops.state.' }
        $init += Get-AzlTerraformBackendArgument -Settings $Settings
    }

    # Apply a plan that was made and reviewed earlier (the approval job of a pipeline): no new plan is made.
    if ($PlanFile) {
        if (-not $Apply) { throw '-PlanFile applies a saved plan, so it needs -Apply.' }
        $PlanFile = (Resolve-Path -LiteralPath $PlanFile).Path
        $savedLock = Join-Path (Split-Path -Path $PlanFile -Parent) '.terraform.lock.hcl'
        # The plan was made with these provider versions; init must select the same ones.
        if (Test-Path -LiteralPath $savedLock) { Copy-Item -LiteralPath $savedLock -Destination (Join-Path $TerraformDirectory '.terraform.lock.hcl') -Force }
        Invoke-AzlNative -FilePath terraform -ArgumentList $init -WorkingDirectory $TerraformDirectory | Out-Null
        $results.Add((Format-AzlResult $task 'terraform init' $TerraformDirectory 'Done'))
        if ($PSCmdlet.ShouldProcess($PlanFile, 'terraform apply the saved plan: create the runners in Azure')) {
            Invoke-AzlNative -FilePath terraform -ArgumentList @('apply', '-input=false', '-no-color', $PlanFile) -WorkingDirectory $TerraformDirectory | Out-Null
            $results.Add((Format-AzlResult $task 'terraform apply' $PlanFile 'Done'))
        }
        else { $results.Add((Format-AzlResult $task 'terraform apply' $PlanFile 'Planned')) }
        return $results.ToArray()
    }

    if ($VarFile) {
        $VarFile = (Resolve-Path -LiteralPath $VarFile).Path
    }
    else {
        if (-not $Settings) { throw 'Pass -Settings (from infrastructure.yml) or -VarFile.' }
        $publicKey = ''
        if ($AdminSshPublicKeyPath) { $publicKey = (Get-Content -LiteralPath $AdminSshPublicKeyPath -Raw).Trim() }
        elseif ($env:AZL_RUNNER_SSH_PUBLIC_KEY) { $publicKey = $env:AZL_RUNNER_SSH_PUBLIC_KEY.Trim() }
        $variables = ConvertTo-AzlRunnerTerraformVariable -Settings $Settings -AdminSshPublicKey $publicKey
        if (@($Settings.Runners | Where-Object { $_.OsType -eq 'linux' }).Count -gt 0 -and -not $publicKey) {
            throw 'A Linux runner needs an SSH public key: pass -AdminSshPublicKeyPath or set AZL_RUNNER_SSH_PUBLIC_KEY (a public key, not a secret).'
        }
        $VarFile = Join-Path $WorkingDirectory 'cicd-infra.auto.tfvars.json'
        if ($PSCmdlet.ShouldProcess($VarFile, 'Write the Terraform variables (names and IDs, no secret)')) {
            $variables | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $VarFile -Encoding utf8
        }
        $results.Add((Format-AzlResult $task 'Terraform variables' $VarFile 'Done' 'Names and IDs only.'))
    }

    Invoke-AzlNative -FilePath terraform -ArgumentList $init -WorkingDirectory $TerraformDirectory | Out-Null
    $results.Add((Format-AzlResult $task 'terraform init' $TerraformDirectory 'Done'))

    Invoke-AzlNative -FilePath terraform -ArgumentList @('validate', '-no-color') -WorkingDirectory $TerraformDirectory | Out-Null
    $results.Add((Format-AzlResult $task 'terraform validate' $TerraformDirectory 'Done'))

    $planFile = Join-Path $WorkingDirectory 'cicd-infra.tfplan'
    $plan = @('plan', '-input=false', '-no-color', "-var-file=$VarFile", "-out=$planFile")
    if ($NoLock) { $plan += '-lock=false' }
    $planned = Invoke-AzlNative -FilePath terraform -ArgumentList $plan -WorkingDirectory $TerraformDirectory
    # Keep the provider lock file with the plan: the apply must select the same provider versions.
    $lock = Join-Path $TerraformDirectory '.terraform.lock.hcl'
    if (Test-Path -LiteralPath $lock) { Copy-Item -LiteralPath $lock -Destination (Join-Path $WorkingDirectory '.terraform.lock.hcl') -Force }
    $summary = ($planned.Output -split "`n" | Where-Object { $_ -match '^(Plan:|No changes\.)' } | Select-Object -Last 1)
    $results.Add((Format-AzlResult $task 'terraform plan' $planFile 'Done' $(if ($summary) { $summary } else { 'See the plan output.' })))

    if (-not $Apply) {
        $results.Add((Format-AzlResult $task 'terraform apply' $planFile 'Skipped' 'Plan only. Review it, then run again with -Apply.'))
    }
    elseif ($PSCmdlet.ShouldProcess($planFile, 'terraform apply: create the runners in Azure')) {
        Invoke-AzlNative -FilePath terraform -ArgumentList @('apply', '-input=false', '-no-color', $planFile) -WorkingDirectory $TerraformDirectory | Out-Null
        $results.Add((Format-AzlResult $task 'terraform apply' $planFile 'Done'))
    }
    else {
        $results.Add((Format-AzlResult $task 'terraform apply' $planFile 'Planned'))
    }
    return $results.ToArray()
}

Export-ModuleMember -Function ConvertTo-AzlCicdSetting, Get-AzlCicdSetting, Resolve-AzlCicdInput, Initialize-AzlCicdLog, Write-AzlCicdLog,
Invoke-AzlCicdBootstrap, New-AzlCicdProject, Set-AzlCicdProjectSetting, New-AzlCicdEnvironment, Set-AzlCicdVariable,
Invoke-AzlCicdRunnerDeployment, ConvertTo-AzlRunnerTerraformVariable, Get-AzlFederatedCredentialPlan, Invoke-AzlNative, Invoke-AzlRest

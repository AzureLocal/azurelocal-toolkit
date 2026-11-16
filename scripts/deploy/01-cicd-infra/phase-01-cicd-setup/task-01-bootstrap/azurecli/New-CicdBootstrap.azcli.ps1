#Requires -Version 7.0
<#
.SYNOPSIS
    Task 01, Azure CLI variant. Creates the CI/CD service principal and its Azure access with az commands only.

.DESCRIPTION
    Does the Azure side of New-CicdBootstrap.ps1 with the Azure CLI and nothing else: the app registration and service principal
    (azure.automation_identity.name), its federated credentials for the platform (or, with devops.authentication.method client_secret, a client secret
    stored only in Key Vault), the role assignments on each subscription, and the Microsoft.Compute and EncryptionAtHost registrations. It does not
    create anything on GitHub, GitLab or Azure DevOps (tasks 02 to 05 do) and it does not sign in: run "az login --tenant <azure.tenant_id>" first as
    someone who can create app registrations and assign roles.

    Reads the devops, azure, key_vaults and landing_zone sections of infrastructure.yml (schema 5) through the same settings reader as the PowerShell
    script (Get-AzlCicdSetting in scripts/common/cicd-infra/AzlCicdInfra.psm1) and takes the federated credentials from the same plan
    (Get-AzlFederatedCredentialPlan), so both scripts make the same objects. Every Azure call in this script is an az command, except one: with the
    client secret method the check "is the secret in Key Vault" goes through the toolkit's secret resolver (Test-AzlSecretReference, which needs the
    Az.KeyVault module), as the secrets rule of the toolkit requires.

    Idempotent: it creates what is missing and leaves the rest. -WhatIf reads what exists and lists what it would do. A client secret is not
    rotated: delete the Key Vault secret to have a new one issued. The secret goes to Key Vault from a temporary file that is removed at once, never on
    a command line, and is never printed.

    Exit codes: 0 done (created, already there, or planned under -WhatIf); 1 an az call failed or a precondition failed (az missing, not signed in,
    wrong tenant); 2 the infrastructure file cannot be read or does not validate.

.PARAMETER InfrastructureFile
    The infrastructure file (infrastructure.yml, schema 5). Required: there is no default path.

.PARAMETER Platform
    Overrides devops.platform: github, gitlab or azure_devops. It decides the federated credentials.

.PARAMETER LogPath
    Optional. Also append the progress lines to this file. Keep it out of the repository.

.EXAMPLE
    ./New-CicdBootstrap.azcli.ps1 -InfrastructureFile ./infrastructure.yml -WhatIf

    Lists what would be created and creates nothing.

.EXAMPLE
    az login --tenant <tenant-id>
    ./New-CicdBootstrap.azcli.ps1 -InfrastructureFile ./infrastructure.yml

    Creates the app registration, the service principal, the federated credentials, the roles and the registrations.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InfrastructureFile,
    [ValidateSet('', 'github', 'gitlab', 'azure_devops')]
    [string]$Platform = '',
    [string]$LogPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$logFile = $LogPath

function Get-CicdModulePath {
    $current = Get-Item -LiteralPath $PSScriptRoot
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName (Join-Path 'scripts' (Join-Path 'common' (Join-Path 'cicd-infra' 'AzlCicdInfra.psm1')))
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $current = $current.Parent
    }
    throw "Unable to locate AzlCicdInfra.psm1 from '$PSScriptRoot'."
}

function Write-Line([string]$Text) {
    Write-Information -MessageData $Text -InformationAction Continue
    if ($logFile) { Add-Content -LiteralPath $logFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -WhatIf:$false }
}
function Exit-InputProblem([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 2 }
function Exit-Failed([string]$Message) { Write-Error $Message -ErrorAction Continue; exit 1 }

# One az call. Returns the text of standard output; throws, with the error text, when az ends with an error (warnings on standard error are dropped).
# With -AllowFailure it returns $null instead of throwing.
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgument, [switch]$AllowFailure)
    $all = @(& az @AzArgument 2>&1)
    $code = $LASTEXITCODE
    $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $text = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        $shown = if ($errorText -or $text) { (@($errorText, $text) | Where-Object { $_ }) -join ' ' } else { "az ended with exit code $code." }
        throw $(if ($shown.Length -gt 600) { $shown.Substring(0, 600) + '...' } else { $shown })
    }
    $text
}

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Action, [string]$Target, [ValidateSet('Created', 'Exists', 'Updated', 'Planned', 'Skipped', 'Done')][string]$Status, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Task = '01-bootstrap'; Action = $Action; Target = $Target; Status = $Status; Detail = $Detail })
    Write-Line ('[{0}] {1}: {2}{3}' -f $Status.ToLowerInvariant(), $Action, $Target, $(if ($Detail) { " ($Detail)" } else { '' }))
}

Import-Module (Get-CicdModulePath)
# The one secret resolver of the toolkit (it answers "is the secret there" for the client secret method).
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'secrets', 'AzlSecret.psm1')))
try { $settings = Get-AzlCicdSetting -InfrastructureFile $InfrastructureFile -Platform $Platform }
catch { Write-Error "The infrastructure file cannot be used: $($_.Exception.Message)" -ErrorAction Continue; exit 2 }

$tenantId = [string]$settings.TenantId
if ($settings.Authentication.Method -eq 'client_secret' -and $settings.Authentication.ClientSecretReference -notmatch '^keyvault://[^/]+/[^/]+$') {
    Exit-InputProblem 'devops.authentication.method is client_secret, so devops.authentication.client_secret must be a keyvault://<vault>/<secret> reference.'
}

# ---- preconditions (read only)
if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) { Exit-Failed 'The Azure CLI (az) was not found. Install it, or use New-CicdBootstrap.ps1.' }
try { $signedInTenant = Invoke-Az -AzArgument @('account', 'show', '--query', 'tenantId', '--output', 'tsv') }
catch { Exit-Failed 'Not signed in to Azure. Run az login --tenant <azure.tenant_id>.' }
if ($tenantId -and $signedInTenant -ne $tenantId) { Exit-Failed "Signed in to tenant $signedInTenant, but azure.tenant_id is $tenantId. Sign in to the right tenant." }

try {
    $appName = [string]$settings.AppName

    # App registration
    $appIds = @(Invoke-Az -AzArgument @('ad', 'app', 'list', '--display-name', $appName, '--query', '[].appId', '--output', 'json') | ConvertFrom-Json)
    if ($appIds.Count -gt 1) { throw "More than one app registration is named '$appName'. Remove the extra ones, or set azure.automation_identity.client_id." }
    $appId = if ($settings.AppClientId) { [string]$settings.AppClientId } elseif ($appIds.Count -eq 1) { [string]$appIds[0] } else { '' }
    if ($appId) { Add-Result -Action 'App registration' -Target $appName -Status Exists -Detail $appId }
    elseif ($PSCmdlet.ShouldProcess($appName, 'Create the app registration')) {
        $appId = Invoke-Az -AzArgument @('ad', 'app', 'create', '--display-name', $appName, '--query', 'appId', '--output', 'tsv')
        Add-Result -Action 'App registration' -Target $appName -Status Created -Detail $appId
    }
    else { Add-Result -Action 'App registration' -Target $appName -Status Planned }

    # Service principal
    $spObjectId = ''
    if ($appId) {
        $found = Invoke-Az -AzArgument @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '--output', 'tsv') -AllowFailure
        if ($found) { $spObjectId = $found; Add-Result -Action 'Service principal' -Target $appName -Status Exists -Detail $spObjectId }
        elseif ($PSCmdlet.ShouldProcess($appName, 'Create the service principal')) {
            $spObjectId = Invoke-Az -AzArgument @('ad', 'sp', 'create', '--id', $appId, '--query', 'id', '--output', 'tsv')
            Add-Result -Action 'Service principal' -Target $appName -Status Created -Detail $spObjectId
        }
        else { Add-Result -Action 'Service principal' -Target $appName -Status Planned }
    }

    # Sign-in: federated credentials, or a client secret that goes to Key Vault only
    if ($settings.Authentication.Method -eq 'oidc') {
        $existing = @()
        if ($appId) { $existing = @(Invoke-Az -AzArgument @('ad', 'app', 'federated-credential', 'list', '--id', $appId, '--query', '[].name', '--output', 'json') | ConvertFrom-Json) }
        foreach ($credential in @(Get-AzlFederatedCredentialPlan -Settings $settings)) {
            if ($credential.Name -in $existing) { Add-Result -Action 'Federated credential' -Target $credential.Name -Status Exists -Detail $credential.Subject }
            elseif ($appId -and $PSCmdlet.ShouldProcess($credential.Name, "Create the federated credential for $($credential.Subject)")) {
                $file = Join-Path ([IO.Path]::GetTempPath()) ('azl-fic-{0}.json' -f [guid]::NewGuid())
                try {
                    [ordered]@{ name = $credential.Name; issuer = $credential.Issuer; subject = $credential.Subject; audiences = @('api://AzureADTokenExchange') } |
                        ConvertTo-Json | Set-Content -LiteralPath $file -Encoding utf8
                    $null = Invoke-Az -AzArgument @('ad', 'app', 'federated-credential', 'create', '--id', $appId, '--parameters', $file, '--output', 'none')
                }
                finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
                Add-Result -Action 'Federated credential' -Target $credential.Name -Status Created -Detail $credential.Subject
            }
            else { Add-Result -Action 'Federated credential' -Target $credential.Name -Status Planned -Detail $credential.Subject }
        }
    }
    else {
        $reference = [string]$settings.Authentication.ClientSecretReference
        $vault, $secretName = ($reference -replace '^keyvault://', '').Split('/', 2)
        # Is it there? The resolver proves it (the value is read into memory and dropped). Any failure counts as "not there".
        $present = Test-AzlSecretReference -Reference $reference -Infrastructure $settings.Infrastructure
        if ($present) { Add-Result -Action 'Client secret' -Target $reference -Status Exists -Detail 'Not rotated. Delete the Key Vault secret to issue a new one.' }
        elseif ($appId -and $PSCmdlet.ShouldProcess($reference, 'Create a client secret and store it in Key Vault')) {
            $file = Join-Path ([IO.Path]::GetTempPath()) ('azl-sec-{0}.txt' -f [guid]::NewGuid())
            try {
                $value = Invoke-Az -AzArgument @('ad', 'app', 'credential', 'reset', '--id', $appId, '--append', '--years', '2', '--query', 'password', '--output', 'tsv')
                Set-Content -LiteralPath $file -Value $value -NoNewline -Encoding utf8
                $value = $null
                $null = Invoke-Az -AzArgument @('keyvault', 'secret', 'set', '--vault-name', $vault, '--name', $secretName, '--file', $file, '--encoding', 'utf-8', '--output', 'none')
            }
            finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            Add-Result -Action 'Client secret' -Target $reference -Status Created -Detail 'Stored in Key Vault. Never printed.'
        }
        else { Add-Result -Action 'Client secret' -Target $reference -Status Planned }
    }

    # Roles and registrations on each subscription
    foreach ($subscriptionId in $settings.RoleSubscriptionIds) {
        $scope = "/subscriptions/$subscriptionId"
        $assigned = @()
        if ($spObjectId) { $assigned = @(Invoke-Az -AzArgument @('role', 'assignment', 'list', '--assignee', $spObjectId, '--scope', $scope, '--query', '[].roleDefinitionName', '--output', 'json') | ConvertFrom-Json) }
        foreach ($role in $settings.Authentication.Roles) {
            if ($role -in $assigned) { Add-Result -Action 'Role assignment' -Target "$role on $scope" -Status Exists }
            elseif ($spObjectId -and $PSCmdlet.ShouldProcess("$role on $scope", 'Assign the role to the service principal')) {
                $null = Invoke-Az -AzArgument @('role', 'assignment', 'create', '--assignee-object-id', $spObjectId, '--assignee-principal-type', 'ServicePrincipal', '--role', $role, '--scope', $scope, '--output', 'none')
                Add-Result -Action 'Role assignment' -Target "$role on $scope" -Status Created
            }
            else { Add-Result -Action 'Role assignment' -Target "$role on $scope" -Status Planned }
        }
        if ($settings.Authentication.RegisterEncryptionAtHost) {
            $state = Invoke-Az -AzArgument @('feature', 'show', '--namespace', 'Microsoft.Compute', '--name', 'EncryptionAtHost', '--subscription', $subscriptionId, '--query', 'properties.state', '--output', 'tsv') -AllowFailure
            if ($state -eq 'Registered') { Add-Result -Action 'Feature' -Target "Microsoft.Compute/EncryptionAtHost in $subscriptionId" -Status Exists }
            elseif ($PSCmdlet.ShouldProcess("Microsoft.Compute and EncryptionAtHost in $subscriptionId", 'Register the provider and the feature')) {
                $null = Invoke-Az -AzArgument @('provider', 'register', '--namespace', 'Microsoft.Compute', '--subscription', $subscriptionId)
                $null = Invoke-Az -AzArgument @('feature', 'register', '--namespace', 'Microsoft.Compute', '--name', 'EncryptionAtHost', '--subscription', $subscriptionId, '--output', 'none')
                Add-Result -Action 'Feature' -Target "Microsoft.Compute/EncryptionAtHost in $subscriptionId" -Status Created -Detail 'Registering. It can take a few minutes.'
            }
            else { Add-Result -Action 'Feature' -Target "Microsoft.Compute/EncryptionAtHost in $subscriptionId" -Status Planned }
        }
    }

    # Optional, high privilege
    if ($settings.Authentication.GrantGraphRoleManagement) {
        if ($appId -and $PSCmdlet.ShouldProcess($appName, 'Add RoleManagement.ReadWrite.Directory and grant admin consent')) {
            $null = Invoke-Az -AzArgument @('ad', 'app', 'permission', 'add', '--id', $appId, '--api', '00000003-0000-0000-c000-000000000000', '--api-permissions', '9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8=Role')
            $null = Invoke-Az -AzArgument @('ad', 'app', 'permission', 'admin-consent', '--id', $appId)
            Add-Result -Action 'Graph permission' -Target 'RoleManagement.ReadWrite.Directory' -Status Done
        }
        else { Add-Result -Action 'Graph permission' -Target 'RoleManagement.ReadWrite.Directory' -Status Planned }
    }
    if ($appId) { Write-Line "Set azure.automation_identity.client_id to $appId in infrastructure.yml (task 05 reads it). It is an identifier, not a secret." }
}
catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }

$results | Format-Table Action, Target, Status, Detail -AutoSize | Out-Host
$results
exit 0

#Requires -Version 7.0
<#
.SYNOPSIS
    Reads a secret reference for an Azure CLI script: a keyvault:// reference with "az keyvault secret show", any other reference with the toolkit's resolver.

.DESCRIPTION
    The toolkit reads a secret through one place, scripts/common/secrets (AzlSecret.psm1). That module reads a keyvault:// reference with the Az.KeyVault
    module and has no Azure CLI fallback. A script of the toolkit that uses the Azure CLI and not the Az PowerShell modules (the *.azcli.ps1 scripts) needs the
    same read with az. This module is that read, kept beside the resolver so that the rule "no script reads a Key Vault secret itself" still holds.

    Get-AzlSecretPlainTextAzureCli takes the reference, the loaded infrastructure file and the way to start az:

        keyvault://<vault>/<secret>[/<version>]   read with "az keyvault secret show --query value --output tsv". The vault must be listed under key_vaults
                                                   (as the resolver requires); the signed-in identity needs Key Vault Secrets User on it.
        env://, file://, command://                read by Get-AzlSecretPlainText of AzlSecret.psm1, without az.

    The caller passes az as a script block (-Az), created in the caller's own script: it gets the argument list and starts az. That keeps this module free of the
    command name az (so a test of the caller can mock az) and lets the caller decide how az is started. The script block must not write standard error to the
    output stream. The function reads $LASTEXITCODE after the call, so the block must start az in the way that sets it (& az ...).

    A secret that holds one of & | < > ^ % " or a line break is refused (exit 2, category UnsafeCharacter), whatever provider it comes from: on Windows az is a
    batch file (az.cmd) and cmd.exe would read such a character in an argument as an operator or a variable (Assert-AzlAzureCliSecret of
    scripts/common/azure-cli/AzlAzureCliArgument.psm1). The check runs right after the read; the message names the reference, never the value.
    Assert-AzlSecretReferenceAzureCli checks a reference without reading it (the form, and that the vault is listed under key_vaults), so that a script can
    refuse a bad reference at plan time, also under -WhatIf, before it calls Azure.

    Security rules (as for the resolver): the value is returned only as a string for the caller that must put it in an az argument; it is never written to a file,
    a log, an error message or any stream by this module, and a message names the reference, never the value. A text that is not a reference is never echoed.
    Errors are exceptions whose Data holds AzlSecretError (the category) and AzlExit (2 for a wrong input, 1 for a failed call).

    Functions
        Assert-AzlSecretReferenceAzureCli  reference + infrastructure -> throws (AzlExit 2) when the reference is not usable; reads nothing
        Get-AzlSecretPlainTextAzureCli     reference + infrastructure + az -> the secret as text
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AzlSecret.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1'))
Import-Module ([IO.Path]::Combine($PSScriptRoot, '..', 'azure-cli', 'AzlAzureCliArgument.psm1'))

# The keyvault form of AzlSecret.psm1: the vault is 3 to 24 letters, digits and hyphens, the secret 1 to 127 letters, digits and hyphens, the version 32 hex digits.
$script:KeyVaultForm = '^keyvault://(?<vault>[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9])/(?<secret>[A-Za-z0-9-]{1,127})(/(?<version>[0-9a-fA-F]{32}))?\z'

function Stop-AzlSecretAzureCli {
    # Raises an error of the kind AzlSecret.psm1 raises. The message must never hold a secret value.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Throws an error; changes no system state.')]
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$Message, [int]$Exit = 1)
    $e = [System.InvalidOperationException]::new($Message)
    $e.Data['AzlSecretError'] = $Category
    $e.Data['AzlExit'] = $Exit
    throw $e
}

function Assert-AzlSecretReferenceAzureCli {
    <#
    .SYNOPSIS
        Throws (AzlExit 2) when a reference cannot be read: not a reference, a keyvault:// reference of a bad form, or a vault that is not listed under key_vaults.
    .DESCRIPTION
        Reads nothing and calls no az. It is the plan-time half of Get-AzlSecretPlainTextAzureCli, so that -WhatIf refuses a bad reference too.
        The message names the reference (a keyvault:// reference is a name, not a secret), and for a text that is not a reference only its length.
    .PARAMETER Reference
        keyvault://<vault>/<secret>[/<version>], env://<VARIABLE>, file://<name> or command://<name>.
    .PARAMETER Infrastructure
        The loaded infrastructure file (Import-AzlInfrastructure).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Infrastructure
    )
    if ($null -eq $Infrastructure) { Stop-AzlSecretAzureCli -Category NotConfigured -Message 'The infrastructure file is needed to read a secret reference, and none was given.' -Exit 2 }
    $provider = Get-AzlSecretProvider -Reference $Reference
    if (-not $provider) {
        $length = if ($null -eq $Reference) { 0 } else { $Reference.Length }
        Stop-AzlSecretAzureCli -Category InvalidReference -Message "The value ($length characters) is not a secret reference. A reference is keyvault://<vault>/<secret>, env://<VARIABLE>, file://<name> or command://<name>. A secret value must never be written where a reference is expected." -Exit 2
    }
    if ($provider -ne 'keyvault') { return }
    $m = [regex]::Match($Reference, $script:KeyVaultForm, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { Stop-AzlSecretAzureCli -Category InvalidReference -Message "$Reference is not a valid keyvault:// reference (keyvault://<vault>/<secret>)." -Exit 2 }
    $vault = $m.Groups['vault'].Value
    $listed = @(Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path 'key_vaults' | ForEach-Object { $_ } | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('name') } | ForEach-Object { [string]$_['name'] })
    if ($vault -notin $listed) { Stop-AzlSecretAzureCli -Category VaultNotListed -Message "$Reference names vault $vault, which is not listed under key_vaults in the infrastructure file. Add the vault there first." -Exit 2 }
}

function Get-AzlSecretPlainTextAzureCli {
    <#
    .SYNOPSIS
        The secret a reference points to, as plain text, read with the Azure CLI when the reference is a keyvault:// reference.
    .DESCRIPTION
        Only for a caller that must put the value in an az argument. The caller must not log, write or return it, and must not keep it longer than the call needs.
    .PARAMETER Reference
        keyvault://<vault>/<secret>[/<version>], env://<VARIABLE>, file://<name> or command://<name>.
    .PARAMETER Infrastructure
        The loaded infrastructure file (Import-AzlInfrastructure). It holds key_vaults and the secrets section.
    .PARAMETER Az
        A script block that starts az with the argument list it is given, for example { param([string[]]$AzArguments) & az @AzArguments 2>$null }.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Reference,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary]$Infrastructure,
        [Parameter(Mandatory)][scriptblock]$Az
    )
    Assert-AzlSecretReferenceAzureCli -Reference $Reference -Infrastructure $Infrastructure
    if ((Get-AzlSecretProvider -Reference $Reference) -ne 'keyvault') {
        $plain = Get-AzlSecretPlainText -Reference $Reference -Infrastructure $Infrastructure
        Assert-AzlAzureCliSecret -Name $Reference -Value ([string]$plain)
        return $plain
    }

    $m = [regex]::Match($Reference, $script:KeyVaultForm, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $vault = $m.Groups['vault'].Value
    $secretName = $m.Groups['secret'].Value
    $arguments = @('keyvault', 'secret', 'show', '--vault-name', $vault, '--name', $secretName)
    if ($m.Groups['version'].Success) { $arguments += '--version'; $arguments += $m.Groups['version'].Value }
    $arguments += @('--query', 'value', '--output', 'tsv')
    $unsafe = Get-AzlAzureCliArgumentProblem -Argument $arguments
    if ($unsafe) { Stop-AzlSecretAzureCli -Category InvalidReference -Message "${Reference}: $unsafe" -Exit 2 }
    $output = @(& $Az $arguments)
    if ($LASTEXITCODE -ne 0) {
        Stop-AzlSecretAzureCli -Category KeyVaultError -Message "The secret of $Reference could not be read with az (exit code $LASTEXITCODE). Check the secret name, the role Key Vault Secrets User on vault $vault and the sign-in."
    }
    $text = (($output | ForEach-Object { "$_" }) -join "`n").TrimEnd("`r", "`n")
    if (-not $text) { Stop-AzlSecretAzureCli -Category EmptySecret -Message "$Reference is empty." }
    Assert-AzlAzureCliSecret -Name $Reference -Value $text
    return $text
}

Export-ModuleMember -Function Get-AzlSecretPlainTextAzureCli, Assert-AzlSecretReferenceAzureCli

#Requires -Version 7.0
<#
.SYNOPSIS
    The one check that every Azure CLI script of the toolkit (*.azcli.ps1) makes on the arguments it hands to az.

.DESCRIPTION
    Why. On Windows az is a batch file (az.cmd). PowerShell 7.4 passes an argument that holds no space to a batch file without quotes, so cmd.exe reads
    the characters & | < > ^ in it as its own operators (an argument "a&b" cuts the command at the &, and the rest runs as a command), and it expands %NAME%
    as a variable. A double quote or a line break breaks the argument in the same way (Microsoft Learn: Considerations for running the Azure CLI in a
    PowerShell scripting language). A tag value, a name, a display name, an e-mail address or a secret that holds one of these characters could therefore cut
    an argument, run a part of it as a command, or leak a part of a secret into an error text.

    The rule of the toolkit: no argument that holds one of  &  |  <  >  ^  %  "  or a line break (CR, LF) ever reaches az. The scripts refuse it with exit
    code 2 before they call Azure. They check twice:

      1. At plan time, right after the file is read (Get-AzlAzureCliValueProblem), so that -WhatIf refuses too, and the message names the key and the value.
      2. In the one function of each script that starts az (Get-AzlAzureCliArgumentProblem), as the last line of defence. That message names the position of the
         argument and the option before it, never the value: an argument may carry a secret.

    A secret read from a reference (Get-AzlSecretPlainTextAzureCli in scripts/common/secrets/AzlSecretAzureCli.psm1) is checked right after the read with
    Assert-AzlAzureCliSecret. A message about a secret names the reference, never the value, and does not say which character it holds.

    Functions
        Test-AzlAzureCliSafeValue          text -> $true when it holds none of the characters
        Get-AzlAzureCliArgumentProblem     argument list -> the message for the first unsafe argument (position and option only), or $null
        Get-AzlAzureCliValueProblem        name-to-value table (values may be text, lists or maps) -> the message for the first unsafe value, or $null
        Assert-AzlAzureCliSecret           name + secret text -> throws (AzlExit 2) when the text is unsafe; the message never holds the text
        Get-AzlAzureCliLauncher            how to start az so that a value with a parenthesis survives az.cmd (the Python of the Azure CLI on Windows)
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# & | < > ^ % " and the two line-break characters.
$script:UnsafeCharacter = '[&|<>^%"\r\n]'
$script:UnsafeList = '& | < > ^ % " or a line break'

function Test-AzlAzureCliSafeValue {
    <#
    .SYNOPSIS
        $true when the text holds none of & | < > ^ % " CR LF. A null or empty text is safe.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][object]$Value)
    if ($null -eq $Value) { return $true }
    return ("$Value" -notmatch $script:UnsafeCharacter)
}

function Get-AzlAzureCliArgumentProblem {
    <#
    .SYNOPSIS
        The message for the first argument of an az call that holds an unsafe character, or $null when every argument is safe.
    .DESCRIPTION
        The message names the position (counting from 1) and the option before it (for example --tags). It never holds the argument: it may be a secret.
    .PARAMETER Argument
        The arguments that would follow az. Lists are flattened; each element is read as text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyCollection()][object]$Argument)
    $items = @($Argument | ForEach-Object { $_ } | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } })
    $option = ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $text = $items[$i]
        if ($text -match $script:UnsafeCharacter) {
            $where = if ($option -and -not $text.StartsWith('-')) { " (the value of $option)" } else { '' }
            return "Argument $($i + 1) of an az call$where holds one of $($script:UnsafeList). On Windows az is a batch file (az.cmd) and cmd.exe would read it as an operator or a variable, so the call was not made. The value is not shown. Remove the character from the value in infrastructure.yml."
        }
        if ($text.StartsWith('--')) { $option = $text }
    }
    return $null
}

function Get-AzlAzureCliValueProblem {
    <#
    .SYNOPSIS
        The message for the first value of a table that holds an unsafe character, or $null. For values read from infrastructure.yml (not secrets).
    .DESCRIPTION
        The table maps a name (the key in the file, for example azure.resource_group) to a value. A value may be text, a list (each element is checked, the name
        gets the position) or a map (each key and each value is checked, the name gets the key). The message names the name and shows the value: a value of the
        file is not a secret. Use -Secret for a value that is, and the message leaves the value out.
    .PARAMETER Value
        Name-to-value table.
    .PARAMETER Secret
        Leave the value and the character out of the message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Value, [switch]$Secret)
    foreach ($name in $Value.Keys) {
        foreach ($item in (Get-AzlAzureCliFlatValue -Name ([string]$name) -Value $Value[$name])) {
            if ($item.Text -match $script:UnsafeCharacter) {
                if ($Secret) { return "$($item.Name) holds one of $($script:UnsafeList), which the Azure CLI cannot carry safely on Windows (az.cmd). The value is not shown." }
                $shown = ($item.Text -replace "`r", '\r') -replace "`n", '\n'
                return "$($item.Name) holds the value '$shown', which has one of $($script:UnsafeList). On Windows az is a batch file (az.cmd) and cmd.exe would read it as an operator or a variable, so nothing was sent to Azure. Remove the character from the value in infrastructure.yml."
            }
        }
    }
    return $null
}

function Get-AzlAzureCliFlatValue {
    # Expands a value into (name, text) pairs: a list gives name[i], a map gives name.key for the key and for the value.
    [CmdletBinding()]
    param([string]$Name, [AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            [pscustomobject]@{ Name = "$Name key '$k'"; Text = [string]$k }
            Get-AzlAzureCliFlatValue -Name "$Name.$k" -Value $Value[$k]
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $i = 0
        foreach ($element in $Value) { Get-AzlAzureCliFlatValue -Name "$Name[$i]" -Value $element; $i++ }
        return
    }
    [pscustomobject]@{ Name = $Name; Text = [string]$Value }
}

function Assert-AzlAzureCliSecret {
    <#
    .SYNOPSIS
        Throws when a secret holds a character that cannot go in an az argument. The error holds the name of the reference, never the value.
    .DESCRIPTION
        The exception carries Data['AzlSecretError'] = 'UnsafeCharacter' and Data['AzlExit'] = 2, as the errors of AzlSecret.psm1 do.
    .PARAMETER Name
        What the secret is called in a message: the reference (keyvault://vault/name) or the key of the file.
    .PARAMETER Value
        The secret text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -ne $Value -and $Value -match $script:UnsafeCharacter) {
        $e = [System.InvalidOperationException]::new("The secret of $Name holds one of $($script:UnsafeList). On Windows the Azure CLI (az.cmd) cannot carry such a character in an argument safely, so the secret was not used. Create the secret again without these characters. The value is not shown.")
        $e.Data['AzlSecretError'] = 'UnsafeCharacter'
        $e.Data['AzlExit'] = 2
        throw $e
    }
}

function Get-AzlAzureCliLauncher {
    <#
    .SYNOPSIS
        How to start the Azure CLI so that a value with a parenthesis survives: the Python of the Azure CLI itself on Windows, az everywhere else.
    .DESCRIPTION
        On Windows az is the batch file az.cmd, and it starts Python inside a parenthesised IF block (IF EXIST python.exe ( python.exe -IBm azure.cli %* ) ELSE ...).
        cmd.exe reads a closing parenthesis in an argument as the end of that block, so an argument such as the virtual switch name Network ATC gives
        (ComputeSwitch(compute)) ends the call with "... was unexpected at this time." before the Azure CLI starts. Seen on a live instance: no logical
        network could be created on a switch that Network ATC named. A script that must hand such a value to az starts the same Python the batch file starts,
        with the same arguments (-IBm azure.cli), and cmd.exe is not involved.

        Command is what to start and Prefix the arguments that come before the az arguments:
            $launcher = Get-AzlAzureCliLauncher -Command (Get-Command -Name az -ErrorAction SilentlyContinue | Select-Object -First 1)
            $all = @($launcher.Prefix) + @($azArguments)
            & $launcher.Command @all
        Give -Command from the script: the lookup then happens in the scope of the script, where a function or an alias named az (a test) is visible.
        When az is not the batch file of the Windows installer (Linux, macOS, a function or an alias named az, as in the tests), Command is 'az' and Prefix is empty.
        The rule for & | < > ^ % and the double quote (Get-AzlAzureCliArgumentProblem) stays as it is: it does not depend on how az is started.
    .PARAMETER Command
        For tests: the command object to decide from, instead of Get-Command az.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([object]$Command = (Get-Command -Name az -ErrorAction SilentlyContinue | Select-Object -First 1))
    if ($Command -and [string]$Command.CommandType -eq 'Application' -and [string]$Command.Source -match '\.(cmd|bat)$') {
        $python = [IO.Path]::GetFullPath([IO.Path]::Combine((Split-Path -Parent ([string]$Command.Source)), '..', 'python.exe'))
        if (Test-Path -LiteralPath $python -PathType Leaf) { return [pscustomobject]@{ Command = $python; Prefix = @('-IBm', 'azure.cli'); Direct = $true; BatchFile = $false } }
        # A batch file without the Python of the Windows installer next to it: az is started as it is, and a parenthesis cannot be carried.
        return [pscustomobject]@{ Command = 'az'; Prefix = @(); Direct = $false; BatchFile = $true }
    }
    [pscustomobject]@{ Command = 'az'; Prefix = @(); Direct = $false; BatchFile = $false }
}

function Get-AzlAzureCliParenthesisProblem {
    <#
    .SYNOPSIS
        The message when an argument holds a parenthesis and az can only be started as a batch file, or $null. The value is not shown.
    .DESCRIPTION
        Get-AzlAzureCliLauncher starts the Python of the Azure CLI when it finds it. When az is a batch file and that Python is not where the
        Windows installer puts it, the batch file is all there is, and cmd.exe would end it at a closing parenthesis. A script that may hand
        such a value to az calls this before the call and stops with the message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Launcher, [AllowNull()][AllowEmptyCollection()][object]$Argument)
    if (-not $Launcher.BatchFile) { return $null }
    $items = @($Argument | ForEach-Object { $_ } | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } })
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i] -match '[()]') {
            return "Argument $($i + 1) of an az call holds a parenthesis. Here az is a batch file (az.cmd) and the Python of the Azure CLI was not found next to it, so cmd.exe would end the call at the parenthesis and the call was not made. Install the Azure CLI with the Windows installer (MSI), or run the script where az is not a batch file. The value is not shown."
        }
    }
    return $null
}

Export-ModuleMember -Function Test-AzlAzureCliSafeValue, Get-AzlAzureCliArgumentProblem, Get-AzlAzureCliValueProblem, Assert-AzlAzureCliSecret, Get-AzlAzureCliLauncher, Get-AzlAzureCliParenthesisProblem

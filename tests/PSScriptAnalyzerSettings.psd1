@{
    # PSScriptAnalyzer settings for azurelocal-toolkit
    # See: https://github.com/PowerShell/PSScriptAnalyzer/blob/master/docs/

    IncludeDefaultRules = $true

    ExcludeRules = @(
        # Scripts use Write-Host intentionally for console-formatted log output.
        # The logging.ps1 helper wraps Write-Host with level/timestamp formatting.
        'PSAvoidUsingWriteHost',

        # Internal helper functions (logging, error-handling) do not expose
        # ShouldProcess because they are not state-changing entry points.
        'PSUseShouldProcessForStateChangingFunctions',

        # Computed property names are used in hashtable constructions for
        # dynamic config key resolution in config-loader.ps1.
        'PSUseOutputTypeCorrectly',

        # Several scripts (keyvault-helper.ps1, Stop-AzureLocalCluster.ps1,
        # Get-DellServerInventory-FromiDRAC.ps1) accept credentials as
        # SecureString parameters passed in at runtime. ConvertTo-SecureString
        # is used only to convert caller-supplied values — not to embed
        # plaintext secrets in source code.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )

    Rules = @{
        # Enforce consistent indentation
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind            = 'space'
        }

        # Enforce consistent whitespace
        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $true
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        # Require .SYNOPSIS in all functions
        PSProvideCommentHelp = @{
            Enable                  = $true
            ExportedOnly            = $false
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'before'
        }

        # Enforce approved verb usage
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # Avoid aliases in scripts
        PSAvoidUsingCmdletAliases = @{
            Enable   = $true
            Whitelist = @('cd', 'ls')
        }

        # Avoid positional parameters for clarity
        PSAvoidUsingPositionalParameters = @{
            Enable      = $true
            CommandName = @('*')
        }
    }
}

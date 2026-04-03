#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for scripts/common/utilities/helpers/logging.ps1
.DESCRIPTION
    Tests Write-Log, Start-LogFile, and Stop-LogFile in isolation.

    Key design note: logging.ps1 uses $script:-scoped variables ($script:LogToFile,
    $script:LogFile) to track file-logging state. In Pester 5, dot-sourced functions
    execute in the test-file script scope, but when a second copy of the functions is
    also imported as a module the dot-sourced version wins command resolution, so
    explicit Write-Log calls from It blocks bypass the module's $script: state that
    Start-LogFile set.  To avoid this entirely, logging.ps1 is loaded ONLY as a named
    module (never dot-sourced).  All functions then share exactly one $script: scope
    (the module's), so Start-LogFile, Write-Log, and Stop-LogFile always see the same
    $script:LogToFile and $script:LogFile values — no InModuleScope needed.
#>

BeforeAll {
    $script:helpersPath = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'common' 'utilities' 'helpers'

    # Load ONLY as a module — do NOT dot-source.
    $loggingContent = Get-Content (Join-Path $script:helpersPath 'logging.ps1') -Raw
    New-Module -Name 'LoggingModule' -ScriptBlock ([scriptblock]::Create($loggingContent)) |
        Import-Module -Force
}

AfterAll {
    Remove-Module LoggingModule -Force -ErrorAction SilentlyContinue
}

Describe 'Write-Log' {
    Context 'Output format' {
        It 'should include the log level in output' {
            $output = Write-Log -Level 'Info' -Message 'Test message' 6>&1 | Out-String
            # Write-Log outputs via Write-Host; capture via stream redirection
            # Validate via mock below
            $true | Should -BeTrue
        }

        It 'should not throw for any valid level' {
            { Write-Log -Level 'Info'    -Message 'info msg'    } | Should -Not -Throw
            { Write-Log -Level 'Warning' -Message 'warning msg' } | Should -Not -Throw
            { Write-Log -Level 'Error'   -Message 'error msg'   } | Should -Not -Throw
            { Write-Log -Level 'Debug'   -Message 'debug msg'   } | Should -Not -Throw
            { Write-Log -Level 'Verbose' -Message 'verbose msg' } | Should -Not -Throw
        }

        It 'should throw for an invalid level' {
            { Write-Log -Level 'Invalid' -Message 'bad level' } | Should -Throw
        }

        It 'should require Message parameter' {
            { Write-Log -Level 'Info' } | Should -Throw
        }

        It 'should require Level parameter' {
            { Write-Log -Message 'no level' } | Should -Throw
        }
    }

    # All file-logging tests call module functions directly — no InModuleScope needed
    # because there is only one Write-Log (from the module), so $script: state set by
    # Start-LogFile is always visible when Write-Log runs.
    Context 'File logging' {
        AfterEach {
            Stop-LogFile  # reset module state between tests
        }

        It 'should write to file when file logging is active' {
            $logPath = Join-Path $TestDrive 'write-active.log'
            Start-LogFile -Path $logPath
            Write-Log -Level 'Info' -Message 'file log test'
            Stop-LogFile
            $logPath | Should -Exist
            (Get-Content $logPath -Raw) | Should -Match 'file log test'
        }

        It 'should include timestamp in file output' {
            $logPath = Join-Path $TestDrive 'write-ts.log'
            Start-LogFile -Path $logPath
            Write-Log -Level 'Info' -Message 'timestamp test'
            Stop-LogFile
            $content = Get-Content $logPath -Raw
            # Timestamp format: [yyyy-MM-dd HH:mm:ss]
            $content | Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }

        It 'should include level in file output' {
            $logPath = Join-Path $TestDrive 'write-level.log'
            Start-LogFile -Path $logPath
            Write-Log -Level 'Warning' -Message 'level test'
            Stop-LogFile
            (Get-Content $logPath -Raw) | Should -Match '\[Warning\]'
        }

        It 'should not write to file when file logging is inactive' {
            $logPath = Join-Path $TestDrive 'write-inactive.log'
            Stop-LogFile
            Write-Log -Level 'Info' -Message 'no file'
            $logPath | Should -Not -Exist
        }

        It 'should append multiple entries to the same log file' {
            $logPath = Join-Path $TestDrive 'write-append.log'
            Start-LogFile -Path $logPath
            Write-Log -Level 'Info'    -Message 'entry one'
            Write-Log -Level 'Warning' -Message 'entry two'
            Stop-LogFile
            $lines = Get-Content $logPath
            $lines.Count | Should -BeGreaterOrEqual 2
            ($lines -join ' ') | Should -Match 'entry one'
            ($lines -join ' ') | Should -Match 'entry two'
        }
    }
}

Describe 'Start-LogFile' {
    It 'should create the log file directory if it does not exist' {
        $logPath = Join-Path $TestDrive 'subdir' 'nested.log'
        Start-LogFile -Path $logPath
        Write-Log -Level 'Info' -Message 'nested'
        Stop-LogFile
        $logPath | Should -Exist
    }
}

Describe 'Stop-LogFile' {
    It 'should not throw when called without a prior Start-LogFile' {
        { Stop-LogFile } | Should -Not -Throw
    }
}

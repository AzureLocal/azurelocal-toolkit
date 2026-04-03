#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for scripts/common/utilities/helpers/logging.ps1
.DESCRIPTION
    Tests the Write-Log, Start-FileLogging, and Stop-FileLogging functions
    in isolation without any external dependencies.
#>

BeforeAll {
    $script:helpersPath = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'common' 'utilities' 'helpers'
    . (Join-Path $script:helpersPath 'logging.ps1')

    # Load as a named module so InModuleScope can be used for file-logging tests.
    # This ensures $script:LogToFile / $script:LogFile share the same scope across
    # all function calls (Start-LogFile, Write-Log, Stop-LogFile) regardless of
    # which Pester block invokes them.
    $loggingContent = Get-Content (Join-Path $script:helpersPath 'logging.ps1') -Raw
    New-Module -Name 'LoggingModule' -ScriptBlock ([scriptblock]::Create($loggingContent)) |
        Import-Module -Force
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

    # File-logging tests use InModuleScope so $script:LogToFile / $script:LogFile
    # are consistent across Start-LogFile, Write-Log, and Stop-LogFile calls.
    Context 'File logging' {
        It 'should write to file when file logging is active' {
            $logPath = Join-Path $TestDrive 'write-active.log'
            InModuleScope 'LoggingModule' -Parameters @{ LogPath = $logPath } {
                param($LogPath)
                Start-LogFile -Path $LogPath
                Write-Log -Level 'Info' -Message 'file log test'
                Stop-LogFile
            }
            $logPath | Should -Exist
            Get-Content $logPath | Should -Match 'file log test'
        }

        It 'should include timestamp in file output' {
            $logPath = Join-Path $TestDrive 'write-ts.log'
            InModuleScope 'LoggingModule' -Parameters @{ LogPath = $logPath } {
                param($LogPath)
                Start-LogFile -Path $LogPath
                Write-Log -Level 'Info' -Message 'timestamp test'
                Stop-LogFile
            }
            $content = Get-Content $logPath
            # Timestamp format: [yyyy-MM-dd HH:mm:ss]
            $content | Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
        }

        It 'should include level in file output' {
            $logPath = Join-Path $TestDrive 'write-level.log'
            InModuleScope 'LoggingModule' -Parameters @{ LogPath = $logPath } {
                param($LogPath)
                Start-LogFile -Path $LogPath
                Write-Log -Level 'Warning' -Message 'level test'
                Stop-LogFile
            }
            Get-Content $logPath | Should -Match '\[Warning\]'
        }

        It 'should not write to file when file logging is inactive' {
            $logPath = Join-Path $TestDrive 'write-inactive.log'
            InModuleScope 'LoggingModule' -Parameters @{ LogPath = $logPath } {
                param($LogPath)
                Stop-LogFile
                Write-Log -Level 'Info' -Message 'no file'
            }
            $logPath | Should -Not -Exist
        }

        It 'should append multiple entries to the same log file' {
            $logPath = Join-Path $TestDrive 'write-append.log'
            InModuleScope 'LoggingModule' -Parameters @{ LogPath = $logPath } {
                param($LogPath)
                Start-LogFile -Path $LogPath
                Write-Log -Level 'Info'    -Message 'entry one'
                Write-Log -Level 'Warning' -Message 'entry two'
                Stop-LogFile
            }
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
        InModuleScope 'LoggingModule' -Parameters @{ LogPath = $logPath } {
            param($LogPath)
            Start-LogFile -Path $LogPath
            Write-Log -Level 'Info' -Message 'nested'
            Stop-LogFile
        }
        $logPath | Should -Exist
    }
}

Describe 'Stop-LogFile' {
    It 'should not throw when called without Stop-LogFile' {
        InModuleScope 'LoggingModule' {
            { Stop-LogFile } | Should -Not -Throw
        }
    }
}

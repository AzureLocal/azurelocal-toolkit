# Testing Framework — azurelocal-toolkit

This directory contains the Pester 5 test suite and PSScriptAnalyzer configuration for the `azurelocal-toolkit` PowerShell scripts.

## Structure

```text
tests/
├── README.md                       # This file
├── PSScriptAnalyzerSettings.psd1   # PSScriptAnalyzer rule configuration
├── Unit/
│   └── Helpers/
│       ├── logging.Tests.ps1           # Tests for scripts/common/utilities/helpers/logging.ps1
│       ├── error-handling.Tests.ps1    # Tests for scripts/common/utilities/helpers/error-handling.ps1
│       └── config-loader.Tests.ps1     # Tests for scripts/common/utilities/helpers/config-loader.ps1
└── Quality/
    ├── ScriptQuality.Tests.ps1         # PSScriptAnalyzer static analysis for all scripts
    └── ScriptStructure.Tests.ps1       # Structural compliance tests (headers, CmdletBinding, etc.)
```

## Prerequisites

```powershell
# Install required modules
Install-Module -Name Pester        -MinimumVersion 5.5.0  -Scope CurrentUser -Force
Install-Module -Name PSScriptAnalyzer -MinimumVersion 1.21.0 -Scope CurrentUser -Force
Install-Module -Name powershell-yaml  -MinimumVersion 0.4.7  -Scope CurrentUser -Force
```

## Running Tests

### All tests

```powershell
# From the repository root
Invoke-Pester -Path ./tests/ -Output Detailed
```

### Unit tests only

```powershell
Invoke-Pester -Path ./tests/Unit/ -Output Detailed
```

### Quality/linting tests only

```powershell
Invoke-Pester -Path ./tests/Quality/ -Output Detailed
```

### Using the QA runner script

```powershell
# Run all tests and generate a report
./scripts/tools/Test-ScriptQuality.ps1

# Run only quality checks with verbose output
./scripts/tools/Test-ScriptQuality.ps1 -TestType Quality -Verbose

# Run unit tests with CI output format
./scripts/tools/Test-ScriptQuality.ps1 -TestType Unit -OutputFormat NUnitXml -OutputPath ./logs/test-results.xml
```

## Test Conventions

- Test files use the `.Tests.ps1` suffix (Pester convention)
- `Describe` blocks mirror the function or module under test
- `Context` blocks group related scenarios
- `It` descriptions are written as specifications: *"should [expected behaviour]"*
- Tests must not write to the filesystem or make real Azure API calls
- Use `Mock` to isolate external dependencies

## PSScriptAnalyzer Rules

See `PSScriptAnalyzerSettings.psd1` for the full rule set. Key exclusions:
- `PSAvoidUsingWriteHost` — excluded because scripts use `Write-Host` intentionally for console-formatted output (logging.ps1 provides the abstraction)
- `PSUseShouldProcessForStateChangingFunctions` — excluded for internal/private helper functions

## CI Integration

The GitHub Actions workflow `.github/workflows/test-scripts.yml` runs on every push and Pull Request that touches `scripts/**` or `tests/**`. Tests run on `ubuntu-latest` using PowerShell 7.

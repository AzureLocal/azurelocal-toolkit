# GitHub Actions — azurelocal-toolkit

> This document describes every GitHub Actions workflow in this repository:
> what it does, why it exists, what it requires, and what must be replicated
> when setting up a new repository in this organisation.

---

## Workflow Index

| File | Name | Trigger | Purpose |
|------|------|---------|---------|
| `test-scripts.yml` | Test Scripts | push/PR to `scripts/` or `tests/` | Runs Pester unit tests + PSScriptAnalyzer quality checks |
| `add-to-project.yml` | Add to Project | issue or PR opened/labeled | Adds items to the GitHub Project board and sets custom fields |
| `validate-config.yml` | Validate Configuration | push/PR to `config/` | Validates YAML syntax and registry compliance |
| `validate-repo-structure.yml` | Validate Repo Structure | PR to `main` | Checks required root files, directories, and PR template exist |
| `release-please.yml` | Release Please | push to `main` | Automates CHANGELOG and release PR creation |

---

## test-scripts.yml

**File:** `.github/workflows/test-scripts.yml`

### What it does

Runs in two sequential steps:

1. **Unit tests** — Pester 5 tests in `tests/Unit/` covering `logging.ps1`, `error-handling.ps1`, and `config-loader.ps1`
2. **Quality tests** — PSScriptAnalyzer tests in `tests/Quality/` running static analysis against every `.ps1` file under `scripts/`

Both steps produce NUnit XML test result artifacts uploaded to the run summary.

### When it triggers

- Push to `main` that touches `scripts/**`, `tests/**`, or the workflow file itself
- Pull request to `main` that touches `scripts/**` or `tests/**`
- Manual `workflow_dispatch`

### Why it exists

Prevents scripts with broken function signatures, missing parameters, or PSScriptAnalyzer `Error` violations from being merged to `main`. Created as part of issue #19.

### Secrets required

None — uses only `GITHUB_TOKEN` (read-only, implicit).

### PSScriptAnalyzer settings

Settings file: `tests/PSScriptAnalyzerSettings.psd1`

Excluded rules (with reasons):

| Rule | Reason |
|------|--------|
| `PSAvoidUsingWriteHost` | `logging.ps1` uses `Write-Host` intentionally for colour-formatted console output |
| `PSUseShouldProcessForStateChangingFunctions` | Internal helpers are not public entry points |
| `PSUseOutputTypeCorrectly` | Dynamic config key resolution uses computed hashtable properties |
| `PSAvoidUsingConvertToSecureStringWithPlainText` | `keyvault-helper.ps1`, `Stop-AzureLocalCluster.ps1`, and `Get-DellServerInventory-FromiDRAC.ps1` accept credentials as runtime parameters — `ConvertTo-SecureString` converts caller-supplied values, it does not embed plaintext secrets |

### Modules installed by CI

| Module | Min version |
|--------|-------------|
| Pester | 5.0.0 |
| PSScriptAnalyzer | 1.21.0 |
| powershell-yaml | latest |

### Replication requirements

When adding this workflow to a new repo:
- Copy `test-scripts.yml`, `tests/PSScriptAnalyzerSettings.psd1`
- Adjust `$config.Run.Path` to match the new repo's test directory layout
- Review `ExcludeRules` — keep only the exclusions that apply to that repo's scripts

---

## add-to-project.yml

**File:** `.github/workflows/add-to-project.yml`

### What it does

Two jobs:

1. **add-to-project** — Adds any new or labeled issue/PR to the AzureLocal GitHub Project (project `#3`)
2. **set-fields** — Reads the issue labels and sets three custom project fields:
   - **Solution** — which AzureLocal solution this item belongs to (mapped from `solution/*` labels)
   - **Priority** — critical / high / medium / low (mapped from `priority/*` labels)
   - **Category** — feature / bug / docs / infra / refactor / security (mapped from `type/*` labels)

### When it triggers

- Issue opened or labeled
- Pull request opened or labeled

### Why it exists

Keeps the GitHub Project board automatically populated without needing manual triage. All repos in the organisation use this same workflow so every issue/PR lands in the shared board with correct metadata immediately.

### Secrets required

| Secret | Value | Why |
|--------|-------|-----|
| `ADD_TO_PROJECT_PAT` | Personal Access Token with `project` scope | `GITHUB_TOKEN` does not have access to organisation-level Projects — a PAT is required |

**This secret must be set at the repository level before this workflow will function.**
To create: GitHub → Settings → Secrets and variables → Actions → New repository secret → `ADD_TO_PROJECT_PAT`

The PAT must belong to an account that has write access to the organisation project.

### Project and field IDs

These IDs are hardcoded in the workflow. They point to the single shared AzureLocal org project:

| Variable | ID |
|----------|----|
| `PROJECT_ID` | `PVT_kwDOCxeiOM4BR2KZ` |
| `SOLUTION_FIELD` | `PVTSSF_lADOCxeiOM4BR2KZzg_jXuY` |
| `PRIORITY_FIELD` | `PVTSSF_lADOCxeiOM4BR2KZzg_jXvs` |
| `CATEGORY_FIELD` | `PVTSSF_lADOCxeiOM4BR2KZzg_jXxA` |
| `ID_FIELD` | `PVTF_lADOCxeiOM4BR2KZzhADImQ` |

### Replication requirements

When adding this workflow to a new repo:
- Copy `add-to-project.yml` verbatim — the project/field IDs are org-wide and do not change
- Add the `ADD_TO_PROJECT_PAT` secret to the new repository
- Verify the `solution/*` label option IDs cover the new repo's solution — add a new `elif` block if the repo represents a solution not already listed

---

## validate-config.yml

**File:** `.github/workflows/validate-config.yml`

### What it does

Validates the `config/` directory:

1. Checks `config/variables/variables.example.yml` is valid YAML
2. Runs `config/variables/scripts/validate-registry.ps1` — verifies the master variable registry structure
3. Runs `config/variables/scripts/validate-variables.ps1 -StrictUnknown` — checks variable definitions against schema, rejects unknown keys
4. Runs `config/variables/scripts/check-alias-expiry.ps1` — flags alias variables past their expiry date

### When it triggers

- Push to `main` that touches `config/**` or the workflow file itself
- Pull request to `main` that touches `config/**`
- Manual `workflow_dispatch`

### Why it exists

The `config/variables/` directory defines variables consumed by deployment scripts. Invalid YAML or schema violations would silently break deployments at runtime. This workflow catches those errors at PR time.

### Secrets required

None.

### Replication requirements

When adding this workflow to a new repo:
- Only applicable to repos that have a `config/variables/` directory with a registry, schema, and validation scripts
- If the new repo has config but a simpler structure, strip down to just the YAML syntax check step

---

## validate-repo-structure.yml

**File:** `.github/workflows/validate-repo-structure.yml`

### What it does

On every PR to `main`, verifies the repository has the minimum required structure:

- **Required root files:** `README.md`, `CONTRIBUTING.md`, `LICENSE`, `CHANGELOG.md`, `.gitignore`
- **Required directories:** `.github/`
- **PR template:** `.github/PULL_REQUEST_TEMPLATE.md`
- **Config structure (if `config/` exists):** `config/variables.example.yml` and `config/schema/variables.schema.json`

### When it triggers

- Pull request to `main` only

### Why it exists

Prevents PRs from accidentally deleting or renaming required files. Acts as a minimum governance gate on every merge.

### Secrets required

None.

### Replication requirements

Copy verbatim to every new repo. No changes needed.

---

## release-please.yml

**File:** `.github/workflows/release-please.yml`

### What it does

When a commit lands on `main`, Release Please:

1. Inspects conventional commit messages since the last release tag
2. Creates or updates a "Release PR" that bumps `CHANGELOG.md` and the version
3. When that Release PR is merged, creates a GitHub Release and git tag

### When it triggers

- Every push to `main`

### Why it exists

Automates versioning and changelog management. Commit messages following the Conventional Commits format (`feat:`, `fix:`, `docs:`, `chore:`, etc.) are automatically sorted into the correct changelog sections.

### Secrets required

None — uses `GITHUB_TOKEN` with `contents: write` and `pull-requests: write` permissions (granted in the workflow permissions block).

### Configuration

Release Please is configured by `release-please-config.json` at the repo root. This file controls:
- Release type (default: `simple`)
- Changelog sections
- Version file locations

### Replication requirements

- Copy `release-please.yml` verbatim
- Copy `release-please-config.json` from an existing repo and adjust version file paths if needed
- Ensure branch protection does not block the `release-please--branches--main--components--*` PR from being created by the GitHub Actions bot

---

## Secrets Summary

| Secret | Required by | Scope |
|--------|-------------|-------|
| `ADD_TO_PROJECT_PAT` | `add-to-project.yml` | Must be set per-repo |
| `GITHUB_TOKEN` | All others | Automatic — provided by GitHub Actions |

---

## Label Requirements

For `add-to-project.yml` to set fields correctly, the repo must use the standard AzureLocal label set. Labels are defined in `.github/labels.yml` (managed via `sync-labels.yml` on the `azurelocal.github.io` repo).

Required label prefixes:
- `solution/*` — identifies which AzureLocal solution
- `priority/*` — critical, high, medium, low
- `type/*` — feature, bug, docs, infra, refactor, security

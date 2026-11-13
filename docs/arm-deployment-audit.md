# ARM Validate and Deploy automation: audit

**Date:** 2026-11-07. **Scope:** what the toolkit has today for validating and deploying an Azure Local instance through
the ARM deployment (Microsoft's quickstart templates, `Microsoft.AzureStackHCI/clusters` with `deploymentSettings`), what is
real and what is a scaffold, what the documentation promises, and what is missing. **Baseline:** `origin/main` of
azurelocal-toolkit at `05eb0e0` (schema 5.4). The work that closes the gaps is described in
[design/arm-validate-deploy.md](design/arm-validate-deploy.md).

**How to read the tables.** *Real* means the code does what it says and has tests that run without Azure. *Scaffold* means
the file exists, runs, and logs "this is a scaffold" instead of doing the task. *Legacy* means it reads the older
`variables.yml` layout and calls a generator that is not in the repository. Nothing here was run against Azure; the audit
reads code, tests and documents.

---

## 1. What exists in the toolkit

### 1.1 Real (schema 5 path)

| Component | Path | What it does | Tests | Notes |
| --- | --- | --- | --- | --- |
| Entry point | `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalClusterDeployment.ps1` | Plan (default) writes and prints the parameter set; `-Execute -Mode Validate` or `Deploy` submits and waits | Module is tested, the script is not | One mode per run; no events, no report, no exit code 2, no approval, no resume |
| Parameters only | `.../New-AzureLocalArmParameters.ps1` | Writes the ARM parameter file from `infrastructure.yml` (no Azure call) | Module is tested | Always safe |
| Module | `scripts/common/arm-deployment/AzlArmDeployment.psm1` | `Select-AzlArmTemplate`, `New-AzlArmParameterSet`, `Test-AzlArmParameterSet`, `ConvertTo-AzlArmParameterFile`, `Get-AzlDeploymentState`, `Invoke-AzlArmDeployment` | `tests/arm-deployment/ArmDeployment.Tests.ps1` (40 test blocks) | The parameter generation is solid: 7 quickstart templates in the catalog, 6 selectable; adapter names by MAC; SAN LUN translation; secrets stay `keyvault://` references |
| Template catalog | `config/azure/arm-templates/template-parameters.json` | Each template's parameters, types, allowed values, and `deploymentSettings` api-version | Used by the tests | Source: Microsoft's quickstart repository, retrieved by hand |
| Master schema | `config/variables/schema/infrastructure.schema.json`, validator in `AzlInfrastructure.psm1` | The one input file | `tests/infrastructure` | No `deployment` options (timeouts, approval, resume) |
| OS configuration | `phase-03-os-configuration/Set-AzureLocalNodeConfiguration.ps1` | Per-node OS configuration; its JSON report carries port names by MAC and SAN disks by LUN | `tests/node-configuration` | The report is the input of the parameter generator (`-NodeReportPath`) |

### 1.2 Built-in guards in `Invoke-AzlArmDeployment`

| Guard | Real? | Source of the rule |
| --- | --- | --- |
| Refuse Validate when the instance is in a failed deployment state (`-AllowRevalidate` overrides) | Real | Learn, "License sync issue": do not start another Validate in Deployment failed state |
| Refuse Deploy without a successful Validate (`-SkipValidationCheck` overrides) | Real | Learn: Deploy "after successful validation" |
| Refuse an empty `infraVolLunId` or `infraPerfLunId` | Real | SAN templates |
| Secrets read from Key Vault into memory, sent as secure parameters | Real | Never written |
| Patch the `deploymentSettings` api-version (`-DeploymentSettingsApiVersion`) | Real | Microsoft's templates still carry preview versions |
| Wait for the ARM deployment, then read validation steps | Real, but see gaps G3 to G6 | Fixed 30 s poll, 90 and 360 minute limits that throw |

### 1.3 Monitoring scripts (interactive dashboards)

| Path | Status | Notes |
| --- | --- | --- |
| `monitoring/powershell/` (`Monitor-Validation.ps1`, `Monitor-Deployment.ps1`, `Invoke-MonitorDeployment-Orchestrated.ps1`) | Removed | Sonar (azurelocal-sonar) shows validation and deployment progress; the toolkit no longer carries progress dashboards |

### 1.4 Scaffolds and legacy scripts (do not run these for a deployment)

| Path | Status | Why |
| --- | --- | --- |
| `active-directory/task-01-.../powershell/Deploy-AzureLocalCluster.ps1` and the `local-identity` copy | Legacy | Calls `Generate-AzureLocal-Parameters.ps1`, which is not in the repository (`find` finds none). Reads `cluster_arm_deployment.*` of the old layout |
| `.../Deploy-AzureLocalCluster-Standalone.ps1` (both identities) | Legacy | Needs a hand-made `azuredeploy.parameters.*.json` with `{{VARIABLE}}` placeholders |
| `.../Invoke-VerifyADPrerequisites-Orchestrated.ps1`, `Test-ADPrerequisites-Standalone.ps1` | Partly real, legacy config | Documented as the AD prerequisite check; reads the old layout |
| `.../Invoke-DeployCluster-Orchestrated.ps1` (local identity), `Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1` | Scaffold / legacy | The first is a 1 KB wrapper over the scaffold module; the second reads the old layout |
| `azurecli/az-deploy-cluster*.ps1` (the Bash variant has since been removed) | Scaffold | `Invoke-DeploymentAzCliPowerShell` logs "standards-compliant scaffold. Add task-specific az commands" |
| `Get-HciResourceProviderObjectId*.ps1` | Real, small | Same lookup the module does (`Get-AzlHciResourceProviderObjectId`) |
| `active-directory/task-02-verify-.../Test-ClusterHealth*.ps1`, `Test-ADDomainStatus*.ps1`, local-identity `Test-LocalIdentityConfig*.ps1` | Real, legacy config | Post-deployment verification over PSRemoting |

### 1.5 Pipelines today

| File | Status | Notes |
| --- | --- | --- |
| `pipelines/github-actions/azure-local-deploy.yml`, `pipelines/azure-devops/azure-local-deploy.yml`, `pipelines/gitlab/.gitlab-ci.yml` + `stages/*.yml` | Legacy | Terraform and Ansible driven, client-secret authentication (`ARM_CLIENT_SECRET`), the `deploy-cluster` stage does not call any schema 5 script, and none has an approval gate that shows a Validate result |

---

## 2. What the documentation says

| Document | Says | Matches the code? |
| --- | --- | --- |
| `docs/os-configuration-and-arm-deployment.md` (toolkit) | Plan, `-Execute -Mode Validate`, then `-Execute -Mode Deploy`, as separate runs; lists prerequisites and who checks each (Code, Azure, You) | Yes for the entry point; the "You" rows are the ones this work turns into checks |
| azurelocal.cloud implementation guide, Phase 05 (`docs/implementation/04-cluster-deployment/phase-05-cluster-deployment/`) | Portal and ARM template routes per identity and storage; ARM pages tell the reader to run `Invoke-VerifyADPrerequisites-Orchestrated.ps1`, `Get-HciResourceProviderObjectId.ps1` and `Deploy-AzureLocalCluster-Standalone.ps1`, and to generate parameters with `Generate-AzureLocal-Parameters.ps1` | **No.** Two of the four scripts are legacy; the generator does not exist; the schema 5 entry point is not mentioned. Last updated 2026-03-08 |
| Implementation guide, Phase 05 monitoring pages | Run `Monitor-Validation.ps1` / `Monitor-Deployment.ps1` | No, the scripts are removed; use Sonar |
| azurelocal.cloud automation guide (`docs/automation/`) | CI/CD pipelines for GitHub Actions, GitLab CI/CD and Azure DevOps; guides for PowerShell, Terraform, Bicep, Ansible | No page for ARM Validate/Deploy automation. Content for it is in `docs/ARM-DEPLOYMENT-GUIDE-SOURCE.md` of this change, to be moved there |
| Microsoft Learn, "Deploy Azure Local via ARM template" (2610) | Validate creates the Azure resources and validates readiness; **Redeploy** the same parameters with `deploymentMode` Deploy; deployment takes 2.5 to 3 hours; after Validate, do not run Validate again if the system is in Deployment failed (license sync); known issues: role assignment already exists, zombie role assignments | Validate/Deploy flow and the license-sync rule are in the code. The two role-assignment issues are not detected anywhere |
| Microsoft Learn, "Deploy Azure Local using the Azure portal" | "Resume deployment" on the instance's Deployments page after a failure | Not available from code. The ARM equivalent is submitting the same deployment again with mode Deploy |

---

## 3. Gaps

| ID | Gap | Effect | Closed by |
| --- | --- | --- | --- |
| G1 | No preconditions before Validate beyond "Arc machine Connected" (only with `-Preflight`/`-Execute`) | Validate runs for 10 to 30 minutes and fails for causes that were knowable: OS configuration not done, Arc names, missing Key Vault secret, provider not registered, no permission | Preconditions (design section 4) |
| G2 | No link to the OS configuration run | The report is read for adapter names only; nobody checks that every node converged | `-OsConfigurationReport`, precondition `OsConfigurationConverged` |
| G3 | Poll is a fixed 30 s sleep; timeout throws and loses the state | A pipeline job that ends at the limit cannot tell "still running" from "failed" and cannot continue | Backoff polling, state `DeploymentTimedOut`, `-Resume` attaches to the running deployment |
| G4 | No resume | A Deploy that fails at step 0.41 can only be started again by hand, and the tool does not know whether Azure supports it | Resume rules (design section 7) |
| G5 | Step failures are listed by `Name` only. `Get-AzlDeploymentState` drops `fullStepIndex` (the "0.41" shown in the portal), start and end times | The failing step cannot be quoted or matched | `FullStepIndex` added to the flattened steps |
| G6 | No knowledge of known failures | A failure reported in another environment (device-ID Arc names, step 0.41, prerelease build; not reproduced here) was met by hand twice | `config/known-issues/arm-deployment.json` and the matcher |
| G7 | No event feed, no `report.json`, no `summary.md` | Sonar cannot follow the run from the pipeline's side; a pipeline job summary has nothing to show | Events JSONL, report, summary |
| G8 | Exit code: 1 on failure, an uncaught exception otherwise (a throw gives 1 too, bad input is not distinguished) | A pipeline cannot tell "fix the input" from "the deployment failed" | Exit codes 0, 1, 2 |
| G9 | No approval gate between Validate and Deploy | In a pipeline, Deploy has to be a separate manual run | `-Mode ValidateAndDeploy` with an approval mode; pipeline environments |
| G10 | Not idempotent: the ARM deployment name is a time stamp, so a re-run of the same inputs submits again, even when the Validate passed with the same parameters | Wasted 10 to 30 minutes per re-run; for Deploy, a risk of a second submission while one is running | Deterministic deployment name from the parameter hash; attach instead of resubmit |
| G11 | Backslash path literals (`'..\infrastructure\AzlInfrastructure.psm1'`, `'..\..\..\common'`) in `AzlArmDeployment.psm1` and in both phase-05 scripts | One file name on Linux: the module cannot be imported under pwsh on a Linux runner | Fixed in this change, with a scan test |
| G12 | Entry point has `exit 1` in the middle of a script and returns objects on success | A wrapper cannot rely on the result shape | The new entry point returns one result and sets the exit code once |
| G13 | Pipelines for the schema 5 path do not exist (the existing ones are Terraform/Ansible with client secrets) | No CI/CD route | New workflows for GitHub Actions, GitLab CI and Azure DevOps, OIDC |
| G14 | Documentation points at legacy scripts (section 2) | Operators follow dead ends | Docs section of this change; implementation guide to link to the new entry point |
| G15 | `Monitor-*.ps1` cannot run unattended | No pipeline feedback while Deploy runs | Polling inside the run, step events in the feed |
| G16 | No check of the AD prerequisites or the LCM user from the master file | The "AD prepared" step is a manual "You" row | Precondition `ActiveDirectoryPrepared` (read-only, uses the ActiveDirectory module when present) |
| G17 | `AzureLocal-OSConfig` and ARM events use no shared contract | Sonar has to read two shapes | Same fields as the OS configuration feed (`timestamp, node, stage, step, state, evidence, level, nextAction`), stage `ArmDeployment` |

## 4. What stays as it is

The parameter generation (`New-AzlArmParameterSet` and friends), the template catalog and the guards listed in 1.2 are reused,
not rewritten. The legacy scripts stay in the repository (they are documented in the implementation guide today) and are
marked legacy in the phase README; removing them is a separate decision.

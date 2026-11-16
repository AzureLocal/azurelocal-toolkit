# CI/CD Pipeline Samples

Pipeline definitions for automated Azure Local deployments across three CI/CD platforms. Each pipeline exists once per platform
(Azure DevOps, GitHub Actions, GitLab CI) and the three copies do the same work with platform-specific syntax.

**No value of a deployment is written in a pipeline file.** Every value a pipeline needs (the sign-in, the runner, the approval
environments, the infrastructure file, the tool versions, the state, the job timeouts) is a key of `infrastructure.yml`. Task 05 of
the CI/CD setup (`scripts/deploy/01-cicd-infra/phase-01-cicd-setup/task-05-configure-variables/powershell/Set-CicdVariables.ps1`)
reads the file and sets it on the platform; the pipelines only read the variables. `tests/variables/PipelineValues.Tests.ps1` fails
when a pipeline file carries a tool version, an infrastructure file path, a runner OS label, a sign-in method of its own, a deploy
branch or a parameter default that is a choice of a deployment.

## The route, pipeline by pipeline

One pipeline per piece of the route, in the order a deployment runs them. Each exists once per platform, and each runs one entry point of the
toolkit and nothing else.

| Pipeline | Entry point | GitHub Actions | GitLab CI | Azure DevOps |
| --- | --- | --- | --- | --- |
| CI/CD infrastructure (the runners) | `Deploy-CicdRunners.ps1` (task 06) | `cicd-infra.yml` | `stages/deploy-cicd-infra.yml` | `cicd-infra.yml` |
| Discovery (BMCs, Azure tenant, Active Directory) | `scripts/common/discovery/Invoke-AzlDiscoveryRun.ps1` | `discovery.yml` | `stages/discovery.yml` | `discovery.yml` |
| OS configuration (phase 03) | `Invoke-AzureLocalOsConfiguration.ps1` | `os-configuration.yml` | `os-configuration.gitlab-ci.yml` | `os-configuration.yml` |
| Pre-cluster verification (the gate) | `Invoke-AzureLocalPreClusterVerification.ps1` | `pre-cluster-verification.yml` | `stages/pre-cluster-verification.yml` | `pre-cluster-verification.yml` |
| ARM Validate and Deploy | `Invoke-AzureLocalArmDeployment.ps1` | `arm-deployment.yml` | `stages/arm-deployment.yml` | `arm-deployment.yml` |
| Terraform foundation and Ansible configuration (the older chain, below) | Terraform, `ansible-playbook` | `azure-local-deploy.yml` | `.gitlab-ci.yml` with `stages/*.yml` | `azure-local-deploy.yml` |

After the deployment come the validation and the day 2 pipelines (stage 07 and stage 08, [below](#validation-and-day-2-stages-07-and-08)). They are
the same shape: a read-only job first, and every job that changes the cluster (or puts load on it) behind the one approval environment of
`devops.pipelines.environments.operations`.

| Pipeline | Entry point | GitHub Actions | GitLab CI | Azure DevOps |
| --- | --- | --- | --- | --- |
| Validation before the handover (stage 07) | `Test-AzureLocalClusterHealth.ps1`, `Test-ArcConnectivity.ps1`, `Test-NetworkConfiguration.ps1`, `Test-StoragePerformance.ps1` | `validation.yml` | `stages/validation.yml` | `validation.yml` |
| Day 2: check for updates, on a schedule (task 01) | `Get-AvailableSolutionUpdate.azcli.ps1` (Azure view) or `Get-AvailableSolutionUpdate.ps1` (cluster view) | `day2-check-updates.yml` | `stages/day2-check-updates.yml` | `day2-check-updates.yml` |
| Day 2: start the solution update (task 02) | `Start-AzureLocalSolutionUpdate.ps1` | `day2-update.yml` | `stages/day2-update.yml` | `day2-update.yml` |
| Day 2: take one node through maintenance (task 03) | `Invoke-NodeMaintenanceReboot.ps1` | `day2-node-maintenance.yml` | `stages/day2-node-maintenance.yml` | `day2-node-maintenance.yml` |
| Day 2: cluster operations (task 04) | `Invoke-ClusterOperations.ps1` | `day2-cluster-operations.yml` | `stages/day2-cluster-operations.yml` | `day2-cluster-operations.yml` |

## The Terraform and Ansible chain

```
validate → plan → deploy-foundation → configure-onprem → configure-operations → validate-deployment
```

| Stage | Tool | Runner |
| --- | --- | --- |
| **Validate** | Terraform validate, Ansible lint | Hosted image (validates only: a platform choice) |
| **Plan** | Terraform plan | Hosted image (plans only: a platform choice) |
| **Deploy Foundation** | Terraform apply | Self-hosted |
| **Configure On-Prem** | Ansible playbooks | Self-hosted (on-prem access) |
| **Configure Operations** | Ansible playbooks | Self-hosted |
| **Validate Deployment** | Azure CLI (GitLab only) | Self-hosted |

The Azure Local cluster itself is deployed by the ARM pipelines below (schema 5, one script), not by this chain. This chain is the Azure
foundation (Terraform) and the Ansible plays of `src/ansible` (domain controllers 05, AD preparation 01, OS configuration 02, Arc registration
03, monitoring 04). K7 checked every script, playbook and path it names against the toolkit: all exist, and every value comes from the variables
task 05 sets. GitHub Actions and Azure DevOps end at Configure Operations; only GitLab has the Validate Deployment stage, and it holds one job,
the read-only policy and Defender for Cloud summary (`validate:compliance`). The no-op `validate:connectivity` job (it ran the same file check as
`config:validate` and printed a hint) is removed: the post-deployment checks are `Invoke-VerifyPostDeployment.ps1` and the scripts of
`scripts/deploy/06-testing-validation`, which need a jump server that reaches the cluster.

Every Terraform and Ansible job writes its inputs from the infrastructure file first:
`config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile <file> -OutputDirectory <the job's temporary directory>`.
Terraform plans with `-var-file=<dir>/terraform/azure-local/terraform.tfvars.json`; the Ansible jobs copy `<dir>/ansible/inventory/*` (`hosts.yml`, `group_vars`, `host_vars`; no `group_vars` is committed) into `src/ansible/inventory` (git-ignored there) and run with `-i inventory/hosts.yml`. The files hold subscription IDs and names, so they are never committed or uploaded. The Ansible jobs are signed in to Azure by `AZL_AUTH_METHOD` (the roles read the LCM and DSRM passwords from Key Vault on the controller, `azure.azcollection` through the Azure CLI, `ANSIBLE_AZURE_AUTH_SOURCE=cli`). The playbooks run in the order 05 (domain controllers), 01 (AD preparation), 02 (OS configuration: `Invoke-AzureLocalOsConfiguration.ps1` on the runner, with `-e azurelocal_os_configuration_infrastructure_file=<path>`, PowerShell 7, powershell-yaml and Az), 03 (Arc registration), then 04 (monitoring) in Configure Operations.
Terraform init takes the state from `TF_BACKEND_RG`, `TF_BACKEND_SA`, `TF_BACKEND_CONTAINER` and `TF_BACKEND_KEY` (below).

## Platforms

### GitLab CI/CD

- **Location**: `gitlab/.gitlab-ci.yml` (includes the stages of the Terraform and Ansible chain), `gitlab/os-configuration.gitlab-ci.yml`, and the stage files that declare their own stages and are included from a pipeline file of their own: `gitlab/stages/arm-deployment.yml`, `gitlab/stages/discovery.yml`, `gitlab/stages/pre-cluster-verification.yml`, `gitlab/stages/validation.yml` and `gitlab/stages/day2-check-updates.yml`, `day2-update.yml`, `day2-node-maintenance.yml`, `day2-cluster-operations.yml`
- **Features**: manual approval gates, protected environments, `resource_group`
- **Tools**: `gitlab/Use-AzlGitLabTool.ps1` installs the versions of `devops.pipelines.tool_versions` (GitLab has no installer action or task)

### GitHub Actions

- **Location**: `github-actions/` (`azure-local-deploy.yml`, `os-configuration.yml`, `arm-deployment.yml`, `cicd-infra.yml`, `discovery.yml`, `pre-cluster-verification.yml`, `validation.yml`, `day2-check-updates.yml`, `day2-update.yml`, `day2-node-maintenance.yml`, `day2-cluster-operations.yml`). This is the only folder of GitHub pipelines: the workflows of this repository's own CI are in `.github/workflows` (K7 removed `archive/github-actions`: see below)
- **Features**: environment protection rules, OIDC or client secret sign-in, artifact passing
- **Copy to**: `.github/workflows/` in your repository

### Azure DevOps

- **Location**: `azure-devops/`
- **Features**: service connections, environment approvals, variable groups
- **Requirements**: the Terraform extension from the marketplace (`TerraformInstaller@1`, `TerraformTaskV4@4`) for the Terraform pipelines

## OS configuration (Phase 03)

The one-run entry point, `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1`, runs standalone or unchanged in a pipeline: a read-only plan job (report and wipe list as artifacts), then an apply job behind an approval gate. The transport and the storage wipe come from the master file (`os_configuration.remoting.transport`, `os_configuration.clear_storage`); no pipeline overrides them.

- GitHub Actions: `github-actions/os-configuration.yml` (the environment of `AZL_ENVIRONMENT_OS_CONFIGURATION`, with required reviewers).
- GitLab CI: `gitlab/os-configuration.gitlab-ci.yml` (manual apply job, `resource_group`).
- Azure DevOps: `azure-devops/os-configuration.yml` (the environment named by the variable `AZL_ENVIRONMENT_OS_CONFIGURATION` of `azure-devops/variables/approval-environments.yml`, a variable of a YAML file bound when the pipeline is compiled, so whoever queues the run cannot choose an environment with no approval; a second approval, the environment of `AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE`, for a storage wipe when `os_configuration.clear_storage` is true). While the first variable is empty, mode Apply fails in the stage `ApprovalEnvironmentNotSet` and nothing is changed; while the second is empty and the plan would wipe, the stage `ConfirmStorageWipe` fails and Apply does not run.

Where the master file and the handoff files come from, the permissions of the pipeline identity and the exit codes are in [OS configuration and ARM deployment](../docs/os-configuration-and-arm-deployment.md#run-it-in-one-go).

## Discovery (before the OS configuration)

`scripts/common/discovery/Invoke-AzlDiscoveryRun.ps1` runs the discovery scripts of the toolkit one after the other and writes one report
(`discovery-report.json`, `summary.md`, and a folder per step): the hardware inventory of every BMC over the standard Redfish API (any maker),
the Dell iDRAC discovery with the proposal for `nodes[]`, the Azure tenant inventory and the Active Directory inventory. Every step is read
only (GET requests to the BMCs, reads in Azure and Active Directory), so the pipelines have **no approval gate**. The run fails when a step
fails, and the report is published as an artifact even then.

- GitHub Actions: `github-actions/discovery.yml` (input `scope`: `all`, `hardware`, `dell`, `tenant`, `directory`).
- GitLab CI: `gitlab/stages/discovery.yml` (run variable `DISCOVERY_SCOPE`; declares its own stage, include it from a pipeline file of its own).
- Azure DevOps: `azure-devops/discovery.yml` (parameter `scope`).

The job runs on the general self-hosted runner, which needs a route to the BMC addresses (HTTPS) and, for the Active Directory step, the
ActiveDirectory module on a domain-joined runner. The BMC login is never in a pipeline file or a pipeline variable: it is the secret reference
of `infrastructure.yml` (`hardware.bmc`, or `nodes[].bmc`), and the toolkit secret resolver reads it from Key Vault at run time with the Azure
sign-in of the job.

**The write-back** (`write_back` / `DISCOVERY_WRITE_BACK`, scope `dell`) prepares the serial numbers and MAC addresses the discovery found in a
**copy** of the master file, in the artifact (`write-back/infrastructure.yml` and `write-back/changes.txt`). The file in the repository is not
changed and no pipeline commits, pushes or opens a pull request: review the copy and commit it through a pull request of your own.

## Pre-cluster verification (the gate before the ARM Validate)

`Invoke-AzureLocalPreClusterVerification.ps1` ([docs/pre-cluster-verification.md](../docs/pre-cluster-verification.md)) checks, read only, everything
Microsoft Learn lists as a prerequisite of a deployment. The ARM run refuses to go on without a passing, current result of it for the same
master file. The pipelines run it, publish `report.json`, `summary.md` and the event feed as an artifact and in the run summary, and **fail the run
when the verdict is not Pass**.

- GitHub Actions: `github-actions/pre-cluster-verification.yml` (job `verify`; job `verify-with-changes` behind the environment of `AZL_ENVIRONMENT_ARM_DEPLOYMENT`).
- GitLab CI: `gitlab/stages/pre-cluster-verification.yml` (job `pre-cluster-verify`; the manual job `pre-cluster-verify-changes` in the protected environment of `AZL_ENVIRONMENT_ARM_DEPLOYMENT`).
- Azure DevOps: `azure-devops/pre-cluster-verification.yml` (stage `Verify`; stage `VerifyWithChanges`, a deployment job in the environment named by the variable `AZL_ENVIRONMENT_ARM_DEPLOYMENT` of `azure-devops/variables/approval-environments.yml`: a variable of a YAML file, bound when the pipeline is compiled, so whoever queues the run cannot choose an environment that has no approval. While it is empty the stage `ApprovalEnvironmentNotSet` fails and nothing is changed).

The read-only job runs Plan or Verify. The two changes the gate can make, `-Fix` (it registers the mandatory resource providers that are not
registered: Azure side only) and `-InstallEnvironmentChecker` (the Environment Checker on the nodes for the run, removed again at the end), run
only in the second, approved job, selected by the inputs `fix` and `install_environment_checker`. A Skipped check blocks the verdict; the input
`accept_skipped` (ids, comma separated) accepts it and the report records that you did.

The script writes its result where the ARM run reads it: `deployment.pre_cluster_verification_report_directory`, else `arm-report/verification/live` in
the environment data folder of the master file. The pipeline passes no `-ReportDirectory` and publishes a copy of that folder. So the ARM run must
run on the same runner, or `deployment.pre_cluster_verification_report_directory` must be a folder both runs reach.

## ARM Validate and Deploy (schema 5, one script)

The Terraform and Ansible pipelines above do not call the schema 5 deployment script. These do, with an approval between Validate and
Deploy. Guide: [docs/arm-deployment-guide.md](../docs/arm-deployment-guide.md).

- **GitHub Actions**: `github-actions/arm-deployment.yml` (the environment of `AZL_ENVIRONMENT_ARM_DEPLOYMENT`)
- **GitLab CI**: `gitlab/stages/arm-deployment.yml` (declares its own stages; include it from a pipeline of its own)
- **Azure DevOps**: `azure-devops/arm-deployment.yml` (the environment named by the variable `AZL_ENVIRONMENT_ARM_DEPLOYMENT` of `azure-devops/variables/approval-environments.yml`, with an Approvals check; while it is empty, a Deploy fails in the stage `ApprovalEnvironmentNotSet` and nothing is changed)

## Validation and day 2 (stages 07 and 08)

Five pipelines run the validation and the day 2 scripts, once per platform. Each runs the script an operator runs by hand and nothing else; the
scripts stay the way to do the same work from a workstation. All of them connect to the cluster over PowerShell remoting **as the service account of
the runner**, which must be an administrator of the cluster: no pipeline takes a node password. The node maintenance reads the node login from its
secret reference in the master file (Key Vault), like the discovery reads the BMC login.

| Pipeline | Read only, no approval | Behind the approval environment |
| --- | --- | --- |
| `day2-check-updates` | the whole pipeline: the Azure view (Azure CLI, no node access) or the cluster view (remoting). Runs on a schedule | none |
| `day2-update` | the plan: `Start-AzureLocalSolutionUpdate.ps1 -WhatIf`, which reads the cluster and says which update it would start | `PrepareOnly` (download and readiness checks) and `Install` (start the update; it does not wait) |
| `day2-node-maintenance` | the plan: the node is checked against `nodes[]` of the master file and `-WhatIf` prints what would happen | `Reboot` (drain, reboot, resume, wait for the storage) and `Resume` (`-ResumeOnly`, after a failed run) |
| `day2-cluster-operations` | `HealthCheck`, `Alerts`, `Capacity`; the `-WhatIf` plan of every other action | `MaintenanceMode`, `LiveMigrate`, `Rebalance` |
| `validation` | cluster health, Arc connectivity, network configuration and the storage checks **without** the load test | the storage performance test (`-RunPerformanceTest`) |

- **Plan first.** The pipelines that change something run a read-only plan job before the approval job, and the approval job starts only when
  the plan succeeded. A plan that fails (a node that is not in the file, an update already running, a health state of Failure) ends the run
  before anyone is asked to approve.
- **The storage performance test is not read only.** `Test-StoragePerformance.ps1 -RunPerformanceTest` writes and reads a scratch file on every cluster
  shared volume for `DurationSeconds` (60 by default) and removes it; its own help says it generates I/O on the cluster. The validation pipeline runs
  the other storage checks read only, and runs the load test as a separate job behind the approval environment, after the read-only validation
  passed. Run it in a maintenance window, never during an update.
- **One approval environment.** `devops.pipelines.environments.operations` (the variable `AZL_ENVIRONMENT_OPERATIONS`) is the environment of every job that
  changes the cluster or puts load on it. Make it an entry of `devops.environments[]` with `approval_required` and give it the approvers of your
  change process. On Azure DevOps the name is the variable of `azure-devops/variables/approval-environments.yml` (bound when the pipeline is compiled,
  empty in the toolkit; while it is empty the stage `ApprovalEnvironmentNotSet` fails and nothing is changed), and the Exclusive lock check of that
  one environment is what keeps an update and a node reboot apart.
- **Never two changes together.** GitHub Actions: the changing job has the concurrency group `azure-local-day2-changes-<infrastructure file>` with
  `cancel-in-progress: false` (a run waits for the one before it; GitHub keeps one waiting run per group, so a third run replaces the waiting second).
  GitLab CI: the changing job has the `resource_group` `azure-local-day2-changes`. Azure DevOps: `lockBehavior: sequential` on the pipeline and on the
  stage, and the Exclusive lock check of the shared environment. The read-only jobs hold no lock.
- **One node per run.** The node is a run input (`node`, `MAINTENANCE_NODE`, `OPERATIONS_NODE`) and the script is given `-RequireNodeInFile`: a name or an
  address that `nodes[]` of the master file does not list ends the run with exit code 2 before any credential is read and before anything is sent to a
  machine. There is no matrix and no loop over nodes: run the pipeline again for the next node after the storage has repaired (exit code 0).
- **A failed script fails the run.** Exit code 1 (a check failed, the cluster needs attention, a step failed) and 2 (a value of the file is missing)
  fail the job, and the report, plan or log is published as an artifact even then.
- **GitLab jobs start only from the web form, the API or a schedule**, never from a push or a merge request; the manual job of a change waits in the
  protected environment. GitHub and Azure DevOps pipelines are started by hand (`workflow_dispatch`, `trigger: none`), apart from the schedule below.

### Check for updates on a schedule (owner directive D74)

`day2-check-updates` fails when the cluster needs attention (an update in a failed state, a health state of Failure, Error or Warning, a failed update
environment, an update service that has not checked for days). An update that is only offered ends with exit code 0: read the verdict in the report.
The failed run is the alert: GitHub, GitLab and Azure DevOps each tell people about a failed run (their notification settings), and the report is
published as the artifact `day2-update-check`. The schedule is the key `devops.pipelines.schedules.check_for_updates` of `infrastructure.yml`: a
five-field cron expression in UTC, default `17 4 * * *` (every day at 04:17; the update agent of the cluster checks once a day). No platform reads a
schedule from a variable, so each applies it where it keeps it, and task 05 of the CI/CD setup prints the value to use:

| Platform | Where the schedule is | What to do |
| --- | --- | --- |
| GitHub Actions | the `cron` line of `on.schedule` in `day2-check-updates.yml` (the sample carries the default; a test keeps it equal to the registry default) | change the line in your copy when the key differs. A scheduled run has no inputs, so it takes the Azure view |
| GitLab CI | the project (CI/CD > Schedules), not the file | create a schedule for the default branch with the value of the key; the Azure view is the default of `UPDATECHECK_SOURCE` |
| Azure DevOps | not in the sample: a scheduled run cannot supply the run parameters (pool, service connection, variable group and file path have no default, because no value of a deployment is written in a pipeline file), and Learn says a schedule cannot use variables | copy the file, give the four parameters of your deployment as defaults and add the commented `schedules` block with the value of the key |

The Azure view (`Get-AvailableSolutionUpdate.azcli.ps1`) needs no access to a node and the Azure CLI on the runner; the identity needs Azure Stack HCI
Administrator or Reader on the cluster resource. The cluster view (`Get-AvailableSolutionUpdate.ps1`) needs a route to the cluster and signs in to nothing.

Guide: [Validation and day 2 operations](../docs/day2-and-validation.md) shows each script by hand and in a pipeline.

## CI/CD infrastructure (the runners)

- **GitHub Actions**: `github-actions/cicd-infra.yml`
- **GitLab CI**: `gitlab/stages/deploy-cicd-infra.yml` (runs with `CICD_INFRA=true`)
- **Azure DevOps**: `azure-devops/cicd-infra.yml`

The first run uses the hosted image, because the self-hosted runners do not exist yet; afterwards choose the self-hosted runner.

## The GitHub folder and the Ansible tree

- **One GitHub pipeline folder.** `github-actions/` holds the deployment pipelines. The old `archive/github-actions` folder is gone: its seven
  workflows (`add-to-project`, `deploy-docs`, `drift-check`, `release-please`, `validate-config`, `validate-repo-structure`, `validate`) were
  repository CI, not deployment pipelines, and each called a reusable workflow of an organisation this repository no longer adopts
  (`.azurelocal-platform.yml` has `reusableWorkflows: []`) or a script that no longer exists. The repository CI is `azure-pipelines.yml`; the one
  live GitHub workflow is `.github/workflows/deploy-docs.yml`. The files are in git history (last at commit `182484a5`).
- **One Ansible tree.** `src/ansible` holds everything: the role `azurelocal_os_configuration` (the front end of
  `Invoke-AzureLocalOsConfiguration.ps1`) is in `src/ansible/roles`, and `playbooks/02-os-configuration.yml` runs it. The former top-level `ansible`
  folder is gone (its README is `src/ansible/roles/azurelocal_os_configuration/README.md`).

## Where every value comes from

Task 05 sets each variable below from its key: on GitHub as a repository variable (`vars.NAME`; the sign-in values also per
environment), on GitLab as a project CI/CD variable (scope `*`; the sign-in values also per environment), on Azure DevOps in the variable
group `devops.pipelines.variable_group` (one per environment, `<name>-<environment>`). Run it again after you change the file.

| Variable | Key in `infrastructure.yml` | GitHub | GitLab | Azure DevOps |
| --- | --- | --- | --- | --- |
| `ARM_CLIENT_ID` | `azure.automation_identity.client_id` (else the app registration task 01 made) | variable | variable | variable group |
| `ARM_TENANT_ID` | `azure.tenant_id` | variable | variable | variable group |
| `ARM_SUBSCRIPTION_ID` | `azure.subscription_id` | variable | variable | variable group |
| `ARM_USE_OIDC` (method oidc) or `ARM_CLIENT_SECRET` (method client_secret, a secret read from `devops.authentication.client_secret`) | `devops.authentication.method` | variable / secret | variable / masked | variable group (secret) |
| `AZL_AUTH_METHOD` | `devops.authentication.method` (`oidc` or `client_secret`) | variable | variable | variable group |
| `TF_BACKEND_RG`, `TF_BACKEND_SA`, `TF_BACKEND_CONTAINER`, `TF_BACKEND_KEY` | `devops.state.resource_group`, `.storage_account`, `.container`, `.azure_local_key` | variable | variable | variable group |
| `AZL_RUNNER_LABEL` | `devops.pipelines.runner_label` (one of `devops.runners[].labels` of the general runner) | variable | variable | (the pool, a run parameter) |
| `AZL_RUNNER_OS` | `devops.runners[].os_type` of the general runner | variable | | |
| `AZL_ENVIRONMENT_OS_CONFIGURATION`, `_OS_CONFIGURATION_CLEAR_STORAGE` (Azure DevOps only), `_ARM_DEPLOYMENT`, `_CICD_INFRA`, `_TERRAFORM_DEPLOYMENT`, `_OPERATIONS` | `devops.pipelines.environments.*` | variable | variable | the variable of the same name in `azure-devops/variables/approval-environments.yml` (written once in the repository; see below) |
| `AZL_INFRASTRUCTURE_FILE` | `devops.pipelines.infrastructure_file` | variable | variable | (a run parameter) |
| `AZL_HANDOFF_PATH` | `devops.pipelines.handoff_path` | variable | variable | (a run parameter) |
| `AZL_TERRAFORM_VERSION`, `AZL_PYTHON_VERSION`, `AZL_ANSIBLE_CORE_VERSION`, `AZL_ANSIBLE_LINT_VERSION`, `AZL_AZ_POWERSHELL_VERSION`, `AZL_POWERSHELL_YAML_VERSION`, `AZL_AZ_KEYVAULT_VERSION` | `devops.pipelines.tool_versions.terraform`, `.python`, `.ansible_core`, `.ansible_lint`, `.az_powershell`, `.powershell_yaml`, `.az_keyvault` | variable | variable | variable group |
| `AZL_VALIDATE_JOB_TIMEOUT_MINUTES`, `AZL_DEPLOY_JOB_TIMEOUT_MINUTES` | `deployment.validate_timeout_minutes`, `deployment.deploy_timeout_minutes`, each plus 60 minutes | variable | | |
| `AZL_DEFAULT_BRANCH` | `devops.repository.default_branch` | | | variable group |
| `AZL_RUNNER_SSH_PUBLIC_KEY` | `devops.runners[].admin_ssh_public_key` of the Linux runner (the key, or a reference task 05 reads) | variable | variable | variable group |

Each name is registered as a `pipeline_inputs` or `pipeline_variables` entry of its file in the registry (`tools.cicd_infra`), with
the key as `source_key`. The table of names and keys is `$script:AzlPipelineVariable` in `scripts/common/cicd-infra/AzlCicdInfra.psm1`;
`tests/pipelines/PipelineSettings.Tests.ps1` checks the files, the entries and the setup against each other.

### Azure DevOps run parameters and the approval environments

Azure DevOps reads the pool, the service connection, the variable group and a parameter path before any
variable exists (a macro variable is expanded only in task inputs, and `${{ variables.name }}` does not see pipeline or library variables:
[Define variables](https://learn.microsoft.com/azure/devops/pipelines/process/variables#understand-variable-syntax),
[Template expressions](https://learn.microsoft.com/azure/devops/pipelines/process/template-expressions)). These are run parameters
**with no default**: the run form asks for them, and task 05 prints the value to enter for each.

| Parameter | Pipelines | Enter |
| --- | --- | --- |
| `agentPool`, `agent_pool` | all | `devops.runners[].pool` of the general runner (`hosted` for the first run of `cicd-infra.yml`) |
| `serviceConnection`, `azureServiceConnection`, `service_connection` | all | `devops.pipelines.service_connection` |
| `variableGroup`, `variable_group` | all | `devops.pipelines.variable_group`, with environments `<name>-<environment>` |
| `infrastructureFile`, `infrastructure_file` | all | `devops.pipelines.infrastructure_file` |
| `handoff_path` | `os-configuration.yml` | `devops.pipelines.handoff_path` (`none` for an ISO-installed cluster) |

**The approval environments are not run parameters.** A deployment job that changes a system sits behind an environment with an Approvals check, and a deployment job to an environment with no check runs without one. If the environment were a run parameter, whoever queues the run could type the name of an environment with no check. So the Azure DevOps pipelines bind it when they are compiled: each environment is a variable of a YAML file of the repository, `azure-devops/variables/approval-environments.yml`, which every pipeline includes with `- template: variables/approval-environments.yml` (a template expression sees only the variables of YAML files, not those stored on the pipeline, in a library or given when you start a run: [Template expressions](https://learn.microsoft.com/azure/devops/pipelines/process/template-expressions)). The variables have the names of the GitHub repository variables and the GitLab project variables of the same purpose, so the three platforms share them. The toolkit ships them empty, because no value of a deployment is written in the toolkit: write the names once, in a pull request, where task 05 lists them. Copy the file with the pipeline when you copy a pipeline to your own repository.

| Variable of `approval-environments.yml` | Enter | Pipeline and stage |
| --- | --- | --- |
| `AZL_ENVIRONMENT_OS_CONFIGURATION` | `devops.pipelines.environments.os_configuration` | `os-configuration.yml`, stage `Apply` |
| `AZL_ENVIRONMENT_OS_CONFIGURATION_CLEAR_STORAGE` | `devops.pipelines.environments.os_configuration_clear_storage` | `os-configuration.yml`, stage `ConfirmStorageWipe` |
| `AZL_ENVIRONMENT_ARM_DEPLOYMENT` | `devops.pipelines.environments.arm_deployment` | `arm-deployment.yml`, stage `Deploy`; `pre-cluster-verification.yml`, stage `VerifyWithChanges` |
| `AZL_ENVIRONMENT_CICD_INFRA` | `devops.pipelines.environments.cicd_infra` | `cicd-infra.yml`, stage `Apply` (when `apply` is on) |
| `AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT` | `devops.pipelines.environments.terraform_deployment` | `azure-local-deploy.yml`, stages `DeployFoundation`, `ConfigureOnPrem` and `ConfigureOperations` |
| `AZL_ENVIRONMENT_OPERATIONS` | `devops.pipelines.environments.operations` | `day2-update.yml`, `day2-node-maintenance.yml` and `day2-cluster-operations.yml`, stage `Apply`; `validation.yml`, stage `StoragePerformance` |

While a variable is empty and the run would change something, a guard stage (`ApprovalEnvironmentNotSet`; `ConfirmStorageWipe` for the wipe approval) fails with a message that names the file and changes nothing. The stages that only read (`Plan`, `Validate`, `Preconditions`, `Verify`) run as before and have no environment.
The other parameters are choices of one run (mode, nodes, steps, resume, an artifact run ID) and default to the safe choice (`Plan`,
`all`, `false`, `none`). Because these parameters have no default, a run started by a push or a pull request could not supply them: the
Azure DevOps pipelines are started by hand.

Each environment is an entry of `devops.environments[]` with `approval_required: true`; task 05 stops when a name is not.

## Sign-in

Every pipeline follows `devops.authentication.method` through `AZL_AUTH_METHOD`:

| Platform | `oidc` | `client_secret` |
| --- | --- | --- |
| GitHub Actions | `azure/login` with `client-id`, `tenant-id`, `subscription-id`; Terraform `ARM_USE_OIDC=true` | `azure/login` with `creds` from `ARM_CLIENT_SECRET`; Terraform `ARM_CLIENT_SECRET` |
| GitLab CI | the ID token `ARM_OIDC_TOKEN` (`id_tokens`, audience `api://AzureADTokenExchange`): `Connect-AzAccount -FederatedToken`, Terraform `ARM_USE_OIDC=true` | the masked `ARM_CLIENT_SECRET`: `Connect-AzAccount -Credential`, Terraform `ARM_CLIENT_SECRET` |
| Azure DevOps | the service connection (workload identity federation, made by task 05): `$env:idToken` | the service connection's secret: `$env:servicePrincipalKey` |

A managed identity of the runner is not a sign-in method of the pipelines.

## Job timeouts and artifact retention

The ARM Validate and Deploy wait as long as the file says (`deployment.validate_timeout_minutes`, default 90, and
`deployment.deploy_timeout_minutes`, default 360; Microsoft Learn: a deployment takes 2.5 to 3 hours,
[Deploy Azure Local using an Azure Resource Manager deployment template](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)).
The script's own wait is the real limit:

| Platform | Validate and Deploy job timeout |
| --- | --- |
| GitHub Actions | `fromJSON(vars.AZL_VALIDATE_JOB_TIMEOUT_MINUTES)` and `fromJSON(vars.AZL_DEPLOY_JOB_TIMEOUT_MINUTES)`: the wait plus 60 minutes, set by task 05 |
| Azure DevOps, GitLab | a fixed upper bound, 1500 minutes (25 hours): the registry maximum of both keys (1440) plus 60. A job timeout is read before any variable exists on these platforms. The GitLab runner's own maximum job timeout must allow it |

The other limits (30 minutes for the read-only preconditions, 60 and 120 minutes for the runner plan and apply) and the artifact
retention (a saved plan for a day, the reports for 30 to 90 days) describe the toolkit's own jobs, not a deployment, and stay in the files,
each with a one-line comment.

## Where the platforms differ, and why

| What | GitHub Actions | GitLab CI | Azure DevOps | Reason |
| --- | --- | --- | --- | --- |
| One run at a time | `concurrency` group | `resource_group` | `lockBehavior: sequential` plus the Exclusive lock check on the environment | each platform's own lock |
| The OS configuration report for the ARM run | by run ID (`os_configuration_run_id`) | a path; add `needs: pipeline:` (parent-child) or `needs: project:` (Premium) to fetch the artifact | by pipeline and run ID (`osConfigurationPipelineId`, `osConfigurationRunId`) | GitLab fetches another pipeline's artifact only through `needs` |
| Deploy branch | `github.event.repository.default_branch` | `$CI_DEFAULT_BRANCH` | `AZL_DEFAULT_BRANCH` (`devops.repository.default_branch`) | Azure DevOps has no predefined variable with the default branch |
| Tool installation | setup actions | `gitlab/Use-AzlGitLabTool.ps1` | installer tasks | GitLab has no installer |
| Second approval of a storage wipe | the apply approval and the published wipe list | the manual job and the wipe list | a second environment | only Azure DevOps has stage-level approvals by environment |

## Prerequisites

### Self-Hosted Runner

The on-premises configuration stages require the general self-hosted runner (the one in `devops.runners[]`, with the label
`devops.pipelines.runner_label` and, on Azure DevOps, the pool `devops.runners[].pool`) with:

- Network access to cluster nodes (WinRM port 5986)
- Network access to domain controllers (LDAP 389, Kerberos 88)
- PowerShell 7 (every pipeline step is PowerShell 7)
- Python at the version `devops.pipelines.tool_versions.python` (`python<version>` on PATH for GitLab)
- Outbound HTTPS to the PowerShell Gallery, PyPI and releases.hashicorp.com, unless the tool versions are already installed

## Customization

1. Fill in `devops` in `infrastructure.yml` (the `pipelines`, `authentication`, `runners`, `state` and `repository` keys) and run the
   CI/CD setup (tasks 01 to 06). Task 05 sets every variable the pipelines read.
2. Copy the pipeline file for your platform to the appropriate location.
3. Adjust stage triggers and approval gates per your change management process.
4. Configure the self-hosted runner with on-premises network access.

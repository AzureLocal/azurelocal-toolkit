# CI/CD Pipeline Samples

Pipeline definitions for automated Azure Local deployments across three CI/CD platforms. Each pipeline exists once per platform
(Azure DevOps, GitHub Actions, GitLab CI) and the three copies do the same work with platform-specific syntax.

**No value of a deployment is written in a pipeline file.** Every value a pipeline needs (the sign-in, the runner, the approval
environments, the infrastructure file, the tool versions, the state, the job timeouts) is a key of `infrastructure.yml`. Task 05 of
the CI/CD setup (`scripts/deploy/01-cicd-infra/phase-01-cicd-setup/task-05-configure-variables/powershell/Set-CicdVariables.ps1`)
reads the file and sets it on the platform; the pipelines only read the variables. `tests/variables/PipelineValues.Tests.ps1` fails
when a pipeline file carries a tool version, an infrastructure file path, a runner OS label, a sign-in method of its own, a deploy
branch or a parameter default that is a choice of a deployment.

## Pipeline Architecture

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
| **Validate Deployment** | Azure CLI, PowerShell | Self-hosted |

The Azure Local cluster itself is deployed by the ARM pipelines below (schema 5, one script), not by this chain.

Every Terraform and Ansible job writes its inputs from the infrastructure file first:
`config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile <file> -OutputDirectory <the job's temporary directory>`.
Terraform plans with `-var-file=<dir>/terraform/azure-local/terraform.tfvars.json`; the Ansible jobs copy `<dir>/ansible/inventory/*` (`hosts.yml`, `group_vars`, `host_vars`; no `group_vars` is committed) into `src/ansible/inventory` (git-ignored there) and run with `-i inventory/hosts.yml`. The files hold subscription IDs and names, so they are never committed or uploaded. The Ansible jobs are signed in to Azure by `AZL_AUTH_METHOD` (the roles read the LCM and DSRM passwords from Key Vault on the controller, `azure.azcollection` through the Azure CLI, `ANSIBLE_AZURE_AUTH_SOURCE=cli`). The playbooks run in the order 05 (domain controllers), 01 (AD preparation), 02 (OS configuration: `Invoke-AzureLocalOsConfiguration.ps1` on the runner, with `-e azurelocal_os_configuration_infrastructure_file=<path>`, PowerShell 7, powershell-yaml and Az), 03 (Arc registration), then 04 (monitoring) in Configure Operations.
Terraform init takes the state from `TF_BACKEND_RG`, `TF_BACKEND_SA`, `TF_BACKEND_CONTAINER` and `TF_BACKEND_KEY` (below).

## Platforms

### GitLab CI/CD

- **Location**: `gitlab/.gitlab-ci.yml` (includes `gitlab/stages/*.yml`)
- **Features**: manual approval gates, protected environments, `resource_group`
- **Tools**: `gitlab/Use-AzlGitLabTool.ps1` installs the versions of `devops.pipelines.tool_versions` (GitLab has no installer action or task)

### GitHub Actions

- **Location**: `github-actions/` (`azure-local-deploy.yml`, `os-configuration.yml`, `arm-deployment.yml`, `cicd-infra.yml`)
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
- Azure DevOps: `azure-devops/os-configuration.yml` (the environment of the parameter `approval_environment`; a second approval for a storage wipe when `os_configuration.clear_storage` is true).

Where the master file and the handoff files come from, the permissions of the pipeline identity and the exit codes are in [OS configuration and ARM deployment](../docs/os-configuration-and-arm-deployment.md#run-it-in-one-go).

## ARM Validate and Deploy (schema 5, one script)

The Terraform and Ansible pipelines above do not call the schema 5 deployment script. These do, with an approval between Validate and
Deploy. Guide: [docs/arm-deployment-guide.md](../docs/arm-deployment-guide.md).

- **GitHub Actions**: `github-actions/arm-deployment.yml` (the environment of `AZL_ENVIRONMENT_ARM_DEPLOYMENT`)
- **GitLab CI**: `gitlab/stages/arm-deployment.yml` (declares its own stages; include it from a pipeline of its own)
- **Azure DevOps**: `azure-devops/arm-deployment.yml` (the environment of the parameter `approvalEnvironment`, with an Approvals check)

## CI/CD infrastructure (the runners)

- **GitHub Actions**: `github-actions/cicd-infra.yml`
- **GitLab CI**: `gitlab/stages/deploy-cicd-infra.yml` (runs with `CICD_INFRA=true`)
- **Azure DevOps**: `azure-devops/cicd-infra.yml`

The first run uses the hosted image, because the self-hosted runners do not exist yet; afterwards choose the self-hosted runner.

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
| `AZL_ENVIRONMENT_OS_CONFIGURATION`, `_ARM_DEPLOYMENT`, `_CICD_INFRA`, `_TERRAFORM_DEPLOYMENT` | `devops.pipelines.environments.*` | variable | variable | (run parameters) |
| `AZL_INFRASTRUCTURE_FILE` | `devops.pipelines.infrastructure_file` | variable | variable | (a run parameter) |
| `AZL_HANDOFF_PATH` | `devops.pipelines.handoff_path` | variable | variable | (a run parameter) |
| `AZL_TERRAFORM_VERSION`, `AZL_PYTHON_VERSION`, `AZL_ANSIBLE_CORE_VERSION`, `AZL_ANSIBLE_LINT_VERSION`, `AZL_AZ_POWERSHELL_VERSION`, `AZL_POWERSHELL_YAML_VERSION`, `AZL_AZ_KEYVAULT_VERSION` | `devops.pipelines.tool_versions.terraform`, `.python`, `.ansible_core`, `.ansible_lint`, `.az_powershell`, `.powershell_yaml`, `.az_keyvault` | variable | variable | variable group |
| `AZL_VALIDATE_JOB_TIMEOUT_MINUTES`, `AZL_DEPLOY_JOB_TIMEOUT_MINUTES` | `deployment.validate_timeout_minutes`, `deployment.deploy_timeout_minutes`, each plus 60 minutes | variable | | |
| `AZL_DEFAULT_BRANCH` | `devops.repository.default_branch` | | | variable group |
| `AZL_RUNNER_SSH_PUBLIC_KEY` | `devops.runners[].admin_ssh_public_key` of the Linux runner (the key, or a reference task 05 reads) | variable | variable | variable group |

Each name is registered as a `pipeline_inputs` or `pipeline_variables` entry of its file in the registry (`tools.cicd_infra`), with
the key as `source_key`. The table of names and keys is `$script:AzlPipelineVariable` in `scripts/common/cicd-infra/AzlCicdInfra.psm1`;
`tests/pipelines/PipelineSettings.Tests.ps1` checks the files, the entries and the setup against each other.

### Azure DevOps run parameters

Azure DevOps reads the pool, the environment of a job, the service connection, the variable group and a parameter path before any
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
| `approvalEnvironment`, `approval_environment` | each | `devops.pipelines.environments.terraform_deployment`, `.arm_deployment`, `.cicd_infra` or `.os_configuration` |
| `clear_storage_approval_environment` | `os-configuration.yml` | `devops.pipelines.environments.os_configuration_clear_storage` |

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

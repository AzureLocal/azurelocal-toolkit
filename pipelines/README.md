# CI/CD Pipeline Samples

Pipeline definitions for automated Azure Local deployments across three CI/CD platforms. All pipelines implement the same deployment stages with platform-specific syntax.

## Pipeline Architecture

```
validate → plan → deploy-foundation → configure-onprem → deploy-cluster → configure-operations → validate-deployment
```

| Stage | Tool | Runner |
|---|---|---|
| **Validate** | Terraform validate, Ansible lint | Cloud-hosted |
| **Plan** | Terraform plan | Cloud-hosted |
| **Deploy Foundation** | Terraform apply | Cloud-hosted |
| **Configure On-Prem** | Ansible playbooks | Self-hosted (on-prem access) |
| **Deploy Cluster** | Azure CLI (ARM) | Cloud-hosted |
| **Configure Operations** | Ansible playbooks | Self-hosted |
| **Validate Deployment** | Azure CLI, PowerShell | Self-hosted |

## Platforms

### GitLab CI/CD (Primary)
- **Location**: `gitlab/.gitlab-ci.yml`
- **Features**: Stage includes, reusable templates, manual approval gates
- **Templates**: `gitlab/templates/terraform-plan-apply.yml`, `gitlab/templates/ansible-playbook.yml`

### GitHub Actions
- **Location**: `github-actions/azure-local-deploy.yml`
- **Features**: Environment protection rules, OIDC authentication, artifact passing
- **Copy to**: `.github/workflows/azure-local-deploy.yml` in your repository

### Azure DevOps
- **Location**: `azure-devops/azure-local-deploy.yml`
- **Features**: Service connections, environment approvals, Terraform task extension
- **Requirements**: Terraform extension from marketplace, service connection configured

## OS configuration (Phase 03)

The one-run entry point, `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/Invoke-AzureLocalOsConfiguration.ps1`, runs standalone or unchanged in a pipeline: a read-only plan job (report and wipe list as artifacts), then an apply job behind an approval gate.

- GitHub Actions: `github/os-configuration.yml` (the environment of `AZL_ENVIRONMENT_OS_CONFIGURATION`, with required reviewers; OIDC).
- GitLab CI: `gitlab/os-configuration.gitlab-ci.yml` (manual apply job, `resource_group`; managed identity or OIDC id_token).

Where the master file and the handoff files come from, the permissions of the pipeline identity and the exit codes are in [OS configuration and ARM deployment](../docs/os-configuration-and-arm-deployment.md#run-it-in-one-go).

## ARM Validate and Deploy (schema 5, one script)
The Terraform and Ansible pipelines above do not call the schema 5 deployment script. These do, with an approval between Validate and
Deploy, OIDC sign-in and no client secret. Guide: [docs/arm-deployment-guide.md](../docs/arm-deployment-guide.md).
- **GitHub Actions**: `github-actions/arm-deployment.yml` (the environment of `AZL_ENVIRONMENT_ARM_DEPLOYMENT`)
- **GitLab CI**: `gitlab/stages/arm-deployment.yml` (declares its own stages; include it from a pipeline of its own)
- **Azure DevOps**: `azure-devops/arm-deployment.yml` (the environment of the parameter `approvalEnvironment`, with an Approvals check)

## Runner labels, agent pools and approval environments

No pipeline file carries a runner label, an agent pool name or an approval environment name. They are choices of a deployment, made once in `infrastructure.yml`: the runners (`devops.runners[]`: `labels`, `pool`) and the environments (`devops.environments[]`) are created by the CI/CD setup (`scripts/deploy/01-cicd-infra`), and the pipelines read the same values from the keys below. Each platform takes them in the way its documentation allows:

| Platform | How the file reads it | Set by | Documentation |
| --- | --- | --- | --- |
| GitHub Actions | `runs-on: [self-hosted, linux, "${{ vars.AZL_RUNNER_LABEL }}"]` and `environment: ${{ vars.AZL_ENVIRONMENT_... }}` (the `vars` context is allowed in `runs-on` and `environment`) | Task 05 sets repository variables | [Contexts: context availability](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability) |
| GitLab CI/CD | `tags: [$AZL_RUNNER_LABEL]` and `environment: name: $AZL_ENVIRONMENT_...` (`tags` and `environment:name` expand CI/CD variables) | Task 05 sets project variables (all environments, scope `*`) | [Where variables can be used](https://docs.gitlab.com/ci/variables/where_variables_can_be_used/) |
| Azure DevOps | `pool: name: ${{ parameters.agentPool }}` and `environment: ${{ parameters.approvalEnvironment }}` (a runtime parameter with no default; a macro variable is expanded only in task inputs, and template expressions do not see pipeline or library variables) | You enter them when you run the pipeline; task 05 lists the values | [Define variables](https://learn.microsoft.com/azure/devops/pipelines/process/variables#understand-variable-syntax), [Template expressions](https://learn.microsoft.com/azure/devops/pipelines/process/template-expressions) |

| Variable or parameter | Key in `infrastructure.yml` |
| --- | --- |
| `AZL_RUNNER_LABEL` (GitHub, GitLab) | `devops.pipelines.runner_label`, one of the `devops.runners[].labels` of the general runner |
| Agent pool (Azure DevOps) | `devops.runners[].pool` of the general runner |
| `AZL_ENVIRONMENT_OS_CONFIGURATION` | `devops.pipelines.environments.os_configuration` |
| `AZL_ENVIRONMENT_ARM_DEPLOYMENT` | `devops.pipelines.environments.arm_deployment` |
| `AZL_ENVIRONMENT_CICD_INFRA` | `devops.pipelines.environments.cicd_infra` |
| `AZL_ENVIRONMENT_TERRAFORM_DEPLOYMENT` | `devops.pipelines.environments.terraform_deployment` |
| Storage wipe approval (Azure DevOps OS configuration) | `devops.pipelines.environments.os_configuration_clear_storage` |

Each environment is an entry of `devops.environments[]` with `approval_required: true`; task 05 stops when a name is not. Every variable and parameter is registered as a `pipeline_inputs` entry of its file in the registry, with the key as `source_key`; `tests/pipelines/PipelineSettings.Tests.ps1` checks the files, the entries and the setup against each other.

The Azure DevOps sample `azure-local-deploy.yml` (Terraform and Ansible) is started by hand: its pool and environment are parameters with no default, so a run started by a push or a pull request could not supply them.

## Job timeouts and artifact retention

These describe the toolkit's own jobs and plan artifacts, not a deployment, so they stay in the files, each with a one-line comment: a deployment job (2.5 to 3 hours by Microsoft Learn, [Deploy Azure Local using an Azure Resource Manager deployment template](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)) has a limit above the wait of the script (`deployment.deploy_timeout_minutes`, default 360); the other limits are the toolkit's own. A saved Terraform plan is kept for a day, the reports of an OS configuration or an ARM deployment for 30 to 90 days.

## Prerequisites

### All Platforms
- Terraform >= 1.6
- Ansible >= 2.15 with required collections
- PowerShell >= 7.0
- Azure CLI with `stack-hci` extension

### Secrets / Variables
| Variable | Description |
|---|---|
| `ARM_CLIENT_ID` | Service Principal Application ID |
| `ARM_CLIENT_SECRET` | Service Principal Secret |
| `ARM_TENANT_ID` | Azure AD Tenant ID |
| `ARM_SUBSCRIPTION_ID` | Target Azure Subscription ID |
| `DOMAIN_ADMIN_PASSWORD` | On-premises domain admin password |
| `CLUSTER_NAME` | Azure Local cluster name |
| `CLUSTER_RESOURCE_GROUP` | Cluster resource group name |

### Self-Hosted Runner
The on-premises configuration stages require a self-hosted runner (the one in `devops.runners[]`, with the label `devops.pipelines.runner_label`) with:
- Network access to cluster nodes (WinRM port 5986)
- Network access to domain controllers (LDAP 389, Kerberos 88)
- Python 3.10+ with Ansible installed
- PowerShell 7.0+
- Azure CLI authenticated

## Customization

1. Copy the pipeline file for your platform to the appropriate location
2. Update CI/CD variables/secrets with your environment values
3. Adjust stage triggers and approval gates per your change management process
4. Configure the self-hosted runner with on-premises network access

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

- GitHub Actions: `github/os-configuration.yml` (environment `azure-local-os-configuration` with required reviewers; OIDC).
- GitLab CI: `gitlab/os-configuration.gitlab-ci.yml` (manual apply job, `resource_group`; managed identity or OIDC id_token).

Where the master file and the handoff files come from, the permissions of the pipeline identity and the exit codes are in [OS configuration and ARM deployment](../docs/os-configuration-and-arm-deployment.md#run-it-in-one-go).

## ARM Validate and Deploy (schema 5, one script)
The Terraform and Ansible pipelines above do not call the schema 5 deployment script. These do, with an approval between Validate and
Deploy, OIDC sign-in and no client secret. Guide: [docs/arm-deployment-guide.md](../docs/arm-deployment-guide.md).
- **GitHub Actions**: `github-actions/arm-deployment.yml` (environment `azure-local-deploy`)
- **GitLab CI**: `gitlab/stages/arm-deployment.yml` (declares its own stages; include it from a pipeline of its own)
- **Azure DevOps**: `azure-devops/arm-deployment.yml` (environment `azure-local-deploy` with an Approvals check)

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
The on-premises configuration stages require a self-hosted runner with:
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

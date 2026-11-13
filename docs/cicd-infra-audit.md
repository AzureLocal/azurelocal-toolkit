# CI/CD infrastructure: audit of the documented flow against the toolkit

Scope: the azurelocal.cloud pages `automation/01-cicd-infra` (tasks 01 to 06), `automation/02-cicd-pipelines`, `automation/03-automation-guides` (Terraform, Ansible), `implementation/02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment`, and the ZTP pages `simplified-provisioning/automation/prerequisites` and `run-from-pipeline`, checked against this repository at `origin/main` (commit 05eb0e0).

Status words: **real** = does what the page says; **scaffold** = compiles or parses but does nothing for the task (or fails); **missing** = not in the repository.

The "After" column says what this branch adds. Paths are relative to the repository root.

## Result in ten lines

1. `src/terraform/modules/cicd-runner`, which the docs name in the index and in task 06, did **not exist**. It is now there.
2. Task 06's `Deploy-CicdRunners.ps1` was a scaffold that **failed to run**: the line `-Configuration [ordered]@{` is not valid PowerShell, so the script threw before doing anything. The same line is in the standalone script of tasks 01 to 05 (and in six scripts of other phases).
3. The orchestrated scripts of all six tasks call `Invoke-DeploymentOrchestrated`, which logs "standards-compliant scaffold" and, when no credential resolves, opens an interactive `Get-Credential` prompt. They create nothing.
4. The `azurecli` variants are the same scaffold wrapper. The `bash` variants of tasks 02 to 05 are scaffolds. Only `bash` tasks 01 and 06 hold real commands, copied from the page: not idempotent, no `-WhatIf`, task 01 prints the client secret, task 06 takes the token as a `--token` argument. (The task 01 Bash script has since been removed; the task 06 one remains.)
5. The pages describe a client secret (`ARM_CLIENT_SECRET`) and runner token variables (`runner_token`, `azdo_pat`). The pipelines and the new code use a federated credential (OIDC) or managed identity, and the runner reads its token from Key Vault. The page and the code differ here on purpose; the docs page needs an edit.
6. The six Terraform modules and the Ansible roles and playbooks exist as the pages say, but `terraform validate` fails on `environments/azure-local` (the `security` module's `azurerm_security_center_contact` has no `name`), and `terraform fmt -check` fails on two files there. The GitLab and GitHub pipelines run both checks, so they would fail.
7. The pipelines exist for all three platforms but use a client secret, not the OIDC the GitHub page claims, and none of them knows about a Windows runner or the `ztp` label.
8. Nothing exists for the ZTP runner: no Windows runner definition, no NSG for TCP 445 from the BMCs, no managed identity roles, no `ztp` label, no approval pipeline.
9. The docs promise `config/variables/variables.yml` keys (`cicd.*`). The master file is `infrastructure.yml` (schema 5), which already has a `devops` section for one runner. This branch extends that section (schema 5.5) rather than adding a second one.
10. Ansible has no role that configures a runner. Added: `cicd_runner`.

## Tasks 01 to 06

| Task | Page says | Toolkit before | Status before | After |
| --- | --- | --- | --- | --- |
| 01 Bootstrap | App registration and service principal, Contributor and User Access Administrator on each subscription, register `Microsoft.Compute` and `EncryptionAtHost`, Graph permission, admin consent | `scripts/deploy/01-cicd-infra/phase-01-cicd-setup/task-01-bootstrap/powershell/New-CicdBootstrap.ps1` (fails on `-Configuration [ordered]@{`); `.../Invoke-CicdBootstrap-Orchestrated.ps1` (scaffold); `.../azurecli/az-bootstrap-cicd-sp.ps1` (scaffold); `.../bash/az-bootstrap-cicd-sp.sh` (the page's commands, not idempotent, prints the secret; since removed, `New-CicdBootstrap.ps1` does the whole task) | scaffold; bash real but unsafe | real: idempotent, `-WhatIf`, federated credentials per platform, no secret unless asked and then only into Key Vault |
| 02 Create project | Repository or project from the Azure Local template, private, named `<org>-azurelocal` | `.../task-02-create-project/powershell/New-CicdProject.ps1` (fails), `Invoke-CicdProject-Orchestrated.ps1`, `azurecli/az-create-cicd-project.ps1`, `bash/az-create-cicd-project.sh` | scaffold | real for GitHub, GitLab, Azure DevOps |
| 03 Configure project | Branch protection, approvals, squash only, secret scanning, push rules, per platform | `.../task-03-configure-project/powershell/Set-CicdProjectConfiguration.ps1` and the same three wrappers | scaffold | real for the three platforms |
| 04 Create environments | Environments `azr-prod-us` and others, with approvers and a `main`-only branch rule | `.../task-04-create-environments/powershell/New-CicdEnvironments.ps1` and wrappers | scaffold | real for the three platforms |
| 05 Configure variables | `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET` per environment (secrets, masked, variable group) | `.../task-05-configure-variables/powershell/Set-CicdVariables.ps1` and wrappers | scaffold | real for the three platforms; no client secret by default (OIDC) |
| 06 Deploy runners | Terraform module `cicd-runner` for Azure VM or VMSS, or an on-premises VM, with labels and the token | `.../task-06-deploy-runners/powershell/Deploy-CicdRunners.ps1` (fails), `Invoke-CicdRunners-Orchestrated.ps1` (scaffold), `azurecli/az-deploy-runners.ps1` (scaffold), `bash/az-deploy-runners.sh` (on-premises Ubuntu install, `--token` on the command line) | scaffold; bash real for an on-premises Ubuntu VM only | real: wraps `terraform init`, `validate`, `plan`, and `apply` only with `-Apply` |
| Config paths | `cicd.project.*`, `cicd.environments[]`, `cicd.runners.*` in `variables.yml` | None of these keys exist in `config/variables`. `config/variables/schema/infrastructure.schema.json` has a one-runner `devops` section | missing | `devops` extended in schema 5.5 (`config/infrastructure/`) |

## Terraform claims

| Page says | Toolkit | Status before | After |
| --- | --- | --- | --- |
| Module `azurelocal-toolkit//terraform/modules/cicd-runner` (index and task 06) | not in `src/terraform/modules`; the path also lacks the `src/` prefix | missing | `src/terraform/modules/cicd-runner` |
| Inputs `runner_type`, `runner_token`, `azdo_pat`, `vm_count`, `os_type`, `runner_labels` | none | missing | `platform`, `registration_secret` (names only), `runner_count`, `os_type`, `purpose`, `extra_labels`. Token variables are deliberately absent |
| Six modules: landing-zone, networking, identity, monitoring, security, compute | `src/terraform/modules/*` | real | unchanged |
| Provider requirements `azurerm ~> 4.0`, `azuread ~> 3.0`, `random ~> 3.0` | `src/terraform/environments/azure-local/providers.tf` | real | the new module uses `azurerm ~> 4.0` and `random ~> 3.0` |
| Backend bootstrap module | `src/terraform/backend` | real (not run) | the new environment uses a partial `backend "azurerm" {}` with `backend.hcl.example` |
| `environments/azure-local` validates and is formatted (the pipelines run both) | `terraform init -backend=false && terraform validate` fails: `azurerm_security_center_contact.main` needs `name` (`modules/security/main.tf` line 26). `terraform fmt -check` lists `environments/azure-local/main.tf` and `variables.tf` | real but broken | fixed later (registry 5.0.43): `name = "default"` added to the contact, `terraform fmt` applied, `terraform validate` passes on the azure-local, backend and cicd-infra environments |
| `Export-TerraformTfvars` generates tfvars from `variables.yml` | `scripts/common/utilities/helpers/config-loader.ps1`; reads the old `variables.yml`, not `infrastructure.yml` | real for the old registry; not wired to schema 5 | removed (registry 5.0.43). `config/variables/scripts/New-IacVariableFiles.ps1` writes the tfvars of every environment from `infrastructure.yml`; task 06 uses the same function for cicd-infra |
| Environment for the runners | none | missing | `src/terraform/environments/cicd-infra` |

## Ansible claims

| Page says | Toolkit | Status before | After |
| --- | --- | --- | --- |
| Seven roles, six playbooks, collections, inventory with `domain_controllers`, `management`, `cluster_nodes` | `src/ansible/roles/*` (7), `playbooks/01` to `05` and `site.yml`, `collections/requirements.yml`, `inventory/hosts.yml.example` | real (roles not run; no Ansible on this workstation) | unchanged |
| `Export-AnsibleVars` writes `inventory/group_vars/all.yml` | `config-loader.ps1`; `all.yml` is a hand-edited example | real for the old registry | removed (registry 5.0.43). `New-IacVariableFiles.ps1` writes `group_vars/all.yml` and `host_vars/<node>.yml` from `infrastructure.yml` |
| Configure a runner or registered host | none | missing | role `cicd_runner`, playbook `00-cicd-runner.yml`, inventory example |
| Windows over WinRM 5986 with Kerberos | `inventory/hosts.yml.example` | real | the new inventory example adds runner groups |

## Pipeline claims

| Page says | Toolkit | Status before | After |
| --- | --- | --- | --- |
| GitLab: stages validate to validate-deployment, templates `terraform-plan-apply.yml` and `ansible-playbook.yml` | `pipelines/gitlab/.gitlab-ci.yml`, `stages/*.yml`, `templates/*.yml` | real; uses `ARM_CLIENT_SECRET`; `tags: [azurelocal, self-hosted]` on every job; the apply job stores `terraform.tfstate` as an artifact | `pipelines/gitlab/stages/deploy-cicd-infra.yml` |
| GitHub: OIDC (`id-token: write`), environment approval, self-hosted runner | `pipelines/github-actions/azure-local-deploy.yml` | real, but its jobs read `ARM_CLIENT_SECRET` | `pipelines/github-actions/cicd-infra.yml` (OIDC) |
| Azure DevOps: service connection, variable group, environment, pool `AzureLocal-SelfHosted` | `pipelines/azure-devops/azure-local-deploy.yml` | real | `pipelines/azure-devops/cicd-infra.yml` |
| Label or pool routing for Azure and on-premises runners | `runs-on: [self-hosted, azurelocal]` only | partial | the new pipelines route `[self-hosted, linux, azure]` and `[self-hosted, windows, ztp]` |
| Manual approval before the destructive Boot stage (ZTP) | none in this repository (the ZTP page points to `azurelocal-ztp`) | missing here | documented; the Windows `ztp` runner and the environment gate exist |

## ZTP runner requirements (`prerequisites` and `run-from-pipeline`)

| Requirement | Toolkit before | After |
| --- | --- | --- |
| Self-hosted Windows runner on the management network | none | module `os_type = "windows"`, `purpose = "ztp"` |
| BMC to runner on TCP 445 | none | NSG rule `Allow-Inbound-BMC-SMB`, source `bmc_cidrs` only, nothing else inbound |
| Runner to BMC 443 and to nodes on WinRM 5985 | none | outbound rules to `reachable_cidrs` and `bmc_cidrs`, ports in `reachable_tcp_ports` |
| Elevated service, long timeouts | none | service as `NT AUTHORITY\SYSTEM`; the pipelines set the job timeout to 480 minutes |
| Managed identity for `-UseManagedIdentity` | none | user-assigned identity with the roles in the table of `docs/cicd-infra-deployment.md` |
| Label or pool just for ZTP (`ztp`) | none | label `ztp` (GitHub), capability `ztp` and its own pool (Azure DevOps) |
| PowerShell 7, Az, `powershell-yaml`, Bicep on the runner | none | installed by the Run Command bootstrap |
| Persistent folder outside the workspace | none | data disk, folder `AZL_ZTP_ROOT`, access for SYSTEM and Administrators only |
| Manual approval between plan and Boot | none | environment `ztp-reinstall` in the new pipelines |

## What stays a scaffold

- The `azurecli` and `bash` variants of tasks 02 to 05 and the `bash` variant of task 06 keep their old content (the task 01 Bash script has been removed), except that the `azurecli` variants now call the PowerShell implementation. Bash is outside the repository's scripting standard; the docs page should stop pointing to it. Update: the remaining Bash scripts are removed; the toolkit holds no Bash.
- The standalone scaffold line `-Configuration [ordered]@{` was in 12 scripts under `scripts/deploy`; the six in `01-cicd-infra` are replaced here and six others remain.

# Source for the azurelocal.cloud AUTOMATION guide: ARM Validate and Deploy

**Where this goes.** The **automation guide** of azurelocal.cloud (`docs/automation/` in the azurelocal.github.io repository,
next to the CI/CD pipeline pages and the PowerShell guide), as one page and, when it is time, a section on each of the three
pipeline pages. It does **not** go into the implementation guide. The implementation guide (`docs/implementation/`) keeps the
manual steps of Phase 05 (portal and ARM template routes) and only gets a link to the scripts (see the last section here).

**Status.** Draft written 2026-11-07 for the move. Nothing in azurelocal.github.io was changed by this work. Move it with the
same review as any automation guide page: check every statement against the toolkit at the commit you publish for.

**Source of truth.** The toolkit: `docs/arm-deployment-guide.md` (operators), `docs/design/arm-validate-deploy.md` (design),
`config/known-issues/arm-deployment.json` (known failures), `config/azure/arm-templates/parameter-sources.json` (key to
parameter map). When the toolkit changes, change the guide in the same release (requirement D19).

Suggested front matter for the Docusaurus page:

```yaml
---
title: "ARM Validate and Deploy automation"
sidebar_label: "ARM Validate and Deploy"
description: "One command, from a jump server or a pipeline, that checks readiness, validates, waits for approval, deploys and explains failures"
---
```

---

# ARM Validate and Deploy automation

After the machines are provisioned (ZTP or an ISO install) and their operating system is configured, the cluster is created by
an ARM deployment: Microsoft's quickstart template, run first in **Validate** mode and then in **Deploy** mode. The toolkit
automates that step with one script that works the same on a jump server and in a pipeline.

## What it does

1. **Reads** the master `infrastructure.yml`, the OS configuration report and, if you have one, the ZTP handoff.
2. **Generates** every parameter of the right Microsoft template for your design and shows which file key fed which parameter.
3. **Checks readiness**, read-only: the operating system configuration converged on every node, the Arc machines are Connected
   and correctly named, the right build everywhere, DNS, time, Active Directory, Key Vault secrets, resource providers,
   permissions, names, and no failed deployment waiting to be damaged by a second Validate.
4. **Validates** and waits (10 to 30 minutes), reading Microsoft's step list as it goes.
5. **Asks for approval.** A pipeline has the platform's approval gate between the Validate job and the Deploy job.
6. **Deploys** and waits (2.5 to 3 hours).
7. **Explains a failure**: the failing step with the number the portal shows, the error text, the matching known issue with its
   cause and remediation, and what may be retried.
8. **Reports**: an event feed (JSON Lines) that monitoring can follow, `report.json`, `summary.md` and an exit code of 0, 1 or 2.

It is **idempotent**. A Validate that already passed with the same parameters is not run again. A deployment that is running is
attached to, not duplicated. A deployment that failed is resubmitted only when you say `-Resume`, because Microsoft warns that
another Validate after a failure can break license sync.

## The pieces

| Piece | Where in the toolkit |
| --- | --- |
| Entry point | `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1` |
| Module | `scripts/common/arm-deployment/AzlArmDeploymentRun.psm1` (the run) and `AzlArmDeployment.psm1` (templates, parameters, submit) |
| Known failures | `config/known-issues/arm-deployment.json` |
| Key to parameter map | `config/azure/arm-templates/parameter-sources.json` |
| Options in the master file | the `deployment` block, schema 5.6 (rule AZL-040) |
| Pipelines | `pipelines/github-actions/arm-deployment.yml`, `pipelines/gitlab/stages/arm-deployment.yml`, `pipelines/azure-devops/arm-deployment.yml` |

## Scenarios

Active Directory or local identity; Storage Spaces Direct, a Fibre Channel SAN, or hybrid (deployed as Storage Spaces Direct,
the SAN connected afterwards); switchless or switched storage; 1 to 16 machines; rack aware with Active Directory and Storage
Spaces Direct. Not generated yet, and reported as such with exit code 2: an iSCSI SAN, disconnected operations, Azure
Government with local identity or a SAN, rack aware with a SAN or with local identity.

## Run it by hand

```powershell
Connect-AzAccount
$arm = './scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1'
& $arm -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Plan
& $arm -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Validate
& $arm -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Deploy
```

## Run it from a pipeline

Use the file for your platform, set the project variables (names only in the files; task 05 of the CI/CD setup sets the runner label and the approval environment from `devops.pipelines`), and add the approval to the environment named by `devops.pipelines.environments.arm_deployment`.

- **GitHub Actions.** Required reviewers on the environment; OIDC through `azure/login`; the jobs are `preconditions`, `validate`, `deploy`.
- **GitLab CI.** The `arm-deploy` job is manual in a protected environment; OIDC through `id_tokens`. The file declares its own stages; include it from a pipeline of its own.
- **Azure DevOps.** An Approvals check on the environment; a service connection with workload identity federation.

None stores a client secret. Passwords are read from the Key Vault named by the `keyvault://` reference in the master file.

## Reading the result

Exit code 0: the part you asked for succeeded. 1: a precondition failed, or the validation or deployment failed or timed out.
2: bad input. The event feed `arm-deployment-events.jsonl` has one line per event: `RunStarted`, `PreconditionChecked`,
`ParametersGenerated`, `ValidationSubmitted`, `ValidationStep`, `ValidationPassed` or `ValidationFailed`, `ApprovalRequested`,
`DeploymentSubmitted`, `DeploymentStep`, `DeploymentSucceeded` or `DeploymentFailed` (with `step` and `knownIssue`), `RunCompleted`.

## The known failures it recognises

The table in `docs/arm-deployment-guide.md` (section "When it fails") lists them. One to know: machines provisioned by simplified provisioning get Arc machine names of the form `<device-id>-1`. A failure of the Deploy step that
sets up the Arc infrastructure (step 0.41, `ParentResourceNotFound`, the machine is looked up by host name) was reported against a prerelease build in
another environment; it has not been reproduced here. The run only warns, in every phase, and the remedy says how to set the Arc resource name to the host name
(it is fixed at onboarding). Nothing to do unless the Deploy hits it.

## What is not proven yet

State this on the published page until a lab run has confirmed it: the exact fields of the live deployment status, that a
resubmitted Deploy resumes at the failed step, the pipelines on a real runner, and the Active Directory lookup.

---

## For the implementation guide (links only)

In `docs/implementation/04-cluster-deployment/phase-05-cluster-deployment/`, on each ARM template page (S2D and SAN, AD and local
identity), add after the manual steps:

> **Automating this step.** The toolkit's `Invoke-AzureLocalArmDeployment.ps1` does the readiness checks, the parameter file, the
> Validate, the Deploy and the monitoring described on this page from the one `infrastructure.yml`, on a jump server or in a
> pipeline. See [ARM Validate and Deploy automation](/automation/arm-validate-deploy) in the automation guide.

and replace the references to the removed `Deploy-AzureLocalCluster-Standalone.ps1`, the placeholder `Invoke-DeployCluster-Orchestrated.ps1` and
`Generate-AzureLocal-Parameters.ps1` (which is not in the toolkit) with that link, or mark them legacy. The interactive
monitoring pages go too: `Monitor-Validation.ps1` and `Monitor-Deployment.ps1` are removed from the toolkit, and Sonar (azurelocal-sonar) shows the progress.

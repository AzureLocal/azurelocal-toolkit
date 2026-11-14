# Phase 05: cluster deployment

**Use `Invoke-AzureLocalArmDeployment.ps1`.** One command for a jump server or a pipeline: read-only preconditions (the OS
configuration converged, Arc machines, Key Vault secrets, providers, permissions, DNS, Active Directory, no leftover failed
deployment), Validate, an approval gate, Deploy, polling with a time limit, the failing step matched to a known issue, an event
feed, `report.json` and exit codes 0, 1 and 2. A failed Deploy is resumed rather than started over; a Validate that already
passed with the same parameters is not run again. Guide: [docs/arm-deployment-guide.md](../../../../docs/arm-deployment-guide.md).
Pipelines: `pipelines/github-actions/arm-deployment.yml`, `pipelines/gitlab/stages/arm-deployment.yml`,
`pipelines/azure-devops/arm-deployment.yml`.

`Invoke-AzureLocalClusterDeployment.ps1` below is the earlier, lower-level script (one mode per run, no report, no resume). The
`active-directory` and `local-identity` folders now hold only placeholders (scripts that end with exit code 3 and change nothing): the legacy scripts that
read the older `variables.yml` layout are removed ([docs/arm-deployment-audit.md](../../../../docs/arm-deployment-audit.md), section 1.4). The run settings file of the entry scripts is `-SettingsFile`.

**Schema 5 path (current):** ARM Validate, then Deploy, generated from `infrastructure.yml`.

```powershell
# Plan: writes the parameter file and prints the parameters; submits nothing
./Invoke-AzureLocalClusterDeployment.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -NodeReportPath <osconfig-report.json>
# Validate (about 10 to 30 minutes), then read the steps
./Invoke-AzureLocalClusterDeployment.ps1 ... -Mode Validate -Execute
# Deploy: a separate, explicit run (2.5 to 3 hours)
./Invoke-AzureLocalClusterDeployment.ps1 ... -Mode Deploy -Execute
```

`New-AzureLocalArmParameters.ps1` writes just the parameter file (files only, no Azure call). The logic is in
`scripts/common/arm-deployment`; the parameter lists of Microsoft's quickstart templates are in
`config/azure/arm-templates/template-parameters.json`. Prerequisites and the keys read:
[docs/os-configuration-and-arm-deployment.md](../../../../docs/os-configuration-and-arm-deployment.md).


# Phase 05: cluster deployment

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

The `active-directory` and `local-identity` folders hold the earlier scripts, which read the older `variables.yml` layout and
call a generator that was never in the repository.

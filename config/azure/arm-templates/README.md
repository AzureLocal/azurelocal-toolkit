# Azure ARM templates

The toolkit deploys an Azure Local instance with Microsoft's ARM quickstart templates. It keeps no parameter file of its own to fill in by hand: the parameters of a deployment are built from `infrastructure.yml`, the one variable file of the instance (its keys are in the master registry, `config/variables/schema/master-registry.yaml`).

## Directory structure

```text
arm-templates/
├── README.md                    # This file
├── template-parameters.json     # The parameters of each Microsoft quickstart template the toolkit can select
├── parameter-sources.json       # Which infrastructure.yml keys feed which ARM parameter
└── examples/                    # Example parameter files, GENERATED from the example infrastructure files
```

## Building the parameters of a deployment

`New-AzureLocalArmParameters.ps1` writes the full parameter file for the design of `infrastructure.yml` (Active Directory or local identity, Storage Spaces Direct or a SAN, rack aware), checked against the parameters of the template it selects. It reads files only and puts no secret in the file:

```powershell
./scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/New-AzureLocalArmParameters.ps1 `
    -InfrastructureFile ./infrastructure.yml -OutputPath ./arm/cluster.parameters.json
```

`Invoke-AzureLocalArmDeployment.ps1` builds the same parameters and runs the deployment. Mode Plan with `-Offline` changes nothing and does not touch Azure:

```powershell
./scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1 `
    -InfrastructureFile ./infrastructure.yml -Mode Plan -Offline -ReportDirectory ./arm-plan
```

The report directory then holds `<cluster>.parameters.json` (secrets are null in it) and `parameter-sources.md` (which key fed which ARM parameter). Both scripts build the parameters with `New-AzlArmParameterSet` (`scripts/common/arm-deployment/AzlArmDeployment.psm1`).

## Examples

[`examples/`](examples/README.md) holds parameter files built by that same code from the example infrastructure files of `config/variables/examples`, with example values only. They are generated: `config/variables/scripts/New-ArmParameterExample.ps1` writes them and its `-Check` (run by the tests) fails when one is out of date. Do not edit them.

## Microsoft's template

The templates come from [Azure Quickstart Templates, microsoft.azurestackhci](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci). The copy of the create-cluster template and Microsoft's sample parameter file that the tests compare against is a test fixture: `tests/fixtures/arm/microsoft-create-cluster`.

## References

- [Deploy Azure Local via ARM template](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)
- [ARM template best practices](https://learn.microsoft.com/azure/azure-resource-manager/templates/best-practices)
- [Azure Local documentation](https://learn.microsoft.com/azure/azure-local/)

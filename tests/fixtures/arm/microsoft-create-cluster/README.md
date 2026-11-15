# Microsoft's create-cluster quickstart template (test fixture)

`azuredeploy.json` and `azuredeploy.parameters.json` in this folder are **Microsoft's files, copied unchanged** from the Azure Quickstart Templates repository ([quickstarts/microsoft.azurestackhci/create-cluster](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster)). They are **not the toolkit's values** and no deployment reads them: the values in `azuredeploy.parameters.json` are Microsoft's sample values.

Only the tests read them, to check that the toolkit agrees with Microsoft's template:

- `tests/arm-deployment/ParameterSetDefaults.Tests.ps1`: the registry defaults equal the `defaultValue` of each template parameter, and the Network ATC QoS defaults equal the values of Microsoft's sample intent.

A deployment builds its parameters from `infrastructure.yml` with `New-AzlArmParameterSet` (`scripts/common/arm-deployment/AzlArmDeployment.psm1`); `New-AzureLocalArmParameters.ps1` writes them to a file. Example parameter files built that way are in `config/azure/arm-templates/examples`.

To refresh the copy, download both files from the address above and replace them here, then run the tests.

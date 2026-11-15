# ARM parameter examples (generated)

**Generated files. Do not edit.** Each `*.parameters.json` here is what the toolkit sends to Microsoft's quickstart template for one example design. `config/variables/scripts/New-ArmParameterExample.ps1` builds them from the example infrastructure files with the deployment's own code (`New-AzlArmParameterSet` and `ConvertTo-AzlArmParameterFile`, as `New-AzureLocalArmParameters.ps1` calls them); `-Check` fails when a file differs from what the builder writes. To change an example, change its infrastructure file and run the script.

| File | Built from | Design |
| --- | --- | --- |
| `active-directory-s2d-switched.parameters.json` | `config/variables/examples/infrastructure.example.yml` | Active Directory, Storage Spaces Direct on switched storage, two machines |
| `local-identity-s2d-switchless.parameters.json` | `config/variables/examples/scenarios/local-identity-switchless-iso.yml` | Local identity with Key Vault, switchless storage, two machines |
| `rack-aware-s2d.parameters.json` | `config/variables/examples/scenarios/rack-aware-ztp.yml` | Rack aware cluster, two zones of two machines |
| `fibre-channel-san.parameters.json` | `config/variables/examples/scenarios/disaggregated-fibre-channel-proxy.yml` | Disaggregated, external SAN over Fibre Channel |

The values are example values only (the IIC example company, documentation address ranges, zero GUIDs). Secrets are Key Vault references, never values. The inputs a real run takes from outside the file are fixed: no ZTP handoff (the Arc machine IDs are built from the subscription, the resource group and the machine names), no OS configuration report (the adapter names are the file's names), no SBE folder, and the zero GUID for the HCI resource provider when the file has none (the deployment looks it up).

For a real deployment, run `New-AzureLocalArmParameters.ps1` or `Invoke-AzureLocalArmDeployment.ps1` with your `infrastructure.yml` (see [../README.md](../README.md)).

# Tool mappings

The variables of the tools that live outside this repository (azurelocal-ztp, azurelocal-sonar, azurelocal-ranger, azurelocal-loadtools, azurelocal-draftsman) are registered in the master registry under `tools.<tool>.<kind>.<group>.<name>`. These CSVs map each name, as the tool writes it, to its registry path:

| File | Tool | Rows |
| --- | --- | --- |
| `ztp.csv` | azurelocal-ztp: script parameters, `ztp-provisioning.json` and OEM config keys, handoff schema 2 fields, state fields, secret names, environment variables | one per variable |
| `sonar.csv` | azurelocal-sonar: `Config.ps1` keys, command parameters, event fields, state fields, secret names, environment variables | one per variable |
| `ranger.csv` | azurelocal-ranger: configuration keys, WAF rule tunables, command parameters, environment variables | one per variable |
| `loadtools.csv` | azurelocal-loadtools: `variables.yml`, cluster, profile and alert rule files, script parameters, pipeline, Bicep and Ansible variables | one per variable |
| `draftsman.csv` | azurelocal-draftsman: URL parameters and `VITE_BASE` | one per variable |

Columns: `tool`, `kind`, `group` (the script, file or feed), `name`, `registry_path`, `read_at` (where the tool reads it).

A variable that is also a key of `infrastructure.yml` is registered once, at its `infrastructure.yml` path (`nodes[].bmc.ip_address`), not here.

The files are generated from the registry: `./config/variables/scripts/New-ToolMapping.ps1` (`-Check` compares). `tests/variables/ToolRegistry.Tests.ps1` fails when a file is out of date or names a path the registry lacks.

A new name in a tool is added to the registry first, then the tool uses it. To check a tool's checkout for parameters the registry does not know:

```powershell
./config/variables/scripts/Test-ToolParameterRegistration.ps1 -Tool ztp -Root D:\git\azurelocal\azurelocal-ztp
```

The test suite runs that check against the checkouts when `AZL_CHECK_EXTERNAL_TOOLS=1` is set, with `AZL_ZTP_REPO` and `AZL_SONAR_REPO` pointing at them.

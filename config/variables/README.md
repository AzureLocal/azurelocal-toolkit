# config/variables: the master of every variable

`schema/master-registry.yaml` is the master of every variable the toolkit, its tools and its documents use: the keys of `infrastructure.yml`, the parameters and settings of each tool, secret names, environment variables. Scripts, schemas, templates and documents conform to it, and the files that can be generated are generated from it.

## Layout

```text
config/variables/
  schema/
    master-registry.yaml          THE MASTER. Edit this.
    variables.schema.json         schema of a variables file (hand-maintained, accepts the infrastructure.yml sections)
    infrastructure.schema.json    GENERATED: the schema of infrastructure.yml (the validator reads this one)
    tools/<tool>.schema.json        GENERATED: the part of the schema one tool reads (one per tool that has keys)
    alias-policy.json, canonical-drift-allowlist.json, legacy-compatible-roots.json
  templates/                      GENERATED
    infrastructure.master.yml       every variable, with comments and allowed values
    scenarios/master.<switch>-<value>.yml   the master for one scenario choice
    tools/<tool>.yml                one template per tool: only the variables that tool reads (a strict subset of the master)
  examples/                       hand-written worked examples, tested against the schema and the rules
    infrastructure.example.yml, infrastructure.ztp.example.yml
    scenarios/*.yml
  docs/
    infrastructure-file.md        what infrastructure.yml is and how to fill it in
    MIGRATION.md                  where every key from the earlier files went, and the schema 5.x steps
    secret-references.md          secret references and the four providers (keyvault, env, file, command), the secrets section
    VARIABLES.md                  GENERATED: every key, type, required, default, example, who reads it
    VARIABLE-MAP.md               GENERATED: what variable goes where (by phase, tool, ARM parameter; who provides it, who reads it)
    variables-reference.metadata.psd1   where to get a value (facts the registry does not hold)
  tool-mappings/                  names of the variables of the other tools mapped to registry paths
  scripts/                        validators, the reader (VariableRegistry.psm1) and the generator
  reports/                        generated reports (variable-map.csv is the machine copy of the variable map)
```

## Registry first

**A new or changed variable is added to the registry first.** Then the script, the example and the document follow, and the generated files are regenerated. A variable that exists only in a script, an infrastructure file or a hand-edited schema is drift, and the tests fail on it.

1. Add the entry to `schema/master-registry.yaml` (see [Entry format](#entry-format)). Bump `_metadata.version`, add a `_metadata.change_log` entry and a line to the change log in the file header.
2. Run `./config/variables/scripts/New-InfrastructureArtifacts.ps1`. It rewrites the schema, the templates and `docs/VARIABLES.md` (the "Read by" column of that page is the `used_by` of the registry; nothing else lists readers). If a tool variable changed, also run `./config/variables/scripts/New-ToolMapping.ps1 -Tool ztp` and `-Tool sonar`. Commit the result with the registry change.
   Rules for the entry: the `example` is a documentation placeholder (RFC 5737 addresses `192.0.2.x`, `198.51.100.x`, `203.0.113.x`; the zero GUID; MACs `00:00:5E:00:53:xx`; `example.com`), never a value from a real environment. `used_by` lists only the tools whose code reads the key (Trailwright: writes it); the ids are in `_tool_catalog`. A key no tool reads yet is kept as a documented placeholder and its description says "Not read by the tools yet". An entry that replaces another is marked `deprecated` with `replaced_by`.
3. Update `schema/variables.schema.json` and `variables.example.yml` if the variable is part of a variables file, and a worked example if it belongs in one.
4. Run the checks below. All must pass.

Never edit a generated file: it carries a `GENERATED from master-registry.yaml` header, and `tests/variables/InfrastructureArtifacts.Tests.ps1` regenerates it and fails when it differs.

## Entry format

The 4.0 entries are unchanged. The sections of `infrastructure.yml` write children under an explicit `properties:` block (a variable can then be called `type`, `name` or `default`); a list is `type: array` with `items`; a map of free keys has `additionalProperties`.

| Attribute | Meaning |
| --- | --- |
| `type`, `description`, `required`, `default`, `enum`, `example`, `pattern`, `minimum`, `maximum`, `minLength`, `maxLength`, `minItems`, `maxItems` | As before. `required: true` means the parent requires it; rules that depend on the scenario are in `_schema_rules`. |
| `since` | The schema version that added the variable (`"5.4.3"`). |
| `deprecated`, `replaced_by`, `alias_for`, `expires_on` | A name kept for compatibility. Every alias is also in `schema/alias-policy.json`, with an expiry inside `rules.max_alias_age_days`. |
| `used_by` | The tools that read the variable (Trailwright: write it). A value is a tool id of `_tool_catalog`: `ztp` (azurelocal-ztp), `os_configuration`, `deployment`, `cicd_infra`, `monitoring` (azurelocal-sonar), `discovery` (Redfish), `trailwright`, `ranger`. A test fails on any other value. The template and the schema of each tool are generated from this. |
| `applies_when` | The scenario condition that makes it relevant (`scenario.identity is active_directory`). The scenario templates leave out what does not apply. |
| `format` | A named type from `_schema_defs` (`ipv4`, `cidr`, `mac`, `guid`, `kv_ref`, ...). `kv_ref` is a secret reference, never a secret value (`keyvault://<vault>/<secret>`, `env://<VARIABLE>`, `file://<name>` or `command://<name>`; see [secret-references.md](docs/secret-references.md)); those entries also carry `sensitive: true`. |
| `schema_extra` | Other JSON Schema keywords of the variable, kept as written (`anyOf`, `not`, `dependentRequired`). |
| `file_schema` | On a 4.0-form section that infrastructure.yml shares (`site`, `identity`, ...): the node's keywords in the infrastructure schema. |
| `data_path` (on a top-level section) | The path in a data file, when it differs from the section name: `file_metadata` is `_metadata`. |

Top-level `_schema_root` (header and the order of the sections), `_schema_defs` (named types) and `_schema_rules` (scope and scenario rules: if/then required keys) hold what JSON Schema needs verbatim.

## The generator

```powershell
./config/variables/scripts/New-InfrastructureArtifacts.ps1            # write everything
./config/variables/scripts/New-InfrastructureArtifacts.ps1 -Check     # exit 1 if anything on disk is stale
./config/variables/scripts/New-InfrastructureArtifacts.ps1 -Cut ztp -From ./infrastructure.yml -Out ./infrastructure.ztp.yml
```

**From the master file to a tool's input.** An operator keeps one `infrastructure.yml` per environment (start from `templates/infrastructure.master.yml`, a scenario template, or the nearest worked example). To give azurelocal-ztp or Sonar its input, cut that file: `-Cut ztp` (or `-Cut monitoring`) writes only the keys that tool reads, and the tool validates it against `schema/tools/ztp.schema.json` (or `monitoring.schema.json`). The cut is always a subset of the master file, and the master file is validated by the full schema and the rules of `Test-InfrastructureFile.ps1`. A tool schema checks the shape and values of the keys the tool reads; completeness of the whole file is the full schema's job.

## Variables owned by tools (`tools:`)

The registry also registers the variables each tool owns, apart from the keys of `infrastructure.yml`: `tools.<tool>.<kind>.<group>.<name>` for `os_configuration`, `ztp`, `sonar`, `arm_deployment`, `cicd_infra`, `discovery`, `ranger`, `loadtools`, `draftsman`, `terraform` and `ansible` (see "The own settings of a tool" in [docs/infrastructure-file.md](docs/infrastructure-file.md)). Kinds: `parameters`, `run_settings`, `guard_settings`, `config_keys`, `event_fields`, `state_fields`, `handoff_fields`, `secret_names`, `env_vars`, `terraform_variables`, `pipeline_variables`, `pipeline_inputs`, `ansible_variables`, and `variables` (the variables of `src/terraform` and `src/ansible`). The group is the script, file or feed (its `area` says which); each entry has the real `name`, `type`, `default`, `enum`, `required`, `read_at` and `description`.

- The Terraform and Ansible variables (`tools.terraform.variables`, `tools.ansible.variables`) each say where they come from: `class`, `source`, `infrastructure_key`, `form` and `target`. `scripts/New-IacVariableFiles.ps1` reads those entries and writes `terraform.tfvars.json`, `backend.hcl`, `group_vars/all.yml` and `host_vars/<node>.yml` from `infrastructure.yml`; `tests/variables/IacVariables.Tests.ps1` fails when a declared variable is not registered. See [Terraform and Ansible variable files](docs/infrastructure-file.md#terraform-and-ansible-variable-files-schema-5617).
- A script parameter that is not registered fails `tests/variables/ToolRegistry.Tests.ps1` (`Test-ToolParameterRegistration.ps1` reads the `param()` block).
- ZTP, Sonar, Ranger, Loadtools and Draftsman live in other repositories: [`tool-mappings/`](tool-mappings/README.md) maps their names to registry paths, and the same check runs on their checkouts with `AZL_CHECK_EXTERNAL_TOOLS=1`.
- The discovery variables describe the Dell Redfish discovery branch; its scripts are checked once it is merged.

## The variable map

[`docs/VARIABLE-MAP.md`](docs/VARIABLE-MAP.md) answers "what variable goes where": for every variable, where it is defined (registry path, type, default, allowed values), who provides the value (you, Trailwright, Dell/Redfish discovery, a Key Vault reference, a default), which tool templates carry it, which tool and function read it (the toolkit, azurelocal-ztp, azurelocal-sonar, Trailwright), what it becomes downstream (ARM template parameter, OS configuration step, Sonar configuration key, pre-cluster verification check) and whether anything reads it at all. It has views by phase, by tool and by ARM parameter, a "where do I set X" lookup for the 40 most used variables and a list of unread variables. [`reports/variable-map.csv`](reports/variable-map.csv) is the same data, one row per variable. The diagram is [`docs/diagrams/variable-flow.drawio`](docs/diagrams/variable-flow.drawio).

The map is **generated** from the registry and a scan of the code (the registry stays the only master); never edit it:

```powershell
./config/variables/scripts/New-VariableMap.ps1                    # regenerate: scans the toolkit; ZTP, Sonar and Trailwright from the committed snapshot
./config/variables/scripts/New-VariableMap.ps1 -RescanExternal    # also rescan the ZTP, Sonar and Trailwright checkouts
./config/variables/scripts/New-VariableMap.ps1 -Check             # exit 1 if a committed file is stale
```

Change a variable or a script that reads one, and the map changes: regenerate it and commit it with the change. `tests/variables/VariableMap.Tests.ps1` fails when the committed map is stale, when a registry variable is missing from it, and when an ARM parameter the builder produces is missing from the by-ARM-parameter table.

## No hard-coded values in scripts

`tests/variables/Enforcement.Tests.ps1` fails the build when a script under `scripts/` carries a value that a deployment chooses, or reads a key that is not in the registry. It uses the PowerShell parser, so comments and help text do not count. The rules:

- **A**: a key path read from the infrastructure file (`Get-AzlInfrastructureValue`, or the property chains and reader commands the variable map recognises) that the registry does not have.
- **B**: a literal IPv4 address or CIDR, a GUID, a DNS name, an Azure region name, a Key Vault name, an Azure resource name (`rg-`, `kv-`, `vnet-`, `snet-`, `nsg-`, `log-`, `vm-`, `iic-` and similar) or a value given to a subscription, tenant, resource group or vault.
- **C**: a parameter whose default is such a value.
- **D**: `Read-Host`, `Get-Credential`, `$Host.UI.Prompt*` or `[Console]::ReadLine` in a script that has `-InfrastructureFile`.

What is not a violation: values Microsoft or a protocol fixes. They are rule-level exceptions in the test, each with its reason: documentation, loopback, link-local, `0.0.0.0` and mask addresses, the Azure platform address `168.63.129.16`, the ranges Azure Local reserves for Arc resource bridge, the public DNS servers Azure Local refuses, `improbability.cloud`, `example.com`, `.net` and `.org`, Microsoft endpoints, the all-zero GUID and the built-in role, policy and application IDs the scripts use (each named). A host under a Microsoft suffix that names a customer resource (`<name>.blob.core.windows.net`, `<name>.vault.azure.net`) is still a violation.

Anything else is in one of two files next to the test:

| File | Holds | Rule |
|---|---|---|
| `tests/variables/enforcement-allowlist.psd1` | A reviewed exception: file, rule, literal, one-line reason. | Small. A line that no longer matches fails the test. |
| `tests/variables/enforcement-baseline.psd1` | Known debt in legacy scripts that are not migrated yet: file, rule, literal, `Count`, reason `legacy script, not yet migrated`. | The test passes with exactly these, prints how many there are, fails on one more (a new violation) and on one fewer (lower `Count` or remove the line). |

Both files write an address masked (`10.x.x.x/24`) and never hold an ID that is not Microsoft-fixed. A new violation is fixed in the script (read the value from the infrastructure file), not added to the baseline. `AZL_ENFORCE_DUMP=<file.csv>` writes every finding, before the two lists, to a file. What the test cannot see: values built at run time, short host names and plain names (`dc01`), values in files that are not PowerShell, and chains from variables it cannot tie to the infrastructure file.

## Checks

```powershell
./config/variables/scripts/validate-registry.ps1                      # structure
./config/variables/scripts/validate-variables.ps1 -StrictUnknown     # variables.example.yml: schema + every path in the registry
./config/variables/scripts/Compare-InfrastructureSchemaToRegistry.ps1 -FailOnGap   # generated schema vs registry (always clean; kept as a guard)
./config/variables/scripts/New-InfrastructureArtifacts.ps1 -Check
Invoke-Pester ./tests/variables, ./tests/infrastructure
```

`validate-variables.ps1` uses Python with PyYAML and jsonschema when they are installed, and otherwise runs the same two checks in PowerShell (`Test-VariablesFile.ps1`). `VariableRegistry.psm1` is the one reader of the registry structure; `InfrastructureArtifacts.psm1` builds the generated files.

## Reports

`reports/infrastructure-vs-registry-before.csv` is the gap when the registry was last behind (schema 5.6.0 against registry 4.0.0: 660 keys missing, 3 in conflict). `reports/infrastructure-vs-registry.csv` is the current state and must have no `missing` or `conflict` row.

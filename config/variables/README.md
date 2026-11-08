# config/variables: the master of every variable

`schema/master-registry.yaml` is the master of every variable the toolkit, its tools and its documents use. Scripts, `infrastructure.yml`, the JSON schemas and the documentation conform to it.

## Registry first

**A new or changed variable is added to the registry first.** Then the script, the schema, the example and the document follow. A variable that exists only in a script, an infrastructure file or `config/infrastructure/infrastructure.schema.json` is drift, and the tests fail on it (`tests/variables/RegistryFirst.Tests.ps1`).

1. Add the entry to `schema/master-registry.yaml` (see [Entry format](#entry-format)). Bump `_metadata.version`, add a `_metadata.change_log` entry and a line to the change log in the file header.
2. Update `schema/variables.schema.json` and `variables.example.yml` when the variable is part of a variables file.
3. Change `config/infrastructure/infrastructure.schema.json` (and the examples, `VARIABLES.md`) to match: same path, type, enum and default.
4. Run the checks below. All must pass.

## The two systems today

| | Registry (`config/variables`) | Infrastructure schema (`config/infrastructure`) |
| --- | --- | --- |
| What | The catalogue of every variable: name, type, default, allowed values, which tool needs it | The JSON Schema and the examples of `infrastructure.yml`, the file an operator fills in per environment |
| Canonical | Yes | No: it must agree with the registry |
| Validates | `variables.yml` (4.0 shape) and the 5.x sections, through `variables.schema.json` | `infrastructure.yml`, through `Test-InfrastructureFile.ps1` (schema plus the AZL-xxx rules) |

Since registry 4.1.0 every key of `infrastructure.yml` schema 5.0 to 5.6.0 is a registry variable at the same path (`nodes[].name`, `os_configuration.remoting.transport`). The 4.0 names (`ad_domain_fqdn`, `node_hostname`) stay as variables of the 4.0 `variables.yml`; where `MIGRATION.md` says a 4.0 name moved, the 5.x name is the one tools read.

## Entry format

The 4.0 entries are unchanged. Sections added in 4.1.0 write children under an explicit `properties:` block (a variable can then be called `type`, `name` or `default`); a list is `type: array` with `items`.

| Attribute | Meaning |
| --- | --- |
| `type`, `description`, `required`, `default`, `enum`, `example`, `pattern`, `minimum`, `maximum`, `minLength`, `maxLength`, `minItems`, `maxItems` | As before. `required: true` means the parent requires it; rules that depend on the scenario are in `_schema_rules`. |
| `since` | The schema version that added the variable (`"5.4.3"`). |
| `deprecated`, `replaced_by`, `alias_for`, `expires_on` | A name kept for compatibility. Every alias is also in `schema/alias-policy.json`, with an expiry inside `rules.max_alias_age_days`. |
| `used_by` | The purposes that need the variable: `ztp`, `os_configuration`, `deployment`, `cicd_infra`. |
| `applies_when` | The scenario condition that makes it required (`scenario.identity is active_directory`). |
| `format` | A named type from `_schema_defs` (`ipv4`, `cidr`, `mac`, `guid`, `kv_ref`, ...). `kv_ref` is a `keyvault://<vault>/<secret>` reference, never a secret value; those entries also carry `sensitive: true`. |
| `schema_extra` | Other JSON Schema keywords of the variable, kept as written (`anyOf`, `not`, `dependentRequired`). |
| `data_path` (on a top-level section) | The path in a data file, when it differs from the section name: `file_metadata` is `_metadata`. |

Top-level `_schema_root`, `_schema_defs` and `_schema_rules` hold the header, the named types and the scope and scenario rules of the infrastructure schema, verbatim.

## Checks

```powershell
./config/variables/scripts/validate-registry.ps1                      # structure
./config/variables/scripts/validate-variables.ps1 -StrictUnknown     # variables.example.yml: schema + every path in the registry
./config/variables/scripts/Compare-InfrastructureSchemaToRegistry.ps1 -FailOnGap   # infrastructure schema vs registry; writes reports/infrastructure-vs-registry.csv
Invoke-Pester ./tests/variables
```

`validate-variables.ps1` uses Python with PyYAML and jsonschema when they are installed, and otherwise runs the same two checks in PowerShell (`Test-VariablesFile.ps1`). `VariableRegistry.psm1` is the one reader of the registry structure.

## Reports

`reports/infrastructure-vs-registry-before.csv` is the gap when the registry was last behind (schema 5.6.0 against registry 4.0.0: 660 keys missing, 3 in conflict). `reports/infrastructure-vs-registry.csv` is the current state and must have no `missing` or `conflict` row.

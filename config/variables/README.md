# config/variables: the master of every variable

`schema/master-registry.yaml` is the master of every variable the toolkit, its tools and its documents use: the keys of `infrastructure.yml`, the parameters and settings of each tool, secret names, environment variables. Scripts, schemas, templates and documents conform to it, and the files that can be generated are generated from it.

## Layout

```text
config/variables/
  schema/
    master-registry.yaml          THE MASTER. Edit this.
    variables.schema.json         schema of a variables file (hand-maintained, accepts the infrastructure.yml sections)
    infrastructure.schema.json    GENERATED: the schema of infrastructure.yml (the validator reads this one)
    purposes/<purpose>.schema.json  GENERATED: the part of the schema one purpose reads
    alias-policy.json, canonical-drift-allowlist.json, legacy-compatible-roots.json
  templates/                      GENERATED
    infrastructure.master.yml       every variable, with comments and allowed values
    scenarios/master.<switch>-<value>.yml   the master for one scenario choice
    purposes/<purpose>.yml          only the variables one purpose reads (a strict subset of the master)
  examples/                       hand-written worked examples, tested against the schema and the rules
    infrastructure.example.yml, infrastructure.ztp.example.yml
    scenarios/*.yml
  docs/
    infrastructure-file.md        what infrastructure.yml is and how to fill it in (was config/infrastructure/README.md)
    MIGRATION.md                  where every key from the earlier files went, and the schema 5.x steps
    VARIABLES.md                  GENERATED: every key, type, required, default, example, who reads it
    variables-reference.metadata.psd1   where to get a value (facts the registry does not hold)
  tool-mappings/                  names of ZTP and Sonar variables mapped to registry paths
  scripts/                        validators, the reader (VariableRegistry.psm1) and the generator
  reports/                        generated reports
config/infrastructure/            two generated stubs for tools that read them in place, and pointers (see its README)
```

## Registry first

**A new or changed variable is added to the registry first.** Then the script, the example and the document follow, and the generated files are regenerated. A variable that exists only in a script, an infrastructure file or a hand-edited schema is drift, and the tests fail on it.

1. Add the entry to `schema/master-registry.yaml` (see [Entry format](#entry-format)). Bump `_metadata.version`, add a `_metadata.change_log` entry and a line to the change log in the file header.
2. Run `./config/variables/scripts/New-InfrastructureArtifacts.ps1`. It rewrites the schema, the templates, the stubs and `docs/VARIABLES.md` (the "Read by" column of that page is the `used_by` of the registry; nothing else lists readers). If a tool variable changed, also run `./config/variables/scripts/New-ToolMapping.ps1 -Tool ztp` and `-Tool sonar`. Commit the result with the registry change.
   Rules for the entry: the `example` is a documentation placeholder (RFC 5737 addresses `192.0.2.x`, `198.51.100.x`, `203.0.113.x`; the zero GUID; MACs `00:00:5E:00:53:xx`; `example.com`), never a value from a real environment. `used_by` lists only the purposes whose code reads the key. A key no tool reads yet is kept as a documented placeholder and its description says "Not read by the tools yet". An entry that replaces another is marked `deprecated` with `replaced_by`.
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
| `used_by` | The purposes that need the variable: `ztp`, `os_configuration`, `deployment`, `cicd_infra`, `monitoring` (Sonar), `discovery` (Redfish). The purpose templates and schemas are cut from this. |
| `applies_when` | The scenario condition that makes it relevant (`scenario.identity is active_directory`). The scenario templates leave out what does not apply. |
| `format` | A named type from `_schema_defs` (`ipv4`, `cidr`, `mac`, `guid`, `kv_ref`, ...). `kv_ref` is a `keyvault://<vault>/<secret>` reference, never a secret value; those entries also carry `sensitive: true`. |
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

**From the master file to a tool's input.** An operator keeps one `infrastructure.yml` per environment (start from `templates/infrastructure.master.yml`, a scenario template, or the nearest worked example). To give azurelocal-ztp or Sonar its input, cut that file: `-Cut ztp` (or `-Cut monitoring`) writes only the keys that purpose reads, and the tool validates it against `schema/purposes/ztp.schema.json` (or `monitoring.schema.json`). The cut is always a subset of the master file, and the master file is validated by the full schema and the rules of `Test-InfrastructureFile.ps1`. A purpose schema checks the shape and values of the keys the purpose reads; completeness of the whole file is the full schema's job.

## Variables owned by tools (`tools:`)

The registry also registers the variables each tool owns, apart from the keys of `infrastructure.yml`: `tools.<tool>.<kind>.<group>.<name>` for `os_configuration`, `ztp`, `sonar`, `arm_deployment`, `cicd_infra` and `discovery`. Kinds: `parameters`, `run_settings`, `guard_settings`, `config_keys`, `event_fields`, `state_fields`, `handoff_fields`, `secret_names`, `env_vars`, `terraform_variables`, `pipeline_variables`, `pipeline_inputs`, `ansible_variables`. The group is the script, file or feed (its `area` says which); each entry has the real `name`, `type`, `default`, `enum`, `required`, `read_at` and `description`.

- A script parameter that is not registered fails `tests/variables/ToolRegistry.Tests.ps1` (`Test-ToolParameterRegistration.ps1` reads the `param()` block).
- ZTP and Sonar live in other repositories: [`tool-mappings/`](tool-mappings/README.md) maps their names to registry paths, and the same check runs on their checkouts with `AZL_CHECK_EXTERNAL_TOOLS=1`.
- The discovery variables describe the Dell Redfish discovery branch; its scripts are checked once it is merged.

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

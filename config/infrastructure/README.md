# config/infrastructure: moved

The `infrastructure.yml` schema, templates, examples and documents moved under [`config/variables`](../variables/README.md), where the master registry is. **The registry is the master**; the schema, the templates and the variables reference are generated from it.

| Was here | Now |
| --- | --- |
| `infrastructure.schema.json` | [`config/variables/schema/infrastructure.schema.json`](../variables/schema/infrastructure.schema.json) (generated) |
| `infrastructure.example.yml`, `infrastructure.ztp.example.yml` | [`config/variables/examples/`](../variables/examples) |
| `examples/*.yml` | [`config/variables/examples/scenarios/`](../variables/examples/scenarios) |
| `README.md` (this page's old content) | [`config/variables/docs/infrastructure-file.md`](../variables/docs/infrastructure-file.md) |
| `MIGRATION.md` | [`config/variables/docs/MIGRATION.md`](../variables/docs/MIGRATION.md) |
| `VARIABLES.md` | [`config/variables/docs/VARIABLES.md`](../variables/docs/VARIABLES.md) (generated) |
| `variables-reference.metadata.psd1` | [`config/variables/docs/variables-reference.metadata.psd1`](../variables/docs/variables-reference.metadata.psd1) |

## The two generated stubs

Two files stay here as generated copies, because other repositories read them in place:

| File | Read by |
| --- | --- |
| `infrastructure.schema.json` | azurelocal-ztp (validates its input), azurelocal-sonar, Trailwright (writes a file that validates against it); the schema's `$id` is unchanged |
| `infrastructure.example.yml`, `infrastructure.ztp.example.yml` | azurelocal-ztp and Trailwright (starting templates), azurelocal-sonar (test input) |

They are not edited. `./config/variables/scripts/New-InfrastructureArtifacts.ps1` refreshes them, and a test fails when one differs from its source. New code reads the files under `config/variables`.

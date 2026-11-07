# Phase 03: OS configuration

**Schema 5 path (current):** `Set-AzureLocalNodeConfiguration.ps1`. One idempotent script reads each node, changes only what
differs from `infrastructure.yml`, and reports; it replaces running tasks 01 to 13 one by one. Without `-Execute` it is a plan.
Prerequisites, roles and the keys it reads: [docs/os-configuration-and-arm-deployment.md](../../../../docs/os-configuration-and-arm-deployment.md).

```powershell
# Plan: reads each node through Azure Arc Run Command, changes nothing
./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json
# Make the changes
./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -StagingStorageAccount <account> -Execute
```

The modules are in `scripts/common/node-configuration` (spec, comparison, transports, the node scripts) and
`scripts/common/azure-local`. The `task-NN-*` folders below are the earlier per-task scripts, which read the older
`variables.yml`; they stay for reference.

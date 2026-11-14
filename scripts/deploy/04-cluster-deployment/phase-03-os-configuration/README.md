# Phase 03: OS configuration

**Schema 5 path (current):** two scripts, one flow.

- `Invoke-AzureLocalOsConfiguration.ps1` is the entry point: the whole instance in ONE run (`-Mode Plan`, then `-Mode Apply`). It merges the ZTP handoffs,
  works out per node whether it was provisioned by ZTP (Arc Run Command) or installed from an ISO (WinRM, plus the computer name and Arc registration),
  plans for all nodes, applies node by node, verifies with a Plan pass, and writes `report.json`, `summary.md`, `plan-report.json` and `wipe-list.txt`.
  `os_configuration.clear_storage: true` (schema 5.4.3) lets Apply wipe leftover local storage; the Plan prints which disks. The same command runs in
  GitHub Actions and GitLab CI (`pipelines/github/os-configuration.yml`, `pipelines/gitlab/os-configuration.gitlab-ci.yml`).
- `Set-AzureLocalNodeConfiguration.ps1` is what it calls once per node, and what you run for a single node. One idempotent script reads each node, changes
  only what differs from `infrastructure.yml`, and reports; it replaces running tasks 01 to 13 one by one. Without `-Execute` it is a plan.
Prerequisites, roles and the keys it reads: [docs/os-configuration-and-arm-deployment.md](../../../../docs/os-configuration-and-arm-deployment.md).

```powershell
# Plan: reads each node through Azure Arc Run Command, changes nothing
./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json
# Make the changes
./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffFile ./ztp-handoff.json -Execute

# The whole instance in one run: plan, then apply
./Invoke-AzureLocalOsConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Plan -ReportDirectory ./out
./Invoke-AzureLocalOsConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -HandoffPath ./ztp-state -Mode Apply -ReportDirectory ./out
```

The SBE package is side-loaded **only when you ask for it** (opt-in). `hardware.sbe.delivery` in `infrastructure.yml` has no default: unset, `none` or `skip`
means nothing is side-loaded, the Sbe step is Skipped ("no SBE side-loading requested") and so is the Drivers step ("no SBE configured"). Ask for it only if your
hardware partner provides an SBE: `winrm_copy` (copied over WinRM from the host that runs the script; add `-Credential`) or `node_pull` (each node downloads it from
`hardware.sbe.node_pull_url` and checks the SHA-256); it is delivered last. Azure Arc Run Command cannot carry a file and there is no storage account route.

The modules are in `scripts/common/node-configuration` (spec, comparison, transports, the node scripts) and
`scripts/common/azure-local`. The `task-NN-*` folders below are the earlier per-task scripts, which read the older
`variables.yml`; they stay for reference.

Two per-task scripts are removed because the schema 5 path replaces them and they carried defaults that a deployment chooses:

- `Enable-WinRmConfiguration.ps1` (task 01) set the TrustedHosts of the node it ran on to a management subnet that it assumed. The RemoteManagement step of
  `Set-AzureLocalNodeConfiguration.ps1` opens WinRM, RDP and ICMP on the node, and the one-time bootstrap (`remoting.bootstrapTransport`: `arc`, `smb` or `auto`)
  reaches a node whose WinRM is closed. TrustedHosts of the host that runs the automation is managed by `Invoke-AzureLocalOsConfiguration.ps1`.
- `Start-Phase03OsConfiguration.ps1` (task 12) took the static address, gateway, DNS servers and host name as parameters with placeholder defaults.
  `Set-AzureLocalNodeConfiguration.ps1` does the same work (tasks 02 to 10: RDP, address, DHCP off, DNS, NTP, ICMP, unused adapters, host name) and reads every
  value from `infrastructure.yml`.

The `Invoke-*-Orchestrated.ps1` wrappers of both task folders stay.

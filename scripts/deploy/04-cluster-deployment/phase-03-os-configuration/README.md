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
`scripts/common/azure-local`. The `task-NN-*` folders below hold one placeholder each (a script that ends with exit code 3, NOT IMPLEMENTED, and
changes nothing): the two scripts above do the work of tasks 01 to 11 and 13, from the one schema 5 `infrastructure.yml`.

| Earlier task | Done now by |
|---|---|
| 01 WinRM, 02 RDP, 08 ICMP | the RemoteManagement step |
| 03 static address, 04 DHCP off | the Network step |
| 05 DNS, 06 DNS check | the Dns step, and the Plan pass that verifies every node |
| 07 time | the Time step |
| 09 unused adapters | the UnusedAdapters step |
| 10 host name | the Hostname step |
| 11 clear storage | the ClearStorage step (`os_configuration.clear_storage`) |
| 13 verification | the verify pass of `Invoke-AzureLocalOsConfiguration.ps1` |

The per-task scripts were removed because the schema 5 path replaces them, and several carried values a deployment chooses or a prompt for a login:
the task scripts of tasks 02, 04, 06, 08, 09 and 11, and the `Invoke-*-Orchestrated.ps1` wrappers (now placeholders). Earlier removals:

- `Enable-WinRmConfiguration.ps1` (task 01) set the TrustedHosts of the node it ran on to a management subnet that it assumed. The RemoteManagement step of
  `Set-AzureLocalNodeConfiguration.ps1` opens WinRM, RDP and ICMP on the node, and the one-time bootstrap (`remoting.bootstrapTransport`: `arc`, `smb` or `auto`)
  reaches a node whose WinRM is closed. TrustedHosts of the host that runs the automation is managed by `Invoke-AzureLocalOsConfiguration.ps1`.
- `Start-Phase03OsConfiguration.ps1` (task 12) took the static address, gateway, DNS servers and host name as parameters with placeholder defaults.
  `Set-AzureLocalNodeConfiguration.ps1` does the same work (tasks 02 to 10: RDP, address, DHCP off, DNS, NTP, ICMP, unused adapters, host name) and reads every
  value from `infrastructure.yml`.
- `Set-StaticIPAddress.ps1` (task 03), `Set-DnsServers.ps1` (task 05), `Set-NTPConfiguration.ps1` (task 07) and `Set-NodeHostname.ps1` (task 10) held
  `REPLACE_WITH_...` text that a person had to type into the script (Network, Dns, Time and Hostname steps of `Set-AzureLocalNodeConfiguration.ps1` read every value from
  `infrastructure.yml`).

The run settings file of `Invoke-AzureLocalOsConfiguration.ps1` is `-SettingsFile` (JSON); `-Settings` is the same keys as a hashtable.
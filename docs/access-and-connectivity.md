# Account access and network connectivity

> One page for the Azure Local automation route: which identity each tool runs as, which roles it needs on which scope, and which network paths must be open. It puts together what three pages already say and adds the pipeline-runner pattern. Every row names its source page, so check the source before you rely on a row.

All addresses on this page are documentation examples (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24). All names are examples.

## How to read this page

The route has four tools, run in this order:

1. **ZTP** ([azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp)): provisions the machines from their BMCs and ends at the Handoff.
2. **OS configuration** (`Set-AzureLocalNodeConfiguration.ps1`, Phase 03): configures each node's OS.
3. **ARM Validate, then Deploy** (`Invoke-AzureLocalClusterDeployment.ps1`, Phase 05): deploys the cluster.
4. **Sonar** ([azurelocal-sonar](https://github.com/AzureLocal/azurelocal-sonar)): read-only monitor, run beside any of the above.

A fifth row, **the pipeline runner**, is not a tool: it is the host that runs the others when you automate the route. See [Running from a pipeline runner in Azure](#running-from-a-pipeline-runner-in-azure).

Sources, cited as the "Source" in each row:

| Short name | Page |
| --- | --- |
| **ZTP prerequisites** | [azurelocal-ztp `docs/prerequisites.md`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/prerequisites.md) (Roles, Key Vault, Operator host, Network and Ports sections) |
| **ZTP pipelines** | [azurelocal-ztp `docs/automation-pipelines.md`](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/automation-pipelines.md) |
| **OS/ARM page** | [`os-configuration-and-arm-deployment.md`](os-configuration-and-arm-deployment.md) (Operator host, Azure roles, Key Vault secrets) |
| **Sonar README** | [azurelocal-sonar `README.md`](https://github.com/AzureLocal/azurelocal-sonar/blob/main/README.md) (Requirements, Which account reads the logs) |
| **Code** | `Set-AzureLocalNodeConfiguration.ps1` and `AzlNodeTransport.psm1` in this repository |

Where a source page gives a "Who" or "Checked" column, this page keeps its meaning: **ZTP checks** or **Code** means the script stops or warns with a message that names the problem; **Azure** means Azure's call fails and the script reports Azure's error (a late failure); **You** means nothing checks it.

### Summary

| Tool | Runs as | Roles it needs | Network paths it needs |
| --- | --- | --- | --- |
| **ZTP** | The signed-in account, a service principal, or a managed identity (`-UseManagedIdentity`) | Owner, or Contributor and Role Based Access Control Administrator, on the cluster resource group; Reader on the subscription; Key Vault Secrets User on each vault named; the same rights on the provisioning-admin vault's resource group. (ZTP prerequisites, Roles) | Host to each BMC 443; each BMC to the host 445; host to the provisioning network 20001; host to the internet 443; machines to Azure 443 and 80. (ZTP prerequisites, Ports) |
| **OS configuration** | The signed-in Az context (`Connect-AzAccount`) | Azure Connected Machine Resource Administrator and Reader on the Arc machines' resource group; Key Vault Secrets User on the management vault. No storage account and no storage role: the SBE package does not travel through Azure. (OS/ARM page, Azure roles) | Default (Arc transport): HTTPS to Azure only; no path to the nodes. With `-Transport WinRM`: a path to the nodes' management subnet. SBE package, by `hardware.sbe.delivery`: `skip` (default) none; `winrm_copy` TCP 5985 from the host that runs the script to every node; `node_pull` the nodes reach a read-only HTTPS or SMB location (see SBE delivery below). (OS/ARM page, SBE; Code) |
| **ARM Validate/Deploy** | The signed-in Az context | Azure Stack HCI Administrator and Reader on the resource group; Key Vault Data Access Administrator, Key Vault Secrets Officer and Key Vault Contributor; Storage Account Contributor. (OS/ARM page, Azure roles) | HTTPS to `management.azure.com`, `login.microsoftonline.com`, `*.vault.azure.net`; on execute `raw.githubusercontent.com`; `aka.ms` for the SBE manifest. (OS/ARM page, Operator host) |
| **Sonar** | The signed-in Az context on the workstation; a separate log account on the seed node | Reader on the resource group (and on the edge machine's Arc resource group if different); secret get on the vault only with `credential.source: keyvault`. (Sonar README, Requirements) | HTTPS to Azure; for live logs WinRM 5985/5986 or SSH 22 to the seed node. Sonar's page listens on localhost only. (Sonar README, Requirements) |
| **Pipeline runner** | A managed identity on the runner VM (pattern below) | Resource-group-scope roles only; never subscription scope. | The VPN to the lab for the BMCs and the provisioning network; HTTPS to Azure. |

## Account access matrix

Rows are scopes, columns are tools. Cells are role names. "none" means the tool needs nothing there. A "(Azure)" mark means the script doesn't check the role and fails late, with Azure's message; "(code)" means the script checks. Neither ZTP nor the OS/ARM page checks roles up front: ZTP "doesn't check roles up front: a missing role fails the ARM template validation or the call that needs it" (ZTP prerequisites, Roles).

| Scope | ZTP | OS configuration | ARM Validate/Deploy | Sonar |
| --- | --- | --- | --- | --- |
| **Subscription** | Reader (reads feature and provider registration, the OS image catalog, the Arc machines); Contributor only if the run must create the resource group (Azure). Registering providers and the `AzureLocalZTP` feature needs Owner or Contributor, done once by someone else. | none for the run. Provider registration (Phase 02) needs contributor or owner, done by the subscription owner (You). | none for the run. Same provider registration (You). | none. The subscription must be selected in the Az context. |
| **Resource group (site and edge machines; the cluster resource group)** | Owner, or Contributor and Role Based Access Control Administrator (Azure) | Azure Connected Machine Resource Administrator and Reader, on the Arc machines' resource group (Azure) | Azure Stack HCI Administrator, Reader, Storage Account Contributor (Azure). Whoever registered the machines with Arc held Azure Connected Machine Onboarding and Azure Connected Machine Resource Administrator here (You). | Reader (all calls are GETs) |
| **Key Vault, management (BMC login, provisioning admin, local admin, LCM user)** | Key Vault Secrets User on every vault a `keyvault://` reference names (Azure for the BMC login and `edgeuser` password; the plan checks that the provisioning admin secret exists, by name) | Key Vault Secrets User (RBAC vault), or an access policy with `get` (Azure) | Key Vault Secrets User for the secrets it reads (Azure). `-SecretMode KeyVaultReference` also needs "Azure Resource Manager for template deployment" enabled on the vault. | Secret get, only with `credential.source: keyvault` |
| **Key Vault that holds the provisioning admin password, and its resource group** | Owner, or Contributor and Role Based Access Control Administrator, on that resource group: the template deploys a nested deployment there (Azure). Covered by the cluster group's roles if the vault is in that group. | none | none | none |
| **Key Vault created by the deployment (`cluster.key_vault`)** | none | none | Key Vault Data Access Administrator, Key Vault Secrets Officer, Key Vault Contributor, on the resource group (Azure) | none |
| **Azure Local managed resource group (the site configuration's resource group that holds the Arc machines ZTP creates)** | Reader at subscription scope covers the Ready stage's read of the Arc machines there | Roles on the Arc machines' resource group (see above) | as above | Reader on it if the edge machine's Arc machine sits in another resource group |
| **Arc machines** | none beyond the above. The edge machine's own identity gets roles from the template. | Azure Connected Machine Resource Administrator (includes `Microsoft.HybridCompute/machines/runCommands/write`) (Azure) | none beyond the resource group roles | none (Sonar never uses Arc Run Command: it writes to Azure) |

### The template assigns these itself

ZTP's template assigns, so you don't (ZTP prerequisites, Roles): Azure Connected Machine Resource Manager to the Azure Local resource provider on the resource group; and, to each edge machine's identity, Role Based Access Control Administrator on the resource group (limited by an ABAC condition to assigning Azure Connected Machine Resource Administrator) and on the vault (limited to assigning Key Vault Secrets User). If your landing zone already holds the first assignment under another name, the deployment fails with `RoleAssignmentExists`.

### The Azure Local managed resource group is protected

Nothing in the source pages grants a role on the Azure Local managed resource group, and the pipeline pattern below relies on this: it is protected by an Azure deny assignment, so no role can be granted on it. This page doesn't repeat Microsoft's description of that protection; check Microsoft Learn before depending on a particular write to it.

### Late failures worth knowing

- ZTP: a missing role shows up as an ARM validation failure or a failed call, not as a role message up front.
- OS configuration: not signed in is checked (the script stops and names Azure Connected Machine Resource Administrator); the role itself is not.
- ARM: Arc machines existing and `Connected` is checked with `-Preflight` or `-Execute`; roles are not.
- Key Vault: ZTP needs the vault on the Azure RBAC permission model and public network access on while machines provision (ZTP prerequisites, Key Vault). OS/ARM accept an access policy with `get`.

## Network paths matrix

Rows are paths; the last columns say which tool or stage needs each. Ports are from the source pages. "Op host" is the operator host or the runner.

| # | From | To | Port, protocol | Why | ZTP | OS config | ARM | Sonar | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Op host | Each BMC (`nodes[].bmc.ip_address`, example 198.51.100.11) | TCP 443 (Redfish over HTTPS) | BIOS settings, virtual media, boot override, power, the BMC log | Boot, Bootstrap, Vouchers, Restore | no | no | no | ZTP prerequisites, Ports |
| 2 | Each BMC | The host that runs ZTP's Boot stage (`media_share.host`, example 198.51.100.5) | TCP 445 (SMB) | The BMC mounts the node's image from the share; the maintenance environment writes the voucher into it. The BMC connects out from its own address; the host's firewall rule allows inbound from the BMC addresses only. | Boot to Vouchers | no | no | no | ZTP prerequisites, Ports; Operator host |
| 3 | Op host | The provisioning network (`maintenance_address`, or every address of `provisioning_dhcp_range`, example 192.0.2.100 to 192.0.2.199) | TCP 20001 (HTTPS, self-signed) | The maintenance environment's REST service: find the node by MAC, set the static address. | Device | no | no | no | ZTP prerequisites, Ports |
| 4 | Op host | The internet | TCP 443 | Azure Resource Manager (`management.azure.com`), Microsoft Entra ID (`login.microsoftonline.com`), Key Vault (`*.vault.azure.net`). | Resolve, Bootstrap, Azure, Ready, Network, Restore, Handoff | all steps | all steps | all calls | ZTP prerequisites, Ports; OS/ARM page, Operator host |
| 5 | Op host | ISO download hosts | TCP 443 | The maintenance ISO: `aka.ms/aep/installeros/<YYMM>`, which redirects to `download.prss.microsoft.com` or `download.microsoft.com` (ZTP refuses other hosts). | Resolve, Bootstrap | no | no | no | ZTP prerequisites, Ports |
| 6 | Op host | `raw.githubusercontent.com`, `aka.ms` | TCP 443 | Microsoft's quickstart template (ARM execute only); the OEM's SBE manifest (skip with `-OfflineManifest`). | no | SBE manifest | template on execute | no | OS/ARM page, Operator host |
| 7 | The machines (maintenance environment, then the installed OS) | Azure | TCP 443 and 80 | [Learn's firewall requirements](https://learn.microsoft.com/azure/azure-local/concepts/firewall-requirements), with no HTTPS inspection. Also needed for the Arc agent to be Connected. | Bootstrap to Restore | the Arc transport depends on the agent's Azure connection | yes (Arc machines `Connected`) | no | ZTP prerequisites, Ports |
| 8 | Op host | The seed node | WinRM TCP 5985 (HTTP) or 5986 (HTTPS); or SSH TCP 22 | Live logs. The account must be in the node's local Administrators. Workgroup nodes and IP addresses need the address in the workstation's WinRM `TrustedHosts`. SSH needs Posh-SSH and `sshd` on the node. Without log access Sonar still runs from Azure. | no | no | no | live logs | Sonar README, Requirements |
| 9 | Op host | The nodes' management subnet | WinRM (default ports 5985/5986) | Only with `-Transport WinRM`. Not needed with the default Arc transport (the SBE package has its own rows, 12 and 13). | no | WinRM transport only | no | no | OS/ARM page, Operator host; Code |
| 10 | Op host | Azure (Arc Run Command) | TCP 443 | Default OS configuration transport: the script goes through ARM to the Connected Machine agent, which calls out to Azure. No inbound path to the nodes. | no | default | no | no | Code (`AzlNodeTransport.psm1`) |
| 11 | Runner | The lab (BMCs, provisioning network) | The paths in rows 1 and 3, over the VPN | See [the runner section](#running-from-a-pipeline-runner-in-azure) | if it runs ZTP | no | no | no | this page |
| 12 | The host that runs the script (the operator host if it can, or a runner) | Each node's management address | WinRM TCP 5985 (or 5986) | Only with `hardware.sbe.delivery: winrm_copy`: the SBE package is copied to `C:\SBE`. The other steps stay on Arc. | no | SBE copy only | no | no | OS/ARM page, SBE; Code |
| 13 | Each node | The location in `hardware.sbe.node_pull_url` (HTTPS 443, or SMB 445 for a UNC folder) | TCP 443 or 445 | Only with `hardware.sbe.delivery: node_pull`: the node downloads the SBE package itself and checks its SHA-256. You serve the folder from a host the nodes can reach; the operator host needs no path to it. | no | SBE pull only | no | no | OS/ARM page, SBE; Code |

ZTP's Network stage opens no port to the nodes and ZTP uses no WinRM (ZTP prerequisites, Ports). ZTP's Device stage scans the provisioning range for TCP 20001; keep it to an isolated provisioning network (ZTP prerequisites, Ports).

## Why OS configuration runs over Azure Arc Run Command, not WinRM

After the OS install, the nodes' management subnet is typically reachable only from the local subnet: the installed OS's WinRM firewall rule allows the local subnet, so an operator host in another network can't reach port 5985. (This is the typical case the script's help describes: "The operator host usually has no path to the nodes' management subnet." The WinRM firewall-rule scope is the installed OS's default and isn't checked by any code in this repository, so confirm it on your build.)

`Set-AzureLocalNodeConfiguration.ps1 -Transport` takes `Auto` (the default), `ArcRunCommand` or `WinRM`:

| Value | What it does (from the script and `AzlNodeTransport.psm1`) |
| --- | --- |
| `Auto` | Uses Arc Run Command when every node has an Arc machine. Uses WinRM when `-Credential` is given and a node has no Arc machine found. If no Arc machine is found and no credential is given, the script stops and says the WinRM transport needs `-Credential`. |
| `ArcRunCommand` | Always Arc Run Command. Stops if any node has no Arc machine. |
| `WinRM` | A `New-PSSession` to each node's management address. For a host that can reach the nodes' management subnet. Needs `-Credential` (the nodes' local administrator). |

How Arc Run Command works: the script creates a `Microsoft.HybridCompute/machines/{name}/runCommands` resource, polls it until the script finishes, reads the result and deletes the resource. The request goes through Azure Resource Manager to the Connected Machine agent on the node, which already calls out to Azure. It needs **no inbound path** to the node. Plan mode (no `-Execute`) still creates and deletes one transient run command per read. Secrets travel as protected parameters. It cannot carry a file, so the SBE package (916 MB for Dell) does not go this way: it is delivered by `hardware.sbe.delivery` (next section) or left to you.

What it needs:

- The Arc agent on each node is **Connected** and version **1.33 or later**, and nothing blocks the Run Command extension (`azcmagent config get extensions.blocklist`) (OS/ARM page, Azure roles). The code warns if an Arc machine's status isn't `Connected`; it does not check the agent version or the blocklist, so those are yours to check.
- The Azure Connected Machine roles: Azure Connected Machine Resource Administrator and Reader on the Arc machines' resource group (OS/ARM page, Azure roles).
- Azure Policy mustn't block extensions or the resource types the deployment creates; see [the policy section](#azure-policy-and-defender-during-provisioning).

### SBE delivery: how the package reaches the nodes

Run Command carries scripts, not files, and there is no storage account in this design. `hardware.sbe.delivery` in `infrastructure.yml` (schema 5.4.2) chooses the route. Every route ends with the SHA-256 checked on the node; the SBE step runs last and a route that cannot be used never stops the other steps (OS/ARM page, SBE; Code).

| `delivery` | What carries the file | The path it needs | Notes |
| --- | --- | --- | --- |
| `skip` (default, also when the key is absent) | nothing | none | The Sbe step reports "NOT DELIVERED" and installs no OEM driver. Use it when ZTP already put the package on the node, or you place it yourself. |
| `winrm_copy` | `Copy-Item` over a WinRM session, into `C:\SBE` | TCP 5985 from the host that **runs the script** to each node's management address, and `-Credential` (the nodes' local administrator). The operator host if it can reach the subnet, otherwise a runner or jump host that can. | Works beside Arc: the other steps still go over Arc Run Command; only the copy opens a WinRM session. |
| `node_pull` | each node downloads from `hardware.sbe.node_pull_url` (HTTPS, or a UNC folder) | The **nodes** reach that location; the operator host needs nothing. You serve the three SBE files read-only from any host the nodes can reach (a web server, or a share that allows the node). | No credential in the address (rule AZL-030). A UNC share is read as the node's own identity, so it must allow it. |

When to use WinRM instead: from a host on the same subnet as the nodes (or one that reaches it), with `-Transport WinRM -Credential`. The two transports run the same node scripts; only the way they reach the node differs.

## Running from a pipeline runner in Azure

This section describes a design in generic terms. It is a pattern, not a verified procedure: the open points are stated at the end.

### The pattern

- **The runner:** a Linux VM in a DevOps subscription, with a **managed identity** and no stored secret.
- **The network:** the runner's VNet is peered to the hub VNet that holds the VPN gateway. On the spoke side the peering sets `useRemoteGateways`; on the hub side it sets `allowGatewayTransit`.
- **The identity holds only resource-group-scope roles.** On the cluster resource group: Contributor and Role Based Access Control Administrator. On the vault: Key Vault Secrets User. It holds **no subscription-scope role**. Provider and feature registration (once per subscription) is done by someone else, as the ZTP prerequisites require.
- **The Azure Local managed resource group is protected by an Azure deny assignment**, so no role can be granted on it. The identity needs none there.
- **The lab path:** the runner reaches the BMCs (443) and the provisioning network (20001) through the VPN.
- **The on-premises firewall must route the runner's address range back over the tunnel, and its tunnel policy or selectors may need that prefix added.** The owner's network team does this. Nothing in the automation changes a firewall.
- **The runner's agents are installed, but not registered.** Registering them (a GitLab runner authentication token, or a GitHub registration token, each kept in Key Vault) is a separate, approved step.

Compare the matrix: the roles above cover ZTP's resource group needs (Contributor and Role Based Access Control Administrator is the alternative to Owner in ZTP prerequisites, Roles), the vault read (Key Vault Secrets User), and Reader-type needs inside that resource group. They do **not** by themselves match every role in the OS/ARM page's list (for example Azure Stack HCI Administrator, or Key Vault Secrets Officer, whose data actions Contributor doesn't carry), and ZTP's Reader on the subscription is a subscription-scope role. See the gaps below.

### The open design point: ZTP's SMB share

ZTP's Boot stage publishes an SMB share on the host that runs it, and the **BMC connects to that host on TCP 445**. So the host that runs the Boot stages must be reachable from the BMC. A runner in Azure therefore needs one of:

1. a share host on a network the BMCs reach, with the runner pointing `media_share.host` (or `host_adapter`) at it; or
2. the pipeline runs the Boot stages from an on-site host, and the Azure runner runs the others.

**This hasn't been proven from a runner yet.** Also, ZTP's own pipeline page says ZTP needs a self-hosted **Windows** runner on the management network, elevated, because the share, the local account and the firewall rule are Windows features (ZTP pipelines; ZTP prerequisites, Operator host). A Linux runner as described above can't run ZTP's Boot stage as written. OS configuration and ARM are PowerShell 7 scripts; whether they run on Linux is not established by the pages this section is built from.

### Checks to run from the runner

Run these before the first pipeline. They use generic names; replace them with yours.

```bash
# 1. The managed identity signs in (no stored secret)
az login --identity
az account show --query "{name:name, id:id}" -o table

# 2. The identity can list secret names in the vault (needs Key Vault Secrets User; lists names, not values)
az keyvault secret list --vault-name kv-example --query "[].name" -o tsv

# 3. A BMC answers on TCP 443 over the VPN (example BMC address)
nc -vz -w 5 198.51.100.11 443

# 4. The management gateway answers (example gateway address)
ping -c 3 192.0.2.1
```

Reading the results: step 2 working means the role and the vault's network access are right; step 3 working means the tunnel, the peering and the firewall's return route are right. Step 4 working and step 3 failing points at the BMC network specifically (see Troubleshooting).

### Gaps in this pattern

- Whether Contributor plus Role Based Access Control Administrator on the resource group satisfies every ARM Deploy role (Azure Stack HCI Administrator, the three Key Vault roles) has not been verified here. The OS/ARM page lists those named roles.
- ZTP's Reader on the subscription and OS/ARM's provider registration are subscription-scope. The pattern's "no subscription-scope role" rule means they must be met another way (a one-time registration by someone else; the ZTP Bootstrap stage reads feature and provider registration, so verify that read works with resource-group roles only).
- `azure.hci_resource_provider_object_id` should be set in the environment file, because a managed identity can't read the directory by default (ZTP prerequisites; ZTP pipelines).

## Troubleshooting by symptom

| Symptom | Likely cause | Check or fix | Source |
| --- | --- | --- | --- |
| 403 on a Key Vault read | Missing Key Vault Secrets User on that vault; or the vault uses access policies instead of Azure RBAC; or public network access is off during provisioning | Check the role on every vault a `keyvault://` reference names; ZTP needs the Azure RBAC model and public network access on while machines provision. Run check 2 above. | ZTP prerequisites, Roles and Key Vault |
| ARM template validation fails with an authorization error | Missing Owner, or Contributor and Role Based Access Control Administrator, on the resource group (or on the vault's resource group) | ZTP doesn't check roles up front; add the role. `RoleAssignmentExists` means the landing zone already holds the Azure Local resource provider's assignment under another name. | ZTP prerequisites, Roles |
| Arc Run Command times out or the run command can't be created | The Arc machine isn't `Connected`; agent older than 1.33; the Run Command extension is blocked; Azure Policy or Defender interferes; the node can't reach Azure on 443 | Check the Arc machine status and agent version, `azcmagent config get extensions.blocklist`, and the machines-to-Azure path. See the policy section. | OS/ARM page, Azure roles and Azure Policy |
| Arc Run Command denied | Missing Azure Connected Machine Resource Administrator on the Arc machines' resource group | Add the role; the script's sign-in message names it. | Code; OS/ARM page |
| WinRM to a node fails (OS configuration, `-Transport WinRM`) | The host is outside the nodes' local subnet | Use the default Arc transport, or run from a host that reaches the subnet. | Code; this page |
| Sonar logs unavailable: WinRM cannot connect (5985) | WinRM is blocked from the workstation | Install Posh-SSH and keep `logs.transport` at `auto`, or set `ssh`; `sshd` must run on the node. | Sonar README, Troubleshooting |
| Sonar logs: not in `TrustedHosts` | Workgroup node or IP address | Add the address to the workstation's `TrustedHosts` (Sonar never changes it). | Sonar README, Troubleshooting |
| BMC can't mount the share | The BMC can't reach the share host on TCP 445, or a firewall in between blocks it; the host named in `media_share.host` isn't the address the BMC reaches | The host's firewall rule allows inbound from the BMC addresses only; open any firewall in between. With a VPN adapter, use `host_adapter`. | ZTP prerequisites, Ports and Values |
| Scan finds no maintenance environment | No DHCP lease on the provisioning network, no path on TCP 20001, or the scan range is wrong | DHCP must answer on the provisioning network; open 20001 from the host; narrow `provisioning_dhcp_range` to the pool, or set `maintenance_address`. The Device stage scans for up to 30 minutes. | ZTP prerequisites, Network and Ports |
| Bootstrap times out; no voucher written | The machine never reached Azure: no DHCP, or 443/80 blocked, or HTTPS inspection on the path | Open Learn's firewall list; remove HTTPS inspection for those endpoints. | ZTP prerequisites, Network and Ports |
| Runner can ping the management gateway but not the BMC | The tunnel works but the BMC network isn't routed or allowed: the firewall's return route or tunnel selectors lack the runner's range, or the BMC subnet isn't in the policy | Test TCP 443 to the BMC (check 3). Ask the network team to route the runner's range back over the tunnel and add the prefix to the tunnel policy. | this page |
| Runner can't sign in with `az login --identity` | No managed identity on the VM, or no role on the resource group | Enable the identity and assign the resource-group roles. | this page |

## Azure Policy and Defender during provisioning

Policies with `deployIfNotExists` or `modify` effects, and Defender for Servers, can collide with provisioning and with Arc Run Command. They are described, with the exemption script and who can run it, in [Azure Policy and Defender during provisioning and deployment](os-configuration-and-arm-deployment.md#azure-policy-and-defender-during-provisioning-and-deployment) on the OS/ARM page. This page doesn't repeat it.

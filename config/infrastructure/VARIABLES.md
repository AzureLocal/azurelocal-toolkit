# infrastructure.yml variables reference

Every key of [`infrastructure.yml`](README.md), schema 5.3, one row each, grouped by section. **This page is generated** from [`infrastructure.schema.json`](infrastructure.schema.json), the templates and [`variables-reference.metadata.psd1`](variables-reference.metadata.psd1). Don't edit it: change those and run:

```powershell
./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1
```

A test fails when this page is out of date (`./scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1 -Check`).

## How to read the tables

| Column | Meaning |
| --- | --- |
| Path | The key. `[]` is an item of a list (`nodes[].name`). |
| Required: full / ztp | Whether the key must be set in a file with `_metadata.scope: full` (the default) and in one with `scope: ztp`. `yes`: always. `if section is set`: required once its parent exists. `when ...`: required when the condition holds. `no`: optional. |
| Default | What a tool does when the key is left out (from the schema). |
| Example | The value in the templates and examples. Placeholders only. |
| Where to get the value | Where the real value comes from. |
| Read by | **ZTP**: azurelocal-ztp (the list is what its `ConvertFrom-ZtpInfrastructureV5` reads, plus the 5.3 and 5.4 keys). **OS configuration**: the toolkit's OS configuration phase (by design, by section). **CI/CD infrastructure**: tasks 01 to 06 of automation / 01-cicd-infra (the `devops` section, plus the Azure identifiers they sign in with). **ARM deployment**: the key becomes a parameter of Microsoft's ARM deployment template (the schema description names the parameter), or is part of the SAN (`storage.san`, `nodes[].san`) that the ARM and SAN deployment reads. **Trailwright**: it can write the key from its design (host-local paths and files are set by the operator). |

Two templates start a file: [`infrastructure.example.yml`](infrastructure.example.yml) (full scope: ZTP, OS configuration and the ARM deployment) and [`infrastructure.ztp.example.yml`](infrastructure.ztp.example.yml) (ztp scope: only what azurelocal-ztp reads). See [Which template](README.md#which-template).

## Secrets: keyvault:// references

**No secret value is ever written in the file.** A secret key holds only `keyvault://<vault>/<secret>`: the vault name and the secret name. Create each secret in Key Vault before the run, and list every vault you reference under `key_vaults` (with its subscription and resource group). The validator refuses a plain value (the key must match the reference form) and a reference to an unlisted vault (rule AZL-001). Keep files with real vault names in a private environment repository.

The templates expect these secrets. The names are the templates' placeholders (vault `kv-iic-mgmt-01`); use your own, and match the vault name to a `key_vaults` entry.

| Path | Vault | Secret | What it holds | In template |
| --- | --- | --- | --- | --- |
| `hardware.bmc.username` | `kv-iic-mgmt-01` | `bmc-username` | A reference to the secret holding the user name, or the user name itself. | full, ztp |
| `hardware.bmc.password` | `kv-iic-mgmt-01` | `bmc-password` | Key Vault reference for the password of hardware.bmc. | full, ztp |
| `identity.local_admin.password` | `kv-iic-mgmt-01` | `local-admin-password` | At least 14 characters with lowercase, uppercase, a digit and a special character. | full, ztp |
| `identity.active_directory.lcm_user.password` | `kv-iic-mgmt-01` | `lcm-password` | At least 14 characters with lowercase, uppercase, a digit and a special character. | full |
| `identity.active_directory.service_accounts[].password` | `kv-iic-mgmt-01` | `svc-backup-password` | Key Vault reference for the password of identity.active_directory.service_accounts[]. | full |
| `operations.notifications.teams_webhook` | `kv-iic-mgmt-01` | `teams-webhook-url` | Key Vault reference for the teams_webhook of operations.notifications. | full |
| `provisioning.simplified.admin.password` | `kv-iic-mgmt-01` | `provisioning-admin-password` | At least 12 characters with lowercase, uppercase, a digit and a special character. | ztp, full |
| `network_devices[].credentials.password` | `kv-iic-mgmt-01` | `switch-admin-password` | Key Vault reference for the password of network_devices[].credentials. | full |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].shared_key` | `kv-iic-mgmt-01` | `vpn-shared-key` | Key Vault reference for the shared_key of landing_zone.connectivity.vpn_gateway.site_to_site[]. | full |
| `landing_zone.virtual_machines[].admin_password` | `kv-iic-mgmt-01` | `vm-admin-password` | Key Vault reference for the admin_password of landing_zone.virtual_machines[]. | full |
| `devops.api_token` | `kv-iic-mgmt-01` | `devops-admin-token` | Key Vault reference to a token with administrator rights on the organization or project. (since 5.5) | full |
| `devops.runners[].registration_secret` | `kv-iic-mgmt-01` | `github-runner-token` | Key Vault reference to the secret the runner reads at boot: a PAT or App token (GitHub), the runner authentication token (GitLab), a PAT with Agent P... | full |

ZTP reads all its secrets from vaults in one subscription (the provisioning admin's vault decides which). `hardware.bmc.username` may be a reference or the user name itself.

## Folders on the management host

Three keys name folders on the machine that runs azurelocal-ztp. **Keep every one outside every git working tree**: they hold ISOs, per-machine images, ownership vouchers, run state and logs, none of which belongs in a repository. azurelocal-ztp refuses `media_path` and `evidence_path` inside a git working tree, and creates them when they are missing. The disk figures are planning estimates; check them against your OEM's bundle.

| Path | What it holds | Disk space | Default |
| --- | --- | --- | --- |
| `provisioning.simplified.media_path` | The maintenance ISO cache, the copy of the SBE and its unpacked drivers, the per-machine USB images, the ownership vouchers and the run state. | About 4 GB per machine for the images, plus the maintenance ISO and the SBE copy (twice the bundle's size, as downloaded and unpacked). Plan 30 GB free for a small cluster, on a fast local disk. | `%ProgramData%\AzureLocalZtp\<site_name>\media` |
| `provisioning.simplified.evidence_path` | The event log the monitors follow (`ztp-events.jsonl`), the BIOS and other Redfish change logs, and run logs. | Small: 1 GB is ample for many runs. Put it where it survives the run, for audit. | `%ProgramData%\AzureLocalZtp\<site_name>\evidence` |
| `hardware.sbe.bundle_path` | The OEM's Solution Builder Extension files, as downloaded. Required with simplified provisioning: ZTP prepares each machine with the SBE before validation. | The size of the OEM bundle (a few GB, varies by OEM). ZTP copies it under `media_path`. | none |

## Reference by section

### _metadata

About this file.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `_metadata` | About this file. | object | yes / yes |  |  |  | ZTP, Trailwright |
| `_metadata.schema_version` | The schema version this file follows. | string | yes / yes |  | `5.5.0` | Set by the template (5.3.0). Change it only with a migration. | ZTP, Trailwright |
| `_metadata.scope` | Full (default): the whole instance, so every design section is required (scenario, environment, cluster, networking.intents, identity and the section... (since 5.3) | one of `full`, `ztp` | no / no | `full` | `ztp` | You: ztp for a file used by azurelocal-ztp alone, full for everything. | ZTP, Trailwright |
| `_metadata.file_version` | Your own version of this file. | string | no / no |  | `1.0.0` | You: bookkeeping for the file. | Trailwright |
| `_metadata.last_updated` | Date of the last change, YYYY-MM-DD. | date (YYYY-MM-DD) | no / no |  | `2026-11-06` | You: bookkeeping for the file. | Trailwright |
| `_metadata.generated_by` | The tool that wrote the file, for example azurelocal-trailwright 1.1.0. | string | no / no |  |  | You: bookkeeping for the file. | Trailwright |
| `_metadata.notes` |  | string | no / no |  |  | You: bookkeeping for the file. | Trailwright |

### scenario

The design choices.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `scenario` | The design choices. | object | yes / yes |  |  |  | ZTP, ARM deployment, Trailwright |
| `scenario.identity` | active_directory: machines join an AD domain (needs identity.active_directory). local_identity: no AD, secrets in Key Vault (needs identity.local_ide... | one of `active_directory`, `local_identity` | yes / no |  | `active_directory` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.storage_architecture` | s2d: Storage Spaces Direct (hyperconverged). san: external SAN only (disaggregated; needs storage.san). hybrid: both. | one of `s2d`, `san`, `hybrid` | yes / no |  | `s2d` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.storage_connectivity` | switched: storage traffic goes through top-of-rack switches. switchless: machines are cabled directly to each other for storage. | one of `switched`, `switchless` | yes / no |  | `switched` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.topology` | standard, or rack_aware (machines split across two local availability zones; every node needs a zone). | one of `standard`, `rack_aware` | yes / no |  | `standard` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.connectivity` | connected to Azure, or disconnected operations (needs the disconnected section). | one of `connected`, `disconnected` | yes / no |  | `connected` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.cloud` | Azure public cloud or Azure Government. | one of `public`, `government` | yes / no |  | `public` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.outbound_path` | How the machines reach Azure. | one of `direct`, `proxy`, `arc_gateway`, `proxy_arc_gateway`, `private_path` | yes / no |  | `direct` | Your design decisions. The README lists what each choice makes required. | Trailwright |
| `scenario.os_install` | iso: the OS is installed from an ISO (by hand or out-of-band). simplified: simplified machine provisioning from Azure, which azurelocal-ztp automates... | one of `iso`, `simplified` | yes / yes |  | `simplified` | Your design decisions. The README lists what each choice makes required. | ZTP, Trailwright |
| `scenario.deploy_method` | How the cluster is deployed: the Azure portal or an ARM template. | one of `portal`, `arm` | yes / no |  | `arm` | Your design decisions. The README lists what each choice makes required. | ARM deployment, Trailwright |

### site

Where the machines are.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `site` | Where the machines are. | object | yes / yes |  |  |  | ZTP, Trailwright |
| `site.code` | Short site code, 2 to 8 uppercase letters or digits. | string | yes / yes |  | `IIC` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | ZTP, Trailwright |
| `site.name` | Display name of the site. | string | yes / yes |  | `IIC Dallas` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | ZTP, Trailwright |
| `site.location` | Physical location, for example a city. | string | no / no |  | `Dallas, TX` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | Trailwright |
| `site.datacenter` |  | string | no / no |  | `dal-01` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | Trailwright |
| `site.customer` |  | string | no / no |  | `Infinite Improbability Corp` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | Trailwright |
| `site.owner` |  | string | no / no |  | `platform-team@improbability.cloud` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | Trailwright |
| `site.time_zone` | Windows time zone ID of the site, for example UTC or Eastern Standard Time. | string | no / yes |  | `Central Standard Time` | Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time). | ZTP, Trailwright |

### environment

Which environment this file describes.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `environment` | Which environment this file describes. | object | yes / no |  |  |  | Trailwright |
| `environment.name` | Environment identifier: lowercase letters, digits and hyphens. | string | yes / if section is set |  | `iic-azl-01` | Your naming for the instance. | Trailwright |
| `environment.type` |  | one of `lab`, `demo`, `poc`, `dev`, `test`, `stg`, `prd` | yes / if section is set |  | `lab` | Your naming for the instance. | Trailwright |
| `environment.owner` |  | string | no / no |  | `platform-team@improbability.cloud` | Your naming for the instance. | Trailwright |
| `environment.description` |  | string | no / no |  | `Example two-machine Azure Local instance.` | Your naming for the instance. | Trailwright |

### tags

Azure tags applied to the resources the tools create.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `tags` | Azure tags applied to the resources the tools create. | map of strings | no / no |  |  |  | ZTP, CI/CD infrastructure, Trailwright |
| `tags.<attribute>` |  | string | no / no |  | `CostCenter: iic-it` | Your tagging policy. | ZTP, CI/CD infrastructure, Trailwright |

### azure

The Azure targets of the instance: tenant, region, and the subscription and resource group of the Arc machines, the cluster and (unless provisioning....

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `azure` | The Azure targets of the instance: tenant, region, and the subscription and resource group of the Arc machines, the cluster and (unless provisioning.... | object | yes / yes |  |  |  | ZTP, CI/CD infrastructure, ARM deployment, Trailwright |
| `azure.tenant_id` |  | GUID | yes / yes |  | `00000000-0000-0000-0000-000000000000` | Azure portal > Microsoft Entra ID > Overview, or az account show. | ZTP, CI/CD infrastructure, Trailwright |
| `azure.location` | Azure region, for example eastus. | Azure region | yes / yes |  | `eastus` | Your Azure design. Simplified provisioning works in eastus only in the preview. | ZTP, CI/CD infrastructure, Trailwright |
| `azure.subscription_id` |  | GUID | yes / yes |  | `00000000-0000-0000-0000-000000000000` | Azure portal > Subscriptions, or az account show. | ZTP, CI/CD infrastructure, Trailwright |
| `azure.resource_group` |  | resource group name | yes / yes |  | `rg-iic-azl-01` | Your Azure design: the resource group for the Arc machines and the site. | ZTP, CI/CD infrastructure, Trailwright |
| `azure.hci_resource_provider_object_id` | Object ID of the Azure Local resource provider's service principal (application 1412d89f-b8a8-4111-b4fd-e82905cbd85d) in the tenant. | GUID | no / no |  | `00000000-0000-0000-0000-000000000000` | Microsoft Entra ID: the object ID of the Microsoft.AzureStackHCI Resource Provider service principal in your tenant. | ZTP, Trailwright |
| `azure.custom_location` | Name of the custom location the deployment creates. | string | no / no |  | `cl-iic-azl-01` | Your Azure design (the automation identity and custom location names). | Trailwright |
| `azure.automation_identity` | The identity that runs automation with no one signed in (pipelines, ZTP, the ARM deployment). | object | no / no |  |  | Your Azure design (the automation identity and custom location names). | CI/CD infrastructure, ARM deployment, Trailwright |
| `azure.automation_identity.type` |  | one of `managed_identity`, `service_principal` | if section is set / if section is set |  | `managed_identity` | Your Azure design (the automation identity and custom location names). | CI/CD infrastructure, Trailwright |
| `azure.automation_identity.name` | Managed identity resource name, or the service principal's display name. | string | if section is set / if section is set |  | `id-iic-cicd-01` | Your Azure design (the automation identity and custom location names). | CI/CD infrastructure, Trailwright |
| `azure.automation_identity.client_id` |  | GUID | no / no |  |  | Your Azure design (the automation identity and custom location names). | CI/CD infrastructure, Trailwright |
| `azure.automation_identity.subscription_id` |  | GUID | no / no |  | `00000000-0000-0000-0000-000000000000` | Your Azure design (the automation identity and custom location names). | CI/CD infrastructure, Trailwright |
| `azure.automation_identity.resource_group` |  | resource group name | no / no |  | `rg-iic-devops-01` | Your Azure design (the automation identity and custom location names). | CI/CD infrastructure, Trailwright |

### key_vaults

Every Key Vault that a keyvault:// reference in this file names, with where it is.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `key_vaults` | Every Key Vault that a keyvault:// reference in this file names, with where it is. | list of objects | no / yes |  |  | Azure portal > Key vaults. List every vault a keyvault:// reference names. | ZTP, CI/CD infrastructure, Trailwright |
| `key_vaults[].name` |  | Key Vault name | if section is set / yes |  | `kv-iic-mgmt-01` | Azure portal > Key vaults. List every vault a keyvault:// reference names. | ZTP, CI/CD infrastructure, Trailwright |
| `key_vaults[].subscription_id` |  | GUID | if section is set / yes |  | `00000000-0000-0000-0000-000000000000` | Azure portal > Key vaults. List every vault a keyvault:// reference names. | ZTP, CI/CD infrastructure, Trailwright |
| `key_vaults[].resource_group` |  | resource group name | if section is set / yes |  | `rg-iic-mgmt-01` | Azure portal > Key vaults. List every vault a keyvault:// reference names. | ZTP, CI/CD infrastructure, Trailwright |
| `key_vaults[].purpose` | What the vault holds, for example management, deployment or backup. | string | no / no |  | `management` | Azure portal > Key vaults. List every vault a keyvault:// reference names. | ZTP, CI/CD infrastructure, Trailwright |

### cluster

The Azure Local instance (the cluster deployment).

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `cluster` | The Azure Local instance (the cluster deployment). | object | yes / no |  |  |  | OS configuration, ARM deployment, Trailwright |
| `cluster.name` | Cluster name: a NetBIOS name of up to 15 characters. | NetBIOS name | yes / if section is set |  | `iic-azl-01` | Your naming standard and witness design. | OS configuration, ARM deployment, Trailwright |
| `cluster.naming_prefix` | Prefix of the Azure resources the deployment creates. | string | no / no |  | `iicazl01` | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.deployment_mode` | ARM deploymentMode: validate runs the checks only; deploy deploys. | one of `validate`, `deploy` | no / no |  | `validate` | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.witness` |  | object | yes / if section is set |  |  | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.witness.type` | cloud (an Azure Storage account), file_share (disconnected operations), or none. | one of `cloud`, `file_share`, `none` | yes / if section is set |  | `cloud` | Your naming standard and witness design. | Trailwright |
| `cluster.witness.storage_account` | Cloud witness storage account. | storage account name | no / no |  | `stiicazl01wit` | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.witness.path` | File share witness UNC path. | string | no / no |  | `\\fs01.improbability.cloud\witness\iic-sec-mgmt` | Your naming standard and witness design. | Trailwright |
| `cluster.key_vault` | The Key Vault the deployment uses for the instance's secrets (one per instance). | object | yes / if section is set |  |  | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.key_vault.name` |  | Key Vault name | yes / if section is set |  | `kv-iic-azl-01` | Your naming standard and witness design. | Trailwright |
| `cluster.key_vault.create_new` | ARM createNewKeyVault. | boolean | no / no |  | `true` | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.key_vault.soft_delete_retention_days` |  | integer | no / no |  | `30` | Your naming standard and witness design. | Trailwright |
| `cluster.diagnostics` | Key Vault audit logs. | object | no / no |  |  | Your naming standard and witness design. | ARM deployment, Trailwright |
| `cluster.diagnostics.storage_account` |  | storage account name | no / no |  | `stiicazl01diag` | Your naming standard and witness design. | Trailwright |
| `cluster.diagnostics.logs_retention_days` |  | integer | no / no |  | `30` | Your naming standard and witness design. | Trailwright |
| `cluster.diagnostics.storage_account_type` |  | string | no / no |  | `Standard_LRS` | Your naming standard and witness design. | Trailwright |

### nodes

The machines, one entry each.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `nodes` | The machines, one entry each. | list of object | yes / yes |  |  |  | ZTP, OS configuration, ARM deployment, Trailwright |
| `nodes[].name` | Host name: up to 15 characters. | NetBIOS name | yes / yes |  | `iic-azl-n01` | Your machine inventory and addressing plan. | ZTP, OS configuration, Trailwright |
| `nodes[].management` | The machine's management port and address (schema 5.0 and 5.1). | object | when one of management or network_adapters / when one of management or network_adapters |  |  | Your machine inventory and addressing plan. | ZTP, OS configuration, ARM deployment, Trailwright |
| `nodes[].management.ip_address` | Management address. | IPv4 address | if section is set / if section is set |  | `192.0.2.11` | Your machine inventory and addressing plan. | ZTP, OS configuration, ARM deployment, Trailwright |
| `nodes[].management.mac_address` | MAC of the management port. | MAC address | when os_install simplified and no network_adapters / when os_install simplified and no network_adapters |  | `00:00:5E:00:53:11` | Your machine inventory and addressing plan. | ZTP, OS configuration, Trailwright |
| `nodes[].management.adapter_name` | Name of the management port in the installed OS, for example 'SLOT 3 Port 1'. | string | no / no |  | `Port1` | Your machine inventory and addressing plan. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters` | Every physical network port of the machine (schema 5.2): name, MAC, roles and how each gets its host address. | list of object | when one of management or network_adapters (simplified: a provisioning port too) / when one of management or network_adapters (simplified: a provisioning port too) |  |  | Your network design and the machine's hardware inventory. | ZTP, OS configuration, ARM deployment, Trailwright |
| `nodes[].network_adapters[].name` | The adapter's name in the installed OS, or the slot label the OS uses, for example 'Embedded NIC 1' or 'Slot 3 Port 1'. networking.intents[].adapters... | string | if section is set / if section is set |  | `Embedded NIC 1` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].mac_address` | The port's MAC. | MAC address | when dhcp_reservation, or a management port with os_install simplified / when dhcp_reservation, or a management port with os_install simplified |  | `00:00:5E:00:53:11` | The BMC's network-device inventory (Redfish EthernetInterfaces), the vendor's order sheet, or the port label. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].slot` | Where the port is, for example Embedded (a LOM), Slot 3 or OCP 1. | string | no / no |  | `Embedded` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].model` | Card model, for example 'NVIDIA ConnectX-6 Dx'. | string | no / no |  | `Example 25GbE NIC` | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].network_adapters[].speed_gbps` |  | number | no / no |  | `25` | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].network_adapters[].rdma` |  | one of `none`, `iwarp`, `roce`, `roce_v2` | no / no |  | `roce_v2` | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].network_adapters[].roles` | What the port is for: management, compute, storage (the Network ATC traffic types), provisioning (the maintenance environment of simplified provision... | list of one of `management`, `compute`, `storage`, `provisioning`, `iscsi:a`, `iscsi:b`, `unused` | if section is set / if section is set |  | `[management]` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].ip_assignment` | How the installed OS gets this port's host address before deployment. | one of `static`, `dhcp_reservation`, `dhcp`, `preconfigured`, `none` | if section is set / if section is set |  | `static` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].ip_address` | The host address. | IPv4 address | when ip_assignment static or dhcp_reservation / when ip_assignment static or dhcp_reservation |  | `192.0.2.11` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, ARM deployment, Trailwright |
| `nodes[].network_adapters[].prefix_length` | Prefix length of ip_address. | integer | no / no | `from networking.management.subnet, which it must match` | `26` | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].network_adapters[].gateway` | Default gateway on this port. | IPv4 address | no / no | `networking.management.gateway` |  | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].network_adapters[].dns_servers` | Default for the management port: networking.management.dns_servers, which it must match. | list of IPv4 address | no / no | `networking.management.dns_servers, which it must match` |  | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].network_adapters[].vlan_id` | The VLAN of this port's traffic. | integer | no / no |  | `711` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].vlan_mode` | access: the switch port is an access (untagged) port; the host doesn't tag, so simplified provisioning sends VLAN 0. tagged: the switch port is a tru... | one of `access`, `tagged` | no / no |  | `access` | Your network design and the machine's hardware inventory. | ZTP, OS configuration, Trailwright |
| `nodes[].network_adapters[].switch_port` | Where the port is cabled. | object | no / no |  |  | Your cabling record. | OS configuration, Trailwright |
| `nodes[].network_adapters[].switch_port.switch` | The switch, for example a network_devices[].hostname. | string | no / no |  | `leaf-a` | Your cabling record. | OS configuration, Trailwright |
| `nodes[].network_adapters[].switch_port.port` | The switch port, for example Ethernet1/11. | string | no / no |  | `Ethernet1/11` | Your cabling record. | OS configuration, Trailwright |
| `nodes[].network_adapters[].switch_port.description` |  | string | no / no |  |  | Your cabling record. | OS configuration, Trailwright |
| `nodes[].network_adapters[].notes` |  | string | no / no |  |  | Your network design and the machine's hardware inventory. | OS configuration, Trailwright |
| `nodes[].serial_number` | Serial number (Dell service tag). | string | when scenario.os_install is simplified / yes |  | `SERIAL01` | The machine's label or its BMC (the Dell service tag). | ZTP, Trailwright |
| `nodes[].bmc` |  | object | when scenario.os_install is simplified / yes |  |  | Your machine inventory and addressing plan. | ZTP, Trailwright |
| `nodes[].bmc.ip_address` |  | IPv4 address | when scenario.os_install is simplified / yes |  | `198.51.100.11` | Your out-of-band addressing plan; the BMC's web page shows it. | ZTP, Trailwright |
| `nodes[].bmc.type` |  | one of `idrac`, `ilo`, `xcc`, `other` | no / no |  | `idrac` | The BMC (iDRAC, iLO, XCC). | Trailwright |
| `nodes[].bmc.username` |  | string | no / no |  |  | The BMC (iDRAC, iLO, XCC). | Trailwright |
| `nodes[].bmc.password` (secret) | Key Vault reference for the password of nodes[].bmc. | keyvault:// reference | no / no |  |  | The BMC (iDRAC, iLO, XCC). | Trailwright |
| `nodes[].rack` |  | string | no / no |  | `R01` | Your machine inventory and addressing plan. | Trailwright |
| `nodes[].rack_position` |  | string | no / no |  | `24` | Your machine inventory and addressing plan. | ZTP, Trailwright |
| `nodes[].zone` | Rack-aware: the local availability zone. | string | when scenario.topology is rack_aware / no |  | `RoomA` | Your machine inventory and addressing plan. | ARM deployment, Trailwright |
| `nodes[].storage_ips` | Storage address on each storage network, in networking.storage.networks order, when networking.storage.auto_ip is false. | list of IPv4 address | no / no |  |  | Your machine inventory and addressing plan. | OS configuration, Trailwright |
| `nodes[].arc_machine_name` | Name of the machine's Arc resource (Microsoft.HybridCompute/machines). | string | no / no | `name` | `iic-azl-n01` | Your machine inventory and addressing plan. | ZTP, OS configuration, ARM deployment, Trailwright |
| `nodes[].arc_resource_name` | Deprecated. Deprecated: use arc_machine_name. | string | no / no |  |  | Your machine inventory and addressing plan. | ZTP, Trailwright |
| `nodes[].bios` | BIOS attributes for this machine in their FINAL state, merged over hardware.bios (a key here wins). | map of strings | no / no |  |  | The BMC's Redfish Bios resource (Attributes of /redfish/v1/Systems/<id>/Bios) or the vendor's BIOS attribute registry. | ZTP, OS configuration, Trailwright |
| `nodes[].bios.<attribute>` |  | string | no / no |  |  | The BMC's Redfish Bios resource (Attributes of /redfish/v1/Systems/<id>/Bios) or the vendor's BIOS attribute registry. | ZTP, OS configuration, Trailwright |
| `nodes[].bios_during_provisioning` | Temporary BIOS attributes for this machine's OS install only, merged over hardware.bios_during_provisioning (a key here wins); during-provisioning va... (since 5.3) | map of strings | no / no |  |  | The BMC's Redfish Bios resource (Attributes of /redfish/v1/Systems/<id>/Bios) or the vendor's BIOS attribute registry. | ZTP, OS configuration, Trailwright |
| `nodes[].bios_during_provisioning.<attribute>` |  | string | no / no |  |  | The BMC's Redfish Bios resource (Attributes of /redfish/v1/Systems/<id>/Bios) or the vendor's BIOS attribute registry. | ZTP, OS configuration, Trailwright |
| `nodes[].maintenance_address` | Simplified provisioning: the address the machine's maintenance environment answers on (its Configurator service, TCP 20001), when it is known: a DHCP... (since 5.3) | IPv4 address | no / no |  | `192.0.2.102` | The DHCP lease or reservation of the machine while it runs the maintenance environment (its console shows it). | ZTP |
| `nodes[].san` | This machine's SAN connections: its Fibre Channel HBAs and their WWPNs (storage.san.type fibre_channel), or its iSCSI initiator IQN (storage.san.type... (since 5.3) | object | when storage.san is set (rule AZL-028) / no |  |  | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas` | The host bus adapters in this machine that reach the SAN: Fibre Channel HBAs, and from 5.4 iSCSI offload adapters. azurelocal-ztp reads their slots (... | list of objects | when storage.san.type is fibre_channel / no |  |  | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas[].slot` | Where the HBA is, as a PCIe slot label: Slot 2, Slot2 or slot-2 (the number is what counts). azurelocal-ztp turns the BIOS attribute of that slot off... | string | if section is set / if section is set |  | `Slot 2` | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas[].type` | Fibre_channel (default; with storage.san.type fibre_channel the ports with their WWPNs are needed for zoning, rule AZL-028) or iscsi_offload (an adap... (since 5.4) | one of `fibre_channel`, `iscsi_offload` | no / no | `fibre_channel` | `fibre_channel` | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas[].bios_attribute` | The vendor's BIOS attribute name for this adapter's slot, as the BMC's Redfish Bios resource names it. (since 5.4) | string | no / no |  |  | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas[].bios_disabled_value` | The value of bios_attribute that turns the slot off for the OS install. (since 5.4) | string | no / no | `the vendor mapping's disabled value, else Disabled` |  | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas[].bios_enabled_value` | The value that turns the slot back on when azurelocal-ztp finds it already at bios_disabled_value in the Restore stage (for example a crashed earlier... (since 5.4) | string | no / no | `the vendor mapping's enabled value, else Enabled` |  | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ZTP, ARM deployment, Trailwright |
| `nodes[].san.hbas[].model` |  | string | no / no |  | `Example 32G FC HBA` | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ARM deployment, Trailwright |
| `nodes[].san.hbas[].ports` |  | list of objects | no / no |  |  | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ARM deployment, Trailwright |
| `nodes[].san.hbas[].ports[].wwpn` | A Fibre Channel World Wide Port Name: 16 hexadecimal digits, as 8 colon-separated pairs (50:00:09:72:08:12:34:56) or without colons. | WWPN | if section is set / if section is set |  | `10:00:00:00:00:00:00:11` | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ARM deployment, Trailwright |
| `nodes[].san.hbas[].ports[].fabric` | A name in storage.san.fibre_channel.fabrics. | string | if section is set / if section is set |  | `A` | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ARM deployment, Trailwright |
| `nodes[].san.initiator_iqn` | The machine's iSCSI initiator name. | iSCSI name (IQN) | when storage.san.type is iscsi / no |  | `iqn.1991-05.com.microsoft:iic-dc03-n01.improbability.cl...` | The SAN administrator: the HBA utility or the fabric switch's name server (WWPNs), the initiator name from the OS (IQN). | ARM deployment, Trailwright |

### hardware

What every machine is.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `hardware` | What every machine is. | object | yes / yes |  |  |  | ZTP, OS configuration, ARM deployment, Trailwright |
| `hardware.vendor` | OEM, for example Dell, HPE, Lenovo or DataON. | string | yes / yes |  | `Dell` | The hardware you ordered. | ZTP, OS configuration, Trailwright |
| `hardware.model` | Model, for example AX-760. | string | yes / yes |  | `AX-760` | The hardware you ordered. | ZTP, OS configuration, Trailwright |
| `hardware.cpu_cores` | Physical cores per machine. | integer | no / no |  | `64` | The hardware you ordered. | Trailwright |
| `hardware.memory_gib` | Memory per machine, GiB. | integer | no / no |  | `1024` | The hardware you ordered. | Trailwright |
| `hardware.gpu` |  | object | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.gpu.enabled` |  | boolean | no / no |  | `false` | The hardware you ordered. | Trailwright |
| `hardware.gpu.model` |  | string | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.gpu.count_per_node` |  | integer | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.bmc` | BMC (iDRAC, iLO, XCC) login used for every machine unless a node sets its own. | object | no / yes |  |  | The hardware you ordered. | ZTP, Trailwright |
| `hardware.bmc.username` | A reference to the secret holding the user name, or the user name itself. | string | if section is set / yes |  | `keyvault://kv-iic-mgmt-01/bmc-username` | A Key Vault secret you create holding the BMC login (see Secrets). | ZTP, Trailwright |
| `hardware.bmc.password` (secret) | Key Vault reference for the password of hardware.bmc. | keyvault:// reference | if section is set / yes |  | `keyvault://kv-iic-mgmt-01/bmc-password` | A Key Vault secret you create holding the BMC login (see Secrets). | ZTP, Trailwright |
| `hardware.bmc.rfs_write_attribute` | Azurelocal-ztp, Boot stage: also set the iDRAC Remote File Share attribute RFS.<n>.WriteProtected to Read Write before it inserts the virtual media.... (since 5.4) | boolean | no / no | `true for Dell (azurelocal-ztp config/oem/dell.json, bmc.rfsWriteAttribute), false for the...` | `true` | Your BMC: the vendor's default is right unless the BMC firmware differs. | ZTP, Trailwright |
| `hardware.bmc.verify_certificate` | Check the BMCs' TLS certificates. (since 5.4) | boolean | no / no | `false` | `false` | Your BMC: the vendor's default is right unless the BMC firmware differs. | ZTP, Trailwright |
| `hardware.bios` | BIOS attributes for every machine, as they are when the machine is finished (schema 5.2; from 5.3 this is the FINAL state): a node's bios is merged o... | map of strings | no / no |  |  | The BMC's Redfish Bios resource or the vendor's BIOS attribute registry. | ZTP, Trailwright |
| `hardware.bios.<attribute>` |  | string | no / no |  | `EmbNic1Nic2: Enabled` | The BMC's Redfish Bios resource or the vendor's BIOS attribute registry. | ZTP, Trailwright |
| `hardware.bios_during_provisioning` | BIOS attributes that hold for the OS install only: TEMPORARY values. (since 5.3) | map of strings | no / no |  |  | The BMC's Redfish Bios resource or the vendor's BIOS attribute registry. | ZTP, Trailwright |
| `hardware.bios_during_provisioning.<attribute>` |  | string | no / no |  | `Slot2: Disabled` | The BMC's Redfish Bios resource or the vendor's BIOS attribute registry. | ZTP, Trailwright |
| `hardware.sbe` | Solution Builder Extension. | object | no / no |  |  | The hardware you ordered. | ZTP, ARM deployment, Trailwright |
| `hardware.sbe.publisher` |  | string | no / no |  | `Dell` | The OEM's Solution Builder Extension release notes. | Trailwright |
| `hardware.sbe.family` |  | string | no / no |  |  | The OEM's Solution Builder Extension release notes. | Trailwright |
| `hardware.sbe.version` |  | string | no / no |  |  | The OEM's Solution Builder Extension release notes. | Trailwright |
| `hardware.sbe.manifest_source` |  | string | no / no |  |  | The OEM's Solution Builder Extension release notes. | Trailwright |
| `hardware.sbe.manifest_creation_date` |  | string | no / no |  |  | The OEM's Solution Builder Extension release notes. | Trailwright |
| `hardware.sbe.bundle_path` | Folder on the management host with the OEM's SBE files as downloaded: one SBE_*.zip, its SBE_*.xml and SBE_Discovery_<oem>.xml. | string | no / no |  | `D:\sbe\dell` | A folder you create on the management host (see Folders), holding the OEM's Solution Builder Extension as downloaded. | ZTP |
| `hardware.sbe.allow_unvalidated` | Test only. | boolean | no / no |  | `false` | The OEM's Solution Builder Extension release notes. | ZTP, Trailwright |
| `hardware.network_cards` | The physical network cards in every machine, and what each port is for. | list of objects | no / no |  |  | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].label` |  | string | no / no |  | `Onboard` | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].make` |  | string | no / no |  |  | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].model` |  | string | no / no |  |  | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].ports` |  | list of objects | no / no |  |  | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].ports[].name` | Adapter name in the OS, as the intents use it. | string | if section is set / if section is set |  | `Port1` | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].ports[].speed_gbps` |  | number | no / no |  | `25` | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].ports[].rdma` |  | one of `none`, `iwarp`, `roce`, `roce_v2` | no / no |  | `none` | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.network_cards[].ports[].role` | unused, intent:<intent name>, cluster:a, cluster:b, iscsi:a or iscsi:b. | string | no / no |  | `intent:management` | The hardware you ordered. | OS configuration, Trailwright |
| `hardware.drives` | Drives per machine. | object | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.drives.capacity` |  | object | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.drives.capacity.media` |  | one of `nvme`, `ssd`, `hdd` | no / no |  | `nvme` | The hardware you ordered. | Trailwright |
| `hardware.drives.capacity.count` |  | integer | no / no |  | `8` | The hardware you ordered. | Trailwright |
| `hardware.drives.capacity.size_tb` |  | number | no / no |  | `3.84` | The hardware you ordered. | Trailwright |
| `hardware.drives.cache` |  | object | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.drives.cache.media` |  | one of `nvme`, `ssd`, `hdd` | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.drives.cache.count` |  | integer | no / no |  |  | The hardware you ordered. | Trailwright |
| `hardware.drives.cache.size_tb` |  | number | no / no |  |  | The hardware you ordered. | Trailwright |

### networking

The on-premises networks.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `networking` | The on-premises networks. | object | yes / yes |  |  |  | ZTP, OS configuration, ARM deployment, Trailwright |
| `networking.management` | The management network and the infrastructure IP pool. | object | yes / yes |  |  | Your network design; Trailwright guides it. | ZTP, OS configuration, ARM deployment, Trailwright |
| `networking.management.subnet` | CIDR. | CIDR | yes / yes |  | `192.0.2.0/24` | Your IP plan for the management network. | ZTP, OS configuration, ARM deployment, Trailwright |
| `networking.management.gateway` | The one default gateway. | IPv4 address | yes / yes |  | `192.0.2.1` | Your IP plan for the management network. | ZTP, OS configuration, ARM deployment, Trailwright |
| `networking.management.vlan_id` | 0 means untagged. | integer | no / no |  | `0` | Your IP plan for the management network. | ZTP, OS configuration, Trailwright |
| `networking.management.dns_servers` | ARM dnsServers. | list of IPv4 address | yes / yes |  | `[192.0.2.4, 192.0.2.5]` | Your IP plan for the management network. | ZTP, OS configuration, ARM deployment, Trailwright |
| `networking.management.ip_assignment` | Deprecated. Deprecated in 5.2: set each port's ip_assignment in nodes[].network_adapters. | one of `static`, `dhcp`, `preconfigured` | no / no | `static` | `static` | Your IP plan for the management network. | ZTP, OS configuration, ARM deployment, Trailwright |
| `networking.management.use_dhcp` | ARM useDhcp: the deployment takes the host and cluster addresses from DHCP instead of static addresses and the infrastructure_pool. | boolean | no / no |  | `false` | Your IP plan for the management network. | OS configuration, ARM deployment, Trailwright |
| `networking.management.site_ip_range` | Simplified provisioning: the address range of the site's network setting (Microsoft.Edge/configurations/networkConfigurations ipv4.addressRange) when... | object | no / no | `the lowest to the highest static management address` |  | Your IP plan for the management network. | ZTP, OS configuration, Trailwright |
| `networking.management.site_ip_range.start` |  | IPv4 address | if section is set / if section is set |  |  | Your IP plan for the management network. | ZTP, OS configuration, Trailwright |
| `networking.management.site_ip_range.end` |  | IPv4 address | if section is set / if section is set |  |  | Your IP plan for the management network. | ZTP, OS configuration, Trailwright |
| `networking.management.provisioning_network` | Simplified provisioning: how the maintenance environment gets the address it reaches Azure with, on the ports with role provisioning, before the mach... | one of `dhcp`, `static` | no / no | `dhcp` | `dhcp` | Your IP plan for the management network. | ZTP, OS configuration, Trailwright |
| `networking.management.static_method` | Simplified provisioning, and only when the management ip_assignment is static: who sets each machine's static management address. device (default): a... (since 5.3) | one of `device`, `site` | no / no | `device` | `device` | Your IP plan for the management network. | ZTP, OS configuration, Trailwright |
| `networking.management.provisioning_dhcp_range` | Simplified provisioning: the DHCP range on the provisioning network (the one the maintenance environment gets its address on). (since 5.3) | object | no / no |  |  | The DHCP scope on the provisioning network (your DHCP server). | ZTP, OS configuration, Trailwright |
| `networking.management.provisioning_dhcp_range.start` |  | IPv4 address | if section is set / if section is set |  | `192.0.2.100` | The DHCP scope on the provisioning network (your DHCP server). | ZTP, OS configuration, Trailwright |
| `networking.management.provisioning_dhcp_range.end` |  | IPv4 address | if section is set / if section is set |  | `192.0.2.199` | The DHCP scope on the provisioning network (your DHCP server). | ZTP, OS configuration, Trailwright |
| `networking.management.infrastructure_pool` | At least six contiguous addresses in the management subnet, outside the machines' addresses. | object | when use_dhcp is not true / no |  |  | Your IP plan for the management network. | OS configuration, ARM deployment, Trailwright |
| `networking.management.infrastructure_pool.start` |  | IPv4 address | if section is set / if section is set |  | `192.0.2.20` | Your IP plan for the management network. | OS configuration, Trailwright |
| `networking.management.infrastructure_pool.end` |  | IPv4 address | if section is set / if section is set |  | `192.0.2.29` | Your IP plan for the management network. | OS configuration, Trailwright |
| `networking.oob` | The out-of-band network of the BMCs. | object | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.oob.subnet` |  | CIDR | no / no |  | `198.51.100.0/24` | Your network design; Trailwright guides it. | Trailwright |
| `networking.oob.gateway` |  | IPv4 address | no / no |  | `198.51.100.1` | Your network design; Trailwright guides it. | Trailwright |
| `networking.oob.vlan_id` |  | integer | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.ntp_servers` | Time sources, as host names or addresses. | list of string | no / no |  | `[192.0.2.4, 192.0.2.5]` | Your network design; Trailwright guides it. | ZTP, OS configuration, Trailwright |
| `networking.intents` | Network ATC intents. | list of object | yes / no |  |  | Your network design; Trailwright guides it. | OS configuration, ARM deployment, Trailwright |
| `networking.intents[].name` |  | string | yes / if section is set |  | `management` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].traffic` |  | list of one of `management`, `compute`, `storage` | yes / if section is set |  | `[management]` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].adapters` | Adapter names in the OS, the same on every machine. | list of string | yes / if section is set |  | `[Port1, Port2]` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides` | Network ATC overrides. | object | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.qos` |  | object | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.qos.cluster_priority` |  | integer | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.qos.smb_priority` |  | integer | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.qos.smb_bandwidth_percent` |  | integer | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.adapter` |  | object | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.adapter.jumbo_packet` |  | one of `1514`, `4088`, `9014` | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.adapter.network_direct` |  | boolean | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.adapter.network_direct_technology` |  | one of `iwarp`, `roce`, `roce_v2` | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.virtual_switch` |  | object | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.virtual_switch.enable_iov` |  | boolean | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.intents[].overrides.virtual_switch.load_balancing_algorithm` |  | one of `dynamic`, `hyper_v_port` | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage` | Storage networks (Storage Spaces Direct). | object | when scenario.storage_connectivity is switchless / no |  |  | Your network design; Trailwright guides it. | OS configuration, ARM deployment, Trailwright |
| `networking.storage.auto_ip` | Network ATC assigns the storage addresses. | boolean | no / no |  | `true` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.switchless_links` | Switchless only: one or two links between each pair of machines. | one of `single`, `dual` | when scenario.storage_connectivity is switchless / no |  | `dual` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.tor_switches` | Top-of-rack switches. | integer | no / no |  | `2` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.layout` | dedicated: storage on its own ports. converged: storage shares ports with other traffic. | one of `dedicated`, `converged` | no / no |  | `converged` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.networks` |  | list of objects | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.networks[].name` | For example StorageNetwork1. | string | if section is set / if section is set |  | `StorageNetwork1` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.networks[].adapter` | Adapter name in the OS. | string | if section is set / if section is set |  | `Port3` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.networks[].vlan_id` | Network ATC defaults are 711 and 712. | integer | if section is set / if section is set |  | `711` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.storage.networks[].subnet` | Needed when auto_ip is false. | CIDR | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.cluster_networks` | Disaggregated (SAN) only: the cluster networks on standalone ports, fabric A and B. | list of objects | when scenario.storage_architecture is san or hybrid / no |  |  | Your network design; Trailwright guides it. | OS configuration, ARM deployment, Trailwright |
| `networking.cluster_networks[].name` |  | string | if section is set / if section is set |  | `clusterNetwork-A` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.cluster_networks[].adapter` |  | string | if section is set / if section is set |  | `NIC3` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.cluster_networks[].vlan_id` |  | integer | if section is set / if section is set |  | `1711` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.cluster_networks[].subnet` |  | CIDR | if section is set / if section is set |  | `198.51.100.0/26` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.vlans` | Every VLAN in the design, by name. | list of objects | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.vlans[].name` |  | string | if section is set / if section is set |  | `storage-1` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.vlans[].id` |  | integer | if section is set / if section is set |  | `711` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.vlans[].subnet` |  | CIDR | no / no |  | `203.0.113.0/24` | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.vlans[].purpose` |  | string | no / no |  |  | Your network design; Trailwright guides it. | OS configuration, Trailwright |
| `networking.logical_networks` | Arc VM logical networks created after deployment. | list of object | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].name` |  | string | if section is set / if section is set |  | `lnet-workloads` | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].vlan_id` |  | integer | no / no |  | `2204` | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].address_prefix` |  | CIDR | no / no |  | `203.0.113.0/24` | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].gateway` |  | IPv4 address | no / no |  | `203.0.113.1` | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].dns_servers` |  | list of IPv4 address | no / no |  | `[192.0.2.4, 192.0.2.5]` | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].ip_pool` |  | object | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].ip_pool.start` |  | IPv4 address | if section is set / if section is set |  | `203.0.113.100` | Your network design; Trailwright guides it. | Trailwright |
| `networking.logical_networks[].ip_pool.end` |  | IPv4 address | if section is set / if section is set |  | `203.0.113.200` | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound` | Details of scenario.outbound_path. | object | when scenario.outbound_path is proxy or proxy_arc_gateway / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.proxy` |  | object | when scenario.outbound_path is proxy or proxy_arc_gateway / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.proxy.url` |  | string | if section is set / if section is set |  | `http://proxy.improbability.cloud:8080` | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.proxy.bypass` |  | list of string | no / no |  | `[localhost, 127.0.0.1, *.improbability.cloud, 192.0.2.*]` | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.arc_gateway` | The Arc gateway resource, in the same subscription as the machines. | object | when scenario.outbound_path is arc_gateway or proxy_arc_gateway / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.arc_gateway.name` |  | string | if section is set / if section is set |  | `arcgw-iic-branch-01` | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.arc_gateway.resource_group` |  | resource group name | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path` |  | object | when scenario.outbound_path is private_path / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.transport` |  | one of `expressroute`, `site_to_site_vpn` | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.virtual_network` |  | string | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.workload_subnet` |  | string | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.firewall_subnet` |  | string | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.firewall_private_ip` |  | IPv4 address | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.firewall_port` |  | integer | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.arc_private_link_scope` |  | boolean | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |
| `networking.outbound.private_path.proxy_bypass` |  | list of string | no / no |  |  | Your network design; Trailwright guides it. | Trailwright |

### identity

Accounts and the identity provider (scenario.identity).

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `identity` | Accounts and the identity provider (scenario.identity). | object | yes / yes |  |  |  | ZTP, OS configuration, ARM deployment, Trailwright |
| `identity.local_admin` | The deployment's local administrator on every machine. | object | yes / yes |  |  | You choose the name; the password is a Key Vault secret you create (see Secrets). | ZTP, OS configuration, ARM deployment, Trailwright |
| `identity.local_admin.username` |  | string | yes / yes |  | `azl-admin` | You choose the name; the password is a Key Vault secret you create (see Secrets). | ZTP, OS configuration, Trailwright |
| `identity.local_admin.password` (secret) | At least 14 characters with lowercase, uppercase, a digit and a special character. | keyvault:// reference | yes / yes |  | `keyvault://kv-iic-mgmt-01/local-admin-password` | You choose the name; the password is a Key Vault secret you create (see Secrets). | ZTP, OS configuration, Trailwright |
| `identity.active_directory` |  | object | when scenario.identity is active_directory / no |  |  | Your Active Directory and Microsoft Entra ID teams. | ARM deployment, Trailwright |
| `identity.active_directory.domain_fqdn` | ARM domainFqdn. | string | if section is set / if section is set |  | `improbability.cloud` | Your Active Directory and Microsoft Entra ID teams. | ARM deployment, Trailwright |
| `identity.active_directory.netbios_name` | Up to 15 letters, digits and hyphens. | NetBIOS name | no / no |  | `IIC` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.ou_path` | Distinguished name of the dedicated OU. | string | if section is set / if section is set |  | `OU=iic-azl-01,OU=AzureLocal,DC=improbability,DC=cloud` | Your Active Directory and Microsoft Entra ID teams. | ARM deployment, Trailwright |
| `identity.active_directory.lcm_user` | The LCM deployment user, created in the OU by the AD preparation module. | object | if section is set / if section is set |  |  | Your Active Directory and Microsoft Entra ID teams. | ARM deployment, Trailwright |
| `identity.active_directory.lcm_user.username` | Name only, no domain. | string | if section is set / if section is set |  | `lcm-iic-azl-01` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.lcm_user.password` (secret) | At least 14 characters with lowercase, uppercase, a digit and a special character. | keyvault:// reference | if section is set / if section is set |  | `keyvault://kv-iic-mgmt-01/lcm-password` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.domain_controllers` | Addresses of domain controllers, for pre-checks. | list of IPv4 address | no / no |  | `[192.0.2.4, 192.0.2.5]` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.security_groups` | Groups created in the OU for administration of the instance. | list of objects | no / no |  |  | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.security_groups[].name` |  | string | if section is set / if section is set |  | `sg-iic-azl-01-admins` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.security_groups[].purpose` |  | string | no / no |  | `Administrators of the instance` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.security_groups[].members` |  | list of string | no / no |  |  | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.service_accounts` | Service and administration accounts, apart from the LCM user. | list of objects | no / no |  |  | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.service_accounts[].name` |  | string | if section is set / if section is set |  | `svc-iic-azl-backup` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.service_accounts[].purpose` |  | string | no / no |  | `Backup agent` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.active_directory.service_accounts[].password` (secret) | Key Vault reference for the password of identity.active_directory.service_accounts[]. | keyvault:// reference | no / no |  | `keyvault://kv-iic-mgmt-01/svc-backup-password` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.local_identity` | Local identity with Key Vault. | object | when scenario.identity is local_identity / no |  |  | Your Active Directory and Microsoft Entra ID teams. | ARM deployment, Trailwright |
| `identity.local_identity.dns_server_config` | ARM dnsServerConfig: use_dns_server (UseDnsServer) or use_forwarder (UseForwarder). | one of `use_dns_server`, `use_forwarder` | if section is set / if section is set |  | `use_dns_server` | Your Active Directory and Microsoft Entra ID teams. | ARM deployment, Trailwright |
| `identity.local_identity.dns_zone` |  | string | no / no |  | `br01.improbability.cloud` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.local_identity.dns_forwarders` |  | list of IPv4 address | no / no |  |  | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra` | Entra ID groups, role assignments and PIM. | object | no / no |  |  | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra.groups` |  | list of objects | no / no |  |  | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra.groups[].name` |  | string | if section is set / if section is set |  | `grp-iic-azl-operators` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra.groups[].purpose` |  | string | no / no |  | `Operate the instance` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra.groups[].roles` | Azure role names assigned to the group. | list of string | no / no |  | `[Azure Stack HCI Administrator]` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra.groups[].scope` | Scope of the role assignments. | string | no / no |  | `/subscriptions/00000000-0000-0000-0000-000000000000/res...` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |
| `identity.entra.break_glass_accounts` | User principal names of emergency access accounts, excluded from Conditional Access. | list of string | no / no |  | `[breakglass01@improbability.cloud]` | Your Active Directory and Microsoft Entra ID teams. | Trailwright |

### storage

Volumes and the SAN.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `storage` | Volumes and the SAN. | object | when scenario.storage_architecture is san or hybrid / no |  |  |  | ARM deployment, Trailwright |
| `storage.configuration_mode` | ARM configurationMode: express (Express), infra_only (InfraOnly) or keep_storage (KeepStorage). | one of `express`, `infra_only`, `keep_storage` | no / no |  | `express` | Your storage design. | ARM deployment, Trailwright |
| `storage.volumes` |  | list of objects | no / no |  |  | Your storage design. | Trailwright |
| `storage.volumes[].name` |  | string | if section is set / if section is set |  | `vol-workloads-01` | Your storage design. | Trailwright |
| `storage.volumes[].size_gib` |  | number | if section is set / if section is set |  | `4096` | Your storage design. | Trailwright |
| `storage.volumes[].resiliency` |  | one of `two_way`, `three_way`, `four_way`, `parity`, `nested_two_way` | no / no |  | `two_way` | Your storage design. | Trailwright |
| `storage.san` | The external SAN of a disaggregated (san) or hybrid deployment. | object | when scenario.storage_architecture is san or hybrid / no |  |  | Your storage design. | ARM deployment, Trailwright |
| `storage.san.type` | fibre_channel needs storage.san.fibre_channel; iscsi needs storage.san.iscsi. | one of `fibre_channel`, `iscsi` | if section is set / if section is set |  | `fibre_channel` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.array` | The storage array that presents the LUNs. (since 5.3) | object | no / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.array.name` | The array's name, for example its hostname in the array manager. | string | if section is set / if section is set |  | `san-iic-dc02-01` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.array.vendor` |  | string | if section is set / if section is set |  | `Dell` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.array.model` |  | string | if section is set / if section is set |  | `PowerStore 1200T` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.array.management_address` | The array's management address, when the SAN deployment drives it. | IPv4 address | no / no |  | `198.51.100.40` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel` | Required when type is fibre_channel: the fabrics and the array's target ports. (since 5.3) | object | when storage.san.type is fibre_channel / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.fabrics` | The Fibre Channel fabrics, for example A and B. | list of objects | no / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.fabrics[].name` | For example A or B. | string | if section is set / if section is set |  | `A` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.fabrics[].switch` | The fabric's switch, for example a network_devices[].hostname. | string | no / no |  | `fc-sw-a-iic-dc02` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.fabrics[].zone_set` | The active zone set on this fabric. | string | no / no |  | `azl-iic-dc02-a` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.target_wwpns` | The array's target ports (WWPNs) and the fabric each is cabled to. | list of objects | when always for fibre_channel (rule AZL-028) / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.target_wwpns[].wwpn` | A Fibre Channel World Wide Port Name: 16 hexadecimal digits, as 8 colon-separated pairs (50:00:09:72:08:12:34:56) or without colons. | WWPN | if section is set / if section is set |  | `50:00:00:00:00:00:01:01` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.fibre_channel.target_wwpns[].fabric` | A name in fabrics. | string | if section is set / if section is set |  | `A` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi` | Required when type is iscsi: the array's targets and CHAP. (since 5.3) | object | when storage.san.type is iscsi / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.targets` | The array's iSCSI targets. | list of objects | when always for iscsi (rule AZL-028) / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.targets[].iqn` | An iSCSI qualified name (iqn.yyyy-mm.reversed.domain[:identifier]), or an eui. or naa. name. | iSCSI name (IQN) | if section is set / if section is set |  | `iqn.2026-11.cloud.improbability:san-iic-dc03-01.a` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.targets[].portals` | The target portals: an IPv4 address, optionally with a port (default 3260), for example 198.51.100.10 or 198.51.100.10:3260. | list of IPv4 or IPv4:port | if section is set / if section is set |  | `[198.51.100.4:3260, 198.51.100.5]` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.targets[].fabric` | The storage network this target serves, matching the iSCSI port role: A for iscsi:a, B for iscsi:b. | string | no / no |  | `A` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.chap` | CHAP authentication of the sessions. | object | no / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.chap.enabled` |  | boolean | if section is set / if section is set |  | `true` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.chap.username` |  | string | when chap.enabled is true / no |  | `azl-chap` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.iscsi.chap.secret` (secret) | Key Vault reference for the secret of storage.san.iscsi.chap. | keyvault:// reference | when chap.enabled is true / no |  | `keyvault://kv-iic-dc03-mgmt/iscsi-chap-secret` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.infra_volume_lun_id` | LUN of the infrastructure volume (250 GB minimum). | string | no / no |  | `0` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.performance_history_lun_id` | LUN of the performance history volume (20 GB minimum). | string | no / no |  | `1` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.luns` |  | list of objects | no / no |  |  | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.luns[].name` |  | string | if section is set / if section is set |  | `lun-workloads-01` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.luns[].size_gib` |  | number | if section is set / if section is set |  | `8192` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |
| `storage.san.luns[].lun_id` |  | string | no / no |  | `2` | The SAN administrator: the array manager and the fabric switches. | ARM deployment, Trailwright |

### security

Security settings of the deployment.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `security` | Security settings of the deployment. | object | no / no |  |  |  | ARM deployment, Trailwright |
| `security.level` | ARM securityLevel: recommended (Recommended) or customized (Customized). | one of `recommended`, `customized` | no / no |  | `recommended` | Your security baseline; Microsoft's recommended defaults apply when omitted. | ARM deployment, Trailwright |
| `security.drift_control` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.credential_guard` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.smb_signing` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.smb_cluster_encryption` |  | boolean | no / no |  | `false` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.bitlocker_boot_volume` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.bitlocker_data_volumes` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.wdac` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.backup_key_vault` |  | Key Vault name | no / no |  |  | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.telemetry` |  | object | no / no |  |  | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.telemetry.streaming_data` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.telemetry.episodic_data_upload` |  | boolean | no / no |  | `true` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |
| `security.telemetry.eu_location` |  | boolean | no / no |  | `false` | Your security baseline; Microsoft's recommended defaults apply when omitted. | Trailwright |

### sdn

SDN enabled by Azure Arc.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `sdn` | SDN enabled by Azure Arc. | object | no / no |  |  | Your SDN design. | Trailwright |
| `sdn.enabled` |  | boolean | if section is set / if section is set |  | `false` | Your SDN design. | Trailwright |
| `sdn.prefix` |  | string | no / no |  |  | Your SDN design. | Trailwright |
| `sdn.dns_records` |  | one of `dynamic`, `static` | no / no |  |  | Your SDN design. | Trailwright |
| `sdn.default_access_policy` |  | boolean | no / no |  |  | Your SDN design. | Trailwright |

### operations



| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `operations` |  | object | no / no |  |  |  | Trailwright |
| `operations.update_method` |  | one of `portal`, `powershell` | no / no |  | `portal` | Your operations design. | Trailwright |
| `operations.monitoring` |  | object | no / no |  |  | Your operations design. | Trailwright |
| `operations.monitoring.enabled` |  | boolean | if section is set / if section is set |  | `true` | Your operations design. | Trailwright |
| `operations.monitoring.log_analytics_workspace` |  | string | no / no |  | `log-iic-azl-01` | Your operations design. | Trailwright |
| `operations.monitoring.workspace_resource_group` |  | resource group name | no / no |  | `rg-iic-mgmt-01` | Your operations design. | Trailwright |
| `operations.monitoring.data_collection_rule` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.monitoring.data_collection_endpoint` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.monitoring.health_alerts` |  | boolean | no / no |  | `true` | Your operations design. | Trailwright |
| `operations.monitoring.alert_email` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.backup` |  | object | no / no |  |  | Your operations design. | Trailwright |
| `operations.backup.enabled` |  | boolean | if section is set / if section is set |  | `false` | Your operations design. | Trailwright |
| `operations.backup.approach` |  | one of `host`, `guest`, `both` | no / no |  |  | Your operations design. | Trailwright |
| `operations.backup.solution` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.backup.recovery_vault` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.backup.resource_group` |  | resource group name | no / no |  |  | Your operations design. | Trailwright |
| `operations.backup.policy` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery` |  | object | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.method` |  | one of `none`, `asr`, `hyper_v_replica` | no / no |  | `none` | Your operations design. | Trailwright |
| `operations.disaster_recovery.recovery_vault` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.resource_group` |  | resource group name | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.replication_policy` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.recovery_plan` |  | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.network` | Network the VMs fail over to. | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.test_network` | Isolated network for test failovers. | string | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.storage_account` |  | storage account name | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.target_rto_minutes` |  | integer | no / no |  |  | Your operations design. | Trailwright |
| `operations.disaster_recovery.target_rpo_minutes` |  | integer | no / no |  |  | Your operations design. | Trailwright |
| `operations.notifications` | Who hears about alerts. | object | no / no |  |  | Your operations design. | Trailwright |
| `operations.notifications.emails` |  | list of string | no / no |  | `[noc@improbability.cloud]` | Your operations design. | Trailwright |
| `operations.notifications.teams_webhook` (secret) | Key Vault reference for the teams_webhook of operations.notifications. | keyvault:// reference | no / no |  | `keyvault://kv-iic-mgmt-01/teams-webhook-url` | Your operations design. | Trailwright |
| `operations.licensing` |  | object | no / no |  |  | Your operations design. | Trailwright |
| `operations.licensing.azure_hybrid_benefit` | Azure Hybrid Benefit for the host fee and Windows Server guests. | boolean | no / no |  | `true` | Your operations design. | Trailwright |
| `operations.licensing.windows_server_subscription` |  | boolean | no / no |  | `false` | Your operations design. | Trailwright |
| `operations.licensing.azure_verification_for_vms` |  | boolean | no / no |  |  | Your operations design. | Trailwright |

### provisioning

How the OS gets onto the machines (scenario.os_install), and the OS version.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `provisioning` | How the OS gets onto the machines (scenario.os_install), and the OS version. | object | when scenario.os_install is simplified / yes |  |  |  | ZTP, OS configuration, ARM deployment, Trailwright |
| `provisioning.os_version` | The solution version the machines run: latest, latest-preview, or a version such as 12.2610.1004.50. | string | if section is set / yes |  | `12.2610.1004.50` | The OS release you pin, from the release notes of Azure Local. | ZTP, OS configuration, Trailwright |
| `provisioning.iso` | OS installed from an ISO. | object | no / no |  |  | The OS release you pin, from the release notes of Azure Local. | Trailwright |
| `provisioning.iso.image_source` | microsoft (the Azure portal download) or oem (the OEM's image). | one of `microsoft`, `oem` | no / no |  | `oem` | The OS release you pin, from the release notes of Azure Local. | Trailwright |
| `provisioning.iso.image_version` |  | string | no / no |  |  | The OS release you pin, from the release notes of Azure Local. | Trailwright |
| `provisioning.simplified` | Simplified machine provisioning from Azure, as azurelocal-ztp runs it. https://learn.microsoft.com/azure/azure-local/deploy/simplified-machine-provis... | object | when scenario.os_install is simplified / yes |  |  | The OS release you pin, from the release notes of Azure Local. | ZTP, ARM deployment, Trailwright |
| `provisioning.simplified.site_name` | Resource name of the Microsoft.Edge site. | string | if section is set / if section is set |  | `iic-site-01` | The OS release you pin, from the release notes of Azure Local. | ZTP, Trailwright |
| `provisioning.simplified.subscription_id` | Subscription of the site and edge machines, when it isn't azure.subscription_id. | GUID | no / no |  |  | The OS release you pin, from the release notes of Azure Local. | ZTP, Trailwright |
| `provisioning.simplified.resource_group` | Resource group of the site and edge machines, when it isn't azure.resource_group. | resource group name | no / no |  |  | The OS release you pin, from the release notes of Azure Local. | ZTP, Trailwright |
| `provisioning.simplified.maintenance_iso` | The provisioning (maintenance environment) ISO: latest, a train such as 2610, a build such as 10.2610.0.3063, or a Microsoft download URL. | string | if section is set / if section is set |  | `latest` | Azure portal > Azure Arc > Machine Provisioning > View downloads, or a Microsoft download URL. | ZTP, Trailwright |
| `provisioning.simplified.admin` | The local administrator that the provisioned OS gets. | object | if section is set / if section is set |  |  | A Key Vault secret you create (see Secrets). | ZTP, Trailwright |
| `provisioning.simplified.admin.username` |  | string | if section is set / if section is set |  | `administrator` | A Key Vault secret you create (see Secrets). | ZTP, Trailwright |
| `provisioning.simplified.admin.password` (secret) | At least 12 characters with lowercase, uppercase, a digit and a special character. | keyvault:// reference | if section is set / if section is set |  | `keyvault://kv-iic-mgmt-01/provisioning-admin-password` | A Key Vault secret you create (see Secrets). | ZTP, Trailwright |
| `provisioning.simplified.maintenance_password` (secret) | The password of the maintenance environment's local user (edgeuser), which azurelocal-ztp's Device stage signs in with to reach the Configurator serv... (since 5.3) | keyvault:// reference | no / no | `the maintenance environment's out-of-box password that Microsoft Learn documents (Configu...` | `keyvault://kv-iic-lab-mgmt/maintenance-password` | A Key Vault secret you create (see Secrets). | ZTP |
| `provisioning.simplified.media_share` | The SMB share the BMCs mount the images from. | object | if section is set / if section is set |  |  | The management host: the share and the address the BMCs reach it on. | ZTP |
| `provisioning.simplified.media_share.name` |  | string | if section is set / if section is set |  | `ztp-virtual-usb` | The management host: the share and the address the BMCs reach it on. | ZTP |
| `provisioning.simplified.media_share.host` | The management host's address as the BMCs reach it. | IPv4 address | no / no |  | `198.51.100.5` | The management host: the share and the address the BMCs reach it on. | ZTP |
| `provisioning.simplified.media_share.host_adapter` | Instead of host: the local adapter whose IPv4 address the BMCs reach. | string | no / no |  | `Management` | The management host: the share and the address the BMCs reach it on. | ZTP |
| `provisioning.simplified.media_share.account_name` | The local account azurelocal-ztp creates on the management host to give the BMCs access to the share (it generates a password for it, and removes the... (since 5.4) | string | no / no | `svc-ztp-media` | `svc-ztp-media` | The management host: the share and the address the BMCs reach it on. | ZTP |
| `provisioning.simplified.media_share.keep` | Keep the share, its firewall rule and the account after the vouchers are collected (azurelocal-ztp removes them by default). (since 5.4) | boolean | no / no | `false` | `false` | The management host: the share and the address the BMCs reach it on. | ZTP |
| `provisioning.simplified.media_path` | Folder on the management host for the run's downloads and data: the maintenance ISO cache, the SBE copy and its unpacked drivers, the per-node USB im... (since 5.2) | string | no / no | `%ProgramData%\AzureLocalZtp\<site_name>\media` | `D:\Data\azl-ztp\iic-azl-01\media` | A folder you create on the management host (see Folders). | ZTP |
| `provisioning.simplified.evidence_path` | Folder on the management host for the run's evidence: the event log monitors follow (ztp-events.jsonl), the BIOS and other Redfish change logs, and r... (since 5.2) | string | no / no | `%ProgramData%\AzureLocalZtp\<site_name>\evidence` | `D:\Data\azl-ztp\iic-azl-01\evidence` | A folder you create on the management host (see Folders). | ZTP |
| `provisioning.simplified.isolate_san_adapters` | While the OS installs, turn off the PCIe slots that hold the SAN adapters listed in nodes[].san.hbas[], so the maintenance environment can't install... (since 5.4) | boolean | no / no | `true when any node lists san.hbas, false otherwise` | `true` | Your hardware design: whether a SAN adapter (nodes[].san.hbas) or an onboard NIC (a port with slot Embedded) needs a BIOS action while the OS installs. The default follows the inventory. | ZTP, Trailwright |
| `provisioning.simplified.enable_embedded_nics` | When a node's management or provisioning port has slot Embedded (an onboard LOM), make sure the embedded NICs are enabled in the BIOS (Dell ships the... (since 5.4) | boolean | no / no | `true` | `true` | Your hardware design: whether a SAN adapter (nodes[].san.hbas) or an onboard NIC (a port with slot Embedded) needs a BIOS action while the OS installs. The default follows the inventory. | ZTP, Trailwright |
| `provisioning.simplified.create_resource_group` | Create the resource group of the site and edge machines (azure.resource_group, or provisioning.simplified.resource_group) when it does not exist. (since 5.4) | boolean | no / no | `true` | `true` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.configuration_name` | Name of the Microsoft.Edge/configurations resource (the site configuration). (since 5.4) | string | no / no | `default` | `default` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.managed_resource_group_name` | Name for the managed resource group of the site configuration, which holds the Arc machines. (since 5.4) | string | no / no | `empty, the service chooses the name` |  | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.apply_site_settings` | Create the site's network, time, connectivity and security settings (Microsoft.Edge/configurations child resources). (since 5.4) | boolean | no / no | `true` | `true` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.use_key_vault_configuration` | Reference the Key Vault in the site's security settings, which the provisioning administrator secret needs. (since 5.4) | boolean | no / no | `true` | `true` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.assign_provisioning_roles` | Give each edge machine its constrained role delegations on the resource group and on the Key Vault. (since 5.4) | boolean | no / no | `true` | `true` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.assign_hci_rp_role` | Give the Azure Local resource provider its Azure Connected Machine Resource Manager role on the resource group. (since 5.4) | boolean | no / no | `true` | `true` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.network_kind` | Kind of the site's network setting: LAN or WLAN. (since 5.4) | one of `LAN`, `WLAN` | no / no | `lan` | `LAN` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.ntp` | The time setting of the site configuration, used while the machines are provisioned. (since 5.4) | object | no / no | `Automatic` |  | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.ntp.configuration` | Automatic or Manual. | one of `Automatic`, `Manual` | no / no | `automatic` | `Automatic` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.ntp.server` | The NTP server (address or name) when configuration is Manual. | string | no / no |  |  | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.ntp.alternate_server` | The alternate NTP server when configuration is Manual. | string | no / no |  |  | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.site_mode` | Auto (create the site and configuration when missing), Create (they must not exist) or Reuse (they must exist). (since 5.4) | one of `Auto`, `Create`, `Reuse` | no / no | `auto` | `Auto` | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, Trailwright |
| `provisioning.simplified.deployment_name` | Name of the ARM deployment. (since 5.4) | string | no / no | `ztp-<site_name>` |  | Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal's. | ZTP, ARM deployment |
| `provisioning.simplified.skip_azure_check` | Skip the Bootstrap stage's check of the Azure prerequisites (the feature, the resource providers and the catalog). (since 5.4) | boolean | no / no | `false` | `false` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.include_preview` | Resolve stage: also consider preview trains when maintenance_iso is latest. (since 5.4) | boolean | no / no | `false` | `false` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.max_train` | Resolve stage: the highest train to consider when maintenance_iso is latest, for example 2609 to stay on the train of a given solution release. (since 5.4) | string | no / no | `none` |  | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.retry_provision_os` | Resubmit a failed OS install job once. (since 5.4) | boolean | no / no | `true` | `true` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.usb_image` | The per-node virtual USB image that carries the maintenance ISO. (since 5.4) | object | no / no |  |  | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.usb_image.size_gb` | Image size in GiB. | integer | no / no | `4` | `4` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.usb_image.name_prefix` | File-name prefix of the images (<prefix><node>.img). | string | no / no | `ztp-usb-` | `ztp-usb-` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.maintenance_environment` | The maintenance environment's Configurator service, which the Device stage reaches before the claim. (since 5.4) | object | no / no |  |  | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.maintenance_environment.port` | TCP port of the service (https://<address>:<port>/BootstrapOobeService). | integer | no / no | `20001` | `20001` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.maintenance_environment.username` | The service's local user. | string | no / no | `edgeuser` | `edgeuser` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts` | How long azurelocal-ztp waits at each stage, and how often it polls. (since 5.4) | object | no / no |  |  | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.bootstrap_minutes` | Bootstrap stage: overall budget until the maintenance environment is up and every node is ready for the portal. | integer | no / no | `120` | `120` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.bootstrap_voucher_minutes` | Bootstrap stage: budget until a valid voucher appears. | integer | no / no | `90` | `90` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.bootstrap_stall_minutes` | Bootstrap stage: how long the BMC may show no change before the stage reports a stall. | integer | no / no | `20` | `20` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.voucher_wait_minutes` | Vouchers stage: how long to wait for each node's voucher in its image. | integer | no / no | `120` | `120` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.device_minutes` | Device stage: how long the maintenance environment may take to report the static address (and to be found by the scan). | integer | no / no | `30` | `30` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.ready_minutes` | Ready stage: polling budget until every machine is ready to cluster. | integer | no / no | `180` | `180` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.network_minutes` | Network stage: how long each Azure configuration job may take. | integer | no / no | `60` | `60` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.restore_settle_minutes` | Restore stage: how long to wait after the BIOS restart before checking that the Arc machines are Connected again. | integer | no / no | `5` | `5` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.bios_minutes` | Boot and Restore stages: how long to wait for a node's BIOS to report the new values after the restart. | integer | no / no | `30` | `30` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |
| `provisioning.simplified.timeouts.poll_interval_seconds` | Ready and Network stages: seconds between polls. | integer | no / no | `60` | `60` | Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains. | ZTP |

### disconnected

Disconnected operations: the control plane appliance, its endpoints, identity and certificates.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `disconnected` | Disconnected operations: the control plane appliance, its endpoints, identity and certificates. | object | when scenario.connectivity is disconnected / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.role` |  | one of `management`, `workload` | if section is set / if section is set |  | `management` | Your disconnected-operations design. | Trailwright |
| `disconnected.base_path` |  | string | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.domain_suffix` |  | string | no / no |  | `autonomous.improbability.cloud` | Your disconnected-operations design. | Trailwright |
| `disconnected.ingress` |  | object | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.ingress.ip_address` |  | IPv4 address | no / no |  | `192.0.2.50` | Your disconnected-operations design. | Trailwright |
| `disconnected.ingress.gateway` |  | IPv4 address | no / no |  | `192.0.2.1` | Your disconnected-operations design. | Trailwright |
| `disconnected.ingress.prefix_length` |  | integer | no / no |  | `24` | Your disconnected-operations design. | Trailwright |
| `disconnected.management` |  | object | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.management.ip_address` |  | IPv4 address | no / no |  | `203.0.113.10` | Your disconnected-operations design. | Trailwright |
| `disconnected.management.gateway` |  | IPv4 address | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.management.prefix_length` |  | integer | no / no |  | `24` | Your disconnected-operations design. | Trailwright |
| `disconnected.dns_server` |  | IPv4 address | no / no |  | `192.0.2.4` | Your disconnected-operations design. | Trailwright |
| `disconnected.time_servers` |  | list of string | no / no |  | `[192.0.2.4]` | Your disconnected-operations design. | Trailwright |
| `disconnected.identity` |  | object | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.identity.authority` |  | string | no / no |  | `https://adfs.improbability.cloud/adfs` | Your disconnected-operations design. | Trailwright |
| `disconnected.identity.client_id` |  | string | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.identity.root_operator_upn` |  | string | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.identity.ldap_server` |  | string | no / no |  | `dc01.improbability.cloud` | Your disconnected-operations design. | Trailwright |
| `disconnected.identity.ldaps` |  | boolean | no / no |  | `true` | Your disconnected-operations design. | Trailwright |
| `disconnected.identity.sync_group_identifier` |  | string | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.operator_subscription_name` |  | string | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.resource_group` |  | string | no / no |  |  | Your disconnected-operations design. | Trailwright |
| `disconnected.internal_ca` |  | boolean | no / no |  | `true` | Your disconnected-operations design. | Trailwright |

### network_devices

Switches, firewalls, console servers and other devices in the design.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `network_devices` | Switches, firewalls, console servers and other devices in the design. | list of object | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].hostname` |  | string | if section is set / if section is set |  | `sw01-iic` | Your network inventory. | Trailwright |
| `network_devices[].type` |  | one of `switch`, `firewall`, `router`, `console_server`, `load_balancer`, `wireless_controller` | if section is set / if section is set |  | `switch` | Your network inventory. | Trailwright |
| `network_devices[].role` |  | one of `primary`, `secondary`, `standalone` | no / no |  | `primary` | Your network inventory. | Trailwright |
| `network_devices[].vendor` |  | string | no / no |  | `Dell` | Your network inventory. | Trailwright |
| `network_devices[].model` |  | string | no / no |  | `S5248F-ON` | Your network inventory. | Trailwright |
| `network_devices[].serial_number` |  | string | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].firmware_version` |  | string | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].management` |  | object | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].management.ip_address` | An IPv4 address, or dhcp. | any | no / no |  | `198.51.100.6` | Your network inventory. | Trailwright |
| `network_devices[].management.vlan_id` |  | integer | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].management.protocol` |  | one of `ssh`, `https`, `telnet`, `snmp` | no / no |  | `ssh` | Your network inventory. | Trailwright |
| `network_devices[].credentials` |  | object | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].credentials.username` |  | string | if section is set / if section is set |  | `admin` | Your network inventory. | Trailwright |
| `network_devices[].credentials.password` (secret) | Key Vault reference for the password of network_devices[].credentials. | keyvault:// reference | if section is set / if section is set |  | `keyvault://kv-iic-mgmt-01/switch-admin-password` | Your network inventory. | Trailwright |
| `network_devices[].ha` |  | object | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].ha.enabled` |  | boolean | no / no |  |  | Your network inventory. | Trailwright |
| `network_devices[].ha.mode` |  | string | no / no |  |  | Your network inventory. | Trailwright |

### landing_zone

Part 2 of the implementation steps: the Azure foundation the instance depends on.

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `landing_zone` | Part 2 of the implementation steps: the Azure foundation the instance depends on. | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.management_groups` |  | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.management_groups[].name` |  | string | if section is set / if section is set |  | `mg-iic` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.management_groups[].display_name` |  | string | no / no |  | `IIC` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.management_groups[].parent` | Parent management group name; empty for the tenant root. | string | no / no |  | `mg-iic` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.subscriptions` | Subscriptions by role. azure.subscription_id is the one the instance uses. | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.subscriptions[].name` |  | string | if section is set / if section is set |  | `sub-iic-connectivity` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.subscriptions[].id` |  | GUID | no / no |  | `00000000-0000-0000-0000-000000000000` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.subscriptions[].role` | What the subscription is for. | one of `connectivity`, `identity`, `management`, `security`, `devops`, `workload`, `azure_local` | if section is set / if section is set |  | `connectivity` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.subscriptions[].management_group` |  | string | no / no |  | `mg-iic-platform` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.resource_groups` |  | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.resource_groups[].name` |  | resource group name | if section is set / if section is set |  | `rg-iic-conn-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.resource_groups[].subscription` | Name of a subscription in landing_zone.subscriptions. | string | no / no |  | `sub-iic-connectivity` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.resource_groups[].location` |  | Azure region | no / no |  | `eastus` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.resource_groups[].purpose` |  | string | no / no |  | `hub network` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.resource_providers` | Resource provider namespaces to register, for example Microsoft.AzureStackHCI. | list of string | no / no |  | `[Microsoft.AzureStackHCI, Microsoft.HybridCompute, Micr...` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.networks` | Azure virtual networks. | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].name` |  | string | if section is set / if section is set |  | `vnet-iic-hub-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].subscription` |  | string | no / no |  | `sub-iic-connectivity` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].resource_group` |  | resource group name | no / no |  | `rg-iic-conn-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].location` |  | Azure region | no / no |  | `eastus` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].role` |  | one of `hub`, `spoke` | no / no |  | `hub` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].address_space` |  | list of CIDR | if section is set / if section is set |  | `[10.20.0.0/22]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].dns_servers` |  | list of IPv4 address | no / no |  | `[192.0.2.4, 192.0.2.5]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].subnets` |  | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].subnets[].name` |  | string | if section is set / if section is set |  | `GatewaySubnet` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].subnets[].prefix` |  | CIDR | if section is set / if section is set |  | `10.20.0.0/27` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].subnets[].network_security_group` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].subnets[].route_table` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.networks[].peer_with` | Names of networks this one peers with. | list of string | no / no |  | `[vnet-iic-hub-01]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `landing_zone.connectivity` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.name` |  | string | if section is set / if section is set |  | `vpng-iic-hub-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.resource_group` |  | resource group name | no / no |  | `rg-iic-conn-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.network` |  | string | no / no |  | `vnet-iic-hub-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.sku` |  | string | no / no |  | `VpnGw1AZ` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.bgp_asn` |  | integer | no / no |  | `65515` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site` |  | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].connection_name` |  | string | if section is set / if section is set |  | `cn-iic-dal-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].local_gateway_name` |  | string | no / no |  | `lgw-iic-dal-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_public_ip` |  | IPv4 address | no / no |  | `203.0.113.1` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_address_prefixes` |  | list of CIDR | no / no |  | `[192.0.2.0/24, 198.51.100.0/24]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_bgp_address` |  | IPv4 address | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].peer_asn` |  | integer | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.site_to_site[].shared_key` (secret) | Key Vault reference for the shared_key of landing_zone.connectivity.vpn_gateway.site_to_site[]. | keyvault:// reference | if section is set / if section is set |  | `keyvault://kv-iic-mgmt-01/vpn-shared-key` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.point_to_site` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.point_to_site.address_pool` |  | CIDR | if section is set / if section is set |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.vpn_gateway.point_to_site.authentication` |  | one of `entra_id`, `certificate`, `radius` | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.bastion` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.bastion.name` |  | string | if section is set / if section is set |  | `bas-iic-hub-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.bastion.resource_group` |  | resource group name | no / no |  | `rg-iic-conn-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.bastion.sku` |  | string | no / no |  | `Standard` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.firewall` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.firewall.name` |  | string | if section is set / if section is set |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.firewall.resource_group` |  | resource group name | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.firewall.sku` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.connectivity.firewall.private_ip` |  | IPv4 address | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines` | Management VMs: domain controllers, jump box, Windows Admin Center, syslog. | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].name` |  | string | if section is set / if section is set |  | `vm-iic-dc-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].hostname` | Up to 15 letters, digits and hyphens. | NetBIOS name | no / no |  | `iic-dc01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].role` |  | one of `domain_controller`, `jumpbox`, `windows_admin_center`, `syslog`, `management`, `other` | if section is set / if section is set |  | `domain_controller` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].deploy_target` | Where the VM runs. | one of `azure`, `azure_local`, `onprem` | no / no |  | `azure` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].subscription` |  | string | no / no |  | `sub-iic-management` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].resource_group` |  | resource group name | no / no |  | `rg-iic-mgmt-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].network` |  | string | no / no |  | `vnet-iic-mgmt-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].subnet` |  | string | no / no |  | `snet-iic-mgmt-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].private_ip` |  | IPv4 address | no / no |  | `10.20.4.10` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].size` |  | string | no / no |  | `Standard_D2s_v5` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].os` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].admin_username` |  | string | no / no |  | `iic-vmadmin` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.virtual_machines[].admin_password` (secret) | Key Vault reference for the admin_password of landing_zone.virtual_machines[]. | keyvault:// reference | no / no |  | `keyvault://kv-iic-mgmt-01/vm-admin-password` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.log_analytics` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.log_analytics.name` |  | string | if section is set / if section is set |  | `log-iic-azl-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.log_analytics.resource_group` |  | resource group name | no / no |  | `rg-iic-mgmt-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.log_analytics.retention_days` |  | integer | no / no |  | `90` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.storage_accounts` |  | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.storage_accounts[].name` |  | storage account name | if section is set / if section is set |  | `stiicazl01wit` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.storage_accounts[].resource_group` |  | resource group name | no / no |  | `rg-iic-azl-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.storage_accounts[].sku` |  | string | no / no |  | `Standard_LRS` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |
| `landing_zone.storage_accounts[].purpose` |  | string | no / no |  | `cloud witness` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | Trailwright |

### devops

Part 1 of the implementation steps: the pipeline platform, the project and its settings, the environments, the sign-in to Azure and the self-hosted r...

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `devops` | Part 1 of the implementation steps: the pipeline platform, the project and its settings, the environments, the sign-in to Azure and the self-hosted r... | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, ARM deployment, Trailwright |
| `devops.platform` |  | one of `github`, `gitlab`, `azure_devops` | if section is set / if section is set |  | `github` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.url` |  | string | no / no |  | `https://github.com` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.organization` | Organization, group or project collection. | string | no / no |  | `improbability-cloud` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.project` |  | string | no / no |  | `iic-azure-local` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.api_token` (secret) | Key Vault reference to a token with administrator rights on the organization or project. (since 5.5) | keyvault:// reference | no / no |  | `keyvault://kv-iic-mgmt-01/devops-admin-token` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.subscription` | Name of the subscription in landing_zone.subscriptions that holds the runners (role devops). (since 5.5) | string | no / no | `the subscription with role devops` | `sub-iic-devops` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.resource_group` | Resource group of the runners, their identity and their network. (since 5.5) | resource group name | no / no |  | `rg-iic-runners-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.create_resource_group` | Create devops.resource_group. (since 5.5) | boolean | no / no | `false` | `false` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.repository` | The deployment repository or project that task 02 creates. (since 5.5) | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.repository.name` | Repository name. | string | no / no | `devops.project` | `iic-azurelocal` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.repository.template` | GitHub: owner/repo of a template repository. | string | no / no |  | `AzureLocal/azurelocal-template` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.repository.visibility` | Repository visibility. | one of `private`, `internal` | no / no | `private` | `private` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.repository.default_branch` | The protected default branch. | string | no / no | `main` | `main` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings` | What task 03 sets on the repository: branch protection, approvals and security. (since 5.5) | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings.required_approvals` | Approvals a pull request needs before it merges. 0 for a sandbox. | integer | no / no | `2` | `2` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings.reviewers` | The team or group whose members review: a GitHub team slug (org/team), a GitLab group path or an Azure DevOps group name. | string | no / no |  | `improbability-cloud/platform-team` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings.squash_only` | Allow squash merges only. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings.secret_scanning` | Turn on secret scanning and push protection (GitHub), secret push rules (GitLab) or the secret file check (Azure DevOps). | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings.resolve_conversations` | All conversations must be resolved before a merge. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.settings.required_status_checks` | Pipeline checks that must pass before a merge. | list of string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.environments` | The deployment environments that task 04 creates, with their approval gate. (since 5.5) | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.environments[].name` | Environment name, for example azr-prod-us, or ztp-reinstall for the approval in front of the ZTP Boot stage. | string | if section is set / if section is set |  | `azr-prod-us` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.environments[].approval_required` | A named reviewer must approve each deployment. | boolean | no / no | `false` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.environments[].approvers` | GitHub user names or org/team slugs, GitLab user names or group paths, Azure DevOps e-mail addresses. | list of string | no / no |  | `[platform-lead]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.environments[].wait_minutes` | Delay before a deployment starts (GitHub). | integer | no / no | `0` |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.environments[].deployment_branch` | The only branch that may deploy to the environment. | string | no / no | `main` | `main` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.authentication` | How the pipelines sign in to Azure (tasks 01 and 05). (since 5.5) | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.authentication.method` | oidc: a federated credential per repository and environment, no secret. client_secret: a secret, stored only in Key Vault (devops.authentication.clie... | one of `oidc`, `client_secret` | no / no | `oidc` | `oidc` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.authentication.client_secret` (secret) | Key Vault reference where task 01 stores the generated client secret (method client_secret). | keyvault:// reference | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.authentication.roles` | Roles the service principal gets on each subscription. | list of string | no / no | `Contributor and User Access Administrator, as the automation docs say` | `[Contributor, User Access Administrator]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.authentication.grant_graph_role_management` | Also add the Microsoft Graph application permission RoleManagement.ReadWrite.Directory and grant admin consent. | boolean | no / no | `false` | `false` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.authentication.register_encryption_at_host` | Register Microsoft.Compute and the EncryptionAtHost feature on each subscription. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners` | The self-hosted runners that task 06 deploys with Terraform. (since 5.5) | list of objects | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, ARM deployment, Trailwright |
| `devops.runners[].name` | Name prefix of the VM or VMs, for example vm-tplabs-runner-lnx. | string | if section is set / if section is set |  | `vm-iic-runner-lnx` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].os_type` | Operating system. | one of `linux`, `windows` | if section is set / if section is set |  | `linux` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].purpose` | general: ARM, Arc, Terraform, Ansible and OS configuration. ztp: the azurelocal-ztp Boot, Bootstrap and Vouchers stages (Windows only). | one of `general`, `ztp` | no / no | `general` | `general` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, ARM deployment, Trailwright |
| `devops.runners[].count` | Number of VMs. | integer | no / no | `1` | `1` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].compute_type` | vm or vmss. | one of `vm`, `vmss` | no / no | `vm` |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].size` | VM size. | string | no / no |  | `Standard_D2s_v5` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].labels` | Labels added to the defaults (azure, the OS, terraform, ansible, ztp). | list of string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].registration_secret` (secret) | Key Vault reference to the secret the runner reads at boot: a PAT or App token (GitHub), the runner authentication token (GitLab), a PAT with Agent P... | keyvault:// reference | no / no |  | `keyvault://kv-iic-mgmt-01/github-runner-token` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].pool` | The Azure Pipelines agent pool, or the GitHub runner group. | string | no / no |  | `azurelocal-ztp` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].private_ips` | Static private addresses, one per VM. | list of IPv4 address | no / no |  | `[10.20.10.4]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].subnet` | The runner subnet inside runner_network.address_space. | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].subnet.name` |  | string | if section is set / if section is set |  | `snet-iic-runner-lnx-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].subnet.prefix` |  | CIDR | if section is set / if section is set |  | `10.20.10.0/26` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runners[].data_disk_gb` | Data disk for the ZTP media, images and vouchers. 512 or more for ztp. | integer | no / no | `0` | `512` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network` | The VNet of the runners, the peering with the hub and the lab ranges they reach. (since 5.5) | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.vnet_name` |  | string | no / no |  | `vnet-iic-devops-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.address_space` |  | list of CIDR | no / no |  | `[10.20.10.0/24]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.dns_servers` |  | list of IPv4 address | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.hub_peering` | Peering with the hub VNet. | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.hub_peering.enabled` | Peer the runner VNet with the hub. | boolean | no / no | `false` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.hub_peering.hub_network` | Name of the hub in landing_zone.networks (its subscription and resource group give the VNet ID). | string | no / no |  | `vnet-iic-hub-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.hub_peering.hub_vnet_id` | Resource ID of the hub VNet. | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.hub_peering.use_remote_gateways` | Use the hub VPN or ExpressRoute gateway to reach the lab. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.hub_peering.create_hub_side` | Create the hub half of the peering. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.reachable_cidrs` | Lab networks the runners reach: management, storage, BMC. | list of CIDR | no / no |  | `[192.0.2.0/24, 198.51.100.0/24]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.reachable_tcp_ports` | TCP ports allowed outbound to the lab networks. | list of string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.bmc_cidrs` | The BMC networks. | list of CIDR | no / no |  | `[198.51.100.0/24]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_network.admin_source_cidrs` | Ranges that may reach SSH or RDP on the runners. | list of CIDR | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_access` | What the runners may do in Azure (least privilege). (since 5.5) | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_access.resource_groups` | Resource groups where the runners are Contributor. | list of resource group name | no / no | `azure.resource_group` | `[rg-iic-azl-01]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_access.rbac_administrator` | Role Based Access Control Administrator on those resource groups, which the Azure Local deployment and ZTP need. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_access.rbac_delegable_role_ids` | Limit the roles the runners may assign to these role definition GUIDs. | list of GUID | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_access.arc_run_command` | Azure Connected Machine Resource Administrator on those resource groups, so jobs can run Arc Run Command on the machines. | boolean | no / no | `true` | `true` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner_access.key_vaults` | Vaults the runners read secrets from. | list of Key Vault name | no / no | `every vault in key_vaults` | `[kv-iic-mgmt-01]` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.name` |  | string | if section is set / if section is set |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.type` |  | one of `vm`, `container_app`, `existing` | if section is set / if section is set |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.subscription` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.resource_group` |  | resource group name | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.network` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.subnet` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.private_ip` |  | IPv4 address | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.size` |  | string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.labels` | Runner tags or labels that jobs select. | list of string | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.runner.registration_token` (secret) | Key Vault reference for the registration_token of devops.runner. | keyvault:// reference | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.state` |  | object | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.state.subscription_id` | Subscription of the state storage account. (since 5.5) | GUID | no / no |  |  | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.state.key` | Blob name of the CI/CD runners state. (since 5.5) | string | no / no | `cicd-infra.tfstate` | `cicd-infra.tfstate` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.state.storage_account` |  | storage account name | no / no |  | `stiictfstate01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.state.container` |  | string | no / no |  | `tfstate` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |
| `devops.state.resource_group` |  | resource group name | no / no |  | `rg-iic-mgmt-01` | Your Azure foundation design (parts 1 and 2 of the implementation steps). | CI/CD infrastructure, Trailwright |

### extensions

Anything this schema doesn't define: settings for one environment or one tool, each under its own key (for example extensions.devops_runner).

| Path | What it is | Type | Required: full / ztp | Default | Example | Where to get the value | Read by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `extensions` | Anything this schema doesn't define: settings for one environment or one tool, each under its own key (for example extensions.devops_runner). | object | no / no |  |  | Anything the schema doesn't define; tools ignore keys they don't own. | Trailwright |

# Variable Reference

This is the complete variable catalog for the Azure Local Toolkit. Variables are organized into the 13-section hierarchy defined by master-registry v4.0.0.

!!! tip "Getting started"
    ```powershell
    cp config/variables.example.yml config/variables.yml
    ```
    **Never commit** `variables.yml` — it is excluded by `.gitignore`.

!!! info "Two config files"
    - `config/infrastructure.yml` — comprehensive 13-section template with full documentation
    - `config/variables.example.yml` — simplified extract with IIC example values for quick deployment

---

## Site

```yaml
site:
  code: "DEMO"
  name: "Azure Local Cloud Demos"
  location: "Portable Conference Deployment"
  environment: "Demo"
  owner: "admin@example.com"
```

| Variable | Type | Required | Description | Default |
|----------|------|:--------:|-------------|---------|
| `site.code` | string | **Yes** | Short site code (2–10 chars, alpha only) | — |
| `site.name` | string | **Yes** | Descriptive site name | — |
| `site.location` | string | No | Physical location | — |
| `site.environment` | string | No | Environment type | — |
| `site.owner` | string | No | Contact email | — |
| `site.hardware.hw_vendor` | string | No | Hardware vendor (`Dell`, `HPE`, `Lenovo`, `DataON`) | — |
| `site.hardware.hw_model` | string | No | Server model | — |
| `site.hardware.hw_generation` | string | No | Hardware generation | — |
| `site.hardware.gpu_enabled` | boolean | No | GPU acceleration enabled | `false` |
| `site.hardware.gpu_model` | string | No | GPU model (e.g., `NVIDIA L4`) | — |

---

## Environment

```yaml
environment:
  env_name: "ProjectIIC"
  env_type: "lab"
  env_owner: "admin@example.com"
```

| Variable | Type | Required | Description | Default |
|----------|------|:--------:|-------------|---------|
| `environment.env_name` | string | **Yes** | Environment identifier | — |
| `environment.env_type` | string | No | Classification: `management`, `lab`, `demo`, `poc`, `production` | — |
| `environment.env_owner` | string | No | Owner email address | — |

---

## Tags

```yaml
tags:
  Environment: "ProjectIIC"
  Project: "Azure Local Infrastructure"
  ManagedBy: "Infrastructure as Code"
```

| Variable | Type | Required | Description | Default |
|----------|------|:--------:|-------------|---------|
| `tags.Environment` | string | **Yes** | Environment tag | — |
| `tags.Project` | string | **Yes** | Project tag | — |
| `tags.ManagedBy` | string | **Yes** | Management method | `Infrastructure as Code` |
| `tags.Owner` | string | No | Owner tag | — |
| `tags.CostCenter` | string | No | Cost center tag | — |

---

## Azure Platform

```yaml
azure_platform:
  azure_tenants:
    aztenant_azurelocal_id: "00000000-0000-0000-0000-000000000000"
    aztenant_azurelocal_name: "Contoso"
    aztenant_azurelocal_domain: "contoso.onmicrosoft.com"
  subscriptions:
    sub_bootstrap_id: "11111111-1111-1111-1111-111111111111"
  region: "eastus"
  resource_group_name: "rg-c01-azl-eus-01"
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `azure_platform.azure_tenants.aztenant_azurelocal_id` | GUID | **Yes** | Azure AD/Entra ID tenant ID |
| `azure_platform.azure_tenants.aztenant_azurelocal_name` | string | No | Tenant display name |
| `azure_platform.azure_tenants.aztenant_azurelocal_domain` | string | No | `*.onmicrosoft.com` domain |
| `azure_platform.subscriptions.sub_bootstrap_id` | GUID | No | Bootstrap subscription ID |
| `azure_platform.region` | string | **Yes** | Azure region for deployment |
| `azure_platform.resource_group_name` | string | **Yes** | Primary resource group |
| `azure_platform.platform.kv_platform_name` | string | **Yes** | Platform Key Vault name |
| `azure_platform.platform.kv_platform_resource_group` | string | No | Key Vault resource group |
| `azure_platform.platform.kv_platform_enable_rbac` | boolean | No | Enable RBAC on Key Vault | 

---

## Identity

### Accounts

```yaml
identity:
  accounts:
    account_local_admin_username: "Administrator"
    account_local_admin_password: "keyvault://kv-platform/azlocal-admin-password"
    account_lcm_username: "lcm-deploy"
    account_lcm_password: "keyvault://kv-platform/lcm-deployment-password"
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `identity.accounts.account_local_admin_username` | string | **Yes** | Local admin username |
| `identity.accounts.account_local_admin_password` | string | **Yes** | Key Vault URI for local admin password |
| `identity.accounts.account_lcm_username` | string | **Yes** | LCM deployment account username |
| `identity.accounts.account_lcm_password` | string | **Yes** | Key Vault URI for LCM password |

### Active Directory

```yaml
identity:
  active_directory:
    domain:
      fqdn: "azrl.mgmt"
      netbios: "MGMT"
    ad_ou_path: "OU=MGMT,DC=azrl,DC=mgmt"
    ad_clusters_ou_path: "OU=clus01,OU=AzureLocal,OU=Clusters,..."
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `identity.active_directory.domain.fqdn` | string | **Yes** | AD domain FQDN |
| `identity.active_directory.domain.netbios` | string | **Yes** | NetBIOS domain name |
| `identity.active_directory.ad_ou_path` | string | **Yes** | Base OU path |
| `identity.active_directory.ad_computers_ou_path` | string | No | OU for computer objects |
| `identity.active_directory.ad_clusters_ou_path` | string | **Yes** | OU for cluster CNO and nodes |

### Service Principal

```yaml
identity:
  service_principal:
    name: "sp-azurelocal-deploy"
    client_id: "00000000-..."
    secret: "keyvault://kv-platform/sp-secret"
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `identity.service_principal.name` | string | No | Service principal display name |
| `identity.service_principal.client_id` | GUID | **Yes** | Application (client) ID |
| `identity.service_principal.object_id` | GUID | No | Object ID |
| `identity.service_principal.secret` | string | **Yes** | Key Vault URI for SP secret |

---

## Networking

### On-Premises VLANs

```yaml
networking:
  onprem:
    vlans:
      management:
        id: 2203
        cidr: "192.168.203.0/24"
        gateway: "192.168.203.1"
      workload:
        id: 2204
        cidr: "192.168.204.0/24"
        gateway: "192.168.204.1"
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `networking.onprem.vlans.<name>.id` | integer | **Yes** | VLAN ID |
| `networking.onprem.vlans.<name>.cidr` | string | **Yes** | Subnet CIDR |
| `networking.onprem.vlans.<name>.gateway` | string | **Yes** | Default gateway |
| `networking.onprem.vlans.<name>.dhcp.enabled` | boolean | No | DHCP enabled |
| `networking.onprem.vlans.<name>.dhcp.range` | string | No | DHCP range |
| `networking.onprem.storage.vlans[].id` | integer | **Yes** | Storage VLAN ID |
| `networking.onprem.storage.vlans[].name` | string | **Yes** | Storage VLAN name |

### Azure Virtual Networking

```yaml
networking:
  azure_vnet:
    vnet_name: "vnet-azrl-azl-eus-01"
    vnet_address_space: ["10.250.1.0/24"]
    subnet_name: "snet-azrl-azl-eus-01"
    subnet_address_prefix: "10.250.1.32/27"
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `networking.azure_vnet.vnet_name` | string | **Yes** | Azure VNet name |
| `networking.azure_vnet.vnet_address_space` | list | **Yes** | VNet address spaces |
| `networking.azure_vnet.subnet_name` | string | **Yes** | Subnet name |
| `networking.azure_vnet.subnet_address_prefix` | string | **Yes** | Subnet CIDR |

### VPN

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `networking.onprem.vpn.azure_gateway.name` | string | No | Azure VPN Gateway name |
| `networking.onprem.vpn.azure_gateway.sku` | string | No | Gateway SKU |
| `networking.onprem.vpn.azure_gateway.bgp.asn` | integer | No | BGP ASN |
| `networking.onprem.vpn.connection.shared_key` | string | No | Key Vault URI for VPN shared key |

### Network Intents

```yaml
networking:
  network_intents: []
  # Defines adapter-to-traffic-type mapping
  # Options: single-intent converged, two-intent standard, three-intent separated
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `networking.network_intents` | list | **Yes** | Adapter-to-traffic intent definitions |
| `networking.azure.sdn.sdn_enabled` | boolean | No | Enable SDN (irreversible) |

---

## Compute

```yaml
nodes:
  - name: "node-01"
    ipv4_address: "192.168.203.11"
    bmc_address: "10.245.64.11"
    serial_number: "ABC1234"
```

| Variable | Type | Required | Description |
|----------|------|:--------:|-------------|
| `nodes[].name` | string | **Yes** | Node hostname |
| `nodes[].ipv4_address` | string | **Yes** | Management IP |
| `nodes[].bmc_address` | string | **Yes** | BMC/iDRAC IP |
| `nodes[].serial_number` | string | No | Hardware serial number |

---

## Key Vault Secret Resolution

All secrets use the `keyvault://` URI format:

```yaml
password: "keyvault://kv-platform-prod/secret-name"
```

| Secret | Used By |
|--------|---------|
| `azlocal-admin-password` | Node local admin |
| `lcm-deployment-password` | LCM deployment account |
| `sp-azurelocal-deploy-secret` | Service principal |
| `vpn-shared-key` | Site-to-site VPN |
| `fortigate-admin` | FortiGate firewall management |
| `switch-admin` | Dell S4112F-ON switch management |
| `opengear-admin` | OpenGear console server |

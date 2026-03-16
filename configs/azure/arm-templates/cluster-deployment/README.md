# Azure Local Cluster Deployment ARM Templates

This directory contains Azure Local Cloud parameter files for Azure Local cluster deployment via ARM templates. Each file maps all **54 parameters** from Microsoft's official `azuredeploy.json` (apiVersion `2025-09-15-preview`).

## Template Files

| File | Purpose | Parameters |
|------|---------|------------|
| `azuredeploy.parameters.ad.json` | Active Directory authentication deployments | 54 (8 required + 46 optional) |
| `azuredeploy.parameters.local-identity.json` | Local Identity authentication deployments | 54 (8 required + 46 optional) |

## Microsoft Official Template

Use the official Microsoft Azure Local ARM template from the Azure Quickstart Templates repository:

**Template URL (for Azure CLI/PowerShell):**
```
https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json
```

**GitHub Repository:**
- [create-cluster](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster) — For Azure Local 2503+
- [create-cluster-2411.3](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster-2411.3) — For Azure Local 2411.3 and earlier

## Usage

### Option A: Config-Driven Generation (Recommended)

Use the generation script to populate all 54 parameters from `infrastructure.yml`:

```powershell
# AD auth
.\configs\Generate-AzureLocal-Parameters.ps1 -ConfigPath "configs/infrastructure.yml" -AuthType AD

# Local Identity auth
.\configs\Generate-AzureLocal-Parameters.ps1 -ConfigPath "configs/infrastructure.yml" -AuthType LocalIdentity
```

The script reads the YAML config, maps all values, and writes a deployment-ready JSON. See `configs/Generate-AzureLocal-Parameters.ps1` for full documentation.

### Option B: Manual Replacement

#### Step 1: Prepare Parameters File

1. Copy the appropriate parameters file for your authentication method
2. Replace all `{{VARIABLE}}` placeholders with values from your `infrastructure.yml`
3. Store secrets (passwords, service principal secrets) in Azure Key Vault
4. Update Key Vault references in the parameters file

### Step 2: Validate Deployment

```bash
# Azure CLI - Validation mode
az deployment group create \
  --resource-group "{{CLUSTER_RESOURCE_GROUP}}" \
  --template-uri "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json" \
  --parameters @azuredeploy.parameters.ad.json \
  --parameters deploymentMode=Validate
```

### Step 3: Deploy Cluster

```bash
# Azure CLI - Deploy mode
az deployment group create \
  --resource-group "{{CLUSTER_RESOURCE_GROUP}}" \
  --template-uri "https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/quickstarts/microsoft.azurestackhci/create-cluster/azuredeploy.json" \
  --parameters @azuredeploy.parameters.ad.json \
  --parameters deploymentMode=Deploy
```

## Authentication Methods

### Active Directory (`azuredeploy.parameters.ad.json`)

Use when:
- Enterprise environment with existing Active Directory
- Domain-joined cluster nodes required
- Group Policy management needed
- Kerberos authentication required

Key AD parameters:
- `domainFqdn`: AD domain FQDN (e.g., `ad.improbability.cloud`)
- `adouPath`: OU for cluster objects (e.g., `OU=AzureLocal,OU=Servers,DC=ad,DC=improbability,DC=cloud`)
- `AzureStackLCMAdminUsername`: Domain UPN (e.g., `svc-azlocal-lcm@ad.improbability.cloud`)

### Local Identity (`azuredeploy.parameters.local-identity.json`)

Use when:
- Edge deployments without AD connectivity
- Proof-of-concept/lab environments
- Simplified deployments requiring AD independence

Key differences:
- `domainFqdn` and `adouPath` are empty strings (`""`)
- `AzureStackLCMAdminUsername` is a local account name (no domain UPN)
- All authentication uses local accounts stored in Key Vault

## Parameter Generation

Instead of manually filling placeholders, use the generation script:

```powershell
.\configs\Generate-AzureLocal-Parameters.ps1 -ConfigPath "configs/infrastructure.yml" -AuthType AD
```

See `configs/Generate-AzureLocal-Parameters.ps1` for full documentation.

## Validated Examples

See `../examples/` for complete parameter files with real IIC values across all three networking patterns.

## References

- [Microsoft Learn - Deploy via ARM Template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deploy-via-arm)
- [Microsoft Learn - Local Identity with Key Vault](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-local-identity-with-key-vault)
- [Azure Quickstart Templates](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci)

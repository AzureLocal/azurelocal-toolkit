# Azure ARM Templates

This directory contains ARM template parameter files and validated examples for Azure Local cluster deployments. The parameter file of a deployment is generated from `infrastructure.yml` by `Invoke-AzureLocalArmDeployment.ps1`.

## Directory Structure

```
arm-templates/
├── README.md                                # This file
├── cluster-deployment/                      # Azure Local cluster deployment templates
│   ├── README.md
│   ├── azuredeploy.parameters.ad.json       # AD auth — 54 parameters ({{VARIABLE}} placeholders)
│   └── azuredeploy.parameters.local-identity.json  # LCI auth — 54 parameters
├── examples/                                # Validated IIC examples by networking pattern
│   ├── README.md
│   ├── single-intent-converged/             # 1-intent converged (IIC)
│   ├── two-intent-standard/                 # 2-intent standard (IIC)
│   └── three-intent-separated/              # 3-intent separated (IIC)
└── (future)
    ├── arc-gateway/                         # Arc Gateway ARM templates
    ├── key-vault/                           # Key Vault ARM templates
    └── storage-account/                     # Storage Account ARM templates
```

## Template Categories

| Directory | Purpose | Status |
|-----------|---------|--------|
| `cluster-deployment/` | Azure Local cluster creation via ARM (54 params per auth method) | ✅ Available |
| `examples/` | Validated IIC examples across 3 networking patterns + env templates | ✅ Available |
| `arc-gateway/` | Arc Gateway for proxy scenarios | 🔜 Planned |
| `key-vault/` | Key Vault for cluster secrets | 🔜 Planned |
| `storage-account/` | Cloud witness storage | 🔜 Planned |

## Quick Start

### Option 1: Automated Generation (Recommended)

`Invoke-AzureLocalArmDeployment.ps1` generates the parameters from `infrastructure.yml` (Active Directory or local identity, as `scenario.identity` says) and checks them against the template. Mode Plan with `-Offline` changes nothing and does not touch Azure:

```powershell
./scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1 `
    -InfrastructureFile ./infrastructure.yml -Mode Plan -Offline -ReportDirectory ./arm-plan
```

The report directory then holds `<cluster>.parameters.json` (secrets are null in it) and `parameter-sources.md` (which key fed which ARM parameter). Modes Validate and Deploy submit the deployment; see the script's help.

### Option 2: Manual Placeholder Replacement

1. Navigate to `cluster-deployment/`
2. Copy the appropriate parameters file:
   - `azuredeploy.parameters.ad.json` — Active Directory authentication
   - `azuredeploy.parameters.local-identity.json` — Local Identity authentication
3. Replace all `{{VARIABLE}}` placeholders with values from `infrastructure.yml`
4. Deploy using Azure CLI or PowerShell

See [cluster-deployment/README.md](cluster-deployment/README.md) for detailed instructions.

## Microsoft Official Template

We use Microsoft's official ARM template (`azuredeploy.json`, apiVersion `2025-09-15-preview`) and provide Azure Local Cloud-customized parameter files:

| Resource | Template Source |
|----------|-----------------|
| Azure Local Cluster | [Azure Quickstart — create-cluster](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster) |

## Adding New Template Categories

When adding ARM templates for new resource types:

1. Create a subdirectory with descriptive name (e.g., `arc-gateway/`)
2. Add a `README.md` with:
   - Purpose and use cases
   - Microsoft template reference (if applicable)
   - Parameter descriptions
   - Deployment instructions
3. Add parameter template files with `{{VARIABLE}}` placeholders
4. Update this README's directory structure and table

## References

- [ARM Template Best Practices](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices)
- [Azure Quickstart Templates](https://github.com/Azure/azure-quickstart-templates)
- [Azure Local Documentation](https://learn.microsoft.com/en-us/azure/azure-local/)
- [Deploy via ARM Template](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deploy-via-arm)

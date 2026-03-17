# iDRAC Management Utilities

> **DOCUMENT CATEGORY**: Reference
> **SCOPE**: Dell iDRAC management automation via Redfish API
> **PURPOSE**: Scripts for configuring and managing Dell iDRAC hardware

[![Reference-Guide](https://img.shields.io/badge/Reference-Guide-purple?logo=book)](https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/)
[![Azure Local Cloud](https://img.shields.io/badge/Azure Local Cloud-AzureLocalCloud-orange)](https://Azure Local Cloud.com)
[![PowerShell](https://img.shields.io/badge/PowerShell-Utilities-blue?logo=powershell)](https://docs.microsoft.com/en-us/powershell/)

## Overview

This directory contains PowerShell scripts for managing Dell iDRAC (Integrated Dell Remote Access Controller) hardware using the Redfish API. These utilities automate common iDRAC configuration tasks for Azure Local infrastructure.

Scripts in this directory dot-source shared helpers from `scripts/common/utilities/helpers/` for logging, config loading, and Key Vault credential resolution.

## Scripts

### Enable-IdracVnc.ps1

Enables and configures VNC access on Dell iDRAC via Redfish API.

**Supports two modes of operation:**

| Mode | Description | Key Parameter |
|------|-------------|---------------|
| **Config-driven** (recommended) | Reads IPs, credentials, and VNC settings from `infrastructure.yml`. Iterates all nodes or a `-TargetNode` subset. | `-ConfigPath` |
| **Standalone** | Targets a single iDRAC IP with explicit parameters. | `-IdracIP` |

**Features:**

- Config-driven multi-node operation from `infrastructure.yml`
- Key Vault credential resolution (`keyvault://` URIs) with az CLI fallback
- PSCredential support (no plaintext passwords)
- YAML-overridable VNC settings (port, timeout, password, enable/disable)
- `Write-Log` structured logging with automatic file output
- `-WhatIf` dry-run support
- `-TargetNode` filtering for specific nodes
- Certificate validation bypass for self-signed iDRAC certs

**Usage — Config-driven mode:**

```powershell
# Enable VNC on all nodes using infrastructure.yml settings
.\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -IgnoreCertificateErrors

# Target a single node
.\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -TargetNode "node-01"

# Dry run — show what would change without applying
.\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -WhatIf

# Override VNC port from config default
.\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -VNCPort 5902

# Provide credentials explicitly (skips Key Vault resolution)
$cred = Get-Credential -UserName "idrac_admin"
.\Enable-IdracVnc.ps1 -ConfigPath "config/infrastructure.yml" -Credential $cred
```

**Usage — Standalone mode:**

```powershell
# Single iDRAC with interactive credential prompt
.\Enable-IdracVnc.ps1 -IdracIP "10.0.0.11" -IgnoreCertificateErrors

# Single iDRAC with explicit credential
$cred = Get-Credential -UserName "root"
.\Enable-IdracVnc.ps1 -IdracIP "10.0.0.11" -Credential $cred -VNCPort 5902

# Disable VNC on a single iDRAC
.\Enable-IdracVnc.ps1 -IdracIP "10.0.0.11" -Credential $cred -EnableVNC "Disabled"
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `ConfigPath` | string | No | — | Path to `infrastructure.yml`. Enables config-driven mode. |
| `Credential` | PSCredential | No | — | iDRAC credentials. Overrides Key Vault resolution. |
| `TargetNode` | string[] | No | all nodes | Node hostnames to target (config mode only). |
| `LogPath` | string | No | auto | Override log file path. Default: `./logs/idrac-management/<date>_EnableVnc.log` |
| `IdracIP` | string | No | — | Single iDRAC IP (standalone mode). |
| `Username` | string | No | `root` | iDRAC username (standalone mode only). |
| `VNCPort` | int | No | `5901` | VNC TCP port. Overrides YAML `vnc.port` if specified. |
| `EnableVNC` | string | No | `Enabled` | `Enabled` or `Disabled`. Overrides YAML `vnc.enabled`. |
| `VNCTimeout` | int | No | `1800` | VNC timeout in seconds (60–10800). Overrides YAML `vnc.timeout_seconds`. |
| `VNCPassword` | string | No | — | VNC auth password (4–8 chars). Resolved from Key Vault in config mode. |
| `IgnoreCertificateErrors` | switch | No | — | Skip SSL cert validation (self-signed iDRAC certs). |

**infrastructure.yml paths used:**

```yaml
security.infrastructure_credentials.idrac.username           # iDRAC admin username
security.infrastructure_credentials.idrac.password_secret     # keyvault:// URI for iDRAC password
security.infrastructure_credentials.idrac.vnc.enabled         # VNC enable flag
security.infrastructure_credentials.idrac.vnc.port            # VNC port
security.infrastructure_credentials.idrac.vnc.timeout_seconds # VNC session timeout
security.infrastructure_credentials.idrac.vnc.password_secret # keyvault:// URI for VNC password
compute.nodes.<key>.idrac_ip                                  # Per-node iDRAC IP
compute.nodes.<key>.hostname                                  # Node hostname (display)
```

**Credential resolution order:**

1. `-Credential` parameter (explicit PSCredential)
2. Key Vault lookup via `keyvault://` URI from config (Az.KeyVault → az CLI fallback)
3. Interactive `Get-Credential` prompt

## Prerequisites

- PowerShell 5.1 or later
- Dell iDRAC 9 or later
- Network connectivity to iDRAC interface
- `powershell-yaml` module (auto-installed in config mode)
- `Az.KeyVault` module or `az` CLI (for Key Vault credential resolution)
- Shared helpers: `logging.ps1`, `config-loader.ps1`, `keyvault-helper.ps1`

## Security Considerations

### Credentials

- **Never pass plaintext passwords** — use `-Credential` (PSCredential) or Key Vault resolution
- The deprecated `-Password` string parameter has been removed; use `-Credential` instead
- iDRAC passwords are stored as `keyvault://` URIs in `infrastructure.yml`
- Credential resolution follows the standard three-step order (parameter → Key Vault → interactive)

### Certificate Validation

- Use `-IgnoreCertificateErrors` only for trusted internal networks with self-signed iDRAC certs
- Production environments should use proper CA-signed certificates
- Supports both PowerShell 5.1 (ServicePointManager) and 7+ (SkipCertificateCheck)

### VNC Security

- VNC is enabled with iDRAC authentication by default
- VNC passwords should be stored in Key Vault (resolved from `vnc.password_secret`)
- Consider firewall rules to restrict VNC access to management networks
- Use strong iDRAC passwords

## Integration Points

- **Azure Local Provisioning**: Used during initial hardware setup to enable remote console access
- **Infrastructure Configuration**: Called from deployment orchestration scripts
- **Config-driven Operation**: Reads from the same `infrastructure.yml` used by all deployment scripts

## Redfish API Reference

- [Dell iDRAC 9 Redfish API Guide](https://www.dell.com/support/manuals/en-us/idrac9-lifecycle-controller-v3.x-series/idrac_3.30.30.30_redfishapiguide/)
- [DMTF Redfish Standard](https://www.dmtf.org/standards/redfish)

## Troubleshooting

### Connection Errors

- Verify iDRAC IP address and network connectivity (`Test-Connection -ComputerName <ip>`)
- Check firewall rules allowing HTTPS (443) to iDRAC management network
- Ensure iDRAC web interface is enabled

### Authentication Errors

- Verify credentials via iDRAC web UI first
- Check Key Vault secret is current (`az keyvault secret show --vault-name <vault> --name <secret>`)
- Ensure the iDRAC account is not locked
- Use `-Credential (Get-Credential)` to test with interactive credentials

### Certificate Errors

- Use `-IgnoreCertificateErrors` for self-signed iDRAC certificates
- Check: `Invoke-WebRequest -Uri "https://<idrac-ip>" -SkipCertificateCheck` (PS 7+)

### Configuration Not Applied

- Some settings require iDRAC reset to take effect
- Check `@Message.ExtendedInfo` in log output for required actions
- Allow 30–60 seconds for iDRAC to process changes

## Logging

Logs are written to `./logs/idrac-management/` (CWD-relative, run from repo root):

```
logs/idrac-management/2026-03-28_143022_EnableVnc.log
```

Override with `-LogPath` to write to a custom location.

## Future Enhancements

Planned additions to this utility module:

- Power management scripts (power on/off, reset)
- BIOS configuration management
- Firmware update automation
- Log collection and diagnostics
- Health monitoring and alerting

---

**Version Control**

- Created: 2026-01-20 by Azure Local Cloudnology Team
- Last Edited: 2026-03-28 by Azure Local Cloudnology Team
- Version: 2.0.0
- Tags: powershell, idrac, redfish, hardware, vnc, config-driven
- Keywords: dell, idrac, redfish, hardware, automation, vnc, keyvault

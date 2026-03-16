# Configure Static IP Address

This task configures static IP addresses on Azure Local cluster nodes by converting their current DHCP configuration to static IP with the same settings.

## Scripts Overview

### 1. Configure-StaticIP-Standalone.ps1
**Purpose**: Run directly on individual Azure Local nodes
**Use Case**: Manual execution on each node, or when configuration helpers are not available
**Features**:
- Auto-detects management NIC or accepts manual specification
- Converts current DHCP config to static IP
- Enhanced validation with retry logic
- Comprehensive error handling and logging

### 2. Configure-StaticIP-NodeLocal.ps1
**Purpose**: Run on nodes with access to configuration helpers
**Use Case**: Automated deployment where infrastructure.yml is available
**Features**:
- Loads configuration from infrastructure.yml using helpers
- Uses registry variables for NIC names and settings
- Same validation and retry logic as standalone
- Integrates with toolkit helper modules

### 3. Invoke-ConfigureStaticIP-Orchestrated.ps1
**Purpose**: Run from jump server to configure multiple nodes
**Use Case**: Centralized management of cluster IP configuration
**Features**:
- PowerShell remoting to target nodes
- Sequential processing for reliability
- Batch configuration across multiple nodes
- Comprehensive reporting and error aggregation

## Prerequisites

### For All Scripts
- PowerShell 5.1 or higher
- Administrative privileges on target nodes
- Network connectivity to target nodes (for orchestrated script)

### For Node-Local and Orchestrated Scripts
- Access to infrastructure.yml configuration file
- Toolkit helper modules (config-loader.ps1, registry-variable.ps1, etc.)
- powershell-yaml module (`Install-Module powershell-yaml -Scope CurrentUser`)

## Usage Examples

### Standalone Script
```powershell
# Auto-detect NIC and configure
.\Configure-StaticIP-Standalone.ps1

# Specify NIC name
.\Configure-StaticIP-Standalone.ps1 -ManagementNIC "Embedded NIC 1"

# With custom retry settings
.\Configure-StaticIP-Standalone.ps1 -RetryCount 5 -RetryDelay 10
```

### Node-Local Script
```powershell
# Uses infrastructure.yml from default location
.\Configure-StaticIP-NodeLocal.ps1

# Specify custom config path
.\Configure-StaticIP-NodeLocal.ps1 -ConfigPath "C:\configs\my-cluster.yml"
```

### Orchestrated Script
```powershell
# Configure all nodes in cluster
.\Invoke-ConfigureStaticIP-Orchestrated.ps1

# Configure specific nodes
.\Invoke-ConfigureStaticIP-Orchestrated.ps1 -NodeNames "AZL-01", "AZL-02"

# Use specific credentials
$cred = Get-Credential
.\Invoke-ConfigureStaticIP-Orchestrated.ps1 -Credential $cred
```

## Validation and Reliability

All scripts include comprehensive validation:

1. **IP Address Verification**: Confirms static IP matches expected value
2. **Gateway Validation**: Ensures default route is correctly configured
3. **DNS Configuration**: Verifies DNS servers are properly set
4. **DHCP Disabled**: Confirms DHCP is disabled on the interface
5. **Connectivity Testing**: Pings gateway to verify network connectivity
6. **Retry Logic**: Automatically retries failed configurations up to 3 times
7. **Stabilization Wait**: Waits for IP configuration to take effect before validation

## Troubleshooting

### Common Issues

**"No suitable network adapter found"**
- Verify the management NIC name in infrastructure.yml
- Check that the adapter is in "Up" status: `Get-NetAdapter`
- Use auto-detection if NIC name is unknown

**"IP configuration did not stabilize"**
- Wait longer for DHCP lease to be applied
- Check network connectivity to DHCP server
- Verify adapter is properly connected

**"Validation failed: IP address mismatch"**
- Ensure DHCP is providing the expected IP range
- Check for IP address conflicts on the network
- Verify adapter configuration after manual intervention

**"Cannot ping gateway"**
- Check physical network connectivity
- Verify gateway IP address is correct
- Ensure firewall rules allow ICMP traffic

### Orchestrated Script Issues

**"Cannot connect to node"**
- Verify WinRM is enabled on target nodes
- Check firewall rules for PowerShell remoting (TCP 5985/5986)
- Ensure credentials are correct and account has admin rights

**"Remote execution failed"**
- Check TrustedHosts configuration on jump server
- Verify network connectivity between jump server and nodes
- Ensure PowerShell remoting is properly configured

## Configuration File Structure

The scripts expect infrastructure.yml with the following structure:

```yaml
azure_local:
  cluster:
    management_nic_name: "Embedded NIC 1"  # Or "Slot 3 Port 1", etc.
    nodes:
      - name: "AZL-01"
        management_ip: "192.168.1.11"
      - name: "AZL-02"
        management_ip: "192.168.1.12"
```

## Security Considerations

- Scripts require administrative privileges
- Credentials are prompted securely (not stored in scripts)
- No sensitive information is logged
- Remote execution uses encrypted PowerShell remoting
- Configuration files should be protected appropriately

## Integration with Deployment Pipeline

These scripts are designed to integrate with the overall Azure Local deployment process:

1. **Phase 02**: OS Installation - Nodes boot with DHCP
2. **Phase 03**: OS Configuration - Convert to static IP (this task)
3. **Phase 04**: Arc Registration - Nodes have stable static IPs

The orchestrated script is particularly useful in CI/CD pipelines for automated cluster deployment.
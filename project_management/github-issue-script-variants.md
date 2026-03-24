# Create Azure CLI and Bash Script Variants for All Deployment Tasks

## Summary

Each task folder under `scripts/deploy/` currently contains a `powershell/` directory with the primary automation scripts. The `azurecli/` and `bash/` directories have been scaffolded with `.gitkeep` placeholders and need equivalent script implementations.

**Scope:**
- Create Azure CLI equivalents in each task's `azurecli/` directory
- Create Bash equivalents in each task's `bash/` directory
- Scripts should mirror the functionality of the corresponding PowerShell primary scripts
- Follow the same naming conventions (e.g., `deploy-resource-groups.sh` for `Deploy-ResourceGroups.ps1`)

**Total task folders:** 96

---

## Task Checklist

### Stage 02 — Azure Foundation

#### phase-01-landing-zones

##### full-deployment

- [ ] **task-03-create-resource-groups** — PS: `Deploy-ResourceGroups.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

##### simplified-deployment

- [ ] **task-03-create-resource-groups** — PS: `Deploy-ResourceGroups.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-02-resource-providers

- [ ] **task-01-register-resource-providers** — PS: `Register-ResourceProviders.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-verify-provider-registration** — PS: `Test-ResourceProviders.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-03-rbac-permissions

- [ ] **task-01-create-azure-local-deployment-spn** — PS: `New-DeploymentServicePrincipal.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-assign-rbac-roles** — PS: `Set-RbacRoleAssignments.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-04-azure-management-infrastructure

- [ ] **task-01-virtual-network** — PS: `Configure-VnetDns.ps1`, `Deploy-ManagementVnet.ps1`, `Deploy-Network.ps1`, `Deploy-VnetPeering.ps1`, `New-VirtualNetwork.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-vpn-gateway** — PS: `New-VpnGateway.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-s2s-vpn-connection** — PS: `New-VpnConnection.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-azure-bastion** — PS: `New-AzureBastion.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-06-network-security-groups** — PS: `Deploy-LighthouseNsg.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-07-nat-gateway** — PS: `New-NatGateway.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-08-arc-gateway** — PS: `New-ArcGateway.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-09-log-analytics** — PS: `Deploy-DiagnosticSettings.ps1`, `New-LogAnalyticsWorkspace.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-10-key-vault** — PS: `New-KeyVault.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-12-configure-adds** — PS: `New-DomainController.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-13-configure-utility-server** — PS: `Deploy-JumpServer.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-14-configure-ndm-server** — PS: `New-NdmServer.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-15-configure-lighthouse** — PS: `Deploy-Lighthouse.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-05-identity-security

- [ ] **task-01-pim-conditional-access** — PS: `Deploy-DefenderForCloud.ps1`, `Deploy-KeyVault.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

---

### Stage 03 — On-Prem Readiness

#### phase-01-active-directory

- [ ] **task-01-ou-creation-pre-creation-artifacts** — PS: `Invoke-ADValidation-Arc.ps1`, `Invoke-ADValidation-AzVM.ps1`, `Set-ADConfiguration.ps1`, `Test-ADConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-create-ad-security-groups** — PS: `New-ADSecurityGroups.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-configure-dns-forwarding** — PS: `Set-DnsForwarding.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-create-ad-accounts** — PS: `New-ADAccounts.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-assign-security-group-memberships** — PS: `Set-ADGroupMemberships.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-02-enterprise-readiness

- [ ] **task-01-hardware-inspection** — PS: `Test-HardwareInspection.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-network-service-verification** — PS: `Set-InfrastructurePrep.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-opengear-verification** — PS: `Test-OpengearVerification.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-validation-signoff** — PS: `Complete-ValidationSignoff.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-03-network-infrastructure

- [ ] **task-01-opengear-console-server** — PS: `Set-OpengearEndpoint.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-dell-powerswitch-configuration** — PS: `Set-PowerSwitchEndpoint.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-firewall-endpoint-verification** — PS: `Set-FirewallEndpoint.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-network-validation** — PS: `Test-NetworkReadiness.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

---

### Stage 04 — Cluster Deployment

#### phase-01-hardware-provisioning

- [ ] **task-01-create-dhcp-reservations-for-idrac-interfaces** — PS: `New-DhcpReservationsIdrac.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-hardware-discovery-via-dell-redfish-api** — PS: `Get-HardwareDiscovery-Standalone.ps1`, `Invoke-HardwareDiscovery.ps1`, `Update-InfrastructureYml-FromDiscovery.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-create-dhcp-reservations-for-management-nics** — PS: `New-DhcpReservationsMgmt.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-bios-and-idrac-settings-validation** — PS: `Test-BiosIdracSettings.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-bios-and-idrac-settings-remediation** — PS: `Set-BiosIdracSettings.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-02-os-installation

- [ ] **task-04-verify-os-deployment** — PS: `Test-OsDeployment.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-03-os-configuration

- [ ] **task-01-enable-winrm-for-remote-management** — PS: `Enable-WinRmConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-enable-rdp** — PS: `Enable-RDP.ps1`, `Invoke-EnableRdp-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-configure-static-ip-address** — PS: `Invoke-ConfigureStaticIP-Orchestrated.ps1`, `Set-StaticIPAddress.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-disable-dhcp-on-management-adapter** — PS: `Disable-DHCPOnAllAdapters.ps1`, `Invoke-DisableDHCP-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-configure-dns-servers** — PS: `Invoke-ConfigureDNS-Orchestrated.ps1`, `Set-DnsServers.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-06-verify-dns-client-configuration** — PS: `Invoke-VerifyDNS-Orchestrated.ps1`, `Test-DnsClientConfig.ps1`, `Test-DnsConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-07-configure-time-synchronization-ntp** — PS: `Invoke-ConfigureNTP-Orchestrated.ps1`, `Set-NTPConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-08-enable-icmp-ping** — PS: `Enable-ICMPFirewallRule.ps1`, `Invoke-EnableICMP-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-09-disable-unused-network-adapters** — PS: `Disable-UnusedAdapters.ps1`, `Invoke-DisableAdapters-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-10-configure-hostname** — PS: `Invoke-ConfigureHostname-Orchestrated.ps1`, `Set-NodeHostname.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-11-clear-previous-storage-configuration-conditional** — PS: `Clear-StorageConfiguration-Direct.ps1`, `Clear-StorageConfiguration.ps1`, `Invoke-ClearStorage-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-12-complete-combined-script-all-steps** — PS: `Invoke-Phase03OsConfiguration-Orchestrated.ps1`, `Start-Phase03OsConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-13-phase03-verification** — PS: `Invoke-Phase03Verification-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-04-arc-registration

- [ ] **task-01-pre-registration-validation** — PS: `Invoke-ArcPrerequisites-Orchestrated.ps1`, `Test-ArcPrerequisites-Orchestrated.ps1`, `Test-ArcPrerequisites.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-register-cluster-nodes-with-azure-arc** — PS: `Invoke-ArcRegistration-Orchestrated.ps1`, `Register-AzureLocalArc-Interactive.ps1`, `Register-AzureLocalArc-Remote.ps1`, `Register-AzureLocalArc-ServicePrincipal.ps1`, `Register-NodesWithArc.ps1`, `Start-ArcRegistrationWithMonitor.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-monitor-bootstrap-process** — PS: `Invoke-BootstrapMonitor-Orchestrated.ps1`, `Watch-BootstrapProgress-Orchestrated.ps1`, `Watch-BootstrapProgress.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-verify-arc-registration-and-connectivity** — PS: `Confirm-ArcRegistration-Orchestrated.ps1`, `Confirm-ArcRegistration.ps1`, `Invoke-ArcVerification-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-05-cluster-deployment

##### active-directory

- [ ] **task-01-initiate-deployment-via-arm-template** — PS: `Deploy-AzureLocalCluster-Standalone.ps1`, `Deploy-AzureLocalCluster.ps1`, `Get-HciResourceProviderObjectId-Standalone.ps1`, `Get-HciResourceProviderObjectId.ps1`, `Invoke-VerifyADPrerequisites-Orchestrated.ps1`, `Test-ADPrerequisites-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-verify-deployment-completion** — PS: `Invoke-VerifyADDomainStatus-Orchestrated.ps1`, `Invoke-VerifyClusterHealth-Orchestrated.ps1`, `Test-ADDomainStatus-Standalone.ps1`, `Test-ADDomainStatus.ps1`, `Test-ClusterHealth-Standalone.ps1`, `Test-ClusterHealth.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

##### local-identity

- [ ] **task-01-initiate-deployment-via-arm-template** — PS: `Deploy-AzureLocalCluster-Standalone.ps1`, `Deploy-AzureLocalCluster.ps1`, `Get-HciResourceProviderObjectId-Standalone.ps1`, `Get-HciResourceProviderObjectId.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-01-initiate-deployment-via-azure-portal** — PS: `Deploy-CreateLocalAdmin.ps1`, `Invoke-CreateLocalIdentityAccounts-Orchestrated.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-verify-deployment-completion** — PS: `Invoke-VerifyClusterHealth-Orchestrated.ps1`, `Invoke-VerifyLocalIdentityConfig-Orchestrated.ps1`, `Test-ClusterHealth-Standalone.ps1`, `Test-ClusterHealth.ps1`, `Test-LocalIdentityConfig-Standalone.ps1`, `Test-LocalIdentityConfig.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

##### monitoring

> *No task folders — phase-level monitoring scripts: `Monitor-Deployment.ps1`, `Monitor-Validation.ps1`*

- [ ] Azure CLI variant(s)
- [ ] Bash variant(s)

#### phase-06-post-deployment

- [ ] **task-01-configure-windows-admin-center** — PS: `Complete-WAC-Setup.ps1`, `Configure-WACEntraID.ps1`, `Configure-WACKerberosDelegation.ps1`, `Deploy-WindowsAdminCenter.ps1`, `Generate-WACCertificate.ps1`, `Install-WAC-Simple.ps1`, `Install-WACExtensions.ps1`, `Install-WindowsAdminCenter.ps1`, `Remote-Deploy-WAC.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-01-deploy-sdn** — PS: `Enable-SDN-Standalone.ps1`, `Get-VirtualSwitchName-Standalone.ps1`, `Get-VirtualSwitchName.ps1`, `Invoke-ConfigureSDNDns-Orchestrated.ps1`, `Invoke-DeploySDN-Orchestrated.ps1`, `Set-SDNDns-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-cluster-quorum-configuration** — PS: `Invoke-ConfigureClusterQuorum-Orchestrated.ps1`, `Invoke-ConfigureClusterQuorum-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-security-groups-applied-to-nodes** — PS: `Invoke-ApplySecurityGroups-Orchestrated.ps1`, `Invoke-ApplySecurityGroups-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-ssh-connectivity-to-nodes** — PS: `Enable-SshConfiguration.ps1`, `Invoke-SSHConnectivity-Orchestrated.ps1`, `Invoke-SSHConnectivity-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-storage-configuration** — PS: `Invoke-StorageCSV-Orchestrated.ps1`, `Invoke-StoragePaths-Orchestrated.ps1`, `New-StorageCSV-Standalone.ps1`, `New-StoragePaths-Standalone.ps1`, `Set-StorageConfiguration.ps1`, `Set-StorageVolumesConfig.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-06-image-downloads** — PS: `Get-ImageDownloads.ps1`, `Invoke-MarketplaceImages-Orchestrated.ps1`, `New-MarketplaceImages-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-07-logical-network-creation** — PS: `Invoke-LogicalNetworks-Orchestrated.ps1`, `New-LogicalNetworks-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-08-post-deployment-verification** — PS: `Invoke-VerifyPostDeployment.ps1`, `Test-PostDeployment-Standalone.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

---

### Stage 05 — Operational Foundations

#### phase-01-sdn-deployment

- [ ] **task-01-validate-sdn-prerequisites** — PS: `Test-SdnPrerequisites.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-enable-sdn-integration** — PS: `Set-SdnIntegration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-configure-network-security-groups** — PS: `Set-NsgConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-02-monitoring-observability

- [ ] **task-01-configure-log-analytics-workspace** — PS: `Deploy-MonitoringSecurity.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-configure-azure-monitor-agent** — PS: `Set-AzureMonitorIntegration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-enable-hci-insights** — PS: `Enable-HciInsights.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-setup-alerting** — PS: `Watch-AzureLocalDeployment.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-deploy-omimswac-monitoring** — PS: `Set-OmimswacConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-06-configure-network-device-logging** — PS: `Deploy-SyslogVm.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-07-configure-datadog-integration** — PS: `Set-DatadogConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-03-backup-dr

- [ ] **task-01-configure-azure-backup** — PS: `Set-BackupConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-configure-site-recovery** — PS: `Set-SiteRecoveryConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-test-dr-procedures** — PS: `Test-DisasterRecovery.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-04-security-governance

- [ ] **task-01-enable-defender-for-cloud** — PS: `Enable-DefenderForCloud.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-apply-azure-policy-initiatives** — PS: `Set-AzurePolicyConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-configure-security-baselines** — PS: `Set-SecurityBaselines.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-enable-security-logging** — PS: `Set-SecurityLogging.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-configure-azure-update-manager** — PS: `Set-UpdateManagerConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

#### phase-05-licensing-telemetry

- [ ] **task-01-enable-azure-hybrid-benefit** — PS: `Enable-AzureHybridBenefit.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-activate-windows-server-subscription** — PS: `Enable-WindowsServerSubscription.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-configure-enhanced-telemetry** — PS: `Set-TelemetryConfiguration.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

---

### Stage 06 — Cluster Testing & Validation

> *Stage 06 contains task folders directly (no phase subdirectories).*

- [ ] **task-01-infrastructure-health-validation** — PS: `Test-InfrastructureHealth.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-02-vmfleet-storage-testing** — PS: `Invoke-VmFleetStorageTest.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-03-network-rdma-validation** — PS: `Test-NetworkRdmaValidation.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-04-high-availability-testing** — PS: `Test-HighAvailability.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-05-security-compliance-validation** — PS: `Test-SecurityCompliance.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

- [ ] **task-06-backup-dr-validation** — PS: `Test-BackupDrValidation.ps1`
  - [ ] Azure CLI variant(s)
  - [ ] Bash variant(s)

---

## Acceptance Criteria

- [ ] Each task folder has functional Azure CLI scripts in `azurecli/`
- [ ] Each task folder has functional Bash scripts in `bash/`
- [ ] Scripts follow repository coding standards and patterns
- [ ] All scripts include proper help documentation / usage info
- [ ] Scripts read from `infrastructure.yml` configuration where applicable
- [ ] Scripts are tested against a reference environment

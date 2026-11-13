# Task catalogue of scripts/deploy: the ONE place that says which task folders exist and whether Azure CLI applies to them.
#
# Read by Generate-DeployScriptScaffolds.ps1 (decides whether to write an Azure CLI placeholder) and by
# New-DeployScriptStatus.ps1 (writes docs/script-status.md). A test fails when this list and the task folders disagree.
#
# AzureCli:
#   yes      the task creates, changes or reads Azure (resources, Entra, RBAC, policy, Arc, monitoring, the ARM deployment).
#            An Azure CLI script is expected; the generator may write a placeholder for it.
#   no       the task runs on a node, against on-premises Active Directory or DNS, against hardware or a BMC, or is
#            operating system work. There is no Azure CLI script and the generator writes none.
#   unclear  not decided. An existing Azure CLI placeholder is kept; the status table flags the task.
#
# Path is relative to scripts/deploy, with forward slashes. Order: ordinal sort of Path.
@{
    SchemaVersion = 1
    Tasks         = @(
        @{ Path = '01-cicd-infra/phase-01-cicd-setup/task-01-bootstrap'; AzureCli = 'yes'; Reason = 'Creates the CI/CD service principal and its Azure access.' }
        @{ Path = '01-cicd-infra/phase-01-cicd-setup/task-02-create-project'; AzureCli = 'yes'; Reason = 'A real Azure CLI script exists (it calls the PowerShell implementation), so it is kept. The task itself acts on the CI/CD platform.' }
        @{ Path = '01-cicd-infra/phase-01-cicd-setup/task-03-configure-project'; AzureCli = 'yes'; Reason = 'A real Azure CLI script exists (it calls the PowerShell implementation), so it is kept. The task itself acts on the CI/CD platform.' }
        @{ Path = '01-cicd-infra/phase-01-cicd-setup/task-04-create-environments'; AzureCli = 'yes'; Reason = 'A real Azure CLI script exists (it calls the PowerShell implementation), so it is kept. The task itself acts on the CI/CD platform.' }
        @{ Path = '01-cicd-infra/phase-01-cicd-setup/task-05-configure-variables'; AzureCli = 'yes'; Reason = 'A real Azure CLI script exists (it calls the PowerShell implementation), so it is kept. The task itself acts on the CI/CD platform.' }
        @{ Path = '01-cicd-infra/phase-01-cicd-setup/task-06-deploy-runners'; AzureCli = 'yes'; Reason = 'A real Azure CLI script exists (it calls the PowerShell implementation), so it is kept. The task itself acts on the CI/CD platform.' }
        @{ Path = '02-azure-foundation/phase-01-landing-zones/full-deployment/task-01-configure-management-groups'; AzureCli = 'yes'; Reason = 'Creates management groups, subscriptions or resource groups.' }
        @{ Path = '02-azure-foundation/phase-01-landing-zones/full-deployment/task-02-create-subscriptions'; AzureCli = 'yes'; Reason = 'Creates management groups, subscriptions or resource groups.' }
        @{ Path = '02-azure-foundation/phase-01-landing-zones/full-deployment/task-03-create-resource-groups'; AzureCli = 'yes'; Reason = 'Creates management groups, subscriptions or resource groups.' }
        @{ Path = '02-azure-foundation/phase-01-landing-zones/simplified-deployment/task-01-configure-management-group'; AzureCli = 'yes'; Reason = 'Creates management groups, subscriptions or resource groups.' }
        @{ Path = '02-azure-foundation/phase-01-landing-zones/simplified-deployment/task-02-create-subscription'; AzureCli = 'yes'; Reason = 'Creates management groups, subscriptions or resource groups.' }
        @{ Path = '02-azure-foundation/phase-01-landing-zones/simplified-deployment/task-03-create-resource-groups'; AzureCli = 'yes'; Reason = 'Creates management groups, subscriptions or resource groups.' }
        @{ Path = '02-azure-foundation/phase-02-resource-providers/task-01-register-resource-providers'; AzureCli = 'yes'; Reason = 'Registers or verifies resource providers on the subscription.' }
        @{ Path = '02-azure-foundation/phase-02-resource-providers/task-02-verify-provider-registration'; AzureCli = 'yes'; Reason = 'Registers or verifies resource providers on the subscription.' }
        @{ Path = '02-azure-foundation/phase-03-rbac-permissions'; AzureCli = 'yes'; Reason = 'Creates the deployment service principal or assigns RBAC roles.' }
        @{ Path = '02-azure-foundation/phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn'; AzureCli = 'yes'; Reason = 'Creates the deployment service principal or assigns RBAC roles.' }
        @{ Path = '02-azure-foundation/phase-03-rbac-permissions/task-02-assign-rbac-roles'; AzureCli = 'yes'; Reason = 'Creates the deployment service principal or assigns RBAC roles.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-01-configure-core-variables'; AzureCli = 'unclear'; Reason = 'Edits the deployment configuration; there is no real script yet that shows whether it touches Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-02-configure-management-mode'; AzureCli = 'unclear'; Reason = 'Edits the deployment configuration; there is no real script yet that shows whether it touches Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-03-configure-cluster-mode'; AzureCli = 'unclear'; Reason = 'Edits the deployment configuration; there is no real script yet that shows whether it touches Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-01-commit-and-push'; AzureCli = 'no'; Reason = 'Commits and pushes the Terraform configuration to Git; the real script uses no az command.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-02-monitor-validate-stage'; AzureCli = 'no'; Reason = 'Watches or approves a pipeline stage; it acts on the pipeline system, not on Azure resources.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-03-review-plan-stage'; AzureCli = 'no'; Reason = 'Watches or approves a pipeline stage; it acts on the pipeline system, not on Azure resources.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-04-approve-deployment'; AzureCli = 'no'; Reason = 'Watches or approves a pipeline stage; it acts on the pipeline system, not on Azure resources.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-05-monitor-apply-stage'; AzureCli = 'no'; Reason = 'Watches or approves a pipeline stage; it acts on the pipeline system, not on Azure resources.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-06-verify-test-stage'; AzureCli = 'no'; Reason = 'Watches or approves a pipeline stage; it acts on the pipeline system, not on Azure resources.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-01-verify-resources'; AzureCli = 'yes'; Reason = 'Checks the deployed VPN gateway and Key Vault secrets in Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-02-test-connectivity'; AzureCli = 'yes'; Reason = 'Checks the VPN and BGP state in Azure (the real Bash script calls az).' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-03-validate-configuration'; AzureCli = 'yes'; Reason = 'Checks Key Vault secrets, diagnostic settings and tags in Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-01-virtual-network'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-02-vpn-gateway'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-03-s2s-vpn-connection'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-04-p2s-vpn-connection'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-05-azure-bastion'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-06-network-security-groups'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-07-nat-gateway'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-08-arc-gateway'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-09-log-analytics'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-10-key-vault'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-11-deploy-management-vms'; AzureCli = 'yes'; Reason = 'Deploys an Azure resource.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/task-12-configure-adds'; AzureCli = 'yes'; Reason = 'Deploys a virtual machine in Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/task-13-configure-utility-server'; AzureCli = 'yes'; Reason = 'Deploys a virtual machine in Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/task-14-configure-ndm-server'; AzureCli = 'yes'; Reason = 'Deploys a virtual machine in Azure.' }
        @{ Path = '02-azure-foundation/phase-04-azure-management-infrastructure/task-15-configure-lighthouse'; AzureCli = 'yes'; Reason = 'Deploys a virtual machine in Azure.' }
        @{ Path = '03-onprem-readiness/phase-01-active-directory/task-01-ou-creation-pre-creation-artifacts'; AzureCli = 'no'; Reason = 'Acts on on-premises Active Directory or DNS.' }
        @{ Path = '03-onprem-readiness/phase-01-active-directory/task-02-security-groups'; AzureCli = 'no'; Reason = 'Acts on on-premises Active Directory or DNS.' }
        @{ Path = '03-onprem-readiness/phase-01-active-directory/task-03-dns-node-a-records'; AzureCli = 'no'; Reason = 'Acts on on-premises Active Directory or DNS.' }
        @{ Path = '03-onprem-readiness/phase-01-active-directory/task-04-service-admin-accounts'; AzureCli = 'no'; Reason = 'Acts on on-premises Active Directory or DNS.' }
        @{ Path = '03-onprem-readiness/phase-01-active-directory/task-05-group-assignments'; AzureCli = 'no'; Reason = 'Acts on on-premises Active Directory or DNS.' }
        @{ Path = '03-onprem-readiness/phase-02-enterprise-readiness/task-01-hardware-inspection'; AzureCli = 'no'; Reason = 'Inspects server hardware on premises.' }
        @{ Path = '03-onprem-readiness/phase-02-enterprise-readiness/task-02-network-service-verification'; AzureCli = 'no'; Reason = 'Checks network services on premises.' }
        @{ Path = '03-onprem-readiness/phase-02-enterprise-readiness/task-03-opengear-verification'; AzureCli = 'no'; Reason = 'Checks the console server on premises.' }
        @{ Path = '03-onprem-readiness/phase-02-enterprise-readiness/task-04-validation-signoff'; AzureCli = 'no'; Reason = 'Sign-off of the on-premises readiness checks.' }
        @{ Path = '03-onprem-readiness/phase-03-network-infrastructure/task-01-opengear-console-server'; AzureCli = 'no'; Reason = 'Acts on on-premises network devices, console server or firewall.' }
        @{ Path = '03-onprem-readiness/phase-03-network-infrastructure/task-02-dell-powerswitch-configuration'; AzureCli = 'no'; Reason = 'Acts on on-premises network devices, console server or firewall.' }
        @{ Path = '03-onprem-readiness/phase-03-network-infrastructure/task-03-firewall-endpoint-verification'; AzureCli = 'no'; Reason = 'Acts on on-premises network devices, console server or firewall.' }
        @{ Path = '03-onprem-readiness/phase-03-network-infrastructure/task-04-network-validation'; AzureCli = 'no'; Reason = 'Acts on on-premises network devices, console server or firewall.' }
        @{ Path = '04-cluster-deployment/phase-01-hardware-provisioning/task-01-create-dhcp-reservations-for-idrac-interfaces'; AzureCli = 'no'; Reason = 'Acts on the DHCP server or on the server BMC (Redfish).' }
        @{ Path = '04-cluster-deployment/phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api'; AzureCli = 'no'; Reason = 'Acts on the DHCP server or on the server BMC (Redfish).' }
        @{ Path = '04-cluster-deployment/phase-01-hardware-provisioning/task-03-create-dhcp-reservations-for-management-nics'; AzureCli = 'no'; Reason = 'Acts on the DHCP server or on the server BMC (Redfish).' }
        @{ Path = '04-cluster-deployment/phase-01-hardware-provisioning/task-04-bios-and-idrac-settings-validation'; AzureCli = 'no'; Reason = 'Acts on the DHCP server or on the server BMC (Redfish).' }
        @{ Path = '04-cluster-deployment/phase-01-hardware-provisioning/task-05-bios-and-idrac-settings-remediation'; AzureCli = 'no'; Reason = 'Acts on the DHCP server or on the server BMC (Redfish).' }
        @{ Path = '04-cluster-deployment/phase-02-os-installation/task-01-delete-and-recreate-virtual-disk-on-dell-boss-card'; AzureCli = 'no'; Reason = 'Acts on server hardware, the BMC or the installed operating system.' }
        @{ Path = '04-cluster-deployment/phase-02-os-installation/task-02-mount-and-verify-dell-gold-image-iso'; AzureCli = 'no'; Reason = 'Acts on server hardware, the BMC or the installed operating system.' }
        @{ Path = '04-cluster-deployment/phase-02-os-installation/task-03-manual-os-installation'; AzureCli = 'no'; Reason = 'Acts on server hardware, the BMC or the installed operating system.' }
        @{ Path = '04-cluster-deployment/phase-02-os-installation/task-04-verify-os-deployment'; AzureCli = 'no'; Reason = 'Acts on server hardware, the BMC or the installed operating system.' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-01-enable-winrm-for-remote-management'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-02-enable-rdp'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-03-configure-static-ip-address'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-05-configure-dns-servers'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-06-verify-dns-client-configuration'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-07-configure-time-synchronization-ntp'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-08-enable-icmp-ping'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-09-disable-unused-network-adapters'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-10-configure-hostname'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-11-clear-previous-storage-configuration-conditional'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-12-complete-combined-script-all-steps'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-03-os-configuration/task-13-phase03-verification'; AzureCli = 'no'; Reason = 'Runs on the nodes (operating system configuration).' }
        @{ Path = '04-cluster-deployment/phase-04-arc-registration/task-01-pre-registration-validation'; AzureCli = 'yes'; Reason = 'Checks the Azure side of Arc registration (resource providers, service principal, roles) as well as the node.' }
        @{ Path = '04-cluster-deployment/phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc'; AzureCli = 'yes'; Reason = 'Registers the nodes with Azure Arc; a real Azure CLI script exists.' }
        @{ Path = '04-cluster-deployment/phase-04-arc-registration/task-04-verify-arc-registration-and-connectivity'; AzureCli = 'yes'; Reason = 'Reads the Arc registration state in Azure.' }
        @{ Path = '04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-01-initiate-deployment-via-arm-template'; AzureCli = 'yes'; Reason = 'Starts the ARM template deployment in Azure.' }
        @{ Path = '04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion'; AzureCli = 'unclear'; Reason = 'Verifies the deployment, but the real scripts only check Active Directory and cluster health on premises.' }
        @{ Path = '04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-arm-template'; AzureCli = 'yes'; Reason = 'Starts the ARM template deployment in Azure; a real Azure CLI script exists.' }
        @{ Path = '04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-azure-portal'; AzureCli = 'unclear'; Reason = 'Named for the Azure portal, but the real scripts create local accounts on the nodes.' }
        @{ Path = '04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-02-verify-deployment-completion'; AzureCli = 'unclear'; Reason = 'Verifies the deployment, but the real scripts only check the local identity set-up and cluster health on premises.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn'; AzureCli = 'unclear'; Reason = 'SDN is enabled on the cluster; Azure is only used to run commands and read secrets.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-02-cluster-quorum-configuration'; AzureCli = 'yes'; Reason = 'Creates or reads the storage account for the cloud witness.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-03-security-groups-applied-to-nodes'; AzureCli = 'no'; Reason = 'Applies Active Directory security groups on the nodes.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-04-ssh-connectivity-to-nodes'; AzureCli = 'yes'; Reason = 'Deploys the OpenSSH Arc extension and the HybridConnectivity setting.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-05-storage-configuration'; AzureCli = 'yes'; Reason = 'Registers the Azure Local storage paths in Azure (and creates CSV volumes on the cluster).' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-06-image-downloads'; AzureCli = 'yes'; Reason = 'Creates Azure Local images from the Azure Marketplace.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-07-configure-nsgs'; AzureCli = 'yes'; Reason = 'Creates Azure Local network security groups.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation'; AzureCli = 'yes'; Reason = 'Creates Azure Local logical networks.' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification'; AzureCli = 'yes'; Reason = 'Reads the Azure Local resources (az stack-hci-vm).' }
        @{ Path = '04-cluster-deployment/phase-06-post-deployment/task-10-sbe-update-import'; AzureCli = 'no'; Reason = 'Reads the SBE package share and prints the import commands for the cluster.' }
        @{ Path = '05-operational-foundations/phase-01-sdn-deployment/task-01-validate-sdn-prerequisites'; AzureCli = 'no'; Reason = 'Checks SDN prerequisites on the cluster; the real script uses no Azure command.' }
        @{ Path = '05-operational-foundations/phase-01-sdn-deployment/task-02-configure-network-security-groups'; AzureCli = 'yes'; Reason = 'Configures SDN integration with az stack-hci.' }
        @{ Path = '05-operational-foundations/phase-01-sdn-deployment/task-03-configure-network-security-groups'; AzureCli = 'yes'; Reason = 'Creates network security groups in Azure.' }
        @{ Path = '05-operational-foundations/phase-02-monitoring-observability/task-01-configure-log-analytics-workspace'; AzureCli = 'yes'; Reason = 'Configures the Log Analytics workspace.' }
        @{ Path = '05-operational-foundations/phase-02-monitoring-observability/task-02-configure-azure-monitor-agent'; AzureCli = 'yes'; Reason = 'Configures Azure Monitor; a real Azure CLI script exists.' }
        @{ Path = '05-operational-foundations/phase-02-monitoring-observability/task-03-enable-hci-insights'; AzureCli = 'yes'; Reason = 'Enables Azure Local Insights.' }
        @{ Path = '05-operational-foundations/phase-02-monitoring-observability/task-04-setup-alerting'; AzureCli = 'yes'; Reason = 'Sets up Azure Monitor alerting.' }
        @{ Path = '05-operational-foundations/phase-04-security-governance/task-01-enable-defender-for-cloud'; AzureCli = 'yes'; Reason = 'Enables Microsoft Defender for Cloud.' }
        @{ Path = '05-operational-foundations/phase-04-security-governance/task-02-apply-azure-policy-initiatives'; AzureCli = 'yes'; Reason = 'Applies Azure Policy.' }
        @{ Path = '05-operational-foundations/phase-04-security-governance/task-03-configure-security-baselines'; AzureCli = 'no'; Reason = 'Applies security baselines on the nodes; the real script uses no Azure command.' }
        @{ Path = '05-operational-foundations/phase-04-security-governance/task-04-enable-security-logging'; AzureCli = 'unclear'; Reason = 'Security logging and audit policy can be on the nodes or in Azure; the real script uses no Azure command.' }
        @{ Path = '05-operational-foundations/phase-05-licensing-telemetry/task-01-enable-azure-hybrid-benefit'; AzureCli = 'yes'; Reason = 'Enables Azure Hybrid Benefit.' }
        @{ Path = '05-operational-foundations/phase-05-licensing-telemetry/task-02-activate-windows-server-subscription'; AzureCli = 'yes'; Reason = 'Activates the Windows Server subscription through Azure.' }
        @{ Path = '05-operational-foundations/phase-05-licensing-telemetry/task-03-configure-enhanced-telemetry'; AzureCli = 'unclear'; Reason = 'Telemetry can be set on the nodes or in Azure; the real script uses no Azure command.' }
        @{ Path = '06-testing-validation/task-01-infrastructure-health-validation'; AzureCli = 'no'; Reason = 'Checks cluster health from the cluster; the real script uses no Azure command.' }
        @{ Path = '06-testing-validation/task-02-vmfleet-storage-testing'; AzureCli = 'no'; Reason = 'Runs storage performance tests on the cluster.' }
        @{ Path = '06-testing-validation/task-03-network-rdma-validation'; AzureCli = 'no'; Reason = 'Validates network and RDMA settings on the nodes.' }
        @{ Path = '06-testing-validation/task-04-high-availability-testing'; AzureCli = 'no'; Reason = 'Tests failover and live migration on the cluster.' }
        @{ Path = '06-testing-validation/task-05-security-compliance-validation'; AzureCli = 'yes'; Reason = 'Reads Azure Policy state, role assignments and Defender pricing.' }
    )
}

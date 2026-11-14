# Script status

Which task folders under `scripts/deploy` have a script, per kind. **Generated** by `scripts/deploy/common/New-DeployScriptStatus.ps1` from the task folders and from `scripts/deploy/common/TaskCatalogue.psd1`. Do not edit it by hand: change the scripts or the catalogue and run the script. A test fails when this page is out of date (`./scripts/deploy/common/New-DeployScriptStatus.ps1 -Check`).

The toolkit is PowerShell. Azure CLI scripts exist only for tasks that act on Azure. Bash is not part of the layout and is not in the tables below.

| Word | Meaning |
|---|---|
| built | The folder holds at least one real script. A folder can also hold a placeholder next to it (for example an orchestrated variant that is not written yet). |
| not built | There is no real script. The folder holds only placeholders, or nothing. |
| not applicable | The task does not act on Azure (it runs on a node, against on-premises Active Directory or DNS, against hardware or a BMC, or is operating system work), so it has no Azure CLI script. |
| yes / no / unclear | Whether Azure CLI applies to the task. `unclear` means it is not decided; an existing Azure CLI placeholder is kept until it is. |

A **placeholder** is a script that does not do the task. Running it prints `NOT IMPLEMENTED: <task> has no <PowerShell or Azure CLI> script yet`, changes nothing and ends with **exit code 3** (the OS configuration and ARM deployment entry points use 0, 1 and 2). Use a real script of the task if there is one, or the steps on the guide page.

## Summary

Task folders: 114.

| Kind | built | not built | not applicable |
|---|--:|--:|--:|
| PowerShell | 86 | 28 | 0 |
| Azure CLI | 9 | 56 | 49 |

Azure CLI applies to 57 tasks, does not apply to 49, and is not decided for 8.

## 01-cicd-infra

| Task | PowerShell | Azure CLI | Azure CLI applies |
|---|---|---|---|
| `phase-01-cicd-setup/task-01-bootstrap` | built | built | yes |
| `phase-01-cicd-setup/task-02-create-project` | built | built | yes |
| `phase-01-cicd-setup/task-03-configure-project` | built | built | yes |
| `phase-01-cicd-setup/task-04-create-environments` | built | built | yes |
| `phase-01-cicd-setup/task-05-configure-variables` | built | built | yes |
| `phase-01-cicd-setup/task-06-deploy-runners` | built | built | yes |

## 02-azure-foundation

| Task | PowerShell | Azure CLI | Azure CLI applies |
|---|---|---|---|
| `phase-01-landing-zones/full-deployment/task-01-configure-management-groups` | built | not built | yes |
| `phase-01-landing-zones/full-deployment/task-02-create-subscriptions` | built | not built | yes |
| `phase-01-landing-zones/full-deployment/task-03-create-resource-groups` | built | not built | yes |
| `phase-01-landing-zones/simplified-deployment/task-01-configure-management-group` | not built | not built | yes |
| `phase-01-landing-zones/simplified-deployment/task-02-create-subscription` | not built | not built | yes |
| `phase-01-landing-zones/simplified-deployment/task-03-create-resource-groups` | built | not built | yes |
| `phase-02-resource-providers/task-01-register-resource-providers` | built | built | yes |
| `phase-02-resource-providers/task-02-verify-provider-registration` | built | not built | yes |
| `phase-03-rbac-permissions/task-01-create-azure-local-deployment-spn` | built | not built | yes |
| `phase-03-rbac-permissions/task-02-assign-rbac-roles` | built | not built | yes |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-01-configure-core-variables` | not built | not built | unclear |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-02-configure-management-mode` | not built | not built | unclear |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-03-configure-cluster-mode` | not built | not built | unclear |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-01-commit-and-push` | not built | not applicable | no |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-02-monitor-validate-stage` | not built | not applicable | no |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-03-review-plan-stage` | not built | not applicable | no |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-04-approve-deployment` | not built | not applicable | no |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-05-monitor-apply-stage` | not built | not applicable | no |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-02-pipeline-execution/task-06-verify-test-stage` | not built | not applicable | no |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-01-verify-resources` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-02-test-connectivity` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-03-validate-configuration` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-01-virtual-network` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-02-vpn-gateway` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-03-s2s-vpn-connection` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-04-p2s-vpn-connection` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-05-azure-bastion` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-06-network-security-groups` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-07-nat-gateway` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-08-arc-gateway` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-09-log-analytics` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-10-key-vault` | built | not built | yes |
| `phase-04-azure-management-infrastructure/02-manual-deployment/task-11-deploy-management-vms` | built | not built | yes |
| `phase-04-azure-management-infrastructure/task-12-configure-adds` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/task-13-configure-utility-server` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/task-14-configure-ndm-server` | not built | not built | yes |
| `phase-04-azure-management-infrastructure/task-15-configure-lighthouse` | not built | not built | yes |

## 03-onprem-readiness

| Task | PowerShell | Azure CLI | Azure CLI applies |
|---|---|---|---|
| `phase-01-active-directory/task-01-ou-creation-pre-creation-artifacts` | built | not applicable | no |
| `phase-01-active-directory/task-02-security-groups` | built | not applicable | no |
| `phase-01-active-directory/task-03-dns-node-a-records` | not built | not applicable | no |
| `phase-01-active-directory/task-04-service-admin-accounts` | built | not applicable | no |
| `phase-01-active-directory/task-05-group-assignments` | built | not applicable | no |
| `phase-02-enterprise-readiness/task-01-hardware-inspection` | built | not applicable | no |
| `phase-02-enterprise-readiness/task-02-network-service-verification` | built | not applicable | no |
| `phase-02-enterprise-readiness/task-03-opengear-verification` | built | not applicable | no |
| `phase-02-enterprise-readiness/task-04-validation-signoff` | built | not applicable | no |
| `phase-03-network-infrastructure/task-01-opengear-console-server` | not built | not applicable | no |
| `phase-03-network-infrastructure/task-02-dell-powerswitch-configuration` | built | not applicable | no |
| `phase-03-network-infrastructure/task-03-firewall-endpoint-verification` | built | not applicable | no |
| `phase-03-network-infrastructure/task-04-network-validation` | built | not applicable | no |

## 04-cluster-deployment

| Task | PowerShell | Azure CLI | Azure CLI applies |
|---|---|---|---|
| `phase-01-hardware-provisioning/task-01-create-dhcp-reservations-for-idrac-interfaces` | not built | not applicable | no |
| `phase-01-hardware-provisioning/task-02-hardware-discovery-via-dell-redfish-api` | built | not applicable | no |
| `phase-01-hardware-provisioning/task-03-create-dhcp-reservations-for-management-nics` | not built | not applicable | no |
| `phase-01-hardware-provisioning/task-04-bios-and-idrac-settings-validation` | built | not applicable | no |
| `phase-01-hardware-provisioning/task-05-bios-and-idrac-settings-remediation` | built | not applicable | no |
| `phase-02-os-installation/task-01-delete-and-recreate-virtual-disk-on-dell-boss-card` | built | not applicable | no |
| `phase-02-os-installation/task-02-mount-and-verify-dell-gold-image-iso` | built | not applicable | no |
| `phase-02-os-installation/task-03-manual-os-installation` | not built | not applicable | no |
| `phase-02-os-installation/task-04-verify-os-deployment` | built | not applicable | no |
| `phase-03-os-configuration/task-01-enable-winrm-for-remote-management` | not built | not applicable | no |
| `phase-03-os-configuration/task-02-enable-rdp` | built | not applicable | no |
| `phase-03-os-configuration/task-03-configure-static-ip-address` | built | not applicable | no |
| `phase-03-os-configuration/task-04-disable-dhcp-on-management-adapter` | built | not applicable | no |
| `phase-03-os-configuration/task-05-configure-dns-servers` | built | not applicable | no |
| `phase-03-os-configuration/task-06-verify-dns-client-configuration` | built | not applicable | no |
| `phase-03-os-configuration/task-07-configure-time-synchronization-ntp` | built | not applicable | no |
| `phase-03-os-configuration/task-08-enable-icmp-ping` | built | not applicable | no |
| `phase-03-os-configuration/task-09-disable-unused-network-adapters` | built | not applicable | no |
| `phase-03-os-configuration/task-10-configure-hostname` | built | not applicable | no |
| `phase-03-os-configuration/task-11-clear-previous-storage-configuration-conditional` | built | not applicable | no |
| `phase-03-os-configuration/task-13-phase03-verification` | built | not applicable | no |
| `phase-04-arc-registration/task-01-pre-registration-validation` | built | not built | yes |
| `phase-04-arc-registration/task-02-register-cluster-nodes-with-azure-arc` | built | built | yes |
| `phase-04-arc-registration/task-04-verify-arc-registration-and-connectivity` | built | not built | yes |
| `phase-05-cluster-deployment/active-directory/task-01-initiate-deployment-via-arm-template` | built | not built | yes |
| `phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion` | built | not built | unclear |
| `phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-arm-template` | built | built | yes |
| `phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-azure-portal` | built | not built | unclear |
| `phase-05-cluster-deployment/local-identity/task-02-verify-deployment-completion` | built | not built | unclear |
| `phase-06-post-deployment/task-01-deploy-sdn` | built | not applicable | no |
| `phase-06-post-deployment/task-02-cluster-quorum-configuration` | built | not built | yes |
| `phase-06-post-deployment/task-03-security-groups-applied-to-nodes` | built | not applicable | no |
| `phase-06-post-deployment/task-04-ssh-connectivity-to-nodes` | built | not built | yes |
| `phase-06-post-deployment/task-05-storage-configuration` | built | not built | yes |
| `phase-06-post-deployment/task-06-image-downloads` | built | not built | yes |
| `phase-06-post-deployment/task-07-configure-nsgs` | built | not built | yes |
| `phase-06-post-deployment/task-08-logical-network-creation` | built | not built | yes |
| `phase-06-post-deployment/task-09-post-deployment-verification` | built | not built | yes |
| `phase-06-post-deployment/task-10-sbe-update-import` | built | not applicable | no |

## 05-operational-foundations

| Task | PowerShell | Azure CLI | Azure CLI applies |
|---|---|---|---|
| `phase-01-sdn-deployment/task-01-validate-sdn-prerequisites` | built | not applicable | no |
| `phase-01-sdn-deployment/task-02-configure-network-security-groups` | built | not built | yes |
| `phase-01-sdn-deployment/task-03-configure-network-security-groups` | not built | not built | yes |
| `phase-02-monitoring-observability/task-01-configure-log-analytics-workspace` | built | not built | yes |
| `phase-02-monitoring-observability/task-02-configure-azure-monitor-agent` | built | not built | yes |
| `phase-02-monitoring-observability/task-03-enable-hci-insights` | built | not built | yes |
| `phase-02-monitoring-observability/task-04-setup-alerting` | built | not built | yes |
| `phase-04-security-governance/task-01-enable-defender-for-cloud` | built | not built | yes |
| `phase-04-security-governance/task-02-apply-azure-policy-initiatives` | built | not built | yes |
| `phase-04-security-governance/task-03-configure-security-baselines` | built | not applicable | no |
| `phase-04-security-governance/task-04-enable-security-logging` | not built | not built | unclear |
| `phase-05-licensing-telemetry/task-01-enable-azure-hybrid-benefit` | built | not built | yes |
| `phase-05-licensing-telemetry/task-02-activate-windows-server-subscription` | built | not built | yes |
| `phase-05-licensing-telemetry/task-03-configure-enhanced-telemetry` | not built | not built | unclear |

## 06-testing-validation

| Task | PowerShell | Azure CLI | Azure CLI applies |
|---|---|---|---|
| `task-01-infrastructure-health-validation` | built | not applicable | no |
| `task-02-vmfleet-storage-testing` | built | not applicable | no |
| `task-03-network-rdma-validation` | built | not applicable | no |
| `task-04-high-availability-testing` | built | not applicable | no |
| `task-05-security-compliance-validation` | built | not built | yes |

## Tasks that need a decision

Azure CLI may or may not apply. Decide, then set `AzureCli` to `yes` or `no` in `TaskCatalogue.psd1`.

| Task | Why it is not decided |
|---|---|
| `02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-01-configure-core-variables` | Edits the deployment configuration; there is no real script yet that shows whether it touches Azure. |
| `02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-02-configure-management-mode` | Edits the deployment configuration; there is no real script yet that shows whether it touches Azure. |
| `02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-01-configuration/task-03-configure-cluster-mode` | Edits the deployment configuration; there is no real script yet that shows whether it touches Azure. |
| `04-cluster-deployment/phase-05-cluster-deployment/active-directory/task-02-verify-deployment-completion` | Verifies the deployment, but the real scripts only check Active Directory and cluster health on premises. |
| `04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-01-initiate-deployment-via-azure-portal` | Named for the Azure portal, but the real scripts create local accounts on the nodes. |
| `04-cluster-deployment/phase-05-cluster-deployment/local-identity/task-02-verify-deployment-completion` | Verifies the deployment, but the real scripts only check the local identity set-up and cluster health on premises. |
| `05-operational-foundations/phase-04-security-governance/task-04-enable-security-logging` | No script. Audit policy and the Security log size are part of the security baseline, which drift control holds; the supported way to change them is Set-AzsSecurity (task-03, security.baseline_settings). Not decided whether Azure is involved. |
| `05-operational-foundations/phase-05-licensing-telemetry/task-03-configure-enhanced-telemetry` | No script. Microsoft Learn documents no way to set the Windows telemetry level of an Azure Local machine; diagnostic data is collected by the telemetry and diagnostics extension. Not decided whether Azure is involved. |

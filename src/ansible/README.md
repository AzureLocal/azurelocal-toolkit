# Ansible Automation for Azure Local

Ansible roles and playbooks for on-premises and guest OS configuration of Azure Local deployments. This covers tasks that Terraform cannot manage: Active Directory preparation, node OS configuration, Azure Arc registration, and monitoring agent deployment.

## Quick Start

```bash
# 1. Install required collections
ansible-galaxy collection install -r collections/requirements.yml

# 2. Copy and edit inventory
cp inventory/hosts.yml.example inventory/hosts.yml
# Edit inventory/hosts.yml with your environment values

# 3. Copy and edit group variables
# Or generate from variables.yml:
#   Export-AnsibleVars -Config $config -OutputPath "inventory/group_vars/all.yml"

# 4. Run all playbooks in order
ansible-playbook -i inventory/hosts.yml playbooks/site.yml

# Or run a specific phase
ansible-playbook -i inventory/hosts.yml playbooks/01-ad-preparation.yml
```

## Deployment Paths

This Ansible project supports two deployment paths:

| Path | Azure Resources | On-Prem Config | When to Use |
|------|:-:|:-:|---|
| **Terraform + Ansible** | Terraform | Ansible | Cross-platform config management |
| **Ansible Only** | `azure.azcollection` | Ansible | Standardizing on Ansible |

## Project Structure

```
src/ansible/
├── ansible.cfg                     # WinRM/Kerberos connection defaults
├── README.md                       # This file
├── collections/
│   └── requirements.yml            # Required Ansible collections
├── inventory/
│   ├── hosts.yml.example           # Example inventory (IIC values)
│   └── group_vars/
│       └── all.yml                 # Shared variables (from variables.yml)
├── roles/
│   ├── ad-preparation/             # OU, security groups, DNS, service accounts
│   ├── os-configuration/           # Hostname, NIC, NTP, DNS, domain join
│   ├── arc-registration/           # Azure Arc agent bootstrapping
│   ├── monitoring-agents/          # Azure Monitor Agent, HCI Insights
│   ├── domain-controller/          # AD DS promotion on management VMs
│   ├── wac-server/                 # Windows Admin Center install + KCD
│   └── syslog-receiver/            # rsyslog/SNMP for network device logging
└── playbooks/
    ├── 01-ad-preparation.yml       # Part 3, Phase 1
    ├── 02-os-configuration.yml     # Part 4, Phase 3
    ├── 03-arc-registration.yml     # Part 4, Phase 4
    ├── 04-monitoring-setup.yml     # Part 5, Phase 2
    ├── 05-management-vms.yml       # Part 2/5 (DC, WAC, Syslog)
    └── site.yml                    # Master playbook (all phases)
```

## Roles

### ad-preparation
Mirrors `scripts/deploy/03-onprem-readiness/phase-01-active-directory/`. Creates the OU hierarchy, cluster security groups, DNS conditional forwarders for Azure endpoints, and the LCM deployment service account.

### os-configuration
Mirrors `scripts/deploy/04-cluster-deployment/phase-03-os-configuration/`. Sets hostname, configures static IP on management NIC, NTP, DNS client, ICMP firewall, and domain join. Runs one node at a time (`serial: 1`) due to reboots.

### arc-registration
Mirrors `scripts/deploy/04-cluster-deployment/phase-04-arc-registration/`. Validates Azure Arc endpoint connectivity, authenticates via SPN, and runs `Invoke-AzStackHciArcInitialization` on each node.

### monitoring-agents
Mirrors `scripts/deploy/05-operational-foundations/phase-02-monitoring/`. Installs Azure Monitor Agent extension, creates Data Collection Rules with performance counters and event logs, and enables HCI Insights.

### domain-controller
Mirrors `scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/task-12-configure-adds/`. Installs AD DS feature and promotes the VM as either a new forest or replica DC.

### wac-server
Mirrors `scripts/deploy/05-operational-foundations/phase-02-monitoring/task-05-deploy-wac/`. Downloads and installs WAC silently, configures Kerberos Constrained Delegation for cluster management.

### syslog-receiver
Mirrors `scripts/deploy/05-operational-foundations/phase-02-monitoring/task-06-configure-network-device-logging/`. Configures rsyslog for UDP syslog reception and SNMP trap handling. Supports both Linux (rsyslog/snmpd) and Windows (WEF) hosts.

## Required Collections

| Collection | Version | Purpose |
|---|---|---|
| `azure.azcollection` | >= 2.4.0 | Azure resource management |
| `microsoft.ad` | >= 1.5.0 | Active Directory (OU, groups, users, domain join) |
| `ansible.windows` | >= 2.3.0 | Core Windows modules (WinRM, services, features) |
| `community.windows` | >= 2.2.0 | Extended Windows modules (firewall, DNS, NIC) |
| `community.general` | >= 9.0.0 | General utilities |

## Variables

Variables are sourced from the central `config/variables/variables.yml` file. Use the PowerShell helper to generate Ansible-compatible group vars:

```powershell
. scripts/common/utilities/helpers/config-loader.ps1
$config = Get-Config -ConfigPath "config/variables/variables.yml"
Export-AnsibleVars -Config $config -OutputPath "src/ansible/inventory/group_vars/all.yml"
```

### Secrets

Sensitive values (passwords, SPN secrets) should be stored in Ansible Vault or Azure Key Vault:

```bash
# Create encrypted vault file
ansible-vault create inventory/group_vars/vault.yml

# Required secrets:
# domain_admin_password: <domain admin password>
# spn_client_secret: <service principal secret>
```

## Prerequisites

- **Control node**: Linux/macOS with Ansible >= 2.15, Python >= 3.10
- **Target nodes**: WinRM enabled with Kerberos authentication
- **Network**: Control node must reach target nodes on WinRM port (5986)
- **Credentials**: Domain admin and Azure SPN with appropriate permissions

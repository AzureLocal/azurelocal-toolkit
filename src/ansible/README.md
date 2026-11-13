# Ansible for Azure Local

Ansible roles and playbooks for the on-premises steps of an Azure Local deployment: Active Directory preparation, node OS configuration, Azure Arc registration and the monitoring agent. They are an alternative route to the PowerShell scripts in `scripts/deploy` for the same tasks. Do not run both routes for the same step.

The values come from `infrastructure.yml`. The roles have no values of their own for the facts of an environment (names, addresses, domain). The registry says, for every variable, which key it comes from.

## Quick start

```powershell
# 1. Write the variable files from infrastructure.yml.
pwsh config/variables/scripts/New-IacVariableFiles.ps1 -InfrastructureFile ./infrastructure.yml -OutputDirectory D:\work\iac -Target Ansible
```

```bash
# 2. Install the collections.
ansible-galaxy collection install -r src/ansible/collections/requirements.yml

# 3. Copy the generated variables next to your inventory, and write the inventory.
cp -r D:/work/iac/ansible/inventory/group_vars D:/work/iac/ansible/inventory/host_vars src/ansible/inventory/
cp src/ansible/inventory/hosts.yml.example src/ansible/inventory/hosts.yml   # host names = nodes[].name

# 4. Pass the secrets at run time, then run all playbooks in order.
ansible-playbook -i src/ansible/inventory/hosts.yml src/ansible/playbooks/site.yml -e @vault.yml
```

`src/ansible/inventory/group_vars/all.yml` in the repository is the output for `config/variables/examples/infrastructure.example.yml` (a test keeps it current). Replace it with your own output. The `host_vars` folder is git-ignored.

## Secrets

No secret is in a variable file. The variables below are never written. Pass them with Ansible Vault (`-e @vault.yml`) or the environment at run time:

| Variable | The file holds the reference at |
| --- | --- |
| `domain_admin_password` | `identity.active_directory.domain_join_account.password`, or `identity.active_directory.lcm_user.password` |
| `spn_client_secret` | `devops.authentication.client_secret` |
| `cicd_runner_registration_token` | (only with `cicd_runner_token_source: variable`) |

```bash
ansible-vault create vault.yml     # domain_admin_password, spn_client_secret
```

## Where each variable comes from

Every variable of `group_vars/all.yml`, `host_vars`, and the role `defaults` and `vars` is registered in `config/variables/schema/master-registry.yaml` (`tools.ansible.variables`) with its class, source, `infrastructure_key` and `target`. See [Terraform and Ansible variable files](../../config/variables/docs/infrastructure-file.md#terraform-and-ansible-variable-files-schema-5617). A test fails when a variable is declared and not registered, or registered and not declared.

## Structure

```
src/ansible/
├── ansible.cfg
├── collections/requirements.yml
├── inventory/
│   ├── hosts.yml.example        # neutral example; host names are nodes[].name
│   ├── cicd-runners.yml.example
│   └── group_vars/all.yml       # written by New-IacVariableFiles.ps1
├── roles/
│   ├── ad-preparation/          # OUs, security groups, DNS forwarders, the LCM account
│   ├── os-configuration/        # host name, management address, NTP, DNS, domain join
│   ├── arc-registration/        # Azure Arc registration of the nodes
│   ├── monitoring-agents/       # Azure Monitor Agent extension, Azure Local Insights step
│   ├── domain-controller/       # AD DS promotion of management VMs
│   ├── wac-server/              # Windows Admin Center (outside the scope of the toolkit)
│   ├── syslog-receiver/         # rsyslog and SNMP trap receiver
│   └── cicd_runner/             # self-hosted CI/CD runner on an existing host
└── playbooks/                   # 00-cicd-runner, 01-ad-preparation, 02-os-configuration, 03-arc-registration, 04-monitoring-setup, 05-management-vms, site
```

## Roles

- **ad-preparation**: the OU tree, the security groups of `identity.active_directory.security_groups`, conditional forwarders for the Azure endpoints and the LCM account.
- **os-configuration**: sets the host name to the inventory name, the management address of the node (`host_vars`), NTP, the DNS client, the ICMP rule and the domain join into `identity.active_directory.ou_path`. One node at a time.
- **arc-registration**: checks the Azure endpoints and runs `Invoke-AzStackHciArcInitialization` on each node.
- **monitoring-agents**: installs the Azure Monitor Agent extension on each node and notes the Azure Local Insights step. It creates no data collection rule: the rule Insights uses is the one the portal creates (`operations.monitoring.data_collection_rule`).
- **domain-controller**: installs AD DS and promotes the VM as a new forest or a replica.
- **wac-server**: Windows Admin Center is out of scope for the toolkit; the role is kept as it was and its variables are registered as class d.
- **syslog-receiver**: rsyslog and snmptrapd on a Linux host, or the firewall rules on a Windows host.
- **cicd_runner**: configures an existing Linux or Windows host as a runner. See `playbooks/00-cicd-runner.yml`.

## Collections

| Collection | Version | Purpose |
| --- | --- | --- |
| `azure.azcollection` | >= 2.4.0 | Azure resource management |
| `microsoft.ad` | >= 1.5.0 | Active Directory (OU, groups, users, domain join) |
| `ansible.windows` | >= 2.3.0 | Core Windows modules |
| `community.windows` | >= 2.2.0 | Extended Windows modules (firewall, DNS) |
| `community.general` | >= 9.0.0 | General utilities |

## Prerequisites

- Control node: Linux or macOS with Ansible 2.15 or later and Python 3.10 or later.
- Targets: WinRM with Kerberos, reachable on port 5986.
- Credentials: a domain account and the Azure service principal, passed at run time.

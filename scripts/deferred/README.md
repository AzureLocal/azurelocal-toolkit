# Deferred tasks

The tasks in this folder are not part of the toolkit's route at this time. Nothing runs them: no pipeline,
no task catalogue entry, no test. They are kept so the work is not lost and has a place to come back to.

| Folder | What it holds | Why it is deferred |
|---|---|---|
| `windows-admin-center` | Windows Admin Center install and configuration, and the OEM extension monitoring task | Windows Admin Center is not part of the work at this point |
| `backup-dr`, `backup-dr-validation` | Azure Backup, Azure Site Recovery, the disaster recovery test; the backup validation | Backup is not dealt with at this time |
| `pim-conditional-access` | Privileged Identity Management and conditional access | For later; both need paid Microsoft Entra ID licences |
| `network-device-logging` | The syslog collector for switch and firewall logs | For later |

State of the scripts: they were moved as they were and keep the folder depth they had under `scripts/deploy`,
so their paths to the shared modules still resolve. They still read old configuration layouts and carry
hard-coded values. A task that comes back is moved to its stage under `scripts/deploy`, rewritten to read the
master `infrastructure.yml` through the registry, and added to the task catalogue with tests.

Paid security services are in `scripts/optional/paid-security-services`.
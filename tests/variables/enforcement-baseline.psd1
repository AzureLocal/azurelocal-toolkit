# Known debt: violations of tests/variables/Enforcement.Tests.ps1 in legacy scripts that are not migrated yet.
# The test passes with exactly these, prints how many there are, and fails on one more (a new violation) or one fewer (fixed debt:
# lower Count or remove the entry). File, Rule (A, B, C, D), Literal as the test prints it (an address is masked, 10.x.x.x/24) and
# Count (how many times the script has it). Reason is always 'legacy script, not yet migrated'. Do not add to this list: fix the script,
# or, when the value is fixed by Microsoft or a protocol, add a rule-level exception to the test; a reviewed one-off goes to enforcement-allowlist.psd1.
@{
    Entries = @(
        @{ File = 'scripts/deferred/backup-dr/phase-03-backup-dr/task-01-configure-azure-backup/powershell/Set-BackupConfiguration.ps1'; Rule = 'C'; Literal = 'DefaultVMBackupPolicy'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/backup-dr/phase-03-backup-dr/task-02-configure-site-recovery/powershell/Set-SiteRecoveryConfiguration.ps1'; Rule = 'C'; Literal = 'rep-policy-24h-rpo'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/pim-conditional-access/phase-05-identity-security/task-01-pim-conditional-access/powershell/Deploy-KeyVault.ps1'; Rule = 'B'; Literal = 'iic-security-01'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/windows-admin-center/phase-06-post-deployment/task-01-configure-windows-admin-center/powershell/Configure-WACKerberosDelegation.ps1'; Rule = 'B'; Literal = 'vm-dc01'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/windows-admin-center/phase-06-post-deployment/task-01-configure-windows-admin-center/powershell/Configure-WACKerberosDelegation.ps1'; Rule = 'B'; Literal = 'vm-dc02'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/windows-admin-center/phase-06-post-deployment/task-01-configure-windows-admin-center/powershell/Remote-Deploy-WAC.ps1'; Rule = 'B'; Literal = 'YOUR_RESOURCE_GROUP'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/windows-admin-center/phase-06-post-deployment/task-01-configure-windows-admin-center/powershell/Remote-Deploy-WAC.ps1'; Rule = 'B'; Literal = 'YOUR_SUBSCRIPTION_ID'; Count = 1; Reason = 'legacy script, not yet migrated' }
        @{ File = 'scripts/deferred/windows-admin-center/phase-06-post-deployment/task-01-configure-windows-admin-center/powershell/Remote-Deploy-WAC.ps1'; Rule = 'B'; Literal = 'YOUR_TENANT_ID'; Count = 1; Reason = 'legacy script, not yet migrated' }
    )
}

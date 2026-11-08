#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }, powershell-yaml
# Category identity: Active Directory over LDAP (OU, LCM user, rights, Block Inheritance, DNS records, node domain state, KDS root key) and
# local identity (zone, static IPs, records, SSH, workgroup). Fakes only.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fake adapter members and mock script blocks keep the signature of the real ones.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helpers build in-memory fixtures; they change no system state.')]
param()

BeforeAll {
    $repo = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    foreach ($m in 'infrastructure\AzlInfrastructure.psm1', 'azure-local\AzlAzure.psm1', 'arm-deployment\AzlArmDeployment.psm1', 'arm-deployment\AzlArmDeploymentRun.psm1', 'arm-deployment\AzlPreClusterGate.psm1', 'arm-deployment\AzlPreClusterVerification.psm1') {
        Import-Module ([IO.Path]::Combine($repo, 'scripts', 'common', $m)) -Force
    }
    Import-Module powershell-yaml
    $script:Fixture = [IO.Path]::Combine($repo, 'tests', 'fixtures', 'infrastructure.fc-san.yml')
    . ([IO.Path]::Combine($PSScriptRoot, 'PreClusterVerification.Helpers.ps1'))
    Mock -ModuleName AzlAzure Invoke-AzRestMethod { throw 'A test tried to call Azure.' }
    $script:LdapOff = @{ Reachable = $false; Server = ''; Entries = @(); AuthFailed = $false; Error = 'no domain controller of the file answered on TCP 389 from this host (tried improbability.cloud)' }
}

Describe 'Active Directory: the preparation the old check silently skipped' {
    It 'passes a prepared directory: OU, LCM user, rights, Block Inheritance' {
        $r = Invoke-PclRun
        foreach ($id in 'IDN-001', 'IDN-002', 'IDN-003', 'IDN-004', 'IDN-006') { (Get-PclCheck $r $id).Status | Should -BeIn 'Passed', 'Warning' -Because $id }
        (Get-PclCheck $r 'IDN-003').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'IDN-004').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'IDN-005').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'IDN-006').Status | Should -Be 'Passed'
    }
    It 'asks Active Directory with the LCM credential from Key Vault, read only (search filters only)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $r = Invoke-PclRun -World $w -Infra $infra
        $w.LdapCalls.Count | Should -BeGreaterThan 3
        foreach ($call in $w.LdapCalls) { $call.Credential.UserName | Should -Be 'IMPROBABILITY\lcm-iic-clus01'; $call.Filter | Should -Match '^\(' }
        $w.Calls | Should -Contain 'GetSecret:keyvault://kv-iic-mgmt-01/lcm-password'
        $r.Verdict | Should -Be 'Pass'
    }
    It 'fails with the preparation command when the OU does not exist' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Ldap['*organizationalUnit*distinguishedName=*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @(); AuthFailed = $false; Error = '' } }
        $r = Invoke-PclRun -World $w -Infra $infra
        $c = Get-PclCheck $r 'IDN-003'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match 'does not exist'
        $c.Remedy | Should -Match "New-HciAdObjectsPreCreation -AzureStackLCMUserCredential \(Get-Credential\) -AsHciOUName 'OU=iic-clus01"
        (Get-PclCheck $r 'IDN-006').Status | Should -Be 'Skipped'
        $r.Verdict | Should -Be 'Fail'
    }
    It 'fails when the LCM user does not exist' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Ldap['*sAMAccountName=*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @(); AuthFailed = $false; Error = '' } }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-004'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'LCM user lcm-iic-clus01 does not exist'
    }
    It 'fails for a disabled, locked or smart-card-only LCM user' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Ldap['*sAMAccountName=*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; AuthFailed = $false; Error = ''; Entries = @([pscustomobject]@{ distinguishedName = 'CN=lcm,OU=x'; dnsHostName = ''; Properties = @{ useraccountcontrol = @(0x40202); accountexpires = @(0); 'msds-user-account-control-computed' = @(0x10); userworkstations = @(); objectsid = @() } }) } }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-004'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'disabled'
        $c.Message | Should -Match 'locked out'
        $c.Message | Should -Match 'smart card'
    }
    It 'fails when Block Inheritance is off on the OU' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $ou = [string]$infra.identity.active_directory.ou_path
        $w.Ldap['*organizationalUnit*distinguishedName=*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; AuthFailed = $false; Error = ''; Entries = @([pscustomobject]@{ distinguishedName = $ou; dnsHostName = ''; Properties = @{ gpoptions = @(0); gplink = @(''); ntsecuritydescriptor = @('') } }) } }.GetNewClosure()
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-006'
        $c.Status | Should -Be 'Failed'
        $c.Remedy | Should -Match 'Set-GPInheritance'
    }
    It 'warns about an enforced GPO link above the OU, which Block Inheritance does not stop' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Ldap['*(|(distinguishedName=*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; AuthFailed = $false; Error = ''; Entries = @([pscustomobject]@{ distinguishedName = 'OU=AzureLocal,DC=improbability,DC=cloud'; dnsHostName = ''; Properties = @{ gplink = @('[LDAP://cn={31B2F340-016D-11D2-945F-00C04FB984F9},cn=policies,cn=system,DC=improbability,DC=cloud;2]') } }) } }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-006'
        $c.Status | Should -Be 'Warning'
        $c.Message | Should -Match 'enforced'
        $c.Remedy | Should -Match 'WMI filter'
    }
    It 'warns when no ACE gives the LCM user the rights on the OU directly' -Skip:(-not $IsWindows) {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $other = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-999')
        $sd = New-PclSecurityDescriptor -Sid $other
        $ou = [string]$infra.identity.active_directory.ou_path
        $w.Ldap['*organizationalUnit*distinguishedName=*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; AuthFailed = $false; Error = ''; Entries = @([pscustomobject]@{ distinguishedName = $ou; dnsHostName = ''; Properties = @{ gpoptions = @(1); gplink = @(''); ntsecuritydescriptor = @($sd) } }) } }.GetNewClosure()
        (Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-005').Status | Should -Be 'Warning'
    }
    It 'says plainly that a KDS root key is not required by Learn 2610 (NotApplicable, not a pass)' {
        $c = Get-PclCheck (Invoke-PclRun) 'IDN-007'
        $c.Status | Should -Be 'NotApplicable'
        $c.Message | Should -Match 'does not list a KDS root key'
        $c.Blocking | Should -BeFalse
    }
}

Describe 'Active Directory: when it cannot be asked, that is Skipped and blocks (never "fine")' {
    It 'Skips every LDAP check when no domain controller answers, with the reason, and fails the verdict' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $off = $script:LdapOff
        $w.Ldap['*'] = { param($r) [pscustomobject]$off }.GetNewClosure()
        $w.Ldap.Remove('*objectClass=domainDNS*'); $w.Ldap.Remove('*organizationalUnit*distinguishedName=*'); $w.Ldap.Remove('*sAMAccountName=*')
        $r = Invoke-PclRun -World $w -Infra $infra
        foreach ($id in 'IDN-002', 'IDN-003', 'IDN-004', 'IDN-010') {
            $c = Get-PclCheck $r $id
            $c.Status | Should -Be 'Skipped' -Because $id
            $c.Blocking | Should -BeTrue
            $c.Message | Should -Match 'TCP 389'
        }
        $r.Verdict | Should -Be 'Fail'
        $r.NextAction | Should -Match 'IDN-002|host that reaches'
    }
    It 'fails the credential check, and stops using the credential (the latch) when the controller rejects it' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Ldap.Clear()
        $w.Ldap['*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @(); AuthFailed = $true; Error = 'LDAP search on dc01:389 failed: The user name or password is incorrect.' } }
        $r = Invoke-PclRun -World $w -Infra $infra
        $c = Get-PclCheck $r 'IDN-002'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'rejected the LCM credential'
        $c.Message | Should -Match 'not sent again'
        $w.LdapCalls.Count | Should -Be 1 -Because 'one rejected bind must stop every later use of the account'
        (Get-PclCheck $r 'IDN-003').Status | Should -Be 'Skipped'
    }
}

Describe 'DNS records and name resolution' {
    It 'fails when a node A record points at another address' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Dns['iic-n01.improbability.cloud'] = @('192.0.2.99')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-008' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match '192\.0\.2\.99'
    }
    It 'fails for a missing record when the DNS servers are not domain controllers (no secure dynamic update), warns when they are' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Dns.Remove('iic-n02.improbability.cloud')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-008' 'iic-n02'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'secure dynamic updates'
        $c.Remedy | Should -Match 'Add-DnsServerResourceRecordA -ZoneName'
        $infra2 = Get-PclInfra
        $infra2.identity.active_directory.domain_controllers = @($infra2.networking.management.dns_servers)
        $w2 = Initialize-PclWorld -Infra $infra2
        $w2.Dns.Remove('iic-n02.improbability.cloud')
        (Get-PclCheck (Invoke-PclRun -World $w2 -Infra $infra2) 'IDN-008' 'iic-n02').Status | Should -Be 'Warning'
    }
    It 'checks the cluster name record (CNO) too' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Dns.Remove('iic-clus01.improbability.cloud')
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-009'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'CNO'
    }
    It 'is Skipped, not passed, when a DNS server does not answer at all' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.DnsSilent = @($infra.networking.management.dns_servers)
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-008' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'answered the query'
    }
    It 'fails on a node that cannot resolve the domain or reach ADWS (DNS/AD name resolution)' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) foreach ($x in $d.Pcl.dnsq) { $x.ok = $false; $x.addrs = @(); $x.err = 'DNS name does not exist' } }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-011' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'cannot resolve improbability\.cloud'
        $c.Message | Should -Match 'No such host is known'
    }
    It 'fails when no domain controller answers on ADWS 9389 from the node' {
        $infra = Get-PclInfra
        $infra.identity.active_directory.domain_controllers = @('192.0.2.4')
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n02'] = { param($d, $q) foreach ($x in $d.Pcl.tcp) { if ($x.p -eq 9389) { $x.ok = $false } } }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-011' 'iic-n02'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match '9389'
    }
}

Describe 'IDN-012 the domain or workgroup state of the nodes (Learn 2604 and later)' {
    It 'passes a workgroup node: it is joined during the deployment' {
        (Get-PclCheck (Invoke-PclRun) 'IDN-012' 'iic-n01').Message | Should -Match 'joined to the domain during the deployment'
    }
    It 'fails a node joined to another domain' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.cs.partOfDomain = $true; $d.Pcl.cs.domain = 'other.example' }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-012' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'other\.example'
    }
    It 'fails a joined node whose deployment user is not a local administrator, and whose computer object is outside the OU' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.cs.partOfDomain = $true; $d.Pcl.cs.domain = 'improbability.cloud' }
        $w.Ldap['*objectCategory=computer*cn=iic-n01*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; AuthFailed = $false; Error = ''; Entries = @([pscustomobject]@{ distinguishedName = 'CN=iic-n01,CN=Computers,DC=improbability,DC=cloud'; dnsHostName = 'iic-n01.improbability.cloud'; Properties = @{} }) } }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-012' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'not in the local Administrators group'
        $c.Message | Should -Match 'not in the OU'
        $c.Remedy | Should -Match "Add-LocalGroupMember -Group 'Administrators' -Member 'IMPROBABILITY\\lcm-iic-clus01'"
    }
    It 'passes a joined node in the OU with the deployment user as a local administrator' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $ou = [string]$infra.identity.active_directory.ou_path
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.cs.partOfDomain = $true; $d.Pcl.cs.domain = 'improbability.cloud'; $d.Pcl.primarySuffix = 'improbability.cloud'; $d.Pcl.admins = @('Administrator', 'IMPROBABILITY\lcm-iic-clus01') }
        $w.Ldap['*objectCategory=computer*cn=iic-n01*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; AuthFailed = $false; Error = ''; Entries = @([pscustomobject]@{ distinguishedName = "CN=iic-n01,$ou"; dnsHostName = 'iic-n01.improbability.cloud'; Properties = @{} }) } }.GetNewClosure()
        $r = Invoke-PclRun -World $w -Infra $infra
        (Get-PclCheck $r 'IDN-012' 'iic-n01').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'IDN-013' 'iic-n01').Status | Should -Be 'Passed'
    }
    It 'fails a disjoint namespace' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.cs.partOfDomain = $true; $d.Pcl.cs.domain = 'improbability.cloud'; $d.Pcl.primarySuffix = 'corp.improbability.cloud' }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-013' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'disjoint namespace'
        $c.Remedy | Should -Match 'Set-DnsClient'
    }
}

Describe 'Passwords and the file' {
    It 'fails a password that does not meet Azure''s rule, without ever showing it' {
        $infra = Get-PclInfra
        $w = Initialize-PclWorld -Infra $infra
        $w.Secrets['keyvault://kv-iic-mgmt-01/lcm-password'] = 'shortpassword'
        $r = Invoke-PclRun -World $w -Infra $infra
        $c = Get-PclCheck $r 'IDN-014'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'LCM user'
        $c.Message | Should -Match 'at least 14 characters'
        $c.Message | Should -Not -Match 'shortpassword'
    }
    It 'fails an OU path at the top of the domain and a LCM user name with a domain part or too long' {
        $infra = Get-PclInfra
        $infra.identity.active_directory.ou_path = 'DC=improbability,DC=cloud'
        $infra.identity.active_directory.lcm_user.username = 'IMPROBABILITY\a-very-long-lcm-user-name'
        $c = Get-PclCheck (Invoke-PclRun -Infra $infra) 'IDN-001'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match "doesn't|can't be the top|start with OU="
        $c.Message | Should -Match 'includes a domain'
    }
}

Describe 'Local identity (AD-less)' {
    BeforeAll {
        $script:Local = { $i = Get-PclInfra -Identity local_identity; $i.identity.local_identity = [ordered]@{ dns_server_config = 'use_dns_server'; dns_zone = 'improbability.cloud'; dns_forwarders = @() }; $i }
    }
    It 'does not run the Active Directory checks, and says so' {
        $r = Invoke-PclRun -Infra (& $script:Local)
        foreach ($id in 'IDN-001', 'IDN-002', 'IDN-003', 'IDN-004', 'IDN-005', 'IDN-006', 'IDN-007', 'IDN-009', 'IDN-010', 'IDN-011', 'IDN-012', 'IDN-013') { (Get-PclCheck $r $id).Status | Should -Be 'NotApplicable' -Because $id }
    }
    It 'passes when the zone, the records and SSH are in place' {
        $infra = & $script:Local
        $w = Initialize-PclWorld -Infra $infra
        foreach ($n in $infra.nodes) { $m = Get-AzlManagementAdapter -Infrastructure $infra -Node $n; $w.Dns["$($n.name).improbability.cloud"] = @([string]$m.IpAddress) }
        $w.Dns['iic-clus01.improbability.cloud'] = @([string]$infra.networking.management.infrastructure_pool.start)
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.sshd = [pscustomobject]@{ status = 'Running'; start = 'Automatic' } }
        $w.Mutate['iic-n02'] = $w.Mutate['iic-n01']
        $r = Invoke-PclRun -World $w -Infra $infra
        foreach ($id in 'IDN-020', 'IDN-021', 'IDN-022', 'IDN-023', 'IDN-024') { @(Get-PclCheck $r $id)[0].Status | Should -Be 'Passed' -Because $id }
        $r.Verdict | Should -Be 'Pass'
    }
    It 'fails without a DNS zone, with the built-in Administrator, and with use_forwarder but no forwarder' {
        $infra = & $script:Local
        $infra.identity.local_identity.dns_zone = ''; $infra.identity.local_identity.dns_server_config = 'use_forwarder'; $infra.identity.local_admin.username = 'Administrator'
        $c = Get-PclCheck (Invoke-PclRun -Infra $infra) 'IDN-020'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'dns_zone is empty'
        $c.Message | Should -Match 'dns_forwarders is empty'
        $c.Message | Should -Match 'built-in Administrator'
    }
    It 'fails when the records of the zone are missing' {
        $infra = & $script:Local
        $w = Initialize-PclWorld -Infra $infra
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-022'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'iic-n01\.improbability\.cloud: no A record'
        $c.Message | Should -Match 'iic-clus01\.improbability\.cloud'
    }
    It 'fails without SSH on a node, and for DHCP' {
        $infra = & $script:Local
        $w = Initialize-PclWorld -Infra $infra
        (Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-023' 'iic-n01').Message | Should -Match 'no sshd service'
        $infra2 = & $script:Local; $infra2.networking.management.use_dhcp = $true
        (Get-PclCheck (Invoke-PclRun -Infra $infra2) 'IDN-021').Status | Should -Be 'Failed'
    }
    It 'fails a domain-joined node (local identity needs a workgroup)' {
        $infra = & $script:Local
        $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.cs.partOfDomain = $true; $d.Pcl.cs.domain = 'x.example' }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra) 'IDN-024' 'iic-n01'
        $c.Status | Should -Be 'Failed'
        $c.Message | Should -Match 'joined to the domain'
    }
}

Describe 'The dedicated local administrator (both identity types)' {
    It 'IDN-015 passes an enabled, dedicated administrator in the Administrators group on every node' {
        $r = Invoke-PclRun -Category identity
        (Get-PclCheck $r 'IDN-015' 'iic-n01').Status | Should -Be 'Passed'
        (Get-PclCheck $r 'IDN-015' 'iic-n02').Status | Should -Be 'Passed'
    }
    It 'IDN-015 fails a user that does not exist, is disabled or is not an administrator' {
        $infra = Get-PclInfra; $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Read.admin.ex = $false }
        $w.Mutate['iic-n02'] = { param($d, $q) $d.Read.admin.en = $false; $d.Read.admin.adm = $false }
        $r = Invoke-PclRun -World $w -Infra $infra -Category identity
        (Get-PclCheck $r 'IDN-015' 'iic-n01').Message | Should -Match "'azl-admin' does not exist"
        $c = Get-PclCheck $r 'IDN-015' 'iic-n02'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'disabled'; $c.Message | Should -Match 'not in the local Administrators'
    }
    It 'IDN-015 fails the built-in Administrator, by name in the file and by SID on the node' {
        $infra = Get-PclInfra; $infra.identity.local_admin.username = 'Administrator'
        $c = Get-PclCheck (Invoke-PclRun -Infra $infra -Category identity) 'IDN-015'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'built-in Administrator'
        $infra2 = Get-PclInfra; $w = Initialize-PclWorld -Infra $infra2
        $w.Mutate['iic-n01'] = { param($d, $q) $d.Pcl.adminAccount.builtin = $true; $d.Pcl.adminAccount.sid = 'S-1-5-21-1-2-3-500' }
        (Get-PclCheck (Invoke-PclRun -World $w -Infra $infra2 -Category identity) 'IDN-015' 'iic-n01').Message | Should -Match 'SID ends in -500'
    }
    It 'IDN-016 passes when the user name secret equals the file' {
        $r = Invoke-PclRun -Category identity
        $c = Get-PclCheck $r 'IDN-016'
        $c.Status | Should -Be 'Passed'
        $c.Message | Should -Match 'kv-iic-mgmt-01/local-admin-username'
    }
    It 'IDN-016 fails when the secret holds another user name (the real mismatch: the vault says Administrator), with the exact commands' {
        $infra = Get-PclInfra; $w = Initialize-PclWorld -Infra $infra
        $w.Secrets['keyvault://kv-iic-mgmt-01/local-admin-username'] = 'Administrator'
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra -Category identity) 'IDN-016'
        $c.Status | Should -Be 'Failed'
        $c.Blocking | Should -BeTrue
        $c.Message | Should -Match "holds the user name 'Administrator', but identity.local_admin.username is 'azl-admin'"
        $c.Remedy | Should -Match "Set-AzKeyVaultSecret -VaultName 'kv-iic-mgmt-01' -Name 'local-admin-username'"
        $c.Remedy | Should -Match "set identity.local_admin.username to 'Administrator'"
    }
    It 'IDN-016 reads the secret the file names, and fails when that secret cannot be read; a missing default secret is a warning' {
        $infra = Get-PclInfra; $infra.identity.local_admin['username_secret'] = 'keyvault://kv-iic-mgmt-01/admin-name'
        $w = Initialize-PclWorld -Infra $infra
        $r = Invoke-PclRun -World $w -Infra $infra -Category identity -Override @{ GetSecret = { param($Reference) if ($Reference -like '*admin-name') { throw 'SecretNotFound' }; 'Sup3r-S3cret-Value!' } }
        $c = Get-PclCheck $r 'IDN-016'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'named by identity.local_admin.username_secret'
        $infra2 = Get-PclInfra; $w2 = Initialize-PclWorld -Infra $infra2
        $r2 = Invoke-PclRun -World $w2 -Infra $infra2 -Category identity -Override @{ GetSecret = { param($Reference) if ($Reference -like '*local-admin-username') { throw 'SecretNotFound' }; 'Sup3r-S3cret-Value!' } }
        (Get-PclCheck $r2 'IDN-016').Status | Should -Be 'Warning'
    }
    It 'IDN-017 passes when the password opened the session, and fails when it is not the account''s password' {
        (Get-PclCheck (Invoke-PclRun -Category identity) 'IDN-017' 'iic-n01').Status | Should -Be 'Passed'
        $infra = Get-PclInfra; $w = Initialize-PclWorld -Infra $infra
        $w.Mutate['iic-n02'] = { param($d, $q) $d.Read.admin.pw = $false }
        $c = Get-PclCheck (Invoke-PclRun -World $w -Infra $infra -Category identity) 'IDN-017' 'iic-n02'
        $c.Status | Should -Be 'Failed'; $c.Message | Should -Match 'identical on all machines'
    }
}

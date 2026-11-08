# Helpers for the pre-cluster verification tests. Dot-sourced inside BeforeAll. Fakes only: no Azure, no domain controller, no node.
# Every call of the gate that touches Azure, Active Directory, DNS or a node goes through the adapter; the adapter here is a table of fakes
# over a "world" that the tests change.

. ([IO.Path]::Combine($PSScriptRoot, '..', 'arm-deployment', 'ArmDeploymentRun.Helpers.ps1'))

function New-PclWorld {
    <# The state of a pretend environment: what Azure, AD, DNS and every node answer. A world built with no arguments passes every check. #>
    [pscustomobject]@{
        Clock = [pscustomobject]@{ Time = [datetime]::Parse('2026-11-08T12:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal); Sleeps = [System.Collections.Generic.List[double]]::new() }
        Providers = @{}; Registered = [System.Collections.Generic.List[string]]::new(); RegisterFails = @()
        Context = 'ok'; Subscription = [pscustomobject]@{ State = 'Enabled'; TenantId = '00000000-0000-0000-0000-000000000000'; DisplayName = 'lab' }
        ResourceGroup = $true; Roles = @('Owner', 'Key Vault Secrets Officer'); Permissions = @('*')
        Secrets = @{}; MissingSecrets = @(); NameTaken = @(); ArcMachines = @{}; ArcElsewhere = @{}; ArcExtensions = @{}
        DeploymentState = $null; RoleAssignments = @(); Gateway = $true
        Dns = @{}; DnsSilent = @(); Ldap = @{}; LdapCalls = [System.Collections.Generic.List[object]]::new()
        NodeData = @{}; Mutate = @{}; NodeFailures = @{}; NodeReads = [System.Collections.Generic.List[string]]::new()
        Ec = $null; EcCalls = 0; Calls = [System.Collections.Generic.List[string]]::new()
    }
}

function New-PclSecurityDescriptor {
    <# The binary DACL of an OU as base64, with an allow entry for the SID: what the LDAP search returns for ntSecurityDescriptor. #>
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid, [string]$Rights = 'GenericAll')
    $sd = [System.DirectoryServices.ActiveDirectorySecurity]::new()
    $sd.AddAccessRule([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Sid, [System.DirectoryServices.ActiveDirectoryRights]$Rights, [System.Security.AccessControl.AccessControlType]::Allow))
    [Convert]::ToBase64String($sd.GetSecurityDescriptorBinaryForm())
}

function Get-PclLcmSid { [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1105') }

function New-PclNodeData {
    <# What a healthy node says: the OS configuration Read and the gate's own payload, in the shape of the real answers. #>
    param([Parameter(Mandatory)]$World, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [Parameter(Mandatory)]$Request, [string]$Address)
    $node = @($Infra.nodes | Where-Object { $_.name -eq $Name })[0]
    $mgmt = Get-AzlManagementAdapter -Infrastructure $Infra -Node $node
    $ip = [string]$mgmt.IpAddress
    $gateway = [string]$Infra.networking.management.gateway
    $utc = $World.Clock.Time.ToString('o')
    $dns = @($Infra.networking.management.dns_servers)
    $ntp = @($Infra.networking.ntp_servers)
    $nics = @(
        [pscustomobject]@{ n = 'Port0'; desc = 'Dell LOM 25G'; st = 'Up'; speed = 25000000000; mac = '000000000000'; drvProv = 'Dell'; drvVer = '1.0'; idx = 4; mtu = 1514; jumbo = '1514'; rdmaCapable = $false; rdmaEnabled = $false; rdmaOp = $null; ips = @($ip); gw = @($gateway) }
        [pscustomobject]@{ n = 'Port1'; desc = 'Dell LOM 25G'; st = 'Up'; speed = 25000000000; mac = '000000000001'; drvProv = 'Dell'; drvVer = '1.0'; idx = 5; mtu = 1514; jumbo = '1514'; rdmaCapable = $false; rdmaEnabled = $false; rdmaOp = $null; ips = @(); gw = @() }
        [pscustomobject]@{ n = 'Port2'; desc = 'Mellanox ConnectX-6'; st = 'Up'; speed = 25000000000; mac = '000000000002'; drvProv = 'Mellanox Technologies Ltd.'; drvVer = '2.0'; idx = 6; mtu = 9014; jumbo = '9014'; rdmaCapable = $true; rdmaEnabled = $true; rdmaOp = $true; ips = @(); gw = @() }
        [pscustomobject]@{ n = 'Port3'; desc = 'Mellanox ConnectX-6'; st = 'Up'; speed = 25000000000; mac = '000000000003'; drvProv = 'Mellanox Technologies Ltd.'; drvVer = '2.0'; idx = 7; mtu = 9014; jumbo = '9014'; rdmaCapable = $true; rdmaEnabled = $true; rdmaOp = $true; ips = @(); gw = @() }
    )
    $disks = @([pscustomobject]@{ num = 0; name = 'BOSS'; serial = 'B0'; size = 480000000000; bus = 'SATA'; media = 'SSD'; canPool = $false; reason = 'Not Healthy'; health = 'Healthy'; fw = 'x'; boot = $true; system = $true; style = 'GPT'; parts = 3 })
    foreach ($i in 1..4) { $disks += [pscustomobject]@{ num = $i; name = "NVMe $i"; serial = "N$i"; size = 3840000000000; bus = 'NVMe'; media = 'SSD'; canPool = $true; reason = ''; health = 'Healthy'; fw = 'x'; boot = $false; system = $false; style = 'RAW'; parts = 0 } }
    $cpu = @(1..2 | ForEach-Object { [pscustomobject]@{ caption = 'Intel64 Family 6'; family = 179; manufacturer = 'GenuineIntel'; maxClock = 2000; cores = 16; logical = 32; threads = 32; vt = $true; slat = $true } })
    $pcl = [pscustomobject]@{
        v = 1; host = $Name; utc = $utc; os = [pscustomobject]@{ caption = 'Azure Local'; build = '10.0.26100.33650' }
        cs = [pscustomobject]@{ partOfDomain = $false; domain = 'WORKGROUP'; memBytes = [int64]256GB; manufacturer = 'Dell'; model = 'AX-760'; hypervisor = $true }; primarySuffix = ''
        cpu = $cpu; mem = @(1..8 | ForEach-Object { [int64]32GB }); fw = [pscustomobject]@{ biosVersion = '2.1.0'; biosVendor = 'Dell'; secureBoot = $true; tpmPresent = $true; tpmReady = $true; tpmSpec = '2.0, 0, 1.38' }
        features = @($Request.PclParameters.features | ForEach-Object { [pscustomobject]@{ n = $_; found = $true; installed = $true } })
        reboot = [pscustomobject]@{ cbs = $false; wu = $false; files = $false; rename = $false }
        time = [pscustomobject]@{ src = $ntp[0]; type = 'NTP'; peers = (($ntp | ForEach-Object { "$_,0x8" }) -join ' ') }
        dns = @([pscustomobject]@{ n = 'Port0'; idx = 4; suffix = ''; servers = $dns }, [pscustomobject]@{ n = 'Port1'; idx = 5; suffix = ''; servers = @() })
        phys = $disks; pools = @(); vdisks = 0; cluster = [pscustomobject]@{ svc = 'Stopped'; name = '' }; nics = $nics
        vms = [pscustomobject]@{ switches = @(); intents = @() }; sshd = $null; admins = @('Administrator', 'azl-admin'); ec = @()
        tcp = @($Request.PclParameters.tcp | ForEach-Object { [pscustomobject]@{ h = $_.h; p = $_.p; ok = $true } })
        https = @($Request.PclParameters.https | ForEach-Object { [pscustomobject]@{ u = $_; ok = $true; status = '404'; err = '' } })
        ping = @($Request.PclParameters.ping | ForEach-Object { [pscustomobject]@{ a = $_; ok = ($_ -eq $gateway) } })
        dnsq = @($Request.PclParameters.dnsq | ForEach-Object { [pscustomobject]@{ name = $_.name; server = $_.server; ok = $true; addrs = @('192.0.2.50'); err = '' } })
        adminAccount = [pscustomobject]@{ user = [string]$Infra.identity.local_admin.username; sid = 'S-1-5-21-1-2-3-1001'; builtin = $false; enabled = $true }
        err = [pscustomobject]@{}
    }
    $read = [pscustomobject]@{
        v = 1; host = $Name; os = '10.0.26100.33650'; reboot = $false; nics = @(); remote = $null
        time = [pscustomobject]@{ type = 'NTP'; peers = $pcl.time.peers; src = $ntp[0] }
        sbe = @(); sbeHeld = @(); drv = @(); admin = [pscustomobject]@{ ex = $true; en = $true; adm = $true; pw = $true }
        stor = [pscustomobject]@{ pools = 0; vdisks = 0; dirty = @(); cluster = [pscustomobject]@{ deployed = $false; why = @() } }
        san = [pscustomobject]@{ feature = 'Enabled'; hw = @(); lb = 'RR'; set = [pscustomobject]@{}; fc = @(); iqn = @(); disks = @(); iscsiSvc = ''; iscsiClaim = '' }
        domainJoin = $null; err = [pscustomobject]@{}
    }
    [pscustomobject]@{ Read = $read; Pcl = $pcl; Address = $(if ($Address) { $Address } else { $ip }) }
}

function New-PclAdapter {
    <# The gate's adapter with every member replaced by a fake that answers from the world. -Override replaces members. #>
    param([Parameter(Mandatory)]$World, [Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [hashtable]$Override = @{})
    $w = $World; $infra = $Infra
    # A closure is bound to a module of its own and does not see the functions of this file: carry the one it needs as a value.
    $buildNode = ${function:New-PclNodeData}
    $a = New-AzlPclAdapter
    $a['Now'] = { $w.Clock.Time }.GetNewClosure()
    $a['Sleep'] = { param($Seconds) $w.Clock.Sleeps.Add([double]$Seconds); $w.Clock.Time = $w.Clock.Time.AddSeconds([double]$Seconds) }.GetNewClosure()
    $a['GetContext'] = {
        $w.Calls.Add('GetContext')
        if ($w.Context -eq 'none') { return $null }
        $sub = if ($w.Context -eq 'wrongSubscription') { '11111111-1111-1111-1111-111111111111' } else { [string]$infra.azure.subscription_id }
        $tenant = if ($w.Context -eq 'wrongTenant') { '22222222-2222-2222-2222-222222222222' } else { [string]$infra.azure.tenant_id }
        [pscustomobject]@{ SubscriptionId = $sub; TenantId = $tenant; Account = 'tester@example.invalid' }
    }.GetNewClosure()
    $a['GetSubscription'] = { $w.Subscription }.GetNewClosure()
    $a['GetResourceGroup'] = { if ($w.ResourceGroup) { [pscustomobject]@{ name = 'rg' } } }.GetNewClosure()
    $a['GetProviderState'] = { param($Subscription, $Namespace) $null = $Subscription; if ($w.Providers.ContainsKey($Namespace)) { $w.Providers[$Namespace] } else { 'Registered' } }.GetNewClosure()
    $a['RegisterProvider'] = {
        param($Subscription, $Namespace)
        $null = $Subscription
        $w.Calls.Add("RegisterProvider:$Namespace")
        if ($Namespace -in $w.RegisterFails) { throw "AuthorizationFailed: no permission to register $Namespace" }
        $w.Registered.Add($Namespace); $w.Providers[$Namespace] = 'Registered'
    }.GetNewClosure()
    $a['GetCallerRoles'] = { param($Scope) @($w.Roles | ForEach-Object { [pscustomobject]@{ Role = $_; Scope = "/subscriptions/$($infra.azure.subscription_id)" } }) }.GetNewClosure()
    $a['GetPermission'] = { , @([pscustomobject]@{ Actions = @($w.Permissions); NotActions = @() }) }.GetNewClosure()
    $a['ListRoleAssignments'] = { param($Scope) @($w.RoleAssignments) }.GetNewClosure()
    $a['ListArcExtensions'] = { param($ResourceId) if ($w.ArcExtensions.ContainsKey($ResourceId)) { @($w.ArcExtensions[$ResourceId]) } else { @() } }.GetNewClosure()
    $a['FindArcMachines'] = {
        param($Subscription, $Name)
        if ($w.ArcElsewhere.ContainsKey($Name)) { return @($w.ArcElsewhere[$Name]) }
        @([pscustomobject]@{ Name = $Name; ResourceId = "/subscriptions/$Subscription/resourceGroups/$($infra.azure.resource_group)/providers/Microsoft.HybridCompute/machines/$Name"; ResourceGroup = [string]$infra.azure.resource_group; Status = 'Connected' })
    }.GetNewClosure()
    $a['GetArcGateway'] = { if ($w.Gateway) { [pscustomobject]@{ Name = 'gw'; ProvisioningState = 'Succeeded' } } }.GetNewClosure()
    $a['TestNameAvailable'] = { param($Subscription, $ResourceGroup, $Type, $Name) $null = $Subscription, $ResourceGroup, $Type; [pscustomobject]@{ Available = ($Name -notin $w.NameTaken); ExistsInResourceGroup = $false; Reason = $(if ($Name -in $w.NameTaken) { 'The name is already in use.' } else { '' }) } }.GetNewClosure()
    $a['TestSecret'] = { param($Vault, $Secret) $null = $Vault; $Secret -notin $w.MissingSecrets }.GetNewClosure()
    $a['GetSecret'] = { param($Reference) $w.Calls.Add("GetSecret:$Reference"); if ($w.Secrets.ContainsKey($Reference)) { $w.Secrets[$Reference] } else { 'Sup3r-S3cret-Value!' } }.GetNewClosure()
    $a['GetHciResourceProviderObjectId'] = { '00000000-0000-0000-0000-000000000009' }
    $a['GetArcMachine'] = {
        param($Node, $ResourceId, $ArcMachineName, $Subscription, $ResourceGroup)
        $null = $ResourceId, $ArcMachineName
        if ($w.ArcMachines.ContainsKey($Node)) { return $w.ArcMachines[$Node] }
        [pscustomobject]@{ Name = $Node; ResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$Node"; Status = 'Connected'; OsVersion = '10.0.26100.33650'; ComputerName = $Node }
    }.GetNewClosure()
    $a['GetDeploymentState'] = { $w.DeploymentState }.GetNewClosure()
    $a['ResolveDns'] = {
        param($Name, $Server)
        if ($Server -in $w.DnsSilent) { return [pscustomobject]@{ Ok = $false; Addresses = @(); Error = 'timed out' } }
        $key = $Name.ToLowerInvariant()
        if ($w.Dns.ContainsKey($key)) { return [pscustomobject]@{ Ok = $true; Addresses = @($w.Dns[$key]); Error = '' } }
        [pscustomobject]@{ Ok = $true; Addresses = @(); Error = 'DNS name does not exist' }
    }.GetNewClosure()
    $a['LdapSearch'] = {
        param($Request)
        $w.LdapCalls.Add($Request)
        foreach ($rule in $w.Ldap.GetEnumerator()) { if ($Request.Filter -like $rule.Key) { return & $rule.Value $Request } }
        [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @(); AuthFailed = $false; Error = '' }
    }.GetNewClosure()
    $a['ReadNode'] = {
        param($Request)
        $w.NodeReads.Add($Request.Node)
        if ($w.NodeFailures.ContainsKey($Request.Node)) { throw $w.NodeFailures[$Request.Node] }
        $d = & $buildNode -World $w -Name $Request.Node -Infra $infra -Request $Request
        if ($w.NodeData.ContainsKey($Request.Node)) { $d = $w.NodeData[$Request.Node] }
        if ($w.Mutate.ContainsKey($Request.Node)) { & $w.Mutate[$Request.Node] $d $Request }
        $d
    }.GetNewClosure()
    $a['EnvChecker'] = {
        param($Request)
        $w.EcCalls++
        if ($w.Ec) { return $w.Ec }
        $v = @{}
        foreach ($n in $Request.Validators) { $v[$n] = @{ ran = $true; reason = ''; results = @(@{ name = "T-$n"; title = "$n test"; status = 'SUCCESS'; severity = 'CRITICAL'; description = 'ok'; remediation = ''; target = 'x' }) } }
        @{ available = $true; reason = ''; validators = $v }
    }.GetNewClosure()
    foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
    $a
}

function Initialize-PclWorld {
    <# A world and an infrastructure whose LDAP answers say that Active Directory is prepared and DNS has the records. #>
    param([System.Collections.IDictionary]$Infra)
    $w = New-PclWorld
    # The Key Vault secret that holds the local administrator user name (next to the password) says what the file says.
    $pw = ConvertFrom-AzlKeyVaultRef -Reference ([string]$Infra.identity.local_admin.password)
    if ($pw) { $w.Secrets["keyvault://$($pw.Vault)/local-admin-username"] = [string]$Infra.identity.local_admin.username }
    $sid = Get-PclLcmSid
    $isAd = $Infra.scenario.identity -eq 'active_directory'
    if ($isAd) {
        $ad = $Infra.identity.active_directory
        $ou = [string]$ad.ou_path; $lcm = [string]$ad.lcm_user.username
        $isWindows_ = $IsWindows
        $sd = if ($isWindows_) { New-PclSecurityDescriptor -Sid $sid } else { '' }
        $w.Ldap['*objectClass=domainDNS*'] = { param($r) [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @([pscustomobject]@{ distinguishedName = 'DC=improbability,DC=cloud'; dnsHostName = ''; Properties = @{} }); AuthFailed = $false; Error = '' } }
        $w.Ldap['*organizationalUnit*distinguishedName=*'] = {
            param($r)
            $isOu = $r.Filter -like "*$($ou -replace '([\\()*])', '\$1')*" -or $r.Filter -like '*OU=*'
            $props = @{ distinguishedname = @($ou); gpoptions = @(1); gplink = @('') }
            if ($r.Properties -contains 'ntsecuritydescriptor') { $props['ntsecuritydescriptor'] = @($sd) }
            [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @([pscustomobject]@{ distinguishedName = $ou; dnsHostName = ''; Properties = $props }); AuthFailed = $false; Error = '' }
        }.GetNewClosure()
        $w.Ldap['*sAMAccountName=*'] = {
            param($r)
            $props = @{ distinguishedname = @("CN=$lcm,$ou"); useraccountcontrol = @(512); accountexpires = @(0); 'msds-user-account-control-computed' = @(0); userworkstations = @(); objectsid = @([Convert]::ToBase64String(([byte[]]::new(28)))) }
            if ($IsWindows) { $b = [byte[]]::new($sid.BinaryLength); $sid.GetBinaryForm($b, 0); $props['objectsid'] = @([Convert]::ToBase64String($b)) }
            [pscustomobject]@{ Reachable = $true; Server = 'dc01'; Entries = @([pscustomobject]@{ distinguishedName = "CN=$lcm,$ou"; dnsHostName = ''; Properties = $props }); AuthFailed = $false; Error = '' }
        }.GetNewClosure()
        $zone = [string]$ad.domain_fqdn
        foreach ($n in $Infra.nodes) { $m = Get-AzlManagementAdapter -Infrastructure $Infra -Node $n; $w.Dns["$($n.name).$zone".ToLowerInvariant()] = @([string]$m.IpAddress) }
        $w.Dns["$($Infra.cluster.name).$zone".ToLowerInvariant()] = @('192.0.2.20')
    }
    $w
}

function Get-PclInfra {
    <# The ARM test infrastructure (Storage Spaces Direct, mgmt+compute and storage intents), file-backed for the hash. #>
    param([ValidateSet('active_directory', 'local_identity')][string]$Identity = 'active_directory', [ValidateSet('s2d', 'san')][string]$Storage = 's2d', [int]$Nodes = 2)
    $infra = Get-TestInfra -Identity $Identity -Storage $Storage -Nodes $Nodes
    $infra
}

function Write-PclInfraFile {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infra, [Parameter(Mandatory)][string]$Directory)
    $null = New-Item -ItemType Directory -Force -Path $Directory
    $path = Join-Path $Directory 'infrastructure.yml'
    ($Infra | ConvertTo-Yaml) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $path
}

function Invoke-PclRun {
    <# One Verify (or Plan) run with the fake adapter. -World and -Infra default to a healthy pair. #>
    param(
        $World, [System.Collections.IDictionary]$Infra, [string]$Mode = 'Verify', [string]$Dir, [string[]]$AcceptSkipped, [switch]$Fix, [string[]]$Category,
        [hashtable]$Override = @{}, [hashtable]$Settings = @{}, [string]$InfraFile, [string[]]$AcknowledgeKnownIssues, [object]$Handoff, [string]$ExtensionFolder
    )
    if (-not $Infra) { $Infra = Get-PclInfra }
    if (-not $World) { $World = Initialize-PclWorld -Infra $Infra }
    if (-not $Dir) { $Dir = Join-Path $TestDrive ('pcl-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
    if (-not $InfraFile) { $InfraFile = Write-PclInfraFile -Infra $Infra -Directory (Join-Path $Dir 'env') }
    $osReport = Get-TestOsReport -Infra $Infra
    $arguments = @{
        Infrastructure = $Infra; InfrastructureFile = $InfraFile; Mode = $Mode; ReportDirectory = (Join-Path $Dir 'live'); OsConfigurationReport = $osReport
        Adapter = (New-PclAdapter -World $World -Infra $Infra -Override $Override); Settings = $Settings
    }
    # No verification module of the repository runs in these tests: the built-in checks are tested alone (a fake module has its own tests).
    if (-not $ExtensionFolder) { $ExtensionFolder = Join-Path $TestDrive 'no-extensions'; $null = New-Item -ItemType Directory -Force -Path $ExtensionFolder }
    $arguments.ExtensionFolder = $ExtensionFolder
    if ($AcceptSkipped) { $arguments.AcceptSkipped = $AcceptSkipped }
    if ($Fix) { $arguments.Fix = $true }
    if ($Category) { $arguments.Category = $Category }
    if ($AcknowledgeKnownIssues) { $arguments.AcknowledgeKnownIssues = $AcknowledgeKnownIssues }
    $result = Invoke-AzlPreClusterVerification @arguments
    $result | Add-Member -NotePropertyName World -NotePropertyValue $World -Force
    $result | Add-Member -NotePropertyName Infra -NotePropertyValue $Infra -Force
    $result | Add-Member -NotePropertyName InfraFile -NotePropertyValue $InfraFile -Force
    $result
}

function Get-PclCheck($Result, [string]$Id, [string]$Node) {
    @($Result.Checks | Where-Object { $_.Id -eq $Id -and (-not $Node -or $_.Node -eq $Node) })
}

function Read-PclEvent([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

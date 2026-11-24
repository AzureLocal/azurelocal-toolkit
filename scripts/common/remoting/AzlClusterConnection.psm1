#Requires -Version 7.0
<#
.SYNOPSIS
    How a validation or day 2 script of the toolkit reaches a deployed Azure Local instance from the management host: which
    machine to connect to, and as whom. Values come only from the loaded infrastructure file.

.DESCRIPTION
    The scripts of stage 07 (validation and handover) and stage 08 (day 2 operations) ask the cluster over PowerShell remoting.
    The management host that runs the toolkit is often NOT a member of the cluster's domain and does not use its DNS (it is
    the host that provisioned the machines and ran the deployment). So a script cannot rely on the cluster name resolving, on
    the failover clustering tools being installed on the management host, or on the account that runs the script being an
    account of the domain. This module is the one place that decides:

      Target       the machine the cluster questions are sent to. -ComputerName when given. Otherwise the first node of nodes[]
                   with a management address; when that node cannot be reached before the first block (it is down, or in
                   maintenance), the next node of the file is tried and then kept. When nodes[] has no address, cluster.name (the run then needs the name to
                   resolve, as on a host in the domain). WinRM over HTTP is tried first, then HTTPS, per machine.
      Node address the management address of a node, by its name (short or with the domain), for the per-node questions: a
                   second hop from one node to another does not work with the default authentication, so each node is asked
                   from the management host.
      Credential   -Credential when given. Otherwise the deployment (LCM) user of the file, identity.active_directory.lcm_user,
                   read through the toolkit's one secret resolver (Microsoft Learn: use the deployment user account for the
                   update cmdlets; the cluster cmdlets need an account of the domain). When the file has no such user, or its
                   secret cannot be read, no credential is used: the account that runs the script. WinRM takes that account
                   only for a name, not for an IP address, so the run then asks the cluster and the nodes by name (a host of
                   the domain), and the notes say so.
      One run      a block of a caller runs once. Which machine answers, and over which transport, is found with a block that
                   does nothing; a connection error while a real block runs is thrown, not answered with a second run.

    Nothing here changes anything on a machine, and no secret value is logged or returned as text.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'infrastructure', 'AzlInfrastructure.psm1')))
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'secrets', 'AzlSecret.psm1')))


function Get-AzlClusterText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure, [Parameter(Mandatory)][string]$Path)
    ([string](Get-AzlInfrastructureValue -Infrastructure $Infrastructure -Path $Path)).Trim()
}

function Resolve-AzlClusterConnection {
    <#
    .SYNOPSIS
        The connection of a run to the cluster of the infrastructure file: target machine, credential and node addresses.
    .PARAMETER Infrastructure
        The file as read by Import-AzlInfrastructure.
    .PARAMETER ComputerName
        Optional. The machine to send the cluster questions to, instead of the one this function would choose.
    .PARAMETER Credential
        Optional. The account for the remoting sessions, instead of the deployment user of the file.
    .PARAMETER RemoteCommand
        Optional. { param([hashtable]$Call) Invoke-Command @Call }, written in the script that calls this function. The remote calls of the
        connection then run through it, in the scope of that script: a test of the script can replace Invoke-Command there. Without it the
        module calls Invoke-Command itself.
    .OUTPUTS
        ClusterName, Target, TargetSource (Parameter, NodeAddress, ClusterName), Candidates (the machines tried in turn for the
        cluster questions), Credential, CredentialSource (Parameter, DeploymentUser, CurrentAccount), NodeAddress (name to address,
        case-insensitive), Transport (what worked per machine), Notes (what was decided and why).
    .EXAMPLE
        $connection = Resolve-AzlClusterConnection -Infrastructure $infra -Credential $Credential
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Infrastructure,
        [string]$ComputerName,
        [pscredential]$Credential,
        [scriptblock]$RemoteCommand
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    $clusterName = Get-AzlClusterText $Infrastructure 'cluster.name'
    $domain = Get-AzlClusterText $Infrastructure 'identity.active_directory.domain_fqdn'

    # ---- the nodes of the file and their management addresses
    $addresses = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @(Get-AzlInfrastructureNode -Infrastructure $Infrastructure)) {
        if (-not $node.ManagementIp) { continue }
        $addresses[[string]$node.Name] = [string]$node.ManagementIp
        if ($domain) { $addresses["$($node.Name).$domain"] = [string]$node.ManagementIp }
        $ordered.Add($node)
    }

    # ---- the target of the cluster questions
    $target = ''; $source = ''; $candidates = @()
    if ($ComputerName) {
        $target = $(if ($addresses.ContainsKey($ComputerName.Trim())) { [string]$addresses[$ComputerName.Trim()] } else { $ComputerName.Trim() })
        $source = 'Parameter'
        $candidates = @($target)
    }
    elseif ($ordered.Count -gt 0) {
        $candidates = @($ordered | ForEach-Object { [string]$_.ManagementIp })
        $target = $candidates[0]
        $source = 'NodeAddress'
    }
    else {
        $target = $clusterName
        $source = 'ClusterName'
        $candidates = @($target)
        $notes.Add('nodes[] of the file has no management address, so the cluster name is used: it must resolve from this host.')
    }

    # ---- the account
    $credential = $Credential; $credentialSource = 'Parameter'
    if (-not $credential) {
        $credentialSource = 'CurrentAccount'
        $user = Get-AzlClusterText $Infrastructure 'identity.active_directory.lcm_user.username'
        $reference = Get-AzlClusterText $Infrastructure 'identity.active_directory.lcm_user.password'
        if ($user -and $reference -and (Get-AzlSecretProvider -Reference $reference)) {
            try {
                $secret = Get-AzlSecretValue -Reference $reference -Infrastructure $Infrastructure
                $netbios = Get-AzlClusterText $Infrastructure 'identity.active_directory.netbios_name'
                $fullName = if ($user -match '\\|@') { $user } elseif ($netbios) { "$netbios\$user" } elseif ($domain) { "$user@$domain" } else { $user }
                $credential = [pscredential]::new($fullName, $secret)
                $credentialSource = 'DeploymentUser'
            }
            catch { $notes.Add("The secret of the deployment user ($reference) could not be read, so the account that runs the script is used: $($_.Exception.Message)") }
        }
        else { $notes.Add('The file has no deployment user with a secret reference (identity.active_directory.lcm_user), so the account that runs the script is used.') }
    }

    # Without a credential the run is the account that runs the script, and WinRM takes that account only for a NAME (Kerberos, on a host of
    # the domain): an IP address needs an explicit credential. So the addresses of the file are not used then: the cluster questions go to
    # the cluster name and each node is asked by its name, as on a management host that is a member of the domain.
    if (-not $credential -and $source -eq 'NodeAddress') {
        $target = $clusterName
        $source = 'ClusterName'
        $candidates = @($target)
        $addresses = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $notes.Add('No credential: the cluster and its nodes are asked by name, as the account that runs the script (WinRM needs an explicit credential for an IP address). On a host that is not in the domain, give -Credential or make the secret of the deployment user readable.')
    }

    [pscustomobject]@{
        ClusterName      = $clusterName
        Target           = $target
        TargetSource     = $source
        Candidates       = $candidates
        Transport        = @{}
        RemoteCommand    = $RemoteCommand
        Credential       = $credential
        CredentialSource = $credentialSource
        NodeAddress      = $addresses
        Notes            = $notes.ToArray()
    }
}

function Get-AzlClusterNodeAddress {
    <#
    .SYNOPSIS
        The address to connect to for a node name: its management address of the file, else the name itself.
    .EXAMPLE
        Get-AzlClusterNodeAddress -Connection $connection -Node 'iic-n01'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Connection, [Parameter(Mandatory)][string]$Node)
    if ($Connection.NodeAddress.ContainsKey($Node)) { return [string]$Connection.NodeAddress[$Node] }
    $short = ($Node -split '\.')[0]
    if ($Node -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and $Connection.NodeAddress.ContainsKey($short)) { return [string]$Connection.NodeAddress[$short] }
    return $Node
}

function Format-AzlClusterConnection {
    <#
    .SYNOPSIS
        One line for the log: where the run connects and as whom. No secret.
    .EXAMPLE
        Format-AzlClusterConnection -Connection $connection
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Connection)
    $who = switch ($Connection.CredentialSource) {
        'Parameter' { "as $($Connection.Credential.UserName) (-Credential)" }
        'DeploymentUser' { "as $($Connection.Credential.UserName) (the deployment user of the file)" }
        default { 'as the account that runs the script' }
    }
    $where = switch ($Connection.TargetSource) {
        'Parameter' { "$($Connection.Target) (-ComputerName)" }
        'NodeAddress' { "$($Connection.Target) (a node of the file)" }
        default { "$($Connection.Target) (the cluster name)" }
    }
    "Connecting to $where $who."
}

function Connect-AzlClusterMachine {
    # Finds out how one machine is reached, with a block that does nothing: WinRM over HTTP first, then HTTPS when the HTTP connection fails.
    # What worked is remembered per machine. Throws the first connection error when neither answers. Only this probe is ever tried twice:
    # the block of a caller runs once, over the transport the probe found (see Invoke-AzlClusterRemote).
    param([object]$Connection, [string]$Computer)
    if ($Connection.Transport.ContainsKey($Computer)) { return }
    $run = if ($Connection.RemoteCommand) { $Connection.RemoteCommand } else { { param([hashtable]$Call) Invoke-Command @Call } }
    $call = @{ ComputerName = $Computer; ScriptBlock = { $true }; ErrorAction = 'Stop' }
    if ($Connection.Credential) { $call.Credential = $Connection.Credential }
    try { $null = & $run $call; $Connection.Transport[$Computer] = 'http'; return }
    catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        $first = $_
        $call.UseSSL = $true
        try { $null = & $run $call; $Connection.Transport[$Computer] = 'https'; return }
        catch [System.Management.Automation.Remoting.PSRemotingTransportException] { throw $first }
    }
}

function Invoke-AzlClusterRemote {
    # One machine, one run of the block. The transport comes from the probe; a connection error while the block runs is not answered with a
    # second try, because the block may have run in part (a volume being created, an update being started).
    param([object]$Connection, [string]$Computer, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    Connect-AzlClusterMachine -Connection $Connection -Computer $Computer
    $call = @{ ComputerName = $Computer; ScriptBlock = $ScriptBlock; ErrorAction = 'Stop' }
    if ($ArgumentList.Count -gt 0) { $call.ArgumentList = $ArgumentList }
    if ($Connection.Credential) { $call.Credential = $Connection.Credential }
    if ([string]$Connection.Transport[$Computer] -eq 'https') { $call.UseSSL = $true }
    $run = if ($Connection.RemoteCommand) { $Connection.RemoteCommand } else { { param([hashtable]$Call) Invoke-Command @Call } }
    & $run $call
}

function Invoke-AzlClusterCommand {
    <#
    .SYNOPSIS
        Runs a script block on the cluster target, or on one node, over PowerShell remoting with the credential of the connection.
    .DESCRIPTION
        Without -Node the block runs on the target of the connection. Before the first block, the target is probed with a block that does
        nothing; when it cannot be reached (a connection error), the other machines of Candidates are probed in the order of the file, and
        the first that answers becomes the target for the rest of the run. The block of the caller then runs once, on that machine: a
        connection error while it runs is thrown, never answered with a second run on another machine or over another transport, because
        the block may have run in part. With -Node the block runs on that node only.
    .PARAMETER Node
        Optional. A node name: the block runs on that node (at its management address of the file). Without it, on the target.
    .EXAMPLE
        Invoke-AzlClusterCommand -Connection $connection -ScriptBlock { Get-ClusterNode }
    .EXAMPLE
        Invoke-AzlClusterCommand -Connection $connection -Node 'iic-n01' -ScriptBlock { param($Name) Get-NetAdapter -Name $Name } -ArgumentList 'Port1'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [string]$Node,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    if ($Node) { return Invoke-AzlClusterRemote -Connection $Connection -Computer (Get-AzlClusterNodeAddress -Connection $Connection -Node $Node) -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList }
    if (-not $Connection.Transport.ContainsKey([string]$Connection.Target)) {
        $order = @([string]$Connection.Target) + @(@($Connection.Candidates) | Where-Object { $_ -ne [string]$Connection.Target })
        $firstError = $null; $reached = ''
        foreach ($computer in $order) {
            try { Connect-AzlClusterMachine -Connection $Connection -Computer $computer; $reached = $computer; break }
            catch [System.Management.Automation.Remoting.PSRemotingTransportException] { if (-not $firstError) { $firstError = $_ } }
        }
        if (-not $reached) { throw $firstError }
        if ($reached -ne [string]$Connection.Target) { Write-Warning "$($Connection.Target) could not be reached; $reached is used for the cluster questions from here on."; $Connection.Target = $reached }
    }
    Invoke-AzlClusterRemote -Connection $Connection -Computer ([string]$Connection.Target) -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}
Export-ModuleMember -Function Resolve-AzlClusterConnection, Get-AzlClusterNodeAddress, Format-AzlClusterConnection, Invoke-AzlClusterCommand

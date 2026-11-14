#Requires -Version 7.0
<#
.SYNOPSIS
    The one list of outbound endpoints the pre-cluster verification tests (AZ-023, NW-005, ID-DNS-003). A library module: it exports no check and no adapter.

.DESCRIPTION
    Every entry comes from Microsoft Learn, view azloc-2610:
      - Firewall requirements for Azure Local, "Required firewall URLs": the consolidated endpoint lists (East US, West Europe, Australia East, Canada Central, India
        Central, Southeast Asia, Japan East, South Central US) in github.com/Azure/AzureStack-Tools/tree/master/HCI, which Learn names as the list to allow.
      - Azure Arc-enabled servers, Connected Machine agent network requirements (regional token endpoint <region>.login.microsoft.com, the service tags).
    Nothing here comes from memory. The substitution rules are the ones the lists show:
      - {region}: the Azure region name without spaces, lower case (eastus). Used where the lists write the region: <region>.dp.kubernetesconfiguration.azure.com,
        <region>.dp.prod.appliances.azure.com, <region>-gas.guestconfiguration.azure.com, <region>.login.microsoft.com, <region>-shared.prod.warm.ingest.monitor.core.windows.net.
      - The Arc hybrid identity endpoint uses a short code, not the region name, and Learn gives it only for the regions of the consolidated lists
        (eastus eus, westeurope weu, australiaeast ae, canadacentral cc, centralindia pn, southeastasia sea, japaneast je, southcentralus scus). For another region the
        short code is not documented, so that one endpoint is NOT tested and the result says so. The host <region>.his.arc.azure.com does not exist and is never tested.
      - South Central US writes scus.dp.prod.appliances.azure.com (the short code) for the appliance data plane.
    Wildcard entries (*.servicebus.windows.net and others), entries that need a name of yours (the Arc gateway endpoint id, your Key Vault), UDP entries and the
    entries Learn marks as needed only after the deployment cannot be tested as a host, and are listed by Get-AzlEndpointNotTested.

    Tier Required: the endpoint is in the list and nothing in the list says it is conditional. Optional: the list says it is conditional or only revocation traffic
    (raw.githubusercontent.com is not required on 2504 and later new deployments, azurestackhci.azurefd.net is the previous data plane URL, CRL and OCSP hosts on port 80).
    An unreachable Optional endpoint is a Warning, an unreachable Required one is a Failed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DocList = 'Learn: concepts/firewall-requirements (Required firewall URLs), consolidated endpoint list of the region'
$script:DocArc = 'Learn (azure-arc): servers/network-requirements'

# Short codes and the appliance code of the regions whose consolidated list Learn publishes.
$script:Region = @{
    eastus         = @{ His = 'eus'; Appliances = 'eastus' }
    westeurope     = @{ His = 'weu'; Appliances = 'westeurope' }
    australiaeast  = @{ His = 'ae'; Appliances = 'australiaeast' }
    canadacentral  = @{ His = 'cc'; Appliances = 'canadacentral' }
    centralindia   = @{ His = 'pn'; Appliances = 'centralindia' }
    southeastasia  = @{ His = 'sea'; Appliances = 'southeastasia' }
    japaneast      = @{ His = 'je'; Appliances = 'japaneast' }
    southcentralus = @{ His = 'scus'; Appliances = 'scus' }
}

# Host (with {region}, {his}, {appliances}), Port, Group, Tier, Note.
# The list is fixed by Microsoft, not a choice of the deployment: it is the consolidated list Learn publishes (see the description above), so it is a constant of this
# module. The only deployment value in it is the Azure region (azure.location), which fills {region}, {his} and {appliances}.
$script:Entry = @(
    # Arc agent (Azure Local Arc agent in the lists; the Connected Machine agent page)
    ,@('download.microsoft.com', 443, 'Arc', 'Required', 'Windows installation package of the Arc agent')
    ,@('pas.windows.net', 443, 'Arc', 'Required', 'Microsoft Entra ID')
    ,@('guestnotificationservice.azure.com', 443, 'Arc', 'Required', 'notification service for extensions and connectivity')
    ,@('gbl.his.arc.azure.com', 443, 'Arc', 'Required', 'global metadata and hybrid identity')
    ,@('{his}.his.arc.azure.com', 443, 'Arc', 'Required', 'regional metadata and hybrid identity (short code of the region)')
    ,@('{region}-gas.guestconfiguration.azure.com', 443, 'Arc', 'Required', 'extension and guest configuration of the region')
    ,@('agentserviceapi.guestconfiguration.azure.com', 443, 'Arc', 'Required', 'notification service for extensions and connectivity')
    # Authentication
    ,@('login.microsoftonline.com', 443, 'Auth', 'Required', 'Microsoft Entra authority, authentication and token validation')
    ,@('login.microsoft.com', 443, 'Auth', 'Required', 'fetch and update Azure Resource Manager tokens')
    ,@('{region}.login.microsoft.com', 443, 'Auth', 'Required', 'regional Microsoft Entra token endpoint (Arc agent page)')
    ,@('login.windows.net', 443, 'Auth', 'Required', 'Microsoft Entra ID')
    ,@('graph.windows.net', 443, 'Auth', 'Required', 'Graph authentication and token validation')
    ,@('graph.microsoft.com', 443, 'Auth', 'Required', 'Graph authentication and ARB role based access')
    ,@('sts.windows.net', 443, 'Auth', 'Required', 'Cluster Connect and Custom Location scenarios')
    # Management and deployment
    ,@('management.azure.com', 443, 'Management', 'Required', 'cluster registration, bootstrapping and management')
    ,@('portal.azure.com', 443, 'Management', 'Required', 'Azure Local deployment')
    ,@('aka.ms', 443, 'Management', 'Required', 'resolves addresses for discovering Azure Local')
    # Data planes (Resource Bridge and Kubernetes configuration)
    ,@('{region}.dp.kubernetesconfiguration.azure.com', 443, 'DataPlane', 'Required', 'Arc Kubernetes data plane of the region, initial validation')
    ,@('{appliances}.dp.prod.appliances.azure.com', 443, 'DataPlane', 'Required', 'Azure Resource Bridge data plane operations in the region')
    # Deployment
    ,@('www.powershellgallery.com', 443, 'Deployment', 'Required', 'PowerShell Gallery modules for Arc registration')
    ,@('hciarcvmscontainerregistry.azurecr.io', 443, 'Deployment', 'Required', 'Arc VM container registry')
    ,@('azurestackreleases.download.prss.microsoft.com', 443, 'Deployment', 'Required', 'Arc extensions deployment')
    ,@('settings-win.data.microsoft.com', 443, 'Deployment', 'Required', 'Azure Local deployment')
    ,@('msk8s.api.cdp.microsoft.com', 443, 'Deployment', 'Required', 'product catalog, bits and OS images')
    ,@('msk8s.sb.tlu.dl.delivery.mp.microsoft.com', 443, 'Deployment', 'Required', 'Arc Resource Bridge OS images')
    ,@('packages.microsoft.com', 443, 'Deployment', 'Required', 'Linux installation package (Resource Bridge)')
    ,@('k8connecthelm.azureedge.net', 443, 'Deployment', 'Required', 'deploy the Azure Arc agent (Resource Bridge)')
    ,@('k8sconnectcsp.azureedge.net', 443, 'Deployment', 'Required', 'Custom Location')
    ,@('kvamanagementoperator.azurecr.io', 443, 'Deployment', 'Required', 'artifacts for appliance-managed components')
    ,@('arcplatformcliextprod.z13.web.core.windows.net', 443, 'Deployment', 'Required', 'deploying Resource Bridge extensions')
    ,@('hciarcvmsstorage.z13.web.core.windows.net', 443, 'Deployment', 'Required', 'storage for the stack-hci-vm CLI extension files')
    ,@('go.microsoft.com', 443, 'Deployment', 'Required', 'Microsoft Update')
    # Billing and diagnostics
    ,@('dp.stackhci.azure.com', 443, 'Billing', 'Required', 'data plane diagnostics and billing')
    ,@('licensing.platform.edge.azure.com', 443, 'Billing', 'Required', 'licensing billing data')
    ,@('billing.platform.edge.azure.com', 443, 'Billing', 'Required', 'licensing billing data')
    ,@('azurestackhci.azurefd.net', 443, 'Billing', 'Optional', 'previous data plane URL, kept for compatibility')
    # Monitoring
    ,@('global.prod.microsoftmetrics.com', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('prod5.prod.microsoftmetrics.com', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('dc.services.visualstudio.com', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('qos.prod.warm.ingest.monitor.core.windows.net', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('{region}-shared.prod.warm.ingest.monitor.core.windows.net', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry of the region (deployment)')
    ,@('gcs.prod.monitoring.core.windows.net', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('adhs.events.data.microsoft.com', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('v20.events.data.microsoft.com', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    ,@('prod5.prod.hot.ingestion.msftcloudes.com', 443, 'Monitoring', 'Required', 'periodic Microsoft-required diagnostic data')
    ,@('azurewatsonanalysis-prod.core.windows.net', 443, 'Monitoring', 'Required', 'metrics and monitoring telemetry')
    # AKS infrastructure and container registries
    ,@('mcr.microsoft.com', 443, 'Aks', 'Required', 'official Microsoft artifacts (container images)')
    ,@('westus.data.mcr.microsoft.com', 443, 'Aks', 'Optional', 'West US site for official artifacts (the lists carry the sites of other regions as alternatives)')
    ,@('northeurope.data.mcr.microsoft.com', 443, 'Aks', 'Optional', 'North Europe site for official artifacts (alternative)')
    ,@('westeurope.data.mcr.microsoft.com', 443, 'Aks', 'Optional', 'Western Europe site for official artifacts (alternative)')
    ,@('azurearcfork8s.azurecr.io', 443, 'Aks', 'Required', 'official artifacts (container images)')
    ,@('linuxgeneva-microsoft.azurecr.io', 443, 'Aks', 'Required', 'official artifacts (container images)')
    ,@('azurearcfork8sdev.azurecr.io', 443, 'Aks', 'Required', 'official artifacts (container images)')
    ,@('hybridaks.azurecr.io', 443, 'Aks', 'Required', 'official artifacts (container images)')
    ,@('aszk8snetworking.azurecr.io', 443, 'Aks', 'Required', 'official artifacts (container images)')
    ,@('ecpacr.azurecr.io', 443, 'Aks', 'Required', 'official artifacts (container images)')
    ,@('edgesupprd.trafficmanager.net', 443, 'Aks', 'Required', 'Remote Support extension')
    ,@('raw.githubusercontent.com', 443, 'Aks', 'Optional', 'GitHub; the list says it is not required on 2504 and later new deployments')
    # Certificate revocation and connectivity (HTTP, port 80)
    ,@('crl3.digicert.com', 80, 'Crl', 'Optional', 'attestation CRL')
    ,@('crl4.digicert.com', 80, 'Crl', 'Optional', 'attestation CRL')
    ,@('crl.microsoft.com', 80, 'Crl', 'Optional', 'CRL for the mandatory Arc extensions (path /pkiinfra)')
    ,@('www.microsoft.com', 80, 'Crl', 'Optional', 'CRL for Microsoft Code Signing PCA2011 (path /pkiops)')
    ,@('ctldl.windowsupdate.com', 80, 'Crl', 'Optional', 'Windows certificate trust and untrusted-certificate lists')
    ,@('oneocsp.microsoft.com', 80, 'Crl', 'Optional', 'OCSP of public authorities')
    ,@('ts-crl.ws.symantec.com', 80, 'Crl', 'Optional', 'CRL of public authorities')
    ,@('ts-ocsp.ws.symantec.com', 80, 'Crl', 'Optional', 'OCSP of public authorities')
    ,@('s.symcd.com', 80, 'Crl', 'Optional', 'CRL of public authorities')
    ,@('ocsp.digicert.com', 80, 'Crl', 'Optional', 'OCSP of public authorities')
    ,@('ocsp.globalsign.com', 80, 'Crl', 'Optional', 'OCSP of public authorities')
    ,@('ocsp2.globalsign.com', 80, 'Crl', 'Optional', 'OCSP of public authorities')
    ,@('www.msftconnecttest.com', 80, 'Crl', 'Optional', 'Windows outbound connectivity validation during bootstrap (path /connecttest.txt)')
)

# Documented entries that are not tested as a host.
$script:NotTested = @(
    ,@('*.do.dsp.mp.microsoft.com, *.prod.do.dsp.mp.microsoft.com', 'wildcard (AKS Arc VHD image download)')
    ,@('*.prod.hot.ingest.monitor.core.windows.net', 'wildcard (diagnostic data)')
    ,@('azgn*.servicebus.windows.net, *.servicebus.windows.net', 'wildcard (Learn: GET https://guestnotificationservice.azure.com/urls/allowlist?api-version=2020-01-01&location=<region> lists the concrete names)')
    ,@('*.waconazure.com', 'wildcard (Windows Admin Center, only if used)')
    ,@('*.blob.core.windows.net, *.blob.storage.azure.net', 'wildcard (multiple components)')
    ,@('*.endpoint.security.microsoft.com', 'wildcard (only with the Defender extension)')
    ,@('*.his.arc.azure.com, *.guestconfiguration.azure.com, *.dp.kubernetesconfiguration.azure.com, *.login.microsoft.com', 'wildcards of the Arc pages; the concrete hosts of the region are tested instead')
    ,@('yourarcgatewayendpointid.gw.arc.azure.com', 'needs the id of your Arc gateway (checked by AZ-022)')
    ,@('yourhcikeyvaultname.vault.azure.net', 'needs the name of your Key Vault (checked by AZ-010 to AZ-012)')
    ,@('time.windows.com', 'UDP 123 (not a TCP probe)')
    ,@('{region}.obo.arc.azure.com:8084', 'Learn marks it as the initial validation after the deployment')
)

function Get-AzlEndpointRegion {
    <#
    .SYNOPSIS
        The region name as the lists write it (no spaces, lower case), whether Learn publishes a consolidated list for it, and its codes.
    #>
    [CmdletBinding()]
    param([string]$Location)
    $name = ([string]$Location -replace '[\s_-]', '').ToLowerInvariant()
    if ($script:Region.ContainsKey($name)) {
        return [pscustomobject]@{ Name = $name; Documented = $true; His = [string]$script:Region[$name].His; Appliances = [string]$script:Region[$name].Appliances }
    }
    return [pscustomobject]@{ Name = $name; Documented = $false; His = ''; Appliances = $name }
}

function Get-AzlEndpointSet {
    <#
    .SYNOPSIS
        The concrete hosts to test for -Location: Host, Port, Group, Tier (Required or Optional), Note, Doc. -Group narrows it (Arc, Auth, Management,
        DataPlane, Deployment, Billing, Monitoring, Aks, Crl). Never a wildcard, never a name that is not in the documented list.
    #>
    [CmdletBinding()]
    param([string]$Location, [string[]]$Group, [int[]]$Port)
    $region = Get-AzlEndpointRegion -Location $Location
    foreach ($e in $script:Entry) {
        if ($Group -and $e[2] -notin $Group) { continue }
        if ($Port -and [int]$e[1] -notin $Port) { continue }
        $hostName = [string]$e[0]
        if ($hostName.Contains('{his}')) { if (-not $region.His) { continue }; $hostName = $hostName.Replace('{his}', $region.His) }
        if ($hostName.Contains('{region}')) { if (-not $region.Name) { continue }; $hostName = $hostName.Replace('{region}', $region.Name) }
        if ($hostName.Contains('{appliances}')) { if (-not $region.Name) { continue }; $hostName = $hostName.Replace('{appliances}', $region.Appliances) }
        [pscustomobject]@{ Host = $hostName; Port = [int]$e[1]; Group = [string]$e[2]; Tier = [string]$e[3]; Note = [string]$e[4]; Doc = $(if ($e[2] -eq 'Auth' -or $e[2] -eq 'Arc') { "$script:DocList; $script:DocArc" } else { $script:DocList }) }
    }
}

function Get-AzlEndpointNotTested {
    <#
    .SYNOPSIS
        The documented entries that are not tested as a host, with the reason: wildcards, names that need yours, UDP, post-deployment. For a region whose
        Arc hybrid identity short code Learn does not publish, that one endpoint is listed too.
    #>
    [CmdletBinding()]
    param([string]$Location)
    $region = Get-AzlEndpointRegion -Location $Location
    foreach ($n in $script:NotTested) { [pscustomobject]@{ Entry = ([string]$n[0]).Replace('{region}', $(if ($region.Name) { $region.Name } else { '<region>' })); Reason = [string]$n[1] } }
    if ($region.Name -and -not $region.Documented) {
        [pscustomobject]@{ Entry = '<code>.his.arc.azure.com'; Reason = "the short code of $($region.Name) is not in the consolidated lists of Learn, so the regional hybrid identity endpoint is not tested (gbl.his.arc.azure.com is)" }
    }
}

function Format-AzlEndpointNotTested {
    <#
    .SYNOPSIS
        One sentence for a result: which documented entries were not tested and why (wildcards in short).
    #>
    [CmdletBinding()]
    param([string]$Location)
    $rows = @(Get-AzlEndpointNotTested -Location $Location)
    $wild = @($rows | Where-Object { $_.Reason -like 'wildcard*' } | ForEach-Object { $_.Entry })
    $other = @($rows | Where-Object { $_.Reason -notlike 'wildcard*' } | ForEach-Object { "$($_.Entry) ($($_.Reason))" })
    "Not tested because they are not concrete hosts: wildcards $($wild -join ' | ')$(if ($other) { '; ' + ($other -join '; ') })."
}

Export-ModuleMember -Function Get-AzlEndpointRegion, Get-AzlEndpointSet, Get-AzlEndpointNotTested, Format-AzlEndpointNotTested

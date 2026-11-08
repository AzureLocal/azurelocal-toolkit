@{
    # Facts the JSON schema doesn't hold, for scripts/common/infrastructure/New-InfrastructureVariablesReference.ps1, which
    # renders config/infrastructure/VARIABLES.md. Patterns are regular expressions over the key path, with [] for array items
    # (nodes[].bmc.ip_address). The first match wins.

    # Keys azurelocal-ztp reads: ConvertFrom-ZtpInfrastructureV5 in azurelocal-ztp (scripts/simplified-provisioning/
    # ZtpEnvironment.Common.ps1), plus the 5.3 and 5.4 keys.
    Ztp           = @(
        '^_metadata\.(schema_version|scope)$'
        '^scenario\.os_install$'
        '^azure\.(tenant_id|location|subscription_id|resource_group|hci_resource_provider_object_id)$'
        '^site\.(code|name|time_zone)$'
        '^tags(\.|$)'
        '^key_vaults(\[\]|$)'
        '^nodes\[\]\.(name|arc_machine_name|arc_resource_name|serial_number|rack_position|maintenance_address)$'
        '^nodes\[\]\.bmc\.ip_address$'
        '^nodes\[\]\.(bios|bios_during_provisioning)(\.|$)'
        '^nodes\[\]\.management(\.|$)'
        '^nodes\[\]\.network_adapters(\[\]\.(name|mac_address|slot|roles|ip_assignment|ip_address|vlan_id|vlan_mode))?$'
        '^nodes\[\]\.san(\.hbas(\[\]\.(slot|type|bios_attribute|bios_disabled_value|bios_enabled_value))?)?$'
        '^hardware\.(vendor|model)$'
        '^hardware\.bmc(\.|$)'
        '^hardware\.(bios|bios_during_provisioning)(\.|$)'
        '^hardware\.sbe\.(bundle_path|allow_unvalidated)$'
        '^networking\.management\.(subnet|gateway|dns_servers|vlan_id|ip_assignment|site_ip_range|provisioning_network|static_method|provisioning_dhcp_range)(\.|$)'
        '^networking\.ntp_servers$'
        '^identity\.local_admin(\.|$)'
        '^provisioning\.os_version$'
        '^provisioning\.simplified(\.|$)'
    )

    # The toolkit's OS configuration phase (what its scripts read through Import-AzlInfrastructure). By design, by section.
    OsConfiguration = @(
        '^nodes\[\]\.(name|arc_machine_name|management|network_adapters|storage_ips|bios)'
        '^hardware\.(vendor|model|network_cards)'
        '^networking\.(management|ntp_servers|intents|storage|vlans|cluster_networks)'
        '^identity\.local_admin'
        '^cluster\.name$'
        '^provisioning\.os_version$'
        '^os_configuration(\.|$)'
    )

    # Keys the ARM and SAN deployment reads beyond those whose schema description names an ARM parameter.
    ArmDeployment = @(
        '^storage\.san(\.|$)'
        '^nodes\[\]\.san(\.|$)'
    )

    # Keys Trailwright does not write: host-local paths and files only the operator sets on the management host.
    TrailwrightNot = @(
        '^os_configuration(\.|$)'
        '^provisioning\.simplified\.(media_path|evidence_path|maintenance_password|media_share|timeouts|usb_image|maintenance_environment|deployment_name|skip_azure_check|include_preview|max_train|retry_provision_os)'
        '^hardware\.sbe\.bundle_path$'
        '^nodes\[\]\.maintenance_address$'
    )

    # Where to get the value. The first matching pattern wins.
    Sources       = @(
        @{ Pattern = '^_metadata\.schema_version$'; Text = 'Set by the template (5.3.0). Change it only with a migration.' }
        @{ Pattern = '^_metadata\.scope$'; Text = 'You: ztp for a file used by azurelocal-ztp alone, full for everything.' }
        @{ Pattern = '^_metadata\.'; Text = 'You: bookkeeping for the file.' }
        @{ Pattern = '^scenario\.'; Text = 'Your design decisions. The README lists what each choice makes required.' }
        @{ Pattern = '^site\.'; Text = 'Your site record: the customer, the location and its time zone (Windows name, for example Central Standard Time).' }
        @{ Pattern = '^environment\.'; Text = 'Your naming for the instance.' }
        @{ Pattern = '^tags\.'; Text = 'Your tagging policy.' }
        @{ Pattern = '^azure\.hci_resource_provider_object_id$'; Text = 'Microsoft Entra ID: the object ID of the Microsoft.AzureStackHCI Resource Provider service principal in your tenant.' }
        @{ Pattern = '^azure\.tenant_id$'; Text = 'Azure portal > Microsoft Entra ID > Overview, or az account show.' }
        @{ Pattern = '^azure\.subscription_id$'; Text = 'Azure portal > Subscriptions, or az account show.' }
        @{ Pattern = '^azure\.location$'; Text = 'Your Azure design. Simplified provisioning works in eastus only in the preview.' }
        @{ Pattern = '^azure\.resource_group$'; Text = 'Your Azure design: the resource group for the Arc machines and the site.' }
        @{ Pattern = '^azure\.'; Text = 'Your Azure design (the automation identity and custom location names).' }
        @{ Pattern = '^key_vaults'; Text = 'Azure portal > Key vaults. List every vault a keyvault:// reference names.' }
        @{ Pattern = '^cluster\.'; Text = 'Your naming standard and witness design.' }
        @{ Pattern = '^nodes\[\]\.serial_number$'; Text = 'The machine''s label or its BMC (the Dell service tag).' }
        @{ Pattern = '^nodes\[\]\.bmc\.ip_address$'; Text = 'Your out-of-band addressing plan; the BMC''s web page shows it.' }
        @{ Pattern = '^nodes\[\]\.bmc\.'; Text = 'The BMC (iDRAC, iLO, XCC).' }
        @{ Pattern = '^nodes\[\]\.network_adapters\[\]\.mac_address$'; Text = 'The BMC''s network-device inventory (Redfish EthernetInterfaces), the vendor''s order sheet, or the port label.' }
        @{ Pattern = '^nodes\[\]\.network_adapters\[\]\.switch_port'; Text = 'Your cabling record.' }
        @{ Pattern = '^nodes\[\]\.network_adapters'; Text = 'Your network design and the machine''s hardware inventory.' }
        @{ Pattern = '^nodes\[\]\.maintenance_address$'; Text = 'The DHCP lease or reservation of the machine while it runs the maintenance environment (its console shows it).' }
        @{ Pattern = '^nodes\[\]\.(bios|bios_during_provisioning)'; Text = 'The BMC''s Redfish Bios resource (Attributes of /redfish/v1/Systems/<id>/Bios) or the vendor''s BIOS attribute registry.' }
        @{ Pattern = '^nodes\[\]\.san'; Text = 'The SAN administrator: the HBA utility or the fabric switch''s name server (WWPNs), the initiator name from the OS (IQN).' }
        @{ Pattern = '^nodes\[\]\.'; Text = 'Your machine inventory and addressing plan.' }
        @{ Pattern = '^hardware\.sbe\.bundle_path$'; Text = 'A folder you create on the management host (see Folders), holding the OEM''s Solution Builder Extension as downloaded.' }
        @{ Pattern = '^hardware\.sbe\.'; Text = 'The OEM''s Solution Builder Extension release notes.' }
        @{ Pattern = '^hardware\.bmc\.(rfs_write_attribute|verify_certificate)$'; Text = 'Your BMC: the vendor''s default is right unless the BMC firmware differs.' }
        @{ Pattern = '^hardware\.bmc\.'; Text = 'A Key Vault secret you create holding the BMC login (see Secrets).' }
        @{ Pattern = '^hardware\.(bios|bios_during_provisioning)'; Text = 'The BMC''s Redfish Bios resource or the vendor''s BIOS attribute registry.' }
        @{ Pattern = '^hardware\.'; Text = 'The hardware you ordered.' }
        @{ Pattern = '^networking\.management\.provisioning_dhcp_range'; Text = 'The DHCP scope on the provisioning network (your DHCP server).' }
        @{ Pattern = '^networking\.management\.'; Text = 'Your IP plan for the management network.' }
        @{ Pattern = '^networking\.'; Text = 'Your network design; Trailwright guides it.' }
        @{ Pattern = '^identity\.local_admin'; Text = 'You choose the name; the password is a Key Vault secret you create (see Secrets).' }
        @{ Pattern = '^identity\.'; Text = 'Your Active Directory and Microsoft Entra ID teams.' }
        @{ Pattern = '^storage\.san\.'; Text = 'The SAN administrator: the array manager and the fabric switches.' }
        @{ Pattern = '^storage\.'; Text = 'Your storage design.' }
        @{ Pattern = '^provisioning\.simplified\.(isolate_san_adapters|enable_embedded_nics)$'; Text = 'Your hardware design: whether a SAN adapter (nodes[].san.hbas) or an onboard NIC (a port with slot Embedded) needs a BIOS action while the OS installs. The default follows the inventory.' }
        @{ Pattern = '^provisioning\.simplified\.(create_resource_group|configuration_name|managed_resource_group_name|apply_site_settings|use_key_vault_configuration|assign_provisioning_roles|assign_hci_rp_role|network_kind|ntp|site_mode|deployment_name)'; Text = 'Your Azure design for the Microsoft.Edge site and its configuration. The defaults are the portal''s.' }
        @{ Pattern = '^provisioning\.simplified\.(skip_azure_check|include_preview|max_train|retry_provision_os|timeouts|usb_image|maintenance_environment)'; Text = 'Optional tuning of azurelocal-ztp. The default is the value that worked on Dell AX servers; change it only when a stage fails for a reason your hardware or network explains.' }

        @{ Pattern = '^provisioning\.simplified\.maintenance_iso$'; Text = 'Azure portal > Azure Arc > Machine Provisioning > View downloads, or a Microsoft download URL.' }
        @{ Pattern = '^provisioning\.simplified\.(media_path|evidence_path)$'; Text = 'A folder you create on the management host (see Folders).' }
        @{ Pattern = '^provisioning\.simplified\.media_share'; Text = 'The management host: the share and the address the BMCs reach it on.' }
        @{ Pattern = '^provisioning\.simplified\.(admin|maintenance_password)'; Text = 'A Key Vault secret you create (see Secrets).' }
        @{ Pattern = '^os_configuration\.network\.confirm_minutes$'; Text = 'You: leave 10 unless a switch or a firewall takes longer than that to pass traffic on the new address. The node reverts by itself when the orchestrator does not confirm in time.' }
        @{ Pattern = '^os_configuration\.network\.stable_seconds$'; Text = 'You: leave 60. Longer waits for a slow spanning tree.' }
        @{ Pattern = '^os_configuration\.remoting\.transport$'; Text = 'You: winrm from a jump server or a runner with a route to the management network. arc only for a site with no route.' }
        @{ Pattern = '^os_configuration\.remoting\.bootstrap_transport$'; Text = 'You: arc when the nodes are fresh from ZTP and your runner is on another subnet than the nodes (their firewall allows their own subnet only). Used once per node.' }
        @{ Pattern = '^os_configuration\.remoting\.allowed_source_cidrs$'; Text = 'You: the CIDRs of the jump server or runner. The management network is always added.' }
        @{ Pattern = '^os_configuration\.clear_storage$'; Text = 'You: true when the machines are re-used and must start with no leftover storage. The OS configuration run lists the disks it would wipe before it wipes them.' }
        @{ Pattern = '^provisioning\.'; Text = 'The OS release you pin, from the release notes of Azure Local.' }
        @{ Pattern = '^security\.'; Text = 'Your security baseline; Microsoft''s recommended defaults apply when omitted.' }
        @{ Pattern = '^operations\.'; Text = 'Your operations design.' }
        @{ Pattern = '^network_devices'; Text = 'Your network inventory.' }
        @{ Pattern = '^(landing_zone|devops)'; Text = 'Your Azure foundation design (parts 1 and 2 of the implementation steps).' }
        @{ Pattern = '^disconnected'; Text = 'Your disconnected-operations design.' }
        @{ Pattern = '^sdn'; Text = 'Your SDN design.' }
        @{ Pattern = '^extensions'; Text = 'Anything the schema doesn''t define; tools ignore keys they don''t own.' }
    )

    # What makes a key required besides its parent. These are written by hand where the schema expresses the condition inside
    # a definition; the scenario-driven conditions are read from the schema itself. The text goes in the full-scope cell.
    Conditions    = @{
        'nodes[].management'                                  = 'one of management or network_adapters'
        'nodes[].management.mac_address'                      = 'os_install simplified and no network_adapters'
        'nodes[].network_adapters'                            = 'one of management or network_adapters (simplified: a provisioning port too)'
        'nodes[].network_adapters[].mac_address'              = 'dhcp_reservation, or a management port with os_install simplified'
        'nodes[].network_adapters[].ip_address'               = 'ip_assignment static or dhcp_reservation'
        'storage.san.fibre_channel'                           = 'storage.san.type is fibre_channel'
        'storage.san.iscsi'                                   = 'storage.san.type is iscsi'
        'storage.san.fibre_channel.target_wwpns'              = 'always for fibre_channel (rule AZL-028)'
        'storage.san.iscsi.targets'                           = 'always for iscsi (rule AZL-028)'
        'nodes[].san'                                         = 'storage.san is set (rule AZL-028)'
        'nodes[].san.hbas'                                    = 'storage.san.type is fibre_channel'
        'nodes[].san.initiator_iqn'                           = 'storage.san.type is iscsi'
        'networking.management.infrastructure_pool'           = 'use_dhcp is not true'
        'storage.san.iscsi.chap.username'                     = 'chap.enabled is true'
        'storage.san.iscsi.chap.secret'                       = 'chap.enabled is true'
    }
}

# The ONE table of Invoke-AzureLocalPostDeployment.ps1: which steps the post-deployment phase has, in which order, which script runs each one, and
# which keys of infrastructure.yml decide whether a step applies. The order is the order of the pages of the Implementation guide
# (docs/implementation/04-cluster-deployment/phase-06-post-deployment/task-NN-*.mdx). tests/post-deployment/PostDeploymentSteps.Tests.ps1 compares this
# table with those pages in the local docs clone (the list of pages, their order, and the script each page names), so the guide and the orchestrator
# cannot drift apart. Nothing about the order or the applicability is written anywhere else.
#
# Every step is a task script that also runs ALONE, with only its own parameters (-InfrastructureFile, -WhatIf, -LogPath, -ComputerName, -Credential).
# The orchestrator calls those public parameters and nothing else: no state, no file and no variable passes from one step to the next, and each
# script checks its own preconditions from the file and from Azure and the cluster.
#
# Fields of a step
#   Id            The name of the step for -Only, -From, -To and operations.post_cluster.skip_steps (the registry lists the same names as the enum of skip_steps).
#   Task          The page of the guide: the file name of the page without .mdx. A task can have more than one step (task 05 has two). -Only task-05 runs both.
#   Title         What the step does, for the summary.
#   Script        The PowerShell script, relative to the repository root. AzureCliScript is its Azure CLI twin (the other tab of the page), run with -Route AzureCli;
#                 absent when the page has none (or when the twin is only part of what the script does).
#   ScriptOnPage  false when the page does not name the script (task 10 describes the steps by hand; the script does them).
#   Plan          WhatIf: Plan mode passes -WhatIf (the script reads Azure and the cluster and changes nothing).
#                 Run: the script changes nothing at all and has no -WhatIf, so Plan runs it as it is (the SBE import plan only prints commands).
#   NeedsCluster  true when the script connects to the machines: the orchestrator probes once, before the first step, that the cluster answers.
#   Irreversible  true when the step cannot be undone: it needs its Requires keys, and a failure of any step stops the run anyway.
#   Applies       Conditions, all of which must hold, else the step is Skipped with the reason. See Test-AzlPostDeploymentCondition in AzlPostDeploymentRun.psm1.
#                 Key + Is / IsNot / NotEmpty / AnyItemHas (an array of mappings with a non-empty field) / AnyNotEmpty (Keys, one of them is set).
#                 An empty list: the step always applies (unless skip_steps names it).
#   Requires      The acknowledgement keys of an Irreversible step. Without them the orchestrator refuses the run (exit code 2) before any step starts.
#                 A requirement with When applies only when that condition holds.
#   Arguments     Extra switches passed when their When condition holds: @{ Name; When }.
@{
    SchemaVersion = 1
    Steps         = @(
        @{
            Id = 'sdn'; Task = 'task-01-deploy-sdn'; Title = 'Turn on SDN enabled by Azure Arc'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-01-deploy-sdn/powershell/Enable-ArcSdn.ps1'
            Plan = 'WhatIf'; NeedsCluster = $true; Irreversible = $true
            Applies = @(@{ Key = 'sdn.enabled'; Is = $true })
            Requires = @(
                @{ Key = 'sdn.acknowledge_maintenance_window'; Is = $true }
                @{ Key = 'sdn.acknowledge_dns_record'; Is = $true; When = @{ Key = 'sdn.dns_records'; Is = 'static' } }
            )
        }
        @{
            Id = 'quorum'; Task = 'task-02-cluster-quorum-configuration'; Title = 'Set the cluster witness'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-02-cluster-quorum-configuration/powershell/Invoke-ConfigureClusterQuorum-Orchestrated.ps1'
            Plan = 'WhatIf'; NeedsCluster = $true
            Applies = @(@{ Key = 'cluster.witness.type'; NotEmpty = $true })
        }
        @{
            Id = 'security-groups'; Task = 'task-03-security-groups-applied-to-nodes'; Title = 'Add the security groups to the local groups of the nodes'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-03-security-groups-applied-to-nodes/powershell/Invoke-ApplySecurityGroups-Orchestrated.ps1'
            Plan = 'WhatIf'; NeedsCluster = $true
            Applies = @(@{ Key = 'identity.active_directory.security_groups'; AnyItemHas = 'local_groups' })
        }
        @{
            Id = 'ssh'; Task = 'task-04-ssh-connectivity-to-nodes'; Title = 'Turn on SSH to the nodes through Azure Arc'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/powershell/Invoke-SSHConnectivity-Orchestrated.ps1'
            AzureCliScript = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-04-ssh-connectivity-to-nodes/azurecli/Enable-ArcSshConnectivity.azcli.ps1'
            Plan = 'WhatIf'; NeedsCluster = $false
            Applies = @()
        }
        @{
            Id = 'storage-volumes'; Task = 'task-05-storage-configuration'; Title = 'Create the Storage Spaces Direct volumes'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-05-storage-configuration/powershell/New-StorageVolume.ps1'
            Plan = 'WhatIf'; NeedsCluster = $true
            Applies = @(@{ Key = 'storage.volumes'; NotEmpty = $true })
        }
        @{
            Id = 'storage-paths'; Task = 'task-05-storage-configuration'; Title = 'Create the storage paths in Azure'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-05-storage-configuration/powershell/New-StoragePath.ps1'
            AzureCliScript = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-05-storage-configuration/azurecli/New-StoragePath.azcli.ps1'
            Plan = 'WhatIf'; NeedsCluster = $false
            Applies = @(@{ Key = 'storage.paths'; NotEmpty = $true })
        }
        @{
            Id = 'vm-images'; Task = 'task-06-image-downloads'; Title = 'Download the VM images from the Azure Marketplace'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-06-image-downloads/powershell/New-VmImage.ps1'
            AzureCliScript = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-06-image-downloads/azurecli/New-VmImage.azcli.ps1'
            Plan = 'WhatIf'; NeedsCluster = $false
            Applies = @(@{ Key = 'storage.vm_images'; NotEmpty = $true })
        }
        @{
            Id = 'nsgs'; Task = 'task-07-configure-nsgs'; Title = 'Create the network security groups'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-07-configure-nsgs/powershell/New-NetworkSecurityGroup.ps1'
            AzureCliScript = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-07-configure-nsgs/azurecli/New-NetworkSecurityGroup.azcli.ps1'
            Plan = 'WhatIf'; NeedsCluster = $false
            Applies = @(@{ Key = 'networking.network_security_groups'; NotEmpty = $true }, @{ Key = 'sdn.enabled'; Is = $true })
        }
        @{
            Id = 'logical-networks'; Task = 'task-08-logical-network-creation'; Title = 'Create the logical networks'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation/powershell/New-LogicalNetwork.ps1'
            AzureCliScript = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-08-logical-network-creation/azurecli/New-LogicalNetwork.azcli.ps1'
            Plan = 'WhatIf'; NeedsCluster = $true
            Applies = @(@{ Key = 'networking.logical_networks'; NotEmpty = $true })
        }
        @{
            Id = 'verification'; Task = 'task-09-post-deployment-verification'; Title = 'Verify the deployed instance against the file (read only)'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-09-post-deployment-verification/powershell/Invoke-PostDeploymentVerification-Orchestrated.ps1'
            Plan = 'WhatIf'; NeedsCluster = $true
            Applies = @()
        }
        @{
            Id = 'external-storage'; Task = 'task-10-enable-external-storage-hybrid'; Title = 'Attach the external SAN (hybrid S2D plus SAN)'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-10-enable-external-storage-hybrid/powershell/Invoke-ExternalStorageHybrid-Orchestrated.ps1'
            ScriptOnPage = $false
            Plan = 'WhatIf'; NeedsCluster = $true
            Applies = @(@{ Key = 'scenario.storage_architecture'; Is = 'hybrid' })
            Arguments = @(@{ Name = 'RollingRestart'; When = @{ Key = 'operations.post_cluster.allow_node_restarts'; Is = $true } })
        }
        @{
            Id = 'sbe-import-plan'; Task = 'task-11-sbe-update-import'; Title = 'List the SBE files and print the import commands (changes nothing)'
            Script = 'scripts/deploy/04-cluster-deployment/phase-06-post-deployment/task-11-sbe-update-import/powershell/Get-AzureLocalSbeImportPlan.ps1'
            Plan = 'Run'; NeedsCluster = $false
            Applies = @(
                @{ Key = 'hardware.sbe.requirement'; IsNot = 'not_applicable' }
                @{ Keys = @('hardware.sbe.source_path', 'hardware.sbe.bundle_path'); AnyNotEmpty = $true }
            )
        }
    )
}

# Reviewed exceptions to tests/variables/Enforcement.Tests.ps1. A line here says: this literal, in this script, is not a value a
# deployment chooses, and the reason. Nothing else belongs here:
#   * a value Microsoft or a protocol fixes (documentation and mask addresses, Microsoft endpoints, built-in role IDs, API versions,
#     port numbers, registry paths) is a rule-level exception in the test itself, with its reason, not a line here;
#   * debt in a legacy script goes to enforcement-baseline.psd1, not here.
# File: path from the repository root, forward slashes. Rule: A, B, C or D. Literal: as the test prints it (an address is written masked,
# 10.x.x.x/24; this file never holds a real-looking address or ID). Reason: one line. A line that no longer matches a finding fails the test.
@{
    Entries = @(
        @{
            File    = 'scripts/common/arm-deployment/verification/AzlVerification.Network.psm1'
            Rule    = 'B'
            Literal = 'proxy.example.test'
            Reason  = 'an example host name (reserved .test domain, RFC 2606) in the text of a finding'
        }
        @{
            File    = 'scripts/common/cicd-infra/AzlCicdInfra.psm1'
            Rule    = 'B'
            Literal = 'gitlab.com'
            Reason  = 'the public GitLab service address, fixed by the vendor; the module supports GitLab as a platform and the file can set another URL'
        }
        @{
            File    = 'pipelines/gitlab/Use-AzlGitLabTool.ps1'
            Rule    = 'B'
            Literal = 'releases.hashicorp.com'
            Reason  = 'the HashiCorp release host Terraform is downloaded from, fixed by the vendor; the version comes from AZL_TERRAFORM_VERSION (devops.pipelines.tool_versions.terraform) and the download is checked against the published SHA256SUMS'
        }
        @{
            File    = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-01-verify-resources/azurecli/Test-ManagementResources.azcli.ps1'
            Rule    = 'B'
            Literal = 'vnet-gateway'
            Reason  = 'a word of the Azure CLI command (az network vnet-gateway), fixed by Microsoft; it names a command group, not a resource of the deployment'
        }
        @{
            File    = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-02-test-connectivity/azurecli/Test-ManagementConnectivity.azcli.ps1'
            Rule    = 'B'
            Literal = 'vnet-gateway'
            Reason  = 'a word of the Azure CLI command (az network vnet-gateway), fixed by Microsoft; it names a command group, not a resource of the deployment'
        }
        @{
            File    = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/01-cicd-pipeline-deployment/phase-03-validation/task-03-validate-configuration/azurecli/Test-ManagementConfiguration.azcli.ps1'
            Rule    = 'B'
            Literal = 'vnet-gateway'
            Reason  = 'a word of the Azure CLI command (az network vnet-gateway), fixed by Microsoft; it names a command group, not a resource of the deployment'
        }
    )
}
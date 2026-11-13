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
            File    = 'scripts/common/arm-deployment/AzlArmDeploymentRun.psm1'
            Rule    = 'D'
            Literal = '$Host.UI.PromptForChoice'
            Reason  = 'the approval gate chosen by deployment.approval: it asks yes or no before a deployment starts, never for a value, and is skipped when input is redirected'
        }
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
            File    = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/02-manual-deployment/task-06-network-security-groups/powershell/Deploy-LighthouseNsg.ps1'
            Rule    = 'B'
            Literal = 'lighthouse.opengear.com'
            Reason  = 'the Opengear Lighthouse service portal, a vendor-fixed endpoint named in an NSG rule description'
        }
        @{
            File    = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/task-15-configure-lighthouse/powershell/Deploy-Lighthouse.ps1'
            Rule    = 'B'
            Literal = 'lighthouse.opengear.com'
            Reason  = 'the Opengear Lighthouse service portal, a vendor-fixed endpoint named in a message'
        }
        @{
            File    = 'scripts/deploy/02-azure-foundation/phase-04-azure-management-infrastructure/task-14-configure-ndm-server/powershell/New-NdmServer.ps1'
            Rule    = 'B'
            Literal = 'community.chocolatey.org'
            Reason  = 'the public Chocolatey package source, fixed by the vendor, used by the setup script it embeds'
        }
    )
}

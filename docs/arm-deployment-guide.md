# ARM Validate and Deploy: run guide

`Invoke-AzureLocalArmDeployment.ps1` checks that an Azure Local instance is ready, generates the ARM parameters from the master
`infrastructure.yml`, runs Microsoft's **Validate**, waits for your approval, runs **Deploy**, and says what went wrong in terms
you can act on. It runs from a jump server or from GitHub Actions, GitLab CI or Azure DevOps, with the same command, for Active
Directory or local identity, Storage Spaces Direct, a SAN (Fibre Channel) or hybrid, switchless or switched storage, and 1 to 16
machines. Running it twice is safe.

- Design and the reasons for each rule: [design/arm-validate-deploy.md](design/arm-validate-deploy.md)
- What existed before and what was missing: [arm-deployment-audit.md](arm-deployment-audit.md)
- Content for the azurelocal.cloud automation guide: [ARM-DEPLOYMENT-GUIDE-SOURCE.md](ARM-DEPLOYMENT-GUIDE-SOURCE.md)
- The steps before this one: [os-configuration-and-arm-deployment.md](os-configuration-and-arm-deployment.md)

```
infrastructure.yml  +  OS configuration report  +  ZTP handoff (optional)
        -> Plan (preconditions) -> Validate -> approval -> Deploy -> report, events, exit code
```

## Run the pre-cluster verification first

Mode Validate and Deploy go ahead only after the pre-cluster verification gate passed for the same infrastructure file. It checks, read only, everything Microsoft Learn lists as a prerequisite
(Azure, Active Directory, the nodes, the network, the storage, Microsoft's Environment Checker) so that the Validate does not fail for something that could have been caught:

```powershell
./Invoke-AzureLocalPreClusterVerification.ps1 -InfrastructureFile ./infrastructure.yml -OsConfigurationReport ./osconfig-report -Mode Verify
```

The result (`report.json`, `precluster-verification-events.jsonl`, `summary.md`) lands in `arm-report\verification\live` of the environment data folder. The ARM run reads it: the verdict must be
`Pass`, the hash of the infrastructure file must match, it must not be older than `deployment.pre_cluster_verification_max_age_hours` (4) and it must cover all six categories. Otherwise the
precondition `PreClusterVerification` fails and names the command to run. The only way past it is the explicit switch `-SkipPreClusterVerification` (warned, and recorded in the report as
`Bypassed`). See [pre-cluster-verification.md](pre-cluster-verification.md).

## Run it from a jump server

PowerShell 7 on Windows or Linux, `powershell-yaml`, `Az.Accounts` and `Az.KeyVault`, and a sign-in. The script does not sign in.

```powershell
Connect-AzAccount            # or: Connect-AzAccount -Identity   (an Azure VM with a managed identity)

$arm = './scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1'
$common = @{ InfrastructureFile = './infrastructure.yml'; OsConfigurationReport = './osconfig-report' }

& $arm @common -Mode Plan     -ReportDirectory ./arm-plan        # reads only; add -Offline to touch no Azure at all
& $arm @common -Mode Validate -ReportDirectory ./arm-validate    # 10 to 30 minutes
& $arm @common -Mode Deploy   -ReportDirectory ./arm-deploy      # 2.5 to 3 hours, only after a Validate of these parameters
```

`-Mode ValidateAndDeploy` does the last two in one run with a gate between them (`-ApprovalMode stop|prompt|none`). The default,
`stop`, ends after a good Validate in state `AwaitingApproval` with exit code 0; run `-Mode Deploy` to continue. `-WhatIf` does
everything except submit.

| Parameter | Meaning |
| --- | --- |
| `-InfrastructureFile` | The master file (schema 5). Required. |
| `-OsConfigurationReport` | The OS configuration run's `report.json`, a node-level report, or its report directory. Gives the OS names of the network ports (found by MAC), the SAN disks (a LUN number becomes the disk's UniqueId), and proves every node converged. |
| `-HandoffFile` | The ZTP handoff: Arc machine resource IDs and the solution build. |
| `-Mode` | `Plan` (default), `Validate`, `Deploy`, `ValidateAndDeploy`. |
| `-ReportDirectory` | Where the events, report, summary and parameter files go. Not for a repository. |
| `-Resume` | Resubmit a failed Deploy (and attach to a running one). |
| `-AcknowledgeKnownIssues` | Known issue ids you accept, for example `arc-device-id-name`. |
| `-Settings`, `-ConfigPath` | Run settings as a hashtable or JSON file; they win over the master file's `deployment` block. |
| `-AllowRevalidate` | Validate an instance in a failed deployment state. Microsoft says not to; support-guided recovery only. |
| `-SkipPreClusterVerification` | The only bypass of the precondition `PreClusterVerification`: the run goes ahead without a passing, current result of the pre-cluster verification gate. Warned loudly and recorded in the report (`preClusterVerification.status` `Bypassed`). There is no file key for it. |
| `-RegisterResourceProviders` | Opt in: register the mandatory resource providers that are not registered and wait until they are Registered (Validate and Deploy only). Without it the run never changes Azure. Same as `deployment.register_resource_providers`. |
| `-TemplateFile` | A local copy of the quickstart template instead of the download. |
| `-Offline` | Plan only: no Azure call at all. |

## Run it from a pipeline

Copy the file for your platform. Each does the same: **preconditions** (Plan), then **Validate**, then **Deploy** behind the
platform's approval, publishing `report.json`, `summary.md` and the event feed of every job.

| Platform | File | Approval | Sign-in |
| --- | --- | --- | --- |
| GitHub Actions | `pipelines/github-actions/arm-deployment.yml` | Environment `azure-local-deploy` with required reviewers | `azure/login@v2`, OIDC |
| GitLab CI | `pipelines/gitlab/stages/arm-deployment.yml` | Manual job in the protected environment `azure-local-deploy` | `id_tokens` and `Connect-AzAccount -FederatedToken` (or a managed identity) |
| Azure DevOps | `pipelines/azure-devops/arm-deployment.yml` | Approvals check on the environment `azure-local-deploy` | A service connection with workload identity federation |

No client secret is stored anywhere. The files hold placeholders only; set the real values as variables of the project. Use a
self-hosted runner that reaches Azure over HTTPS. The Active Directory check also needs a domain-joined runner with the
ActiveDirectory module; elsewhere it is reported as Skipped, never as passed.

The Deploy job re-runs every precondition and checks that **these parameters were validated** (the Validate's ARM deployment is
named from a hash of the parameters), so an approval cannot start a Deploy of something that was never validated. The reviewer
reads the Validate job's `summary.md`.

## What it checks first (all read-only)

Each check is `Passed`, `Failed` (stops the run, exit 1), `Warning`, or `Skipped` (with the reason). The report lists all of them.

| Check | What it looks for | Typical fix |
| --- | --- | --- |
| `PreClusterVerification` | The latest result of the pre-cluster verification gate is a Pass for this file, covers all categories and has not expired (Failed in Validate and Deploy, a Warning in Plan) | Run `Invoke-AzureLocalPreClusterVerification.ps1 -Mode Verify` (the report prints the exact command) |
| `AzureContext` | Signed in; the subscription and tenant are the file's | `Set-AzContext`, or fix `azure.subscription_id` |
| `ResourceGroup` | `azure.resource_group` exists | Create it |
| `ResourceProviders` | All 13 resource providers Microsoft requires are Registered (list below). Any one that is not is **Failed**, never a Warning, with its own command in the report | `Register-AzResourceProvider -ProviderNamespace <name>`, or run with `-RegisterResourceProviders` |
| `Permissions` | May write deployments, clusters, vaults, storage accounts and role assignments at the resource group | Owner, or Contributor plus User Access Administrator |
| `NamesAvailable` | Diagnostic and witness storage account names, and the new Key Vault's name, are free | Pick another name; a soft-deleted vault keeps its name |
| `KeyVaultSecrets` | Every `keyvault://` reference points at a listed vault and an existing secret (the value is not read) | Create the secret; grant `Get` on secrets |
| `ArcMachinesConnected` | Each node's Arc machine exists, is Connected, is in the instance's resource group | Finish ZTP or Arc registration |
| `ArcMachineNaming` | The Arc machine is named after the host. A device-ID name (`<id>-1`) fails the Deploy at step 0.41 on build 2690 | See the known issue below |
| `OsConfigurationConverged` | The OS configuration report says every node converged, for this cluster | Run the OS configuration with `-Mode Apply` |
| `OsBuildConsistent` | Every node runs the same OS build | Install the same build everywhere |
| `SbeConsistent` | The SBE is opt-in. No `hardware.sbe.version`: Passed, "deploying without a Solution Builder Extension". With a version: the family must be set too (Warning if not) | Set `hardware.sbe.family`, or remove the version to deploy without an SBE |
| `SbeValidatedWithSolution` | Passed, "deploying without a Solution Builder Extension", when no SBE is configured. Otherwise: the SBE (`hardware.sbe.family`, `version`) is validated with the solution version the nodes run, read from the SBE discovery catalog (`SBE_Discovery_*.xml` in `hardware.sbe.bundle_path`, or the run setting `sbeCatalogPath`; nothing is downloaded). The solution version is the run setting `solutionVersion`, else the ZTP handoff, else derived from the OS build (only builds that map unambiguously). Azure refuses a mismatch only after about 13 minutes of Validate (`ErrorUnvalidatedSolutionAndSbeCombination`, known issue `unvalidated-solution-sbe-combination`). Failed names the validated SBE versions; Warning when the solution version is unknown; Skipped without a catalog | Download the validated SBE from the OEM, set `hardware.sbe.version` and `bundle_path`, run the OS configuration |
| `DnsAndTime` | DNS servers set and valid, NTP set, no pending Dns/Time change in the OS report | Fix `networking.management.dns_servers`, `ntp_servers` |
| `ActiveDirectoryPrepared` | OU not at the top of the domain; LCM user name 20 characters or fewer; the OU and user exist | Run Microsoft's AD preparation tool |
| `LocalIdentityPrerequisites` | `identity.local_identity.dns_zone` set | Set it |
| `NoLeftoverFailedDeployment` | No failed or running deployment that this run would damage | Resume with `-Mode Deploy -Resume`, never Validate again |
| `ValidatedBeforeDeploy` | (Deploy) Validation succeeded for these parameters | Run Validate |

Skip a check on purpose with `deployment.skip_preconditions`; it still appears in the report as Skipped.

### The mandatory resource providers

Azure Local needs these 13 resource providers registered in the subscription before the deployment starts. The list is the one in
Microsoft Learn, [Assign required permissions for Azure Local deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions)
(Azure prerequisites, *Register required resource providers*). Microsoft marks none of them optional for a hyperconverged deployment.

| Provider | Provider | Provider |
| --- | --- | --- |
| `Microsoft.HybridCompute` | `Microsoft.GuestConfiguration` | `Microsoft.HybridConnectivity` |
| `Microsoft.AzureStackHCI` | `Microsoft.Kubernetes` | `Microsoft.KubernetesConfiguration` |
| `Microsoft.ExtendedLocation` | `Microsoft.ResourceConnector` | `Microsoft.HybridContainerService` |
| `Microsoft.Attestation` | `Microsoft.Storage` | `Microsoft.Insights` |
| `Microsoft.KeyVault` | | |

Azure's own validation (step `ValidateArcIntegration`, check `AzStackHci_ArcIntegration_MandatoryRPRegistration_Check`) fails on any
of them that is not registered, and `Microsoft.Insights` is needed for the diagnostic account and the Key Vault audit logging. A
missing `Microsoft.HybridContainerService` used to be only a Warning here and the failure came later, from Azure; the precondition now
fails first and names every missing provider with `Register-AzResourceProvider -ProviderNamespace <name>`. A provider that is
`Registering` still counts as missing until it is `Registered`.

**Registration is opt in.** By default the run reads and never changes Azure. To let the run register what is missing, pass
`-RegisterResourceProviders` (or set `deployment.register_resource_providers: true`, or `-Settings @{ registerResourceProviders = $true }`):

```powershell
./Invoke-AzureLocalArmDeployment.ps1 -InfrastructureFile ./infrastructure.yml -Mode Validate -RegisterResourceProviders
```

* It registers only the providers that are not registered, asks once for each, and reads their state every 10 seconds for up to 15
  minutes until all are `Registered`. A provider already `Registering` is waited for, not asked again.
* It acts only in Mode Validate, Deploy or ValidateAndDeploy. Mode Plan and `-WhatIf` never change Azure; with the switch they still
  report the providers as Failed and say nothing was registered.
* It needs Owner or Contributor on the subscription. A refused registration, a provider that does not exist in the subscription, or a
  provider still not `Registered` after 15 minutes is a Failed check that names the provider and the manual command.
<!-- sbe-optional-arm:begin -->
### The Solution Builder Extension is opt-in

A deployment without an SBE is a normal deployment. When `hardware.sbe` is absent, or has no `version`, the run passes none of the seven SBE parameters of Microsoft's template (`sbeVersion`, `sbeFamily`, `sbePublisher`, `sbeManifestSource`, `sbeManifestCreationDate`, `partnerProperties`, `partnerCredentiallist`); the template defaults them to empty strings and empty lists. `SbeConsistent` and `SbeValidatedWithSolution` are Passed with the note `deploying without a Solution Builder Extension`, and `parameter-sources.md` lists the seven parameters as `no SBE configured`. An SBE is passed, exactly as before, only when `hardware.sbe.version` is set. If Azure still names an SBE problem in a run without an SBE (the nodes carry an SBE package in `C:\SBE`), the known issue `sbe-referenced-but-not-configured` says so and offers both ways out.
<!-- sbe-optional-arm:end -->

## What it builds from the master file

`parameter-sources.md` in the report directory shows, for your scenario, which `infrastructure.yml` key fed each ARM parameter.
A required value that is empty ends the run (exit 2) with a message such as:

```
ARM parameter adouPath (required when scenario.identity is active_directory) needs identity.active_directory.ou_path in infrastructure.yml, and it is empty.
```

All missing keys are listed at once. The map is data: `config/azure/arm-templates/parameter-sources.json`. A design the generator
does not support yet (iSCSI SAN, disconnected operations, Azure Government with local identity or a SAN, rack aware with a SAN
or local identity) stops with exit 2 and says so.

## Re-running, resuming, waiting

| Found in Azure | Validate | Deploy |
| --- | --- | --- |
| Nothing | Submits | Refused: validate first |
| Validated with these parameters | Not submitted again | Submits |
| A validation of these parameters running | Attaches and waits | Refused |
| A deployment running | Refused | Attaches and waits |
| A failed deployment | **Refused** (Microsoft: another Validate can break license sync) | Refused, unless `-Resume` |
| A succeeded deployment | Refused | Reports it, submits nothing |

**Resume.** The portal has *Resume deployment*. For the ARM route Microsoft documents a second submission with the same
parameters and `deploymentMode` Deploy; `-Resume` does that, under the same deployment name. Whether Azure continues at the failed
step or restarts is not documented for the ARM route; the first step events after a resume show where it started. A failure whose
known issue says "do not retry" (for example `arc-device-id-name`) blocks the resume until you acknowledge the issue.

**Waiting.** The status is read every 15 s, growing by half each read to 120 s. Validate is given 90 minutes and Deploy 6 hours. At
the limit the run ends in `ValidationTimedOut` or `DeploymentTimedOut` with exit 1; Azure keeps working and the next run
**attaches** to it. Five failed reads in a row end the wait.

## When it fails

The run names the failing step with the number the portal shows (for example `0.41`), copies the step's error text (secrets
removed), and looks it up in `config/known-issues/arm-deployment.json`:

| Id | Meaning | Retry |
| --- | --- | --- |
| `arc-device-id-name` | Step *Deploy Arc infrastructure components*, `ParentResourceNotFound`: Arc machines named `<device-id>-1`, looked up by host name (build 2690) | no |
| `arc-device-id-name-step-0-41` | Any failure at step 0.41: rule the above out first | no |
| `unsupported-os-version` | "Unsupported OS version": a build the subscription does not accept, or nodes on different builds | after the fix |
| `registration-5901` | 403 on the target Arc machine soon after the role assignment | once, after a wait |
| `role-assignment-already-exists` | A portal attempt in the same resource group left the role assignment | after the fix |
| `role-assignment-zombie` | Role assignments of deleted resources remain | after the fix |
| `license-sync-after-failed-validate` | A second Validate after a failure | never Validate |
| `ad-prerequisites` | OU, LCM user, GPO or rights (pattern, not yet seen in a run) | after the fix |
| `dns-resolution` | The domain or an Azure endpoint does not resolve (pattern) | after the fix |
| `vmswitch-not-bound` | Stale validation switch data (Learn) | after the fix |

Add an entry when you understand a new failure; the run then explains it the next time.

### The whole reason, not a cut-off line

Azure reports a failed validation step (for example `0.170` *ValidateCluster*) with a long text: the EnvironmentValidator results
as JSON, and inside the Test-Cluster result the lines `[!!Failed!!]` and `[!!Warning!!]` with the sentences that say why (for
example *Storage - List Disks: Two disks have been found on node ... that cannot be distinguished from one another ... disk
signature ... SCSI page 83h VPD ...*). The run keeps all of it:

| Where | What you get |
| --- | --- |
| `report.json`, `validate.failedSteps[]` | `errors`: the full text of every exception, never cut. `results`: every EnvironmentValidator result with `name`, `title`, `description`, `status`, `severity`, `remediation` and `detail` (AdditionalData.Detail). `checks`: the Test-Cluster checks (`Failed`, `Warning`, `Info`) with their whole message. `testClusterReportFile`: the `AzStackHciEnvironmentChecker-ClusterValidationReport-*.htm` path **on the node**, to open there. `validate.error` is the whole error text too. |
| `summary.md` | Per failed step: the Test-Cluster report path, then each failed or warned check with its message; for any other EnvironmentValidator step each result that did not pass with its description, `Remediation` URL and detail. Steps with no structure show the whole error text. |
| `arm-deployment-events.jsonl` | The step event and the `ValidationFailed` / `DeploymentFailed` event carry the whole text in `detail`, the checks in `checks` and the node path in `testClusterReportFile`. |
| Console and `evidence` | One line only. This is the only place text is cut, and the line always ends with `(full text: <path of report.json>)`. |

Secrets are still removed from every text.

### Steps of an earlier run are not this run's

The cluster resource keeps the steps of every earlier attempt until a new attempt runs them again, so a Validate that was
submitted now could be blamed for an old error (a `0.60` *InvokeEnvironmentChecker* failure of the previous run). The run
therefore ignores a step when its latest start or end time is more than the allowed clock skew (`staleSkewMinutes`, 5) older than the
moment this run submitted, or when its text names another deployment (`azl-validate-<hash>` or `azl-deploy-<hash>` with a different
hash than this run's). Ignored steps are listed in `report.json` (`validate.ignoredSteps`), in `summary.md` and in one
`StaleStepsIgnored` event; they are never the failing step and get no step event. A run that **attaches** to its own running
deployment keeps the steps it finds, because they belong to that deployment.

## What you get

| File | For |
| --- | --- |
| `arm-deployment-events.jsonl` | One JSON line per event (`timestamp, node, stage, step, state, evidence, level, nextAction` plus data). Sonar can follow it. |
| `report.json` | Result, state history, every precondition, validation and deployment sections, failing steps, known issue, approval |
| `summary.md` | The same for a person; the job summary in a pipeline |
| `<cluster>.parameters.json` | The ARM parameter file. Secrets are null in it. |
| `parameter-sources.md` | Which key fed which parameter |

Exit codes: **0** the requested part succeeded (Plan clean; Validate passed; Deploy succeeded; ValidateAndDeploy stopped at the
approval gate); **1** a precondition failed, or the validation or deployment failed or timed out; **2** bad input (a file or a
required key missing, an unsupported design, no Azure sign-in when one is needed).

## What is verified

Verified by tests that use a fake Azure and a fake clock (`tests/arm-deployment/`, no subscription touched): parameters for AD and
local identity, S2D and SAN, switchless and switched, 1, 2, 4 and 16 machines, and the key messages; every precondition with a
passing and a failing case; the state machine; the wait on a fake clock including a 6 hour time-out; skip, attach, submit and
resume decisions; the full failure text kept in report.json, summary.md and the events (with a fake payload shaped like the real ValidateCluster failure) and the steps of earlier runs ignored; the known-issue mapping on a fixture that copies the 2026-11-06 failure (step 0.41, build 2690); the event
feed, report, exit codes and secret scrubbing; the three pipeline files parse and carry the approval gate; no backslash path
literal in the new files; schema 5.6 and rule AZL-040.

**Not verified, because it needs Azure or a machine:** that the real deployment status carries the step numbers and times the
code reads; the real ARM states during a Deploy; that a resubmitted Deploy resumes at the failed step; the permissions,
name-availability and provider REST calls; the Active Directory lookup; the pipelines on a real runner; Linux runs of the modules
this one imports (the infrastructure and Azure helper modules still carry Windows paths on this branch). The first run on a lab
instance is the acceptance test: Plan, Validate, then a Deploy that is allowed to fail.

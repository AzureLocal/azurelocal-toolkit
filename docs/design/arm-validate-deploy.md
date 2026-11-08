# ARM Validate and Deploy automation: design

**Status:** Draft v1, implemented in this change. **Audit this answers:** [../arm-deployment-audit.md](../arm-deployment-audit.md).
**Follows:** the principles and the event feed of the OS configuration design (`pmo/azure-local/os-configuration-design.md`).
**Entry point:** `scripts/deploy/04-cluster-deployment/phase-05-cluster-deployment/Invoke-AzureLocalArmDeployment.ps1`.
**Module:** `scripts/common/arm-deployment/AzlArmDeploymentRun.psm1`.

One automated solution for the step after OS configuration: check that the instance is ready, generate the ARM parameters,
submit **Validate**, wait for it, ask for approval, submit **Deploy**, wait for it, and explain a failure. It runs from a jump
server or from a CI/CD pipeline (GitHub Actions, GitLab CI, Azure DevOps) with the same command, for any operator and any
scenario (Active Directory or local identity; Storage Spaces Direct, SAN over Fibre Channel or iSCSI, or hybrid; switchless
or switched; 1 to 16 nodes), driven by the same master `infrastructure.yml` (schema 5.x) as ZTP, OS configuration, Sonar
and Trailwright.

---

## 1. Goals and principles

1. **One declarative source.** Everything comes from `infrastructure.yml`, plus what earlier steps produced (the ZTP handoff
   and the OS configuration report). No second parameter file to keep in step.
2. **Check before you spend 30 minutes.** A Validate takes 10 to 30 minutes and a Deploy 2.5 to 3 hours. Everything that can
   be known beforehand is checked read-only first (section 4), and each failed check names the key or the action to fix.
3. **Plan, validate, approve, deploy.** Plan is read-only. Validate creates the Azure resources and runs Microsoft's
   validation. Approval is a gate between the two. Deploy runs only against a Validate that succeeded **with the same
   parameters**.
4. **Idempotent and re-runnable.** Running the same command twice is safe. A Validate that already passed is not submitted
   again; a running deployment is attached to, not duplicated; a failed Deploy is resumed (section 7).
5. **Never make a failed instance worse.** Microsoft: do not run Validate again when the instance is in the Deployment
   failed state, because it resets the system properties and can break license sync. The tool refuses.
6. **Say what happened.** Every run writes an event feed (JSON Lines), `report.json`, `summary.md`, and exits with 0, 1 or 2.
   A failure is matched to a known issue and prints its cause and remediation.
7. **No secrets, ever, in a file, an event or a log.** Secrets are `keyvault://` references, read into memory only to send
   them as secure ARM parameters, and scrubbed from every text the tool prints.
8. **Same code on a jump server and in a pipeline.** PowerShell 7 on Windows or Linux. A pipeline only supplies the sign-in,
   the files and the approval; it contains no logic.

---

## 2. Components

| Component | Where | Job |
| --- | --- | --- |
| `Invoke-AzureLocalArmDeployment.ps1` | phase-05 folder | Thin entry point: parameters in, `Invoke-AzlArmDeploymentRun`, exit code out |
| `AzlArmDeploymentRun.psm1` | `scripts/common/arm-deployment/` | Settings, preconditions, key check, run state machine, polling, step extraction, known-issue matching, approval, events, report |
| `AzlArmDeployment.psm1` | same folder (existing) | Template choice, parameter generation, parameter checks, submit (`Invoke-AzlArmDeployment`), deployment state read |
| Parameter sources | `config/azure/arm-templates/parameter-sources.json` | Which `infrastructure.yml` keys feed which ARM parameter (data) |
| Known issues | `config/known-issues/arm-deployment.json` | Failing step or error text to cause, remediation and retry advice (data) |
| Template catalog | `config/azure/arm-templates/template-parameters.json` (existing) | Each Microsoft quickstart template's parameters |
| Azure adapter | inside the module (`New-AzlArmAzureAdapter`) | The only code that touches Azure. Every call is a scriptblock that tests replace |
| Event feed | `<ReportDirectory>/arm-deployment-events.jsonl` | One JSON line per event; Sonar reads it |
| Reports | `report.json`, `summary.md`, `<cluster>.<mode>.parameters.json`, `parameter-sources.md` | Result, state history, preconditions, failing step, known issue |
| Pipelines | `pipelines/github-actions/arm-deployment.yml`, `pipelines/gitlab/stages/arm-deployment.yml`, `pipelines/azure-devops/arm-deployment.yml` | Preconditions and Validate, then an approval environment, then Deploy |

Not changed: Sonar. It already reads the validation and deployment step trees from Azure
(`deploymentSettings/default`). The feed this tool writes uses the same fields as the OS configuration and ZTP feeds and adds
the portal's step numbers, so one reader can follow all three.

---

## 3. Flow

```
 infrastructure.yml  ztp handoff  os-configuration report
        \                |              /
         v               v             v
   [1 Prepare]  settings, required keys, template, parameters, parameter hash        (input errors: exit 2)
        |
   [2 Preconditions]  read-only; Azure, nodes, identity, secrets, leftover state
        |    any Failed -> stop, exit 1 (Plan: reported, exit 1)
        v
   Mode Plan ---------------------------------------------------------> report, exit 0
        |
   [3 Validate]  attach / skip / submit  -> poll with backoff -> ValidationPassed | Failed | TimedOut
        |
   [4 Approval]  stop | prompt | none     (ValidateAndDeploy; pipelines use a separate job)
        |
   [5 Deploy]    attach / resume / submit -> poll with backoff -> Succeeded | Failed | TimedOut
        |
   [6 Report]    report.json, summary.md, RunCompleted, exit 0 | 1
```

Modes: `Plan` (steps 1, 2), `Validate` (1, 2, 3), `Deploy` (1, 2, 5; needs a Validate that succeeded), `ValidateAndDeploy`
(1 to 5). `-WhatIf` runs 1 and 2 and says what it would submit; it never submits.

---

## 4. Preconditions (all read-only)

Each check returns `Passed`, `Failed` (blocks), `Warning` (reported, does not block) or `Skipped` (cannot be checked here,
with the reason). A check that needs Azure is `Skipped` in `Plan` when nobody is signed in; in `Validate`, `Deploy` and
`ValidateAndDeploy` a missing sign-in is bad input (exit 2). Per node checks produce one result per node. A check can be
skipped on purpose with `deployment.skip_preconditions` or `-Settings @{ skipPreconditions = ... }`; it is then recorded as
`Skipped` (operator decision), never hidden.

| Name | Scope | Checks | Not met means | Phase |
| --- | --- | --- | --- | --- |
| `AzureContext` | run | An Az context exists; its subscription is `azure.subscription_id` and its tenant `azure.tenant_id` | Failed | all |
| `ResourceGroup` | run | `azure.resource_group` exists | Failed | all |
| `ResourceProviders` | run | All 13 providers Microsoft Learn lists as required are Registered: HybridCompute, GuestConfiguration, HybridConnectivity, AzureStackHCI, Kubernetes, KubernetesConfiguration, ExtendedLocation, ResourceConnector, HybridContainerService, Attestation, Storage, Insights, KeyVault. Azure's own check (ValidateArcIntegration, AzStackHci_ArcIntegration_MandatoryRPRegistration_Check) fails on any that is not. Opt-in `-RegisterResourceProviders` registers the missing ones and waits for Registered (Validate and Deploy only) | Failed | all |
| `Permissions` | run | The signed-in identity may write deployments, `Microsoft.AzureStackHCI/clusters`, Key Vault, storage accounts and role assignments at the resource group (Owner, or Contributor plus User Access Administrator) | Failed | Validate, Deploy |
| `NamesAvailable` | run | The diagnostic and witness storage account names, and the Key Vault name when `create_new` is true, are free (or already in this resource group). A soft-deleted vault holds its name | Failed | Validate |
| `KeyVaultSecrets` | run | Every `keyvault://` reference the parameters use points at a vault listed in `key_vaults` and the secret exists (the value is not read) | Failed | all |
| `ArcMachinesConnected` | node | The node's Arc machine exists (handoff ID, else name), is Connected, and sits in the instance's subscription and resource group | Failed | all |
| `ArcMachineNaming` | node | The Arc machine is named after the node's host name. A device-ID name (`<id>-1`) is reported, not reproduced here, as the cause of a step 0.41 failure on a prerelease build in another environment (known issue `arc-device-id-name`) | Warning in every phase (never a blocker); the remedy says how to set the Arc resource name to the host name | all |
| `OsConfigurationConverged` | node | The OS configuration report says the node converged (or planned nothing to change) and is for this cluster; without a report: `Skipped` with a warning, or Failed when `require_os_configuration_report` | Failed | all |
| `OsBuildConsistent` | run | Every node runs the same OS build (Arc `osVersion`, else the OS report); the handoff's solution build (`vsrVersion`) is shown, not compared, because its format differs from the OS version | Failed | all |
| `SbeConsistent` | run | The SBE values are known (`hardware.sbe` or the SBE folder), else a Warning: the deployment then uses the SBE the OS install discovered | Warning | all |
| `SbeValidatedWithSolution` | run | The configured SBE (family, version) is listed in the OEM's SBE discovery catalog as validated with the solution version in use (read from a file, no download: run setting `sbeCatalogPath`, else `SBE_Discovery_*.xml` in `hardware.sbe.bundle_path`). Solution version: run setting `solutionVersion`, else the ZTP handoff, else derived from the nodes' OS build (only builds in a short table map; the result says it is derived). Failed names the validated SBE versions of the family and the fix; Warning when the solution version or the SBE entry is unknown; Skipped without a catalog | Failed | all |
| `DnsAndTime` | run | DNS servers set and valid (unless DHCP), NTP servers set; the OS report's `Dns` and `Time` steps are fine; for Active Directory the DNS server resolves the domain (when it can be asked) | Failed / Warning | all |
| `ActiveDirectoryPrepared` | run | Active Directory only: `ou_path` is not the top level, the LCM user name is 20 characters or fewer, and (from a domain-joined host with the ActiveDirectory module) the OU and the LCM user exist | Failed / Skipped | all |
| `LocalIdentityPrerequisites` | run | Local identity only: `dns_zone` is set and the Key Vault is reachable for the identity secrets | Failed | all |
| `NoLeftoverFailedDeployment` | run | Validate: the instance is not in a failed deployment state (Microsoft). Deploy: a failed state needs `-Resume`; a running deployment is attached to | Failed | Validate, Deploy |
| `ValidatedBeforeDeploy` | run | Deploy: `validationStatus` is Succeeded, and the ARM deployment named from the same parameter hash exists and succeeded (Warning when the validation was run elsewhere, for example in the portal) | Failed / Warning | Deploy |

**Quotas.** Azure Local has no compute quota to check. What fails for resource reasons is the provider registration, the
permissions and the names, which are checked above. Anything else (regional capacity of the Arc Resource Bridge image, for
example) shows up in the validation steps and the known issues.

---

## 5. Parameters from the master file

`New-AzlArmParameterSet` (existing) builds every parameter of the right template for the scenario; `Test-AzlArmParameterSet`
checks it against the template's own parameter list. The run adds:

- **A key check before generation.** `config/azure/arm-templates/parameter-sources.json` lists, per ARM parameter, the
  `infrastructure.yml` keys it comes from and when it is required (always, or for one identity, storage or topology choice).
  A required value that is empty stops the run with exit 2 and a message in the form
  `ARM parameter adouPath is required for Active Directory; set identity.active_directory.ou_path in infrastructure.yml`.
  All missing keys are listed at once.
- **The mapping printed.** `parameter-sources.md` in the report directory shows, for this scenario, each parameter, the keys it
  came from and whether the value is a secret reference.
- **A parameter hash.** SHA-256 over the canonical parameter JSON without `deploymentMode` (secrets as references). The first
  12 characters name the ARM deployments `azl-validate-<hash>` and `azl-deploy-<hash>`.

| Scenario | Template | Differences in the parameters |
| --- | --- | --- |
| AD + S2D | `create-cluster` | `domainFqdn`, `adouPath`, LCM user and password; `storageNetworkList` |
| Local identity + S2D | `create-adless-cluster-external-dns-public-preview` | `identityProvider`, `dnsZones`; no AD, no LCM |
| AD + SAN (Fibre Channel) | `create-cluster-san` | `sanNetworkList`, `infraVolLunId`, `infraPerfLunId` (LUN numbers translated to UniqueIds by the OS report) |
| Local identity + SAN | `create-cluster-adless-san` | same, without AD |
| Hybrid | `create-cluster` | Deployed as S2D; the SAN is connected afterwards (Learn: external storage) |
| Rack aware | `create-cluster-rac-enabled` | `clusterPattern`, `localAvailabilityZones` |
| Switchless / switched / 1 node | any | `networkingType` is `switchlessMultiServerDeployment`, `switchedMultiServerDeployment` or `singleServerDeployment`; `storageConnectivitySwitchless` |
| iSCSI SAN, disconnected, Azure Government with local identity | not generated | The run stops with exit 2 and says so |

---

## 6. State machine of a run

```
                         +--------------------------------------------------------------+
                         |                                                              |
 Prepared --submit--> Validating --> ValidationPassed --> AwaitingApproval --> Deploying |
    |   \                  |   \             |                  |    \            |  \   |
    |    \                 |    +-> ValidationTimedOut          |     +-> (stop)  |   +--+--> DeploymentTimedOut
    |     +-skip-(already  +------> ValidationFailed            +-> (declined)    |
    |        validated)--> ValidationPassed                                       +--> DeploymentFailed
    |                                                                             +--> DeploymentSucceeded
    +--(Deploy mode, or -Resume)--> Resumed --> Deploying | DeploymentSucceeded
```

| State | Meaning | Next |
| --- | --- | --- |
| `Prepared` | Inputs read, parameters generated, preconditions passed | Validating, Resumed, ValidationPassed (already validated) |
| `Validating` | A Validate deployment is running in Azure and the tool is polling | ValidationPassed, ValidationFailed, ValidationTimedOut |
| `ValidationPassed` | `validationStatus` Succeeded, fresh, for these parameters | AwaitingApproval, Deploying, end (mode Validate) |
| `ValidationFailed` | The validation failed; the failing step and the known issue are in the report | end |
| `ValidationTimedOut` | The wait limit passed while Azure was still working. Azure keeps going; run again to attach | end |
| `AwaitingApproval` | The gate. `stop`: the run ends here with exit 0 and says how to continue. `prompt`: asks the operator. `none`: passes at once | Deploying, end |
| `Deploying` | A Deploy deployment is running and the tool is polling | DeploymentSucceeded, DeploymentFailed, DeploymentTimedOut |
| `Resumed` | The run started from an existing Azure deployment instead of from nothing: a failed Deploy being resubmitted, a deployment still running (attached to), or one that already succeeded (nothing to do) | Deploying, DeploymentSucceeded |
| `DeploymentSucceeded` | `deploymentStatus` Succeeded | end |
| `DeploymentFailed` | Failed; failing step, known issue, next action in the report | end (a later run with `-Resume` enters `Resumed`) |
| `DeploymentTimedOut` | Wait limit passed, Azure still running | end (a later run attaches) |

A transition not in the table throws, so a bug cannot silently skip a gate. The history (state, time, reason) is in
`report.json`. Across runs the state is not stored by the tool: **Azure is the record** (`deploymentSettings/default` and the
named ARM deployments), so a pipeline's second job needs no artifact from the first to know where things stand.

---

## 7. Idempotent re-runs and resume

| Situation found in Azure | Mode Validate | Mode Deploy |
| --- | --- | --- |
| No cluster resource, nothing submitted | Submit `azl-validate-<hash>` | Refused: no successful validation |
| Validation Succeeded, ARM deployment `azl-validate-<hash>` Succeeded | `ValidationPassed` without submitting (`ValidationSkipped` event). `-Settings @{ revalidate = $true }` submits again | Submit `azl-deploy-<hash>` |
| Validation Succeeded, different parameter hash (the file changed) | Submit a new Validate | Failed `ValidatedBeforeDeploy`: validate the new parameters first |
| Validation InProgress (ours, same hash) | Attach: poll it | Refused |
| Validation Failed (instance not in a failed deployment state) | Fix the cause, run again: submits a new Validate | Refused |
| Deployment InProgress | Refused (`NoLeftoverFailedDeployment` names it) | Attach: poll it (`Resumed`) |
| Deployment Failed or the ARM deployment Failed | **Refused**: Microsoft says not to Validate again. `-AllowRevalidate` exists for support-guided recovery and is not in the pipelines | **Resume**: needs `-Resume` or `deployment.resume: true`; resubmits the same Deploy |
| Deployment Succeeded | Nothing to validate; reported | `DeploymentSucceeded` without submitting |

**What Microsoft supports.** The portal has *Resume deployment* on a failed instance's Deployments page (Learn, "Deploy Azure
Local using the Azure portal"). For the ARM route Learn describes the flow as Validate, then **Redeploy** with the same
parameters and `deploymentMode` Deploy, and warns against a second Validate after a failure. This tool resumes by submitting
the same parameters in Deploy mode again under the same deployment name. That this resumes at the failed step, as the portal
button does, rather than starting over is **not documented for the ARM route and is not verified here**. The report says
"resubmitted" (not "resumed at step N") and the first step events after a resume show where Azure actually restarted. Before
a resume the known issue for the failure is shown, and a known issue with `retry: none` blocks the resume until the cause is
acknowledged (`deployment.acknowledge_known_issues`).

---

## 8. Polling

Submit returns at once. The tool then reads the ARM deployment and `deploymentSettings/default` until done:

- Delay between reads: 15 s, times 1.5 each read, up to 120 s (`poll_seconds`, `poll_max_seconds`). No jitter, so tests are exact.
- Limits: Validate 90 minutes, Deploy 360 minutes (`validate_timeout_minutes`, `deploy_timeout_minutes`). At the limit the
  state is `ValidationTimedOut` or `DeploymentTimedOut`, exit 1, and Azure is left running. Nothing is cancelled.
- A read that fails (throttling, a 5xx, a dropped connection) is a Warning event and a retry; five in a row end the wait as
  failed. This matters during Deploy, when the management network briefly changes.
- Stale status: an earlier attempt's `validationStatus` is still on the resource when a new Validate starts. A snapshot counts
  only when our named ARM deployment reached a terminal state **and** the step times are not older than the submit time
  (5 minutes of clock skew allowed). Otherwise the tool keeps waiting.
- Each poll compares every step's status with the last one seen and emits a `ValidationStep` or `DeploymentStep` event only
  for what changed.
- The clock and the sleep are injected, so the tests run a 6-hour wait in milliseconds.

---

## 9. Failing step and known issues

The step tree of `reportedProperties.validationStatus` / `deploymentStatus` is flattened with each step's `fullStepIndex` (the
number the portal shows, for example `0.41`), name, status, times and `exception` texts. The **failing step** is the first
deepest step with status Error or Failed. The failure text is that step's exceptions plus the ARM deployment's error message,
with secrets scrubbed.

`config/known-issues/arm-deployment.json` maps a failure to guidance. An entry matches when every `match` member it gives
(`stepId`, `stepName`, `error`: regular expressions, case-insensitive) matches; the entry with the most members wins.

| Id | Match | Cause in one line | Retry | Seen |
| --- | --- | --- | --- | --- |
| `arc-device-id-name` | step name Arc infrastructure, error ParentResourceNotFound (Deploy) | Arc machines are named `<device-id>-1`; the step looks them up by host name (reported against a prerelease build in another environment, not reproduced here) | none | pattern |
| `arc-device-id-name-step-0-41` | step id `0.41` (Deploy) | Same, when the text is different | none | observed |
| `unsupported-os-version` | error text "Unsupported OS version" | The build is not accepted for a new deployment in this subscription, or nodes differ | after-fix | observed |
| `registration-5901` | error 5901 | 403 on the target Arc machine soon after the role assignment | resubmit-once | observed |
| `role-assignment-already-exists` | role assignment exists | An earlier portal attempt in the same resource group | after-fix | documented |
| `role-assignment-zombie` | "aren't allowed to be updated" | Role assignments of deleted resources remain | after-fix | documented |
| `license-sync-after-failed-validate` | license sync | A second Validate after a failure | no-validate | documented |
| `ad-prerequisites` | external Active Directory, OU, LCM user | AD preparation missing or mismatched | after-fix | pattern |
| `dns-resolution` | name resolution, ADWS | DNS cannot resolve the domain or Azure | after-fix | pattern |
| `vmswitch-not-bound` | not bound to the management virtual switch | Stale validation switch data after a failed Validate | after-fix | documented |

`DeploymentFailed` and `ValidationFailed` events carry `knownIssue` (the id, or empty) and the report carries the whole entry.
Only the entries marked observed or documented were seen or written by Microsoft; `pattern` entries are matched by name or text
and have not been seen in one of our runs.

---

## 10. Approval gate

`deployment.approval` (or `-ApprovalMode`):

| Mode | ValidateAndDeploy behaviour |
| --- | --- |
| `stop` (default) | Ends after a good Validate: state `AwaitingApproval`, event `ApprovalRequested`, exit 0, `nextAction` says to run Mode Deploy. Safe default for every unattended run |
| `prompt` | Asks on the console (`yes` to continue). Without an interactive console it behaves as `stop` |
| `none` | Continues at once (`-AutoApprove`); for a lab |

**Pipelines** do not use `ValidateAndDeploy`. They run `Validate` in one job, publish its report, and run `Deploy` in a second
job that sits behind the platform's approval feature (GitHub environment with required reviewers, GitLab manual protected
job, Azure DevOps environment with an approval check). The reviewer reads the Validate job's `summary.md`. The Deploy job
re-checks every precondition and `ValidatedBeforeDeploy` itself, so an approval cannot launch a Deploy of parameters that were
never validated.

---

## 11. Outputs

**Event feed**, `arm-deployment-events.jsonl`, JSON Lines, UTF-8 without BOM, UTC round-trip timestamps, appended:
`timestamp, node, stage ("ArmDeployment"), step, state, evidence, level (Info|Warning|Error), nextAction, schemaVersion,
runId, mode, cluster`, plus per event data. `node` is `*` for the run and the node name for per-node checks.

| State | Step | Extra fields |
| --- | --- | --- |
| `RunStarted` | | `nodes`, `template`, `runMode` |
| `PreconditionChecked` | check name | `name`, `result` (Passed, Failed, Warning, Skipped) |
| `ParametersGenerated` | | `template`, `parameterCount`, `parameterHash`, `deploymentSettingsApiVersion` |
| `PlanCompleted` | | `failedPreconditions` |
| `RunStateChanged` | | `from`, `to` |
| `ValidationSubmitted` / `DeploymentSubmitted` | | `deploymentName` |
| `ValidationSkipped` | | `deploymentName` (already validated for these parameters) |
| `ValidationStep` / `DeploymentStep` | `fullStepIndex` | `status`, `stepName`, `depth` |
| `ValidationPassed` / `ValidationFailed` / `ValidationTimedOut` | failing step | `knownIssue`, `status` |
| `ApprovalRequested` / `ApprovalGranted` | | `approvalMode` |
| `DeploymentResumed` | | `deploymentName`, `previous` (Failed, InProgress, Succeeded) |
| `DeploymentSucceeded` / `DeploymentFailed` / `DeploymentTimedOut` | failing step | `knownIssue`, `stepName`, `status` |
| `PollError` | | `consecutive` |
| `PhaseRefused` | | `phase`, `knownIssue` (a Validate or Deploy that was not started, with the reason) |
| `RunFailed` | | the message (an input error or an unexpected failure) |
| `RunCompleted` | | `exitCode`, `state` |

Sonar needs nothing new to read it: the fields are those of the ZTP and OS configuration feeds, and the step number matches
the step tree it reads from Azure.

**`report.json`** (schema 1): run id, mode, cluster, template, parameter hash, state and state history, exit code, every
precondition result, validation and deployment sections (deployment name, status, steps, failed steps), the known issue entry,
approval, warnings, next action, timings. **`summary.md`**: the same for a person, in the job summary of a pipeline.

**Exit codes.** `0`: the requested part succeeded (Plan clean; Validate passed; Deploy succeeded; ValidateAndDeploy stopped at
the approval gate). `1`: a precondition failed, the validation or deployment failed or timed out. `2`: bad input (a file or a
required key missing, an unsupported scenario, no Azure sign-in when one is needed).

---

## 12. Authentication and security

- The tool never signs in; it needs an Az context. Jump server: `Connect-AzAccount` (user, or `-Identity` on an Azure VM).
  Pipelines: GitHub `azure/login` with OIDC, GitLab an ID token to `Connect-AzAccount -FederatedToken`, Azure DevOps a
  workload identity federation service connection. No client secret is stored anywhere.
- The identity needs: read on the resource group, Arc machines, Key Vault secret metadata and `Get` on the secrets named by the
  references, deployment write, and the rights listed under `Permissions` above.
- Secrets pass through memory as secure ARM parameters. The values are remembered only to scrub them from texts. Reports,
  events, parameter files (secret members are null) and logs contain references and names only.
- A report directory is a run artifact, not for a repository: it holds subscription, tenant and node addresses.

---

## 13. Tests and what is verified

All tests run without Azure (the adapter is replaced). See `tests/arm-deployment/`.

| Area | Test file |
| --- | --- |
| Parameters per scenario (AD or local identity; S2D or SAN; switchless or switched; 1, 2, 4, 16 nodes) and the key check | `ArmDeploymentRun.Parameters.Tests.ps1` |
| Preconditions | `ArmDeploymentRun.Preconditions.Tests.ps1` |
| State machine, polling with a fake clock, failing step, known issues, resume, approval, events, exit codes, secret scrub | `ArmDeploymentRun.Tests.ps1` |
| Pipelines parse and contain the gates | `ArmDeploymentRun.Pipelines.Tests.ps1` |
| Backslash scan of the new and changed files; the entry point in a child pwsh (`-Offline`) | `ArmDeploymentRun.CrossPlatform.Tests.ps1` |
| Schema 5.6 deployment block, AZL-040, the variables reference | `ArmDeploymentRun.Schema.Tests.ps1` |

**Verified** (by tests with mocks): the parameter generation and key messages per scenario; the precondition logic on fake
Azure and fake nodes; the state machine; the wait and its limits on a fake clock; the idempotency table; resume decisions;
known-issue matching on fixtures that copy the real step 0.41 failure; events, report and exit codes; secrets not in outputs;
the pipeline files parse.

**Not verified** (everything that needs Azure or a node): that the real `deploymentSettings` payload carries `fullStepIndex`
and times as assumed; the real ARM provisioning states during a Deploy; that resubmitting resumes at the failed step; the
Permissions and name-availability REST calls; the Active Directory probe; the pipelines on a real runner; Linux runs of the
existing modules (the infrastructure and Azure helper modules still carry Windows paths in this branch; the OS configuration
branch fixes them). A canary on one lab instance (Validate, then a Deploy that is allowed to fail) is the acceptance test.

---

## 14. Risks and open questions

| Rank | Risk | Handling |
| --- | --- | --- |
| 1 | Resubmitting a failed Deploy may restart rather than resume | Reported as "resubmitted"; read the first step events; confirm on the canary |
| 2 | `deploymentStatus` freshness rule wrongly rejects a good snapshot (no step times) | When no step has times the ARM deployment state alone decides; reports say which rule was used |
| 3 | Microsoft changes the quickstart templates' api-versions | `deployment_settings_api_version` override; catalog refresh |
| 4 | A known issue pattern matches the wrong failure | The match is shown in the report with the evidence text; `pattern` entries are labelled |
| 5 | The AD probe needs a domain-joined host | `Skipped` with the reason; the Microsoft validator is named in the next action |
| 6 | Approval depends on the platform feature being configured | The pipeline files say so at the top; the Deploy job re-checks Validate itself |

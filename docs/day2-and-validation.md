# Validation and day 2 operations (stages 07 and 08)

The scripts of stage 07 (validation and handover) and stage 08 (day 2 operations) work on a running Azure Local cluster. Each is a command an
operator can run by hand from a workstation or a jump server that reaches the cluster with PowerShell remoting, and each has a pipeline on GitHub
Actions, GitLab CI and Azure DevOps. This page shows both ways. The pipelines are in [pipelines/README.md](../pipelines/README.md); every value they
need is a key of `infrastructure.yml`, set on the platform by task 05 of the CI/CD setup.

| Task | Script | Reads or changes | Pipeline |
| --- | --- | --- | --- |
| Stage 07 task 01 to 04 | `Test-AzureLocalClusterHealth.ps1`, `Test-ArcConnectivity.ps1`, `Test-NetworkConfiguration.ps1`, `Test-StoragePerformance.ps1` | read only; with `-RunPerformanceTest` the last one writes load on the cluster | `validation` |
| Stage 08 task 01 | `Get-AvailableSolutionUpdate.azcli.ps1` and `Get-AvailableSolutionUpdate.ps1` | read only | `day2-check-updates` |
| Stage 08 task 02 | `Start-AzureLocalSolutionUpdate.ps1` | starts an update (`-PrepareOnly` only downloads and checks) | `day2-update` |
| Stage 08 task 03 | `Invoke-NodeMaintenanceReboot.ps1` | drains, reboots and resumes one node | `day2-node-maintenance` |
| Stage 08 task 04 | `Invoke-ClusterOperations.ps1` | `HealthCheck`, `Alerts` and `Capacity` read; `MaintenanceMode`, `LiveMigrate` and `Rebalance` change the cluster | `day2-cluster-operations` |

Both PowerShell scripts of the update stage (`Get-AvailableSolutionUpdate.ps1`, `Start-AzureLocalSolutionUpdate.ps1`) also append their run to `update-events.jsonl` in the events folder: `deployment.events_directory` in the master file, else `%ProgramData%&AzureLocalToolkit&<cluster.name>&events`. Mode `Check` for the check, `WhatIf` for a `-WhatIf` plan and `Install` for a started or prepared update; `RunStarted`, one event per step (environment, discovery, update) and `RunCompleted` or `RunFailed` with the exit code. azurelocal-sonar follows that file in its Update view without Azure. The pre-cluster gate's Plan writes `precluster-plan-events.jsonl` (mode `Plan`, one event per category, no verdict) to the same folder; its Verify feed `precluster-verification-events.jsonl` stays in the gate's report directory. A run given `-ReportDirectory` while `deployment.events_directory` is not set keeps its feed with the reports and warns that Sonar will not see it.

## Run it

```powershell
# Validation (read only; add -RunPerformanceTest to the storage script only in a maintenance window: it generates I/O on the cluster)
./scripts/deploy/07-validation-handover/task-01-cluster-health-validation/powershell/Test-AzureLocalClusterHealth.ps1 -InfrastructureFile ./infrastructure.yml -OutputFormat JSON -OutputPath ./reports/cluster-health
./scripts/deploy/07-validation-handover/task-02-arc-connectivity-validation/powershell/Test-ArcConnectivity.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath ./reports/arc-connectivity
./scripts/deploy/07-validation-handover/task-03-network-configuration-validation/powershell/Test-NetworkConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath ./reports/network
./scripts/deploy/07-validation-handover/task-04-storage-performance-validation/powershell/Test-StoragePerformance.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath ./reports/storage

# Check for updates (read only; the Azure view needs az signed in to the tenant of the file, the cluster view needs a route to the cluster)
./scripts/deploy/08-day2-operations/task-01-check-for-updates/azurecli/Get-AvailableSolutionUpdate.azcli.ps1 -InfrastructureFile ./infrastructure.yml -OutputPath ./reports/update-check.json

# The monthly update: see what it would do, download it, then start it inside the maintenance window
./scripts/deploy/08-day2-operations/task-02-start-solution-update/powershell/Start-AzureLocalSolutionUpdate.ps1 -InfrastructureFile ./infrastructure.yml -Mode OnDemand -WhatIf
./scripts/deploy/08-day2-operations/task-02-start-solution-update/powershell/Start-AzureLocalSolutionUpdate.ps1 -InfrastructureFile ./infrastructure.yml -Mode OnDemand -PrepareOnly
./scripts/deploy/08-day2-operations/task-02-start-solution-update/powershell/Start-AzureLocalSolutionUpdate.ps1 -InfrastructureFile ./infrastructure.yml -Mode OnDemand

# One node through maintenance (check the node against the file first, then the real run), and the cluster operations
./scripts/deploy/08-day2-operations/task-03-node-maintenance/powershell/Invoke-NodeMaintenanceReboot.ps1 -InfrastructureFile ./infrastructure.yml -TargetNode node01 -RequireNodeInFile -WhatIf
./scripts/deploy/08-day2-operations/task-04-cluster-operations/powershell/Invoke-ClusterOperations.ps1 -InfrastructureFile ./infrastructure.yml -Action HealthCheck -OutputPath ./reports/health.json
```

Exit codes are the same in every script of these two stages: 0 done (or planned under `-WhatIf`), 1 a check failed, the cluster needs attention or a
step failed, 2 a value of the file is missing or not usable (nothing was sent).

## Run it in a pipeline

Each pipeline runs the command above on the general self-hosted runner and nothing else. See [pipelines/README.md](../pipelines/README.md#validation-and-day-2-stages-07-and-08)
for the files per platform, the inputs, the approval and the lock.

- **A read-only job comes first.** The pipelines that change something run the script with `-WhatIf` as a plan job, and only then, behind the
  approval environment of `devops.pipelines.environments.operations`, run it for real. The check for updates and the validation have no approval job
  at all, apart from the storage performance test (below).
- **The storage performance test is behind the approval.** `-RunPerformanceTest` writes and reads a scratch file on every cluster shared volume. The
  validation pipeline runs the other checks read only and the load test as a separate approved job (input `run_performance_test`).
- **No approval environment, no change.** With `devops.pipelines.environments.operations` empty, the job that changes the cluster does not run on any platform: on GitHub and GitLab a refusal job (`approval-environment-not-set`) fails with a message that names the variable, and on Azure DevOps the stage `ApprovalEnvironmentNotSet` does. Nothing is changed.
- **One change at a time.** The update, the node maintenance, the changing cluster operations and the load test share one concurrency group
  (GitHub), one `resource_group` (GitLab) and one environment with an Exclusive lock check (Azure DevOps), so two of them never run on the cluster
  together.
- **One node per run.** The node is a run input checked against `nodes[]` of the file (`-RequireNodeInFile`): a name the file does not list ends the
  run with exit code 2 before anything is sent. Run the pipeline again for the next node after the storage has repaired.
- **The account.** The scripts connect as the service account of the runner, which must be an administrator of the cluster. No node password is in a
  pipeline; the node maintenance reads the node login from the secret reference of the file (`identity.local_admin`), like every other toolkit script.
- **A schedule for the check.** `day2-check-updates` runs on the schedule `devops.pipelines.schedules.check_for_updates` (default every day at 04:17
  UTC) and fails the run when the cluster needs attention, so the platform's notification of a failed run is the alert. GitHub and Azure DevOps keep the cron
  expression in the pipeline file and GitLab in the project; task 05 writes the cron line (and the Azure DevOps branch) and creates the GitLab schedule, so
  the key works on all three platforms (D126); the README has the table.

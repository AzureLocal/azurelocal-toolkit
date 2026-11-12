# Paid security services (optional, not part of the automation)

Nothing in this folder is run by a pipeline, an orchestrator or any other script of the toolkit. Everything
here turns on services that are billed. Turning them on is the operator's own decision.

What the toolkit automation does turn on is the free level that Azure Local needs to show its security
settings in the Azure portal: Foundational CSPM and the Microsoft cloud security benchmark initiative. That is
`scripts/deploy/05-operational-foundations/phase-04-security-governance/task-01-enable-defender-for-cloud/powershell/Enable-DefenderForCloud.ps1`.

| Folder | What it turns on | State |
|---|---|---|
| `defender-paid-plans` | Defender CSPM with its add-ons, Defender for Servers Plan 2, Defender for SQL on machines, on every subscription of the tenant | Not working: `Deploy-DefenderPaidPlans.ps1` has parse errors and loads a helper that is not in the repository. Kept as a starting point only |

Not in the toolkit: Microsoft Sentinel and third-party agents (for example Datadog). There is no script for either.

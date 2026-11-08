# Handoff

<!--
  Written at the END of every session by whichever tool was used.
  This is the single most important cross-tool file — the next session
  (possibly a different tool) starts by reading it.
-->

## Last session

- **What changed and why:** Fixed the OS configuration host/node stalls found on the first real lab runs (branch `fix/guard-status-stall`, from toolkit main 4992b41). The node-side guarded change worked every time, but the host never received the guard STATUS result, so every status call hung to its hard cap, the guard ended Unknown and halted the run (SBE delivery and the unused-port step never ran).
  1. Status payload answers at once (partial result right after the acknowledgement), shared-stream log tail, no `-Recurse`; ack-only payload; an abandoned call hands back the partial output it had (`0eba2bc`).
  2. Caps (status/ack 30, stage 60, Read 90, restart 60, Apply 300 or 900 with a storage wipe; hard cap = timeout + 15 s), session options (open 30 s, cancel 5 s), Stopwatch wait, background clean-up of an abandoned call, `NodeCallAttempt` events, `ObservedCommitted` (an Unknown guard whose items a Read shows in place no longer halts), circuit breaker (`ffb09fb`).
  3. Chunked, resumable SBE delivery over WinRM (8 MiB, 60 s per chunk, `SbeDeliveryProgress`), small files first, and a report that says why the package is missing (`4151935`).
- **Files touched:** scripts/common/node-configuration/{AzlNodeTransport,AzlNodeGuard,AzlGuardedChange,AzlNodeConfiguration,AzlOsConfigurationEvents,AzlOsConfigurationRun}.psm1, Set-AzureLocalNodeConfiguration.ps1, config/variables/schema/master-registry.yaml, docs/os-configuration-and-arm-deployment.md, tests/node-configuration (new: GuardStatusStall, TransportCaps, GuardStallFlow, SbeChunkedDelivery).
- **Commands / tests run and results:** tests/node-configuration, pipelines, ansible, remoting, variables with fakes only (4 processes, BelowNormal); PSScriptAnalyzer with scripts/tools/qa/PSScriptAnalyzerSettings.psd1 clean. The node payloads were also run under Windows PowerShell 5.1 against a local sandbox folder. Nothing was run against a node or Azure.
- **Branch:** fix/guard-status-stall (worktree D:\git\worktrees\tk-stallfix) — committed: yes — pushed: no
- **Blockers:** None. Unverified on a real node: the status call may still stall inside the node's slow part (live adapter query) after the early answer; each such call then costs the 45 s cap instead of 210 s.
- **Exact next steps:** Run the OS configuration on a lab node and read the `NodeCallAttempt` events for the real cost of each call; if status still hangs, bound the live-adapter section on the node. Consider `node_pull` for the SBE zip when the node has a route to the URL.

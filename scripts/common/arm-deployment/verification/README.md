# Verification modules

Every `AzlVerification.*.psm1` in this folder is imported by the pre-cluster verification gate (`../AzlPreClusterVerification.psm1`). A module adds checks to the gate.

A module exports:

- `Get-AzlVerificationCheckDefinition`: an array of `@{ Id; Category; Title; Source; Blocking; Applies = { param($Context) }; Run = { param($Context) } }`.
- `Get-AzlVerificationAdapterDefault` (optional): a table of read only scriptblocks that the module's checks call through `$Context.Adapters`.

`Run` returns `@{ Status = 'Passed'|'Failed'|'Warning'|'Skipped'|'NotApplicable'; Node = '*'; Message; Remedy; Evidence }` (one per node for a per-node check). A check reads Azure,
Active Directory and the nodes only through `$Context.Adapters`, so that a test can replace them with fakes.

The full contract, with the `$Context` members, is in [docs/pre-cluster-verification.md](../../../../docs/pre-cluster-verification.md), section "Verification modules".

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 1.0.0 (2026-05-12)


### Features

* add -AssociateNsg switch to orchestrated script, add associate_nsg flag to standalone script ([c77ba47](https://github.com/AzureLocal/azurelocal-toolkit/commit/c77ba47f3070da57b55178df3ba91e1d31113198))
* add Azure Local automation foundation ([009f026](https://github.com/AzureLocal/azurelocal-toolkit/commit/009f0263f9fbbadfda5b7dbe85ea1c250fe6e53c))
* add Dell OS10 ToR switch reference configs for Azure Local ([8932605](https://github.com/AzureLocal/azurelocal-toolkit/commit/893260568776ca44c109a4e43883306d9cb3e6ea))
* add generated deployment script scaffolds ([2054b82](https://github.com/AzureLocal/azurelocal-toolkit/commit/2054b82f2624cf4cb030dbdfe55de79af63119f1))
* add NSG script folder, renumber task folders, populate variables with NSG and logical network config ([7dce96d](https://github.com/AzureLocal/azurelocal-toolkit/commit/7dce96ddb9289e06be651bc1219a82c4edd9188d))
* add primary scripts, azurecli/bash scaffolding, and issue template ([343cd2b](https://github.com/AzureLocal/azurelocal-toolkit/commit/343cd2b24033a8f0682b0d4904d1633bc431d995))
* add reusable QA and authoring tools (closes [#19](https://github.com/AzureLocal/azurelocal-toolkit/issues/19)) ([1280ae2](https://github.com/AzureLocal/azurelocal-toolkit/commit/1280ae2b6889dcf19fd41369bd7e992234968e8f))
* add sync-issues-to-project script for full project coverage ([570e167](https://github.com/AzureLocal/azurelocal-toolkit/commit/570e1671a2148a7891ebdff9742d619e4df4f6a9))
* add unique project ID field automation (TKT-N prefix) ([c6cc365](https://github.com/AzureLocal/azurelocal-toolkit/commit/c6cc36524921940b66f7ae3b016c0996b133ae3f))
* complete variable registry standardization (Phases 2-7) ([5f20d9f](https://github.com/AzureLocal/azurelocal-toolkit/commit/5f20d9fb4528a73bf412639bcee03ce6b86561d3))
* extract scripts from implementation docs for 17 tasks ([8ed4f9c](https://github.com/AzureLocal/azurelocal-toolkit/commit/8ed4f9cc01b59420f05559585a26c2e3231e4aa6))
* initial toolkit migration from prodtech-docs-azl-toolkit ([29645e3](https://github.com/AzureLocal/azurelocal-toolkit/commit/29645e318772ced78903a85b090952b59785963c)), closes [#12](https://github.com/AzureLocal/azurelocal-toolkit/issues/12)
* **tests:** add Pester 5 and PSScriptAnalyzer testing framework ([aa6000f](https://github.com/AzureLocal/azurelocal-toolkit/commit/aa6000f1833379282f59447fe5a3c84ba43fd54d)), closes [#19](https://github.com/AzureLocal/azurelocal-toolkit/issues/19)


### Bug Fixes

* add reopened trigger to add-to-project workflow ([a085469](https://github.com/AzureLocal/azurelocal-toolkit/commit/a08546999338ecefcc7bec598239a37deb38310f))
* make set-fields resilient to add-to-project failures ([6b02773](https://github.com/AzureLocal/azurelocal-toolkit/commit/6b027736b1556c0cf00718ed51abcad8bd3c0ee6))
* remove all hallucinated content from master-registry ([f6a5573](https://github.com/AzureLocal/azurelocal-toolkit/commit/f6a5573a4767c75ee80799262eb94ab2def6eedf))
* remove invalid sitemap plugin, move gtag to preset options ([8dbc1fd](https://github.com/AzureLocal/azurelocal-toolkit/commit/8dbc1fda6d42d2fa18f7a44197243c2f79c49849))
* remove remaining hardcoded variable validation paths ([16c99f0](https://github.com/AzureLocal/azurelocal-toolkit/commit/16c99f077e30d423c4f182963951a8696b2cb579))
* remove solutions directory and all solution references ([5e7dda7](https://github.com/AzureLocal/azurelocal-toolkit/commit/5e7dda7bd2d9f8181b5b1a362c6d01f93567af74))
* repair registry and schema validation paths ([6bbd7dc](https://github.com/AzureLocal/azurelocal-toolkit/commit/6bbd7dc7924aadbbcaf7fe2030b8eba568ccb877))
* replace hardcoded local path in check-alias-expiry.ps1 with PSScriptRoot-relative path ([4e11713](https://github.com/AzureLocal/azurelocal-toolkit/commit/4e11713b38f93993ba83ed5f045072f8d71128a4))
* **tests:** correct function name mismatches and scope bugs in unit tests ([f3cea31](https://github.com/AzureLocal/azurelocal-toolkit/commit/f3cea314d3012834e8ff74512e837d902724f611))
* **tests:** load logging.ps1 as module-only to fix persistent file-logging test failures ([d8b1746](https://github.com/AzureLocal/azurelocal-toolkit/commit/d8b1746372f74cb05bc5e7c58e1855c86152b30d))
* **tests:** resolve remaining 4 CI failures in unit tests ([aff66d1](https://github.com/AzureLocal/azurelocal-toolkit/commit/aff66d15faeff84998a5c8d7620618be695255fe))
* **tests:** use Get-Content -Raw for multi-line pattern matching in Pester 5 ([46aeb5c](https://github.com/AzureLocal/azurelocal-toolkit/commit/46aeb5c4a43f8c295d0756f8c5ec21357b8cdd13))
* update Solution field option IDs and set toolkit option ID ([dc38e7b](https://github.com/AzureLocal/azurelocal-toolkit/commit/dc38e7bcfdf0596b123377f96db5c6c90d2a6bec))
* use action output for item ID, fix stale solution field option IDs ([8b240a2](https://github.com/AzureLocal/azurelocal-toolkit/commit/8b240a28cc9164ded9eaf8f5df4d9323c261598d))


### Reverts

* remove incomplete QA framework (issue [#19](https://github.com/AzureLocal/azurelocal-toolkit/issues/19) redo) ([a1fc19d](https://github.com/AzureLocal/azurelocal-toolkit/commit/a1fc19d1254d8b8a9b29c78952d41e52418d4fac))

## [Unreleased]

### Changed

- Removed the MkDocs site, docs publishing workflow, and repository `docs/` tree; the README is now the primary repo-level documentation.

### Features

- Initial repository scaffold — MkDocs Material, release-please, GitHub Pages, CI/CD workflows
- Migrate toolkit content from AzureLocalCloud-docs-azl-toolkit (scripts, configs)
- Branding scrub — remove all Azure Local Cloud/AzureLocalCloud/HCS references

# Repository Setup — azurelocal-toolkit

> How this repository is configured. Use this as the reference when replicating
> this setup to a new repository or auditing an existing one.

---

## Branch Protection — main

| Setting | Value |
|---------|-------|
| Require pull request before merging | Yes |
| Required approving reviews | 0 (small team — review is encouraged not enforced) |
| Dismiss stale reviews on new push | No |
| Require status checks to pass | Yes |
| Required status checks | `test` (Test Scripts), `check-structure` (Validate Repo Structure) |
| Require branches to be up to date | No |
| Allow force pushes | No |
| Allow deletions | No |
| Administrator bypass | Yes — allows org admins to push directly for controlled maintenance |

---

## Labels

Labels are defined in and synced from:
[`azurelocal.github.io/.github/labels.yml`](https://github.com/AzureLocal/azurelocal.github.io/blob/main/.github/labels.yml)

The `sync-labels` workflow on `azurelocal.github.io` handles propagation. When new labels are added to `labels.yml`, they are synced to all repos in the organisation.

Label prefixes used:
- `type/` — feature, bug, docs, infra, refactor, security
- `priority/` — critical, high, medium, low
- `solution/` — which AzureLocal solution the issue belongs to
- `status/` — work state tracking

---

## Secrets

| Secret | Required by | How to create |
|--------|-------------|---------------|
| `ADD_TO_PROJECT_PAT` | `add-to-project.yml` | GitHub PAT with `project` scope, owned by a user with org project write access. Set at: Settings → Secrets and variables → Actions → New repository secret |
| `GITHUB_TOKEN` | All other workflows | Automatic — provided by GitHub Actions, no setup needed |

---

## CODEOWNERS

File: `.github/CODEOWNERS`

```
* @AzureLocal/maintainers
```

All files are owned by the `maintainers` team. Adjust to the actual team or individuals maintaining this repo.

---

## Issue Templates

Location: `.github/ISSUE_TEMPLATE/`

| Template | Purpose |
|----------|---------|
| `feature_request.md` | New feature or enhancement |
| `bug_report.md` | Bug report |
| `docs_issue.md` | Documentation problem |

---

## PR Template

File: `.github/pull_request_template.md`

Standard PR template covering: description, type of change, testing done, checklist.

---

## Release Automation

Configured by: `release-please-config.json` and `.release-please-manifest.json`

Release Please monitors conventional commits on `main` and:
1. Opens a release PR with updated `CHANGELOG.md` and bumped version
2. When the release PR is merged, creates a GitHub Release and git tag

Commit prefixes and their changelog sections:
- `feat:` → Features
- `fix:` → Bug Fixes
- `docs:` → Documentation
- `chore:` → Miscellaneous

---

## GitHub Project Integration

This repo's issues and PRs are automatically added to the AzureLocal organisation project:
[AzureLocal Project Board](https://github.com/orgs/AzureLocal/projects/3)

This is handled by `add-to-project.yml`. See [`automation.md`](automation.md) for details.

---

## Replication Checklist

When creating a new repo that should match this setup:

- [ ] Copy `.github/workflows/` — all workflow files
- [ ] Copy `.github/ISSUE_TEMPLATE/` — issue templates
- [ ] Copy `.github/pull_request_template.md`
- [ ] Copy `.github/CODEOWNERS` and update team/owner names
- [ ] Copy `release-please-config.json` and `.release-please-manifest.json`
- [ ] Add `ADD_TO_PROJECT_PAT` secret (Settings → Secrets → Actions)
- [ ] Sync labels from `azurelocal.github.io/.github/labels.yml`
- [ ] Enable GitHub Pages if repo has a docs site (Settings → Pages → GitHub Actions source)
- [ ] Set branch protection on `main` with required status checks matching the workflows in use
- [ ] Create `repo-management/README.md`, `repo-management/setup.md`, `repo-management/automation.md`

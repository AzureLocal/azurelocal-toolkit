# sync-issues-to-project.ps1
# Ensures every open issue (and PR, if desired) from all repos is in the GitHub Project.
# Then backfills Solution, Priority, Category, and ID fields for any newly added items.

$ErrorActionPreference = "Stop"

$projectId   = "PVT_kwDOCxeiOM4BR2KZ"
$projectNum  = 3
$org         = "AzureLocal"

# Field IDs
$ID_FIELD       = "PVTF_lADOCxeiOM4BR2KZzhADImQ"
$SOLUTION_FIELD = "PVTSSF_lADOCxeiOM4BR2KZzg_jXuY"
$PRIORITY_FIELD = "PVTSSF_lADOCxeiOM4BR2KZzg_jXvs"
$CATEGORY_FIELD = "PVTSSF_lADOCxeiOM4BR2KZzg_jXxA"

# Solution option IDs (must match option IDs in the project)
$SOLUTION_OPTIONS = @{
    "azurelocal-sofs-fslogix"          = "441d7b73"   # SOFS / FSLogix
    "azurelocal-avd"                   = "88c2cad1"   # AVD
    "azurelocal-loadtools"             = "e681af20"   # Load Tools
    "azurelocal-vm-conversion-toolkit" = "24cfc8b7"   # VM Conversion
    "azurelocal-toolkit"               = "5a5921eb"   # Toolkit
    "azurelocal.github.io"             = "409662e1"   # Docs
}

# Prefix map
$PREFIX_MAP = @{
    "azurelocal-sofs-fslogix"          = "SOFS"
    "azurelocal-avd"                   = "AVD"
    "azurelocal-loadtools"             = "LOAD"
    "azurelocal-vm-conversion-toolkit" = "VMCT"
    "azurelocal-toolkit"               = "TKT"
    "azurelocal.github.io"             = "DOCS"
}

$repos = @(
    "azurelocal-sofs-fslogix",
    "azurelocal-avd",
    "azurelocal-loadtools",
    "azurelocal-vm-conversion-toolkit",
    "azurelocal-toolkit",
    "azurelocal.github.io"
)

# ── Step 1: Collect all open issues from all repos ───────────────────────────
Write-Host "`n=== Step 1: Fetching all open issues from all repos ===" -ForegroundColor Cyan

$allIssues = @{}  # key = content URL, value = {repo, number, title, labels}

foreach ($repo in $repos) {
    Write-Host "  Fetching: $org/$repo" -NoNewline
    $page = 1
    $repoIssues = @()
    do {
        $batch = gh issue list --repo "$org/$repo" --state open --limit 200 --json number,title,url,labels 2>$null | ConvertFrom-Json
        if ($null -eq $batch -or $batch.Count -eq 0) { break }
        $repoIssues += $batch
        $page++
    } while ($batch.Count -eq 200)

    Write-Host " → $($repoIssues.Count) open issues"
    foreach ($issue in $repoIssues) {
        $allIssues[$issue.url] = @{
            repo   = $repo
            number = $issue.number
            title  = $issue.title
            labels = $issue.labels | ForEach-Object { $_.name }
            url    = $issue.url
        }
    }
}

Write-Host "Total open issues across all repos: $($allIssues.Count)" -ForegroundColor Yellow

# ── Step 2: Collect all items currently in the project ───────────────────────
Write-Host "`n=== Step 2: Fetching all current project items ===" -ForegroundColor Cyan

$projectUrls = @{}
$afterCursor = $null
$gqlQuery = 'query($projectId: ID!, $after: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            ... on Issue { url }
            ... on PullRequest { url }
          }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldTextValue {
                field { ... on ProjectV2Field { id } }
                text
              }
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { id } }
                optionId
              }
            }
          }
        }
      }
    }
  }
}'

do {
    if ($afterCursor) {
        $result = gh api graphql -f query=$gqlQuery -F projectId=$projectId -F after="$afterCursor" | ConvertFrom-Json
    } else {
        $result = gh api graphql -f query=$gqlQuery -F projectId=$projectId | ConvertFrom-Json
    }

    $page = $result.data.node.items
    foreach ($item in $page.nodes) {
        $url = $item.content.url
        if ($url) {
            # Track which fields are already set
            $hasId       = $false
            $hasSolution = $false
            $hasPriority = $false
            $hasCategory = $false
            foreach ($fv in $item.fieldValues.nodes) {
                if ($fv.field.id -eq $ID_FIELD       -and $fv.text)     { $hasId       = $true }
                if ($fv.field.id -eq $SOLUTION_FIELD -and $fv.optionId) { $hasSolution = $true }
                if ($fv.field.id -eq $PRIORITY_FIELD -and $fv.optionId) { $hasPriority = $true }
                if ($fv.field.id -eq $CATEGORY_FIELD -and $fv.optionId) { $hasCategory = $true }
            }
            $projectUrls[$url] = @{
                itemId      = $item.id
                hasId       = $hasId
                hasSolution = $hasSolution
                hasPriority = $hasPriority
                hasCategory = $hasCategory
            }
        }
    }

    $afterCursor = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
} while ($afterCursor)

Write-Host "Total items currently in project: $($projectUrls.Count)" -ForegroundColor Yellow

# ── Step 3: Find missing issues ───────────────────────────────────────────────
Write-Host "`n=== Step 3: Finding issues not in the project ===" -ForegroundColor Cyan

$missing = @()
foreach ($url in $allIssues.Keys) {
    if (-not $projectUrls.ContainsKey($url)) {
        $missing += $allIssues[$url]
    }
}

Write-Host "Issues missing from project: $($missing.Count)" -ForegroundColor $(if ($missing.Count -gt 0) { "Red" } else { "Green" })

if ($missing.Count -eq 0) {
    Write-Host "`nAll issues are already in the project. Nothing to do." -ForegroundColor Green
    exit 0
}

# ── Step 4: Add missing issues to the project ────────────────────────────────
Write-Host "`n=== Step 4: Adding missing issues to project ===" -ForegroundColor Cyan

$addMutation = 'mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
    item { id }
  }
}'

# We need the node ID for each issue (gh issue view gives us that)
$newItems = @()
foreach ($issue in $missing) {
    $repoFull = "$org/$($issue.repo)"
    Write-Host "  Adding $($issue.repo)#$($issue.number): $($issue.title.Substring(0, [Math]::Min(60, $issue.title.Length)))" -NoNewline

    # Get the node ID for the issue
    $nodeId = gh issue view $issue.number --repo $repoFull --json id --jq '.id' 2>$null
    if (-not $nodeId) {
        Write-Host " [ERROR: could not get node ID]" -ForegroundColor Red
        continue
    }

    # Add to project
    $addResult = gh api graphql -f query=$addMutation -F projectId=$projectId -F contentId=$nodeId 2>$null | ConvertFrom-Json
    $itemId = $addResult.data.addProjectV2ItemById.item.id
    if (-not $itemId) {
        Write-Host " [ERROR: add failed]" -ForegroundColor Red
        continue
    }

    Write-Host " [added: $itemId]" -ForegroundColor Green
    $newItems += @{
        itemId = $itemId
        repo   = $issue.repo
        number = $issue.number
        title  = $issue.title
        labels = $issue.labels
        url    = $issue.url
    }
}

Write-Host "`nSuccessfully added: $($newItems.Count) items" -ForegroundColor Yellow

# ── Step 5: Backfill fields on newly added items ──────────────────────────────
Write-Host "`n=== Step 5: Backfilling fields on new items ===" -ForegroundColor Cyan

function Get-PriorityOptionId($labels) {
    foreach ($l in $labels) {
        if ($l -match "critical")  { return "74334e8d" }
        if ($l -match "high")      { return "2e3ede9d" }
        if ($l -match "medium")    { return "7709e85d" }
        if ($l -match "low")       { return "2182b5f9" }
    }
    return "7709e85d"  # default: medium
}

function Get-CategoryOptionId($labels, $title) {
    # First try label-based detection
    foreach ($l in $labels) {
        if ($l -match "type/bug|^bug$")              { return "206e624a" }
        if ($l -match "type/feature|enhancement")    { return "7a4fa8ea" }
        if ($l -match "type/epic|^epic$")            { return "7a4fa8ea" }
        if ($l -match "type/docs|^doc")              { return "355ce6c1" }
        if ($l -match "type/infra|chore|cleanup")    { return "05996f93" }
        if ($l -match "type/refactor|refactor")      { return "7f5509ab" }
        if ($l -match "type/security|security")      { return "d2af4749" }
    }
    # Fall back to title conventional commit prefix
    if ($title -match '^docs[(:]')     { return "355ce6c1" }
    if ($title -match '^feat[(:]')     { return "7a4fa8ea" }
    if ($title -match '^fix[(:]')      { return "206e624a" }
    if ($title -match '^chore[(:]')    { return "05996f93" }
    if ($title -match '^ci[(:]')       { return "05996f93" }
    if ($title -match '^test[(:]')     { return "05996f93" }
    if ($title -match '^refactor[(:]') { return "7f5509ab" }
    return "7a4fa8ea"  # default: feature
}

foreach ($item in $newItems) {
    $prefix    = $PREFIX_MAP[$item.repo]
    $solOptId  = $SOLUTION_OPTIONS[$item.repo]
    $priOptId  = Get-PriorityOptionId($item.labels)
    $catOptId  = Get-CategoryOptionId $item.labels $item.title
    $idText    = "$prefix-$($item.number)"

    Write-Host "  $idText" -NoNewline

    # Set ID field
    gh project item-edit --project-id $projectId --id $item.itemId `
        --field-id $ID_FIELD --text $idText 2>$null | Out-Null

    # Set Solution field
    if ($solOptId) {
        gh project item-edit --project-id $projectId --id $item.itemId `
            --field-id $SOLUTION_FIELD --single-select-option-id $solOptId 2>$null | Out-Null
    }

    # Set Priority field
    gh project item-edit --project-id $projectId --id $item.itemId `
        --field-id $PRIORITY_FIELD --single-select-option-id $priOptId 2>$null | Out-Null

    # Set Category field
    gh project item-edit --project-id $projectId --id $item.itemId `
        --field-id $CATEGORY_FIELD --single-select-option-id $catOptId 2>$null | Out-Null

    Write-Host " [fields set]" -ForegroundColor Green
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "Added $($newItems.Count) missing issue(s) to the project and backfilled all fields." -ForegroundColor Green

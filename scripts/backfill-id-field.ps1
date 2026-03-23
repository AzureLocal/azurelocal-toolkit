#!/usr/bin/env pwsh
# Backfill the ID field (e.g., SOFS-8, AVD-42) for all project items missing it.

$ID_FIELD  = "PVTF_lADOCxeiOM4BR2KZzhADImQ"
$projectId = "PVT_kwDOCxeiOM4BR2KZ"

function Get-Prefix($url) {
    if ($url -match "azurelocal-sofs")                          { return "SOFS" }
    if ($url -match "azurelocal-avd")                           { return "AVD" }
    if ($url -match "azurelocal-loadtools")                     { return "LOAD" }
    if ($url -match "azurelocal-vm-conv")                       { return "VMCT" }
    if ($url -match "azurelocal\.github\.io|azurelocalcloud")   { return "DOCS" }
    if ($url -match "azurelocal-toolkit")                       { return "TKT" }
    return $null
}

$gqlQuery = 'query($projectId: ID!, $after: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            ... on Issue { url number }
            ... on PullRequest { url number }
          }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldTextValue {
                field { ... on ProjectV2Field { id } }
                text
              }
            }
          }
        }
      }
    }
  }
}'

$allItems = [System.Collections.Generic.List[object]]::new()
$afterCursor = $null
do {
    if ($afterCursor) {
        $result = (gh api graphql -f query="$gqlQuery" -F projectId="$projectId" -F after="$afterCursor" | ConvertFrom-Json)
    } else {
        $result = (gh api graphql -f query="$gqlQuery" -F projectId="$projectId" | ConvertFrom-Json)
    }
    $page = $result.data.node.items
    foreach ($n in $page.nodes) { $allItems.Add($n) }
    $hasNext     = $page.pageInfo.hasNextPage
    $afterCursor = $page.pageInfo.endCursor
} while ($hasNext)

Write-Host "Total items: $($allItems.Count)"
$updated = 0

foreach ($item in $allItems) {
    if (-not $item.content -or -not $item.content.url) { continue }

    # Skip if ID already set
    $hasId = $item.fieldValues.nodes | Where-Object { $_.field.id -eq $ID_FIELD -and $_.text }
    if ($hasId) { continue }

    $url    = $item.content.url
    $number = $item.content.number
    $prefix = Get-Prefix $url
    if (-not $prefix) { Write-Host "SKIP (unknown repo): $url"; continue }

    $idValue = "$prefix-$number"
    gh project item-edit --project-id $projectId --id $item.id --field-id $ID_FIELD --text $idValue | Out-Null
    Write-Host "Set $idValue  <- $url"
    $updated++
}

Write-Host "`nDone. $updated item(s) updated."

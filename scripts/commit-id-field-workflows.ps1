#!/usr/bin/env pwsh
$repos = @(
    @{ path = "C:\git\azurelocal-sofs-fslogix"; prefix = "SOFS" },
    @{ path = "C:\git\azurelocal-avd"; prefix = "AVD" },
    @{ path = "C:\git\azurelocal-loadtools"; prefix = "LOAD" },
    @{ path = "C:\git\azurelocal-vm-conversion-toolkit"; prefix = "VMCT" },
    @{ path = "C:\git\azurelocal-toolkit"; prefix = "TKT" },
    @{ path = "C:\git\azurelocalcloud-azurelocal.github.io"; prefix = "DOCS" }
)

foreach ($repo in $repos) {
    Set-Location $repo.path
    $status = git status --porcelain .github/workflows/add-to-project.yml
    if ($status) {
        git add .github/workflows/add-to-project.yml
        if ($repo.prefix -eq "TKT") {
            git add scripts/backfill-id-field.ps1
        }
        git commit -m "feat: add unique project ID field automation ($($repo.prefix)-N prefix)"
        git push
        Write-Host "DONE: $($repo.prefix)"
    } else {
        Write-Host "SKIP (already committed): $($repo.prefix)"
    }
}
Write-Host "`nAll repos processed."

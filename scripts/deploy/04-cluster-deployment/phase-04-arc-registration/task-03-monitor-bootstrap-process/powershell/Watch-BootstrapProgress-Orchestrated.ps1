#Requires -Version 7.0
# Task 03 - Monitor Bootstrap Progress (orchestrated from management server)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConfigPath = ".\configs\infrastructure.yml"
Import-Module ([IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..', '..', 'common', 'infrastructure', 'AzlInfrastructure.psm1'))) -Force
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Yaml

$ServerList = @(Get-AzlInfrastructureNode -Infrastructure $cfg | ForEach-Object { $_.ManagementIp } | Where-Object { $_ })

$IntervalSeconds = 60
$MaxIterations   = 120

for ($i = 1; $i -le $MaxIterations; $i++) {
    Write-Host "`n===== Iteration $i  $(Get-Date -Format 'HH:mm:ss') =====" -ForegroundColor Cyan

    $results = Invoke-Command -ComputerName $ServerList -ScriptBlock {
        $s = Get-ArcBootstrapStatus
        [PSCustomObject]@{
            Status = $s.Response.Status
            Start  = $s.Response.StartTime
            End    = $s.Response.EndTime
            Phases = ($s.Response.DetailedResponse | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join '; '
        }
    } -ErrorAction SilentlyContinue

    $results | Sort-Object PSComputerName | Format-Table PSComputerName, Status, Phases -AutoSize

    $allDone = $results | Where-Object { $_.Status -eq 'Succeeded' }
    if ($allDone.Count -eq $ServerList.Count) {
        Write-Host "All nodes completed bootstrap." -ForegroundColor Green
        break
    }

    Start-Sleep -Seconds $IntervalSeconds
}

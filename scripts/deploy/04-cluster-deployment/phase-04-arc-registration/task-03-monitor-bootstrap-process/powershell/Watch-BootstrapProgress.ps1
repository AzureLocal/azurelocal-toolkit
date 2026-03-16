# Task 03 - Check Bootstrap Status (run on each node)

$status = Get-ArcBootstrapStatus
$status.Response | Select-Object Status, StartTime, EndTime

if ($status.Response.DetailedResponse) {
    foreach ($phase in $status.Response.DetailedResponse) {
        Write-Host "$($phase.Name): $($phase.Status)"
        if ($phase.DetailedResponse) {
            $phase.DetailedResponse | ForEach-Object { Write-Host "  $($_.Name): $($_.Status)" }
        }
    }
}

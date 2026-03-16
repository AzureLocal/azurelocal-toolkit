# Task 09 - Disable Unused Network Adapters (run locally on each node)

Get-NetAdapter | Format-Table Name, Status, LinkSpeed -AutoSize

Get-NetAdapter | Where-Object { $_.Status -eq "Disconnected" } | Disable-NetAdapter -Confirm:$false

Get-NetAdapter | Format-Table Name, Status, LinkSpeed -AutoSize

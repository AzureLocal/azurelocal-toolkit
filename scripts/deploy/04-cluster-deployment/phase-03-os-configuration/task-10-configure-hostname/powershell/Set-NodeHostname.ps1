# Task 10 - Configure Hostname (run locally on each node)
# Set $NewHostname to the node's hostname from infrastructure.yml before running

$NewHostname = "REPLACE_WITH_HOSTNAME"   # cluster_nodes[].hostname

if ($NewHostname -match "^REPLACE_") { Write-Host "Set `$NewHostname before running" -ForegroundColor Red; exit 1 }

Rename-Computer -NewName $NewHostname -Force

Write-Host "Hostname set to $NewHostname. Restart required." -ForegroundColor Green
Write-Host -NoNewline "Restart now? [Y/N]: "; if ((Read-Host) -match "^[Yy]") { Restart-Computer -Force }

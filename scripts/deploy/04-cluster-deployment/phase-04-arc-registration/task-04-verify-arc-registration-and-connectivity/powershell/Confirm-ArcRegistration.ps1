# Task 04 - Verify Arc Registration (run on each node)

# Check Arc agent service
Get-Service himds | Format-Table Name, Status, StartType

# Show Arc agent registration and configuration
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show

# Test endpoint connectivity (validates Arc Gateway routing if configured)
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" check

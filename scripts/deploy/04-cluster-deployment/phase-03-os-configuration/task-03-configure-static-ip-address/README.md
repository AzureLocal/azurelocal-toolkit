# Configure static IP address

This task sets the static management address of each Azure Local node from `infrastructure.yml`.

## Scripts

| Script | What it does |
|---|---|
| `Invoke-ConfigureStaticIP-Orchestrated.ps1` | A placeholder: it ends with exit code 3 (NOT IMPLEMENTED) and changes nothing. The work is done by the Network step below. |

The earlier wrapper and the node-local script `Set-StaticIPAddress.ps1` are removed. The adapter name, address, gateway and DNS servers were
`REPLACE_WITH_...` text that a person had to type into the script. A schema 5 script does the same work: the Network
step of `Set-AzureLocalNodeConfiguration.ps1` (one level up, in `phase-03-os-configuration`) finds the management
port by its MAC address and sets the address, gateway and DNS only when they differ from the file. Without `-Execute`
it only plans. It needs PowerShell 7, rights on the nodes and network access to them (WinRM, TCP 5985 or 5986).

## Example

```powershell
# Plan: reads each node and changes nothing
./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -Step Network

# Make the change
./Set-AzureLocalNodeConfiguration.ps1 -InfrastructureFile ./infrastructure.yml -Step Network -Execute
```

## Where the values come from

Every value is read from the infrastructure file (`nodes[]` and the networking keys). Nothing is typed into a script.

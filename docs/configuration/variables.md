# Variables Reference

The toolkit uses a config-driven approach with three key files:

## infrastructure.yml

Master configuration template with 14 sections covering the full Azure Local deployment:

- Azure tenant and subscription
- Resource groups and naming
- Networking (VNet, subnets, DNS, NTP)
- Compute (cluster nodes, NIC intents, BMC)
- Storage (volumes, deduplication)
- Security (Key Vault, certificates)
- Monitoring and backup
- Active Directory
- And more...

This file serves as a **metadata and schema registry**. Copy `variables.template.yml` for your deployment-specific values.

## variables.template.yml

Azure Local-specific variables extracted from the master config. Copy this file to `variables.yml` (gitignored) and fill in your environment values.

## solutions.yaml

Maps which variables each solution needs, with validation rules and artifact paths. Used by `Generate-AzureLocal-Parameters.ps1` to produce per-solution parameter files.

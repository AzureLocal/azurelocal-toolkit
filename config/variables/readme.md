# Variables

This directory provides supplementary variable information for the Azure Local Toolkit.

## Config Structure

```
config/
├── infrastructure.yml          # Full 14-section config (platform deployments)
├── variables.example.yml       # Copyable template with IIC example values
├── variables.yml               # Your actual config (gitignored)
├── schema/
│   ├── master-registry.yaml    # Complete variable definitions with types/defaults
│   └── variables.schema.json   # JSON Schema for validation
└── variables/
    └── readme.md               # This file
```

## Quick Start

```bash
cp config/variables.example.yml config/variables.yml
# Edit config/variables.yml with your environment values
```

## References

- `config/variables.example.yml` — minimal starting template (IIC fictional data)
- `config/infrastructure.yml` — full 14-section configuration reference
- `config/schema/master-registry.yaml` — authoritative variable definitions
- `config/schema/variables.schema.json` — JSON Schema for CI validation


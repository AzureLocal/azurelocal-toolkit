#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$VariablesPath = "E:\git\azurelocal-toolkit\config\variables\variables.example.yml",
    [string]$RegistryPath = "E:\git\azurelocal-toolkit\config\variables\schema\master-registry.yaml",
    [string]$SchemaPath = "E:\git\azurelocal-toolkit\config\variables\schema\variables.schema.json",
    [string]$LegacyRootsPath = "E:\git\azurelocal-toolkit\config\variables\schema\legacy-compatible-roots.json",
    [string]$CanonicalDriftAllowlistPath = "E:\git\azurelocal-toolkit\config\variables\schema\canonical-drift-allowlist.json",
    [string]$UnknownReportCsv = "E:\git\azurelocal-toolkit\config\variables\reports\canonical-unknown-paths.csv",
    [string]$UnknownSummaryTxt = "E:\git\azurelocal-toolkit\config\variables\reports\canonical-unknown-summary.txt",
    [switch]$StrictUnknown
)

$ErrorActionPreference = "Stop"

foreach ($path in @($VariablesPath, $RegistryPath, $SchemaPath, $LegacyRootsPath, $CanonicalDriftAllowlistPath)) {
    if (-not (Test-Path $path)) {
        throw "Required file not found: $path"
    }
}

$py = @'
import json
import pathlib
import re
import sys

try:
    import yaml
    from jsonschema import validate, ValidationError
except Exception as ex:
    raise SystemExit(f"Missing Python deps (pyyaml/jsonschema): {ex}")


def flatten(obj, prefix=""):
    paths = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = f"{prefix}.{k}" if prefix else str(k)
            paths.append(p)
            paths.extend(flatten(v, p))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            p = f"{prefix}[{i}]"
            paths.extend(flatten(v, p))
    return paths


def normalize_path(path):
    return re.sub(r"\[\d+\]", "", path)


# Registry metadata keys that are NOT variable names
_REG_META_KEYS = {
    "type", "description", "required", "format", "pattern", "minimum",
    "maximum", "default", "example", "examples", "note", "enum",
    "allowedValues", "minItems", "maxItems", "minLength", "maxLength",
    "sensitive", "category", "subcategory", "infrastructure_type",
    "depends_on", "solutions", "tier", "items", "properties",
    "additionalProperties", "_meta", "conflicts_with",
    "estimated_variables", "shared_groups", "variable_groups",
}


def build_registry_data_paths(reg_paths):
    """Build data-equivalent paths from registry metadata paths.

    The registry stores variable definitions with metadata nesting like
    ``items.properties.<field>`` and ``additionalProperties.properties.<field>``.
    This function collapses those patterns so they match the flat data-level
    paths found in the variables file.

    Also builds wildcard patterns for additionalProperties (dynamic keys).
    """
    data_paths = set()
    wildcard_paths = set()

    for p in reg_paths:
        # Collapse items.properties → direct child
        dp = re.sub(r"\.items\.properties\.", ".", p)
        # Collapse items (when items has direct children, no properties sub-key)
        dp = re.sub(r"\.items\.", ".", dp)
        # Handle end-of-path items
        dp = re.sub(r"\.items(\.properties)?$", "", dp)
        data_paths.add(dp)

        # Build wildcard for additionalProperties
        wp = p
        # Mid-path patterns
        wp = re.sub(r"\.additionalProperties\.properties\.", ".*.", wp)
        wp = re.sub(r"\.additionalProperties\.", ".*.", wp)
        # End-of-path patterns
        wp = re.sub(r"\.additionalProperties(\.properties)?$", ".*", wp)
        # Also collapse items in wildcard paths
        wp = re.sub(r"\.items\.properties\.", ".", wp)
        wp = re.sub(r"\.items\.", ".", wp)
        wp = re.sub(r"\.items(\.properties)?$", "", wp)
        if "*" in wp:
            wildcard_paths.add(wp)

        # Combined collapse (additionalProperties + items)
        cp = re.sub(r"\.additionalProperties\.properties\.", ".", p)
        cp = re.sub(r"\.additionalProperties\.", ".", cp)
        cp = re.sub(r"\.additionalProperties(\.properties)?$", "", cp)
        cp = re.sub(r"\.items\.properties\.", ".", cp)
        cp = re.sub(r"\.items\.", ".", cp)
        cp = re.sub(r"\.items(\.properties)?$", "", cp)
        data_paths.add(cp)

    return data_paths, wildcard_paths


def is_known_path(path, direct_paths, wildcard_paths):
    """Check if a variable path matches known registry paths."""
    if path in direct_paths:
        return True
    # Check wildcard patterns (for additionalProperties dynamic keys)
    parts = path.split(".")
    for i in range(len(parts)):
        candidate = ".".join(parts[:i] + ["*"] + parts[i + 1:])
        if candidate in wildcard_paths:
            return True
    return False

vars_path = pathlib.Path(sys.argv[1])
reg_path = pathlib.Path(sys.argv[2])
schema_path = pathlib.Path(sys.argv[3])
legacy_roots_path = pathlib.Path(sys.argv[4])
canonical_drift_allowlist_path = pathlib.Path(sys.argv[5])
strict_unknown = sys.argv[6].lower() == "true"
unknown_report_csv = pathlib.Path(sys.argv[7])
unknown_summary_txt = pathlib.Path(sys.argv[8])

variables = yaml.safe_load(vars_path.read_text(encoding="utf-8"))
registry = yaml.safe_load(reg_path.read_text(encoding="utf-8"))
schema = json.loads(schema_path.read_text(encoding="utf-8"))
legacy_roots_doc = json.loads(legacy_roots_path.read_text(encoding="utf-8"))
legacy_roots = set(legacy_roots_doc.get("roots", []))
drift_allowlist_doc = json.loads(canonical_drift_allowlist_path.read_text(encoding="utf-8"))
canonical_drift_allowlist = set(drift_allowlist_doc.get("paths") or [])

if not isinstance(variables, dict):
    raise SystemExit("variables file must deserialize to a YAML mapping")
if not isinstance(registry, dict):
    raise SystemExit("registry file must deserialize to a YAML mapping")

# Type mismatch and required variable detection via schema validation
try:
    validate(instance=variables, schema=schema)
    print("PASS: schema validation passed")
except ValidationError as e:
    path = " > ".join(str(p) for p in e.absolute_path)
    raise SystemExit(f"Schema validation failed: {e.message} | Path: {path}")

var_paths_raw = set(flatten(variables))
reg_paths_raw = set(flatten(registry))

var_paths = set(normalize_path(p) for p in var_paths_raw)
reg_paths = set(normalize_path(p) for p in reg_paths_raw)

# Build data-equivalent paths from registry metadata structure
reg_data_paths, reg_wildcard_paths = build_registry_data_paths(reg_paths)

compatibility_paths = set()
for p in var_paths:
    root = p.split(".", 1)[0].split("[", 1)[0]
    if root in legacy_roots:
        compatibility_paths.add(p)

unknown = sorted(
    p
    for p in var_paths
    if not is_known_path(p, reg_paths | reg_data_paths, reg_wildcard_paths)
    and not p.startswith("_metadata.")
    and p not in compatibility_paths
)

allowlisted_unknown = sorted(p for p in unknown if p in canonical_drift_allowlist)
unknown = sorted(p for p in unknown if p not in canonical_drift_allowlist)

if compatibility_paths:
    print(f"INFO: compatibility alias paths allowed during migration: {len(compatibility_paths)}")
if allowlisted_unknown:
    print(f"INFO: canonical drift allowlisted paths: {len(allowlisted_unknown)}")

if unknown:
    print(f"WARN: canonical unknown variable paths not found in registry: {len(unknown)}")
    root_counts = {}
    for p in unknown:
        root = p.split('.', 1)[0].split('[', 1)[0]
        root_counts[root] = root_counts.get(root, 0) + 1
    print("Top unknown roots:")
    for root, count in sorted(root_counts.items(), key=lambda x: x[1], reverse=True)[:10]:
        print(f"  - {root}: {count}")
    for p in unknown[:20]:
        print(f"  - {p}")

    unknown_report_csv.parent.mkdir(parents=True, exist_ok=True)
    unknown_report_csv.write_text(
        "path\n" + "\n".join(unknown) + "\n",
        encoding="utf-8",
    )

    summary_lines = [
        "Canonical Unknown Summary",
        f"Total unknown paths: {len(unknown)}",
        "Top unknown roots:",
    ]
    for root, count in sorted(root_counts.items(), key=lambda x: x[1], reverse=True):
        summary_lines.append(f"- {root}: {count}")
    unknown_summary_txt.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")

    print(f"Wrote unknown report: {unknown_report_csv}")
    print(f"Wrote unknown summary: {unknown_summary_txt}")

    if strict_unknown:
        raise SystemExit("Unknown variable paths detected (strict mode)")
else:
    print("PASS: no canonical unknown variable paths")

print(f"Variables key paths: {len(var_paths)}")
print(f"Registry key paths: {len(reg_paths)}")
'@

python -c $py $VariablesPath $RegistryPath $SchemaPath $LegacyRootsPath $CanonicalDriftAllowlistPath $($StrictUnknown.IsPresent) $UnknownReportCsv $UnknownSummaryTxt
if ($LASTEXITCODE -ne 0) {
    throw "Variable validation failed"
}
Write-Host "PASS: variable validation completed"

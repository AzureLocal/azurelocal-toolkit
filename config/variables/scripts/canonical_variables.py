"""
Canonical Variable Reader for Azure Local Toolkit.

Provides a standardized interface for reading variables from the canonical
variables file (variables.yml) with alias resolution from the master registry.

Usage:
    from canonical_variables import CanonicalVariables

    cv = CanonicalVariables()
    tenant_id = cv.get("identity.azure_tenant_id")
    cv.require("identity.azure_tenant_id", "security.keyvault_name")
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml


class CanonicalVariables:
    """Reader for canonical variables with alias resolution from the master registry."""

    def __init__(
        self,
        variables_path: str | Path | None = None,
        registry_path: str | Path | None = None,
    ) -> None:
        config_base = self._find_config_base()

        if variables_path is None:
            primary = config_base / "variables.yml"
            fallback = config_base / "variables.example.yml"
            if primary.exists():
                variables_path = primary
            elif fallback.exists():
                variables_path = fallback
            else:
                raise FileNotFoundError(
                    f"No variables file found at {primary} or {fallback}"
                )

        if registry_path is None:
            registry_path = config_base / "schema" / "master-registry.yaml"

        variables_path = Path(variables_path)
        registry_path = Path(registry_path)

        for p in (variables_path, registry_path):
            if not p.exists():
                raise FileNotFoundError(f"Required file not found: {p}")

        with open(variables_path, encoding="utf-8") as f:
            self._variables: dict = yaml.safe_load(f) or {}

        with open(registry_path, encoding="utf-8") as f:
            registry: dict = yaml.safe_load(f) or {}

        self._alias_map: dict[str, str] = {}
        self._build_alias_map(registry, "")

    # ── Public API ──

    def get(self, path: str, default: Any = None) -> Any:
        """Resolve a dotted path from the variables file, with alias fallback.

        Args:
            path: Dot-notation path (e.g. "identity.azure_tenant_id").
                  Supports array indexing with [n].
            default: Value returned when path does not exist.

        Returns:
            The resolved value, or *default* if not found.
        """
        value = self._resolve(self._variables, path)
        if value is not None:
            return value

        # Alias fallback
        canonical = self._alias_map.get(path)
        if canonical is not None:
            value = self._resolve(self._variables, canonical)
            if value is not None:
                return value

        return default

    def exists(self, path: str) -> bool:
        """Check whether a dotted path exists in the variables."""
        return self.get(path) is not None

    def require(self, *paths: str, caller: str = "") -> None:
        """Validate that all paths exist; raise on any missing.

        Args:
            *paths: Required dotted paths.
            caller: Optional caller identifier for error messages.

        Raises:
            ValueError: If any path is missing.
        """
        missing = [p for p in paths if not self.exists(p)]
        if missing:
            label = f"[{caller}] " if caller else ""
            items = "\n  - ".join(missing)
            raise ValueError(
                f"{label}Missing required canonical variables:\n  - {items}"
            )

    @property
    def alias_map(self) -> dict[str, str]:
        """Return a copy of the alias → canonical path mapping."""
        return dict(self._alias_map)

    # ── Internal helpers ──

    @staticmethod
    def _find_config_base() -> Path:
        """Walk up from this file (or CWD) to find config/variables/."""
        # Try relative to this script first
        here = Path(__file__).resolve().parent
        for ancestor in [here, *here.parents]:
            candidate = ancestor / "config" / "variables"
            if candidate.is_dir():
                return candidate

        # Fallback: walk from CWD
        cwd = Path.cwd()
        for ancestor in [cwd, *cwd.parents]:
            candidate = ancestor / "config" / "variables"
            if candidate.is_dir():
                return candidate

        raise FileNotFoundError(
            "Cannot locate config/variables/ directory. "
            "Pass explicit paths or run from within the repository."
        )

    def _build_alias_map(self, node: Any, path: str) -> None:
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key in ("_meta", "infrastructure_type"):
                continue
            child_path = f"{path}.{key}" if path else key
            if isinstance(value, dict):
                if "alias_for" in value:
                    self._alias_map[child_path] = str(value["alias_for"])
                self._build_alias_map(value, child_path)

    @staticmethod
    def _resolve(obj: Any, path: str) -> Any:
        """Navigate a nested dict/list by dotted path with [n] array indexing."""
        current = obj
        for segment in _parse_segments(path):
            if current is None:
                return None
            key, index = segment
            if isinstance(current, dict):
                current = current.get(key)
            else:
                return None
            if index is not None:
                if isinstance(current, (list, tuple)):
                    if index < len(current):
                        current = current[index]
                    else:
                        return None
                else:
                    return None
        return current


def _parse_segments(path: str) -> list[tuple[str, int | None]]:
    """Parse 'a.b[0].c' into [('a', None), ('b', 0), ('c', None)]."""
    import re

    segments: list[tuple[str, int | None]] = []
    for part in path.split("."):
        m = re.match(r"^([^\[]+)(?:\[(\d+)\])?$", part)
        if m:
            key = m.group(1)
            idx = int(m.group(2)) if m.group(2) is not None else None
            segments.append((key, idx))
        else:
            segments.append((part, None))
    return segments

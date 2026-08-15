#!/usr/bin/env python3
"""Require reproducible SwiftPM dependencies and a committed resolution record."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


DISALLOWED_REQUIREMENTS = {"branch", "range"}
PINNED_REQUIREMENTS = {"exact", "revision"}


def nested_keys(value: Any) -> set[str]:
    keys: set[str] = set()
    if isinstance(value, dict):
        for key, item in value.items():
            keys.add(key)
            keys.update(nested_keys(item))
    elif isinstance(value, list):
        for item in value:
            keys.update(nested_keys(item))
    return keys


def dependency_identity(value: Any) -> str:
    if isinstance(value, dict):
        identity = value.get("identity")
        if isinstance(identity, str):
            return identity
        for item in value.values():
            candidate = dependency_identity(item)
            if candidate:
                return candidate
    elif isinstance(value, list):
        for item in value:
            candidate = dependency_identity(item)
            if candidate:
                return candidate
    return "<unknown>"


def load_package(package_root: Path) -> dict[str, Any]:
    completed = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=package_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "swift package dump-package failed")
    return json.loads(completed.stdout)


def load_resolution_record(path: Path) -> list[dict[str, Any]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error
    pins = payload.get("pins")
    if not isinstance(pins, list):
        raise RuntimeError(f"{path} does not contain a SwiftPM pins array")
    return pins


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", type=Path, required=True)
    args = parser.parse_args()
    package_root = args.package_root.resolve()

    try:
        package = load_package(package_root)
    except (RuntimeError, json.JSONDecodeError) as error:
        print(f"Swift dependency check failed: {error}")
        return 1

    dependencies = package.get("dependencies", [])
    if not isinstance(dependencies, list):
        print("Swift dependency check failed: dump-package dependencies is not an array")
        return 1

    resolution_path = package_root / "Package.resolved"
    if not dependencies:
        if resolution_path.exists():
            print("Swift dependency check failed: remove stale Package.resolved from dependency-free package")
            return 1
        print("Swift dependency check passed: package has no external dependencies")
        return 0

    findings: list[str] = []
    identities: set[str] = set()
    for dependency in dependencies:
        identity = dependency_identity(dependency)
        identities.add(identity)
        keys = nested_keys(dependency)
        disallowed = sorted(keys & DISALLOWED_REQUIREMENTS)
        if disallowed:
            findings.append(f"{identity}: floating requirement is not allowed ({', '.join(disallowed)})")
        if not keys & PINNED_REQUIREMENTS:
            findings.append(f"{identity}: use an exact version or immutable revision")

    if not resolution_path.is_file():
        findings.append("Package.resolved is required when external dependencies exist")
    else:
        try:
            pins = load_resolution_record(resolution_path)
        except RuntimeError as error:
            findings.append(str(error))
        else:
            resolved_identities: set[str] = set()
            for pin in pins:
                identity = dependency_identity(pin)
                resolved_identities.add(identity)
                state = pin.get("state", {})
                if not isinstance(state, dict) or not (state.get("version") or state.get("revision")):
                    findings.append(f"{identity}: resolution is missing version/revision")
                if isinstance(state, dict) and state.get("branch"):
                    findings.append(f"{identity}: resolved branch is not allowed")
            missing = sorted(identities - resolved_identities)
            if missing:
                findings.append(f"Package.resolved is missing: {', '.join(missing)}")

    for finding in findings:
        print(f"Swift dependency check failed: {finding}")
    if findings:
        return 1
    print(f"Swift dependency check passed: {len(dependencies)} dependency pin(s) verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

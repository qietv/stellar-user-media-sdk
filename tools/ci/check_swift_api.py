#!/usr/bin/env python3
"""Compare portable Swift public symbol graphs with a reviewed baseline."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


DEFAULT_MODULES = (
    "StellarCore",
    "StellarRemoteMedia",
    "StellarLocalMedia",
    "StellarWebDAV",
    "StellarMediaLibrary",
    "StellarSMB2Core",
    "StellarUserMediaSDK",
)


def portable_identifier(identifier: str) -> str:
    """Canonicalize SDK module ownership that differs across Swift platforms."""
    return identifier.replace("20FoundationEssentials", "10Foundation")


def has_only_ignorable_test_bundle_failures(output: str, modules: tuple[str, ...]) -> bool:
    """Recognize SwiftPM failures for synthetic test bundles outside the reviewed API."""
    error_lines = [
        line.strip() for line in output.splitlines() if line.strip().startswith("error:")
    ]
    if not error_lines:
        return False

    pattern = re.compile(
        r"error: Failed to emit symbol graph for '([^']+)': "
        r"Couldn't load module '[^']+' in the current SDK and search paths\."
    )
    for line in error_lines:
        match = pattern.fullmatch(line)
        if not match:
            return False
        module = match.group(1)
        if module in modules or not module.endswith(("PackageTests", "PackageDiscoveredTests")):
            return False
    return True


def emit_symbol_graphs(package_root: Path, modules: tuple[str, ...]) -> Path:
    completed = subprocess.run(
        [
            "swift",
            "package",
            "dump-symbol-graph",
            "--minimum-access-level",
            "public",
            "--skip-synthesized-members",
            "--skip-inherited-docs",
        ],
        cwd=package_root,
        check=False,
        capture_output=True,
        text=True,
    )
    output = "\n".join(part for part in (completed.stdout, completed.stderr) if part)
    matches = re.findall(r"Files written to (.+)", output)
    if matches:
        graph_dir = Path(matches[-1].strip()).resolve()
    else:
        candidates = sorted(
            package_root.glob(".build/**/symbolgraph"), key=lambda path: path.stat().st_mtime
        )
        if not candidates:
            raise RuntimeError(output.strip() or "SwiftPM did not create a symbol graph directory")
        graph_dir = candidates[-1].resolve()

    if completed.returncode != 0 and not has_only_ignorable_test_bundle_failures(output, modules):
        raise RuntimeError(output.strip() or "swift package dump-symbol-graph failed")
    return graph_dir


def declaration(symbol: dict[str, Any]) -> str:
    fragments = symbol.get("declarationFragments", [])
    return "".join(
        fragment.get("spelling", "") for fragment in fragments if isinstance(fragment, dict)
    )


def public_symbols(graph: dict[str, Any]) -> list[dict[str, Any]]:
    symbols: list[dict[str, Any]] = []
    for symbol in graph.get("symbols", []):
        if symbol.get("accessLevel") not in {"public", "open"}:
            continue
        identifier = symbol.get("identifier", {}).get("precise")
        if not identifier:
            continue
        identifier = portable_identifier(identifier)
        symbols.append(
            {
                "identifier": identifier,
                "kind": symbol.get("kind", {}).get("identifier", ""),
                "path": symbol.get("pathComponents", []),
                "declaration": declaration(symbol),
            }
        )
    return sorted(symbols, key=lambda symbol: symbol["identifier"])


def undocumented_top_level_symbols(graph: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    for symbol in graph.get("symbols", []):
        path = symbol.get("pathComponents", [])
        if (
            symbol.get("accessLevel") in {"public", "open"}
            and len(path) == 1
            and symbol.get("location")
            and not symbol.get("docComment")
        ):
            findings.append(path[0])
    return sorted(findings)


def snapshot(graph_dir: Path, modules: tuple[str, ...]) -> tuple[dict[str, Any], list[str]]:
    module_snapshots: dict[str, Any] = {}
    documentation_findings: list[str] = []
    for module in modules:
        path = graph_dir / f"{module}.symbols.json"
        if not path.is_file():
            raise RuntimeError(f"missing symbol graph for {module}: {path}")
        graph = json.loads(path.read_text(encoding="utf-8"))
        module_snapshots[module] = {"symbols": public_symbols(graph)}
        documentation_findings.extend(
            f"{module}.{symbol}" for symbol in undocumented_top_level_symbols(graph)
        )
    return {"schema_version": 1, "modules": module_snapshots}, documentation_findings


def index_symbols(payload: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    indexed: dict[tuple[str, str], dict[str, Any]] = {}
    for module, module_payload in payload.get("modules", {}).items():
        for symbol in module_payload.get("symbols", []):
            indexed[(module, symbol["identifier"])] = symbol
    return indexed


def portable_signature(module: str, symbol: dict[str, Any]) -> tuple[str, str, tuple[str, ...], str]:
    """Identify the same declaration when Swift mangles imported types differently.

    Swift's precise identifiers are not fully portable across Darwin and Linux. In
    particular, Foundation overlay substitutions can give an otherwise identical
    declaration a different mangled identifier. The human-readable declaration,
    path, and symbol kind remain stable and together preserve overload identity.
    """
    return (
        module,
        symbol.get("kind", ""),
        tuple(symbol.get("path", [])),
        symbol.get("declaration", ""),
    )


def discard_portable_matches(
    expected_only: set[tuple[str, str]],
    actual_only: set[tuple[str, str]],
    expected_symbols: dict[tuple[str, str], dict[str, Any]],
    actual_symbols: dict[tuple[str, str], dict[str, Any]],
) -> None:
    """Discard unmatched precise IDs that describe the same portable API."""
    expected_by_signature: dict[tuple[str, str, tuple[str, ...], str], list[tuple[str, str]]] = {}
    actual_by_signature: dict[tuple[str, str, tuple[str, ...], str], list[tuple[str, str]]] = {}

    for key in expected_only:
        expected_by_signature.setdefault(
            portable_signature(key[0], expected_symbols[key]), []
        ).append(key)
    for key in actual_only:
        actual_by_signature.setdefault(
            portable_signature(key[0], actual_symbols[key]), []
        ).append(key)

    for signature in expected_by_signature.keys() & actual_by_signature.keys():
        expected_keys = sorted(expected_by_signature[signature])
        actual_keys = sorted(actual_by_signature[signature])
        for expected_key, actual_key in zip(expected_keys, actual_keys):
            expected_only.discard(expected_key)
            actual_only.discard(actual_key)


def describe(module: str, symbol: dict[str, Any]) -> str:
    path = ".".join(symbol.get("path", []))
    return f"{module}.{path}: {symbol.get('declaration', '')}"


def compare(expected: dict[str, Any], actual: dict[str, Any]) -> list[str]:
    expected_symbols = index_symbols(expected)
    actual_symbols = index_symbols(actual)
    expected_only = set(expected_symbols.keys() - actual_symbols.keys())
    actual_only = set(actual_symbols.keys() - expected_symbols.keys())
    discard_portable_matches(expected_only, actual_only, expected_symbols, actual_symbols)

    findings: list[str] = []
    for key in sorted(expected_only):
        findings.append(f"removed {describe(key[0], expected_symbols[key])}")
    for key in sorted(actual_only):
        findings.append(f"added {describe(key[0], actual_symbols[key])}")
    for key in sorted(expected_symbols.keys() & actual_symbols.keys()):
        if expected_symbols[key] != actual_symbols[key]:
            findings.append(
                f"changed {describe(key[0], expected_symbols[key])} -> "
                f"{actual_symbols[key].get('declaration', '')}"
            )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-root", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--module", action="append", dest="modules")
    args = parser.parse_args()
    package_root = args.package_root.resolve()
    baseline = args.baseline
    if not baseline.is_absolute():
        baseline = package_root / baseline
    modules = tuple(args.modules or DEFAULT_MODULES)

    try:
        graph_dir = emit_symbol_graphs(package_root, modules)
        actual, documentation_findings = snapshot(graph_dir, modules)
    except (RuntimeError, OSError, json.JSONDecodeError) as error:
        print(f"Swift API check failed: {error}")
        return 1

    for finding in documentation_findings:
        print(f"Swift API check failed: missing top-level DocC comment for {finding}")
    if documentation_findings:
        return 1

    if args.update:
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_text(json.dumps(actual, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        count = sum(len(module["symbols"]) for module in actual["modules"].values())
        print(f"Swift API baseline updated: {count} public symbols in {baseline}")
        return 0

    if not baseline.is_file():
        print(f"Swift API check failed: baseline does not exist: {baseline}")
        print("Run this command with --update and review the generated baseline")
        return 1
    try:
        expected = json.loads(baseline.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Swift API check failed: cannot read baseline: {error}")
        return 1

    findings = compare(expected, actual)
    for finding in findings[:50]:
        print(f"Swift API check failed: {finding}")
    if len(findings) > 50:
        print(f"Swift API check failed: {len(findings) - 50} additional change(s) omitted")
    if findings:
        print("Regenerate with --update only after reviewing compatibility impact")
        return 1
    count = sum(len(module["symbols"]) for module in actual["modules"].values())
    print(f"Swift API check passed: {count} public symbols match {baseline}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

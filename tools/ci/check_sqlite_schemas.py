#!/usr/bin/env python3
"""Execute and verify the cross-platform SQLite schema contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import tempfile
from pathlib import Path
from typing import Any


def load_manifest(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1 or not isinstance(payload.get("databases"), list):
        raise ValueError("unsupported or invalid schema manifest")
    return payload


def load_migrations(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1 or not isinstance(payload.get("migrations"), list):
        raise ValueError("unsupported or invalid schema migration manifest")
    return payload


def verify_schema(spec_root: Path, definition: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    name = definition.get("name", "<unknown>")
    relative_file = definition.get("file")
    if not isinstance(relative_file, str):
        return [f"{name}: missing schema file"]

    path = spec_root / relative_file
    try:
        content = path.read_bytes()
    except OSError as error:
        return [f"{name}: cannot read {path}: {error}"]

    checksum = hashlib.sha256(content).hexdigest()
    if checksum != definition.get("sha256"):
        findings.append(
            f"{name}: checksum mismatch; reviewed manifest has {definition.get('sha256')}, got {checksum}"
        )

    with tempfile.NamedTemporaryFile(suffix=".sqlite") as temporary:
        database = sqlite3.connect(temporary.name)
        try:
            database.execute("PRAGMA foreign_keys = ON")
            database.executescript(content.decode("utf-8"))
            application_id = database.execute("PRAGMA application_id").fetchone()[0]
            user_version = database.execute("PRAGMA user_version").fetchone()[0]
            table_count = database.execute(
                """
                SELECT COUNT(*)
                FROM sqlite_schema
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """
            ).fetchone()[0]
            foreign_key_findings = list(database.execute("PRAGMA foreign_key_check"))
            quick_check = database.execute("PRAGMA quick_check").fetchone()[0]
        except (sqlite3.Error, UnicodeDecodeError) as error:
            findings.append(f"{name}: schema execution failed: {error}")
            return findings
        finally:
            database.close()

    if application_id != definition.get("application_id"):
        findings.append(f"{name}: application_id is {application_id}, expected {definition.get('application_id')}")
    if user_version != definition.get("user_version"):
        findings.append(f"{name}: user_version is {user_version}, expected {definition.get('user_version')}")
    if table_count != definition.get("business_table_count"):
        findings.append(
            f"{name}: business table count is {table_count}, expected {definition.get('business_table_count')}"
        )
    if foreign_key_findings:
        findings.append(f"{name}: foreign_key_check returned {len(foreign_key_findings)} row(s)")
    if quick_check != "ok":
        findings.append(f"{name}: quick_check returned {quick_check!r}")
    return findings


def verify_migration_chain(
    spec_root: Path,
    base: dict[str, Any],
    definitions: list[dict[str, Any]],
) -> list[str]:
    findings: list[str] = []
    name = base.get("name", "<unknown>")
    try:
        base_content = (spec_root / base["file"]).read_bytes()
    except (KeyError, OSError) as error:
        return [f"{name}: cannot read migration base: {error}"]

    ordered = sorted(definitions, key=lambda item: item.get("from_version", -1))
    with tempfile.NamedTemporaryFile(suffix=".sqlite") as temporary:
        database = sqlite3.connect(temporary.name)
        try:
            database.execute("PRAGMA foreign_keys = ON")
            database.executescript(base_content.decode("utf-8"))
            current_version = base.get("user_version")
            for definition in ordered:
                relative_file = definition.get("file")
                if not isinstance(relative_file, str):
                    findings.append(f"{name}: migration file is missing")
                    break
                if definition.get("from_version") != current_version:
                    findings.append(
                        f"{name}: migration chain expected v{current_version}, "
                        f"got v{definition.get('from_version')}"
                    )
                    break
                content = (spec_root / relative_file).read_bytes()
                checksum = hashlib.sha256(content).hexdigest()
                if checksum != definition.get("sha256"):
                    findings.append(
                        f"{name}: migration checksum mismatch; reviewed manifest has "
                        f"{definition.get('sha256')}, got {checksum}"
                    )
                database.executescript(content.decode("utf-8"))
                current_version = definition.get("to_version")
                user_version = database.execute("PRAGMA user_version").fetchone()[0]
                table_count = database.execute(
                    "SELECT COUNT(*) FROM sqlite_schema "
                    "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
                ).fetchone()[0]
                if user_version != current_version:
                    findings.append(
                        f"{name}: migrated user_version is {user_version}, "
                        f"expected {current_version}"
                    )
                if table_count != definition.get("business_table_count"):
                    findings.append(
                        f"{name}: migrated table count is {table_count}, "
                        f"expected {definition.get('business_table_count')}"
                    )
            foreign_key_findings = list(database.execute("PRAGMA foreign_key_check"))
            quick_check = database.execute("PRAGMA quick_check").fetchone()[0]
        except (sqlite3.Error, UnicodeDecodeError) as error:
            findings.append(f"{name}: migration execution failed: {error}")
            return findings
        except OSError as error:
            findings.append(f"{name}: cannot read migration input: {error}")
            return findings
        finally:
            database.close()
    if foreign_key_findings:
        findings.append(f"{name}: migrated foreign_key_check returned rows")
    if quick_check != "ok":
        findings.append(f"{name}: migrated quick_check returned {quick_check!r}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    manifest_path = root / "specs/storage/schema-manifest-v1.json"
    migrations_path = root / "specs/storage/schema-migrations.json"

    try:
        manifest = load_manifest(manifest_path)
        migrations = load_migrations(migrations_path)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"SQLite schema check failed: {error}")
        return 1

    findings: list[str] = []
    spec_root = manifest_path.parent
    for definition in manifest["databases"]:
        if not isinstance(definition, dict):
            findings.append("manifest database entry is not an object")
            continue
        findings.extend(verify_schema(spec_root, definition))
    bases = {
        definition["name"]: definition
        for definition in manifest["databases"]
        if isinstance(definition, dict) and isinstance(definition.get("name"), str)
    }
    migrations_by_name: dict[str, list[dict[str, Any]]] = {}
    for definition in migrations["migrations"]:
        if not isinstance(definition, dict):
            findings.append("manifest migration entry is not an object")
            continue
        name = definition.get("name")
        if not isinstance(name, str):
            findings.append("manifest migration name is missing")
            continue
        migrations_by_name.setdefault(name, []).append(definition)
    for name, definitions in migrations_by_name.items():
        base = bases.get(name)
        if base is None:
            findings.append(f"{name}: migration base is missing")
            continue
        findings.extend(verify_migration_chain(spec_root, base, definitions))

    for finding in findings:
        print(f"SQLite schema check failed: {finding}")
    if findings:
        return 1
    print(
        "SQLite schema check passed: "
        f"{len(manifest['databases'])} base contract(s), "
        f"{len(migrations['migrations'])} migration(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

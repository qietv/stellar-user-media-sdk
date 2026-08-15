#!/usr/bin/env python3
"""Verify the Linux SMB LGPL source/object/relink delivery kit."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from typing import Any


EXPECTED_PREFIX = "stellar_user_media_sdk_libsmb2_"


def run(command: list[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"{' '.join(command)} failed: {detail}")
    return completed.stdout.strip()


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error


def verify_manifest(kit: Path) -> None:
    manifest = load_json(kit / "manifest.json")
    if manifest.get("schema_version") != 1 or manifest.get("algorithm") != "SHA-256":
        raise RuntimeError("unsupported LGPL kit manifest")
    recorded = manifest.get("files")
    if not isinstance(recorded, dict) or not recorded:
        raise RuntimeError("LGPL kit manifest has no files")
    actual = {
        path.relative_to(kit).as_posix()
        for path in kit.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    }
    if actual != set(recorded):
        raise RuntimeError("LGPL kit file inventory does not match the manifest")
    for relative, expected_hash in recorded.items():
        actual_hash = hashlib.sha256((kit / relative).read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(f"LGPL kit hash mismatch: {relative}")


def verify_source(kit: Path, component: dict[str, Any]) -> Path:
    source_name = Path(str(component["source_archive"])).name
    source_archive = kit / "source" / source_name
    if hashlib.sha256(source_archive.read_bytes()).hexdigest() != component["source_sha256"]:
        raise RuntimeError("complete corresponding source hash does not match build metadata")
    with tarfile.open(source_archive, "r:gz") as archive:
        names = archive.getnames()
    for required_suffix in ("/COPYING", "/LICENCE-LGPL-2.1.txt", "/lib/sync.c"):
        if not any(name.endswith(required_suffix) for name in names):
            raise RuntimeError(f"libsmb2 source archive is missing {required_suffix}")
    return source_archive


def verify_binary(binary: Path) -> None:
    run([str(binary), "version"])
    symbols = run(["nm", "--defined-only", str(binary)])
    if EXPECTED_PREFIX not in symbols:
        raise RuntimeError("relinked executable does not contain private libsmb2 symbols")
    dynamic = run(["nm", "-D", "-g", "--defined-only", str(binary)])
    if EXPECTED_PREFIX in dynamic:
        raise RuntimeError("relinked executable exports private libsmb2 symbols dynamically")
    linked = run(["ldd", str(binary)])
    if "libsmb2" in linked.lower():
        raise RuntimeError("relinked executable unexpectedly depends on shared libsmb2")


def safe_extract(archive_path: Path, destination: Path) -> Path:
    destination_resolved = destination.resolve()
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            target = (destination / member.name).resolve()
            if target != destination_resolved and destination_resolved not in target.parents:
                raise RuntimeError("source archive contains an unsafe path")
        archive.extractall(destination, filter="data")
    roots = [path for path in destination.iterdir() if path.is_dir()]
    if len(roots) != 1:
        raise RuntimeError("source archive must contain one top-level directory")
    return roots[0]


def verify_rebuild(kit: Path, source_archive: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="stellar-lgpl-relink-") as temporary:
        temporary_path = Path(temporary)
        source = safe_extract(source_archive, temporary_path / "source")
        replacement = temporary_path / "libstellar_libsmb2_modified.a"
        run(
            [
                str(kit / "scripts/rebuild-private-libsmb2.sh"),
                "--lock",
                str(kit / "metadata/libsmb2.lock.json"),
                "--source",
                str(source),
                "--output",
                str(replacement),
            ]
        )
        relinked = temporary_path / "stellar-media.modified"
        run([str(kit / "scripts/relink.sh"), str(replacement), str(relinked)])
        verify_binary(relinked)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kit", type=Path, required=True)
    parser.add_argument("--verify-rebuild", action="store_true")
    args = parser.parse_args()
    kit = args.kit.resolve()
    required_commands = ("ldd", "nm", "swiftc")
    missing = [command for command in required_commands if shutil.which(command) is None]
    if missing:
        print(f"LGPL kit check failed: missing commands: {', '.join(missing)}")
        return 1
    try:
        verify_manifest(kit)
        kit_metadata = load_json(kit / "metadata/kit.json")
        component = load_json(kit / "metadata/libsmb2.json")
        if kit_metadata.get("artifact") != "stellar-linux-smb-lgpl-relink-kit":
            raise RuntimeError("unexpected LGPL kit artifact identity")
        if component.get("license") != "LGPL-2.1-or-later":
            raise RuntimeError("unexpected libsmb2 license metadata")
        for required in (
            "README.md",
            "licenses/libsmb2-COPYING",
            "licenses/LGPL-2.1.txt",
            "project/smb-integration-source.tar.gz",
            "metadata/objects.rsp",
            "lib/libstellar_libsmb2_private.a",
            "scripts/rebuild-private-libsmb2.sh",
            "scripts/relink.sh",
        ):
            if not (kit / required).is_file():
                raise RuntimeError(f"LGPL kit is missing {required}")
        objects = (kit / "metadata/objects.rsp").read_text(encoding="utf-8").splitlines()
        if len(objects) != kit_metadata.get("object_count") or not objects:
            raise RuntimeError("LGPL kit object inventory is inconsistent")
        source_archive = verify_source(kit, component)
        verify_binary(kit / "bin/stellar-media.relinked")
        if args.verify_rebuild:
            verify_rebuild(kit, source_archive)
    except (KeyError, OSError, RuntimeError, tarfile.TarError) as error:
        print(f"LGPL kit check failed: {error}")
        return 1
    print(
        "Linux SMB LGPL kit passed: licenses, corresponding source, object code, "
        "private archive, relink and integrity manifest"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

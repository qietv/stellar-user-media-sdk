#!/usr/bin/env python3
"""Verify Apple libsmb2 XCFramework slices, isolation, and linkability."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any


EXPECTED_SLICES = {
    ("macos", None): {"arm64", "x86_64"},
    ("ios", None): {"arm64"},
    ("ios", "simulator"): {"arm64", "x86_64"},
}


def run(command: list[str]) -> str:
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"{' '.join(command)} failed: {detail}")
    return completed.stdout.strip()


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error


def defined_identifiers(archive: Path, architecture: str) -> set[str]:
    output = run(["xcrun", "nm", "-arch", architecture, "-gjU", str(archive)])
    symbols = {line.removeprefix("_") for line in output.splitlines()}
    return {
        symbol
        for symbol in symbols
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", symbol)
    }


def verify_compliance(compliance: Path, lock: dict[str, Any]) -> None:
    metadata = load_json(compliance / "metadata.json")
    if (
        metadata.get("revision") != lock.get("revision")
        or metadata.get("upstream_version") != lock.get("upstream_version")
        or metadata.get("symbol_prefix") != lock.get("symbol_prefix")
        or metadata.get("license") != lock.get("license")
    ):
        raise RuntimeError("Apple libsmb2 compliance metadata does not match the lock")
    source_archive = compliance / str(metadata.get("source_archive", ""))
    if not source_archive.is_file():
        raise RuntimeError("Apple libsmb2 corresponding source archive is missing")
    if hashlib.sha256(source_archive.read_bytes()).hexdigest() != metadata.get("source_sha256"):
        raise RuntimeError("Apple libsmb2 corresponding source hash does not match metadata")
    required = (
        compliance / "licenses/COPYING",
        compliance / "licenses/LICENCE-LGPL-2.1.txt",
        compliance / "build/stellar-libsmb2-prefix-all.h",
        compliance / "build/symbol-map.txt",
        compliance / "integration/stellar_smb2_wrapper.c",
        compliance / "SHA256SUMS",
    )
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RuntimeError("Apple libsmb2 compliance materials are missing: " + ", ".join(missing))


def verify_manifest(compliance: Path) -> None:
    manifest = compliance / "SHA256SUMS"
    for line in manifest.read_text(encoding="utf-8").splitlines():
        digest, separator, relative = line.partition("  ")
        path = compliance / relative
        if not separator or not path.is_file():
            raise RuntimeError(f"invalid Apple compliance manifest entry: {line}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Apple compliance manifest hash mismatch: {relative}")


def verify_link_smoke(
    root: Path,
    library: Path,
    headers: Path,
    sdk: str,
    target: str,
    output: Path,
) -> None:
    source = root / "tools/ci/stellar_smb2_wrapper_smoke.c"
    sdk_path = run(["xcrun", "--sdk", sdk, "--show-sdk-path"])
    run(
        [
            "xcrun",
            "--sdk",
            sdk,
            "clang",
            "-std=c11",
            "-target",
            target,
            "-isysroot",
            sdk_path,
            "-I",
            str(headers),
            str(source),
            str(library),
            "-o",
            str(output),
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--xcframework", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    xcframework = args.xcframework.resolve()
    compliance = xcframework.with_name(xcframework.name.removesuffix(".xcframework") + ".compliance")

    try:
        if os.uname().sysname != "Darwin":
            raise RuntimeError("Apple XCFramework verification requires macOS and Xcode")
        if not xcframework.is_dir():
            raise RuntimeError(f"Apple libsmb2 XCFramework is missing: {xcframework}")
        lock = load_json(root / "third_party/libsmb2.lock.json")
        with (xcframework / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        available = info.get("AvailableLibraries", [])
        actual_slices: dict[tuple[str, str | None], set[str]] = {}
        slice_paths: dict[tuple[str, str | None], tuple[Path, Path]] = {}
        prefix = str(lock["symbol_prefix"])

        for entry in available:
            platform = str(entry.get("SupportedPlatform", ""))
            variant_value = entry.get("SupportedPlatformVariant")
            variant = str(variant_value) if variant_value is not None else None
            key = (platform, variant)
            identifier = str(entry.get("LibraryIdentifier", ""))
            library = xcframework / identifier / str(entry.get("LibraryPath", ""))
            headers = xcframework / identifier / str(entry.get("HeadersPath", ""))
            architectures = {str(value) for value in entry.get("SupportedArchitectures", [])}
            if not library.is_file() or not headers.is_dir():
                raise RuntimeError(f"Apple XCFramework slice is incomplete: {identifier}")
            module_map = headers / "module.modulemap"
            wrapper_header = headers / "stellar_smb2_wrapper.h"
            if not module_map.is_file() or not wrapper_header.is_file():
                raise RuntimeError(f"Apple XCFramework C module headers are incomplete: {identifier}")
            if "module CStellarSMB2Wrapper" not in module_map.read_text(encoding="utf-8"):
                raise RuntimeError(f"Apple XCFramework module identity is invalid: {identifier}")

            for architecture in architectures:
                symbols = defined_identifiers(library, architecture)
                unexpected = sorted(
                    symbol
                    for symbol in symbols
                    if not symbol.startswith(prefix) and not symbol.startswith("stellar_smb2_")
                )
                if unexpected:
                    raise RuntimeError(
                        f"Apple XCFramework {identifier}/{architecture} exports unexpected symbols: "
                        + ", ".join(unexpected[:10])
                    )
                required = {
                    prefix + "smb2_init_context",
                    prefix + "smb2_pread",
                    "stellar_smb2_client_create",
                    "stellar_smb2_client_open_directory",
                    "stellar_smb2_client_read_directory",
                    "stellar_smb2_client_close_directory",
                    "stellar_smb2_client_read",
                }
                if not required.issubset(symbols):
                    raise RuntimeError(
                        f"Apple XCFramework {identifier}/{architecture} is missing required ABI symbols"
                    )
            actual_slices[key] = architectures
            slice_paths[key] = (library, headers)

        if actual_slices != EXPECTED_SLICES:
            raise RuntimeError(
                f"Apple XCFramework slices {actual_slices!r} do not match {EXPECTED_SLICES!r}"
            )

        verify_compliance(compliance, lock)
        verify_manifest(compliance)
        with tempfile.TemporaryDirectory(prefix="stellar-libsmb2-apple-smoke-") as temporary:
            temporary_path = Path(temporary)
            host_architecture = "arm64" if os.uname().machine == "arm64" else "x86_64"
            macos_library, macos_headers = slice_paths[("macos", None)]
            macos_smoke = temporary_path / "macos-smoke"
            verify_link_smoke(
                root,
                macos_library,
                macos_headers,
                "macosx",
                f"{host_architecture}-apple-macos14.0",
                macos_smoke,
            )
            run([str(macos_smoke)])
            linked = run(["xcrun", "otool", "-L", str(macos_smoke)])
            dependencies = "\n".join(linked.splitlines()[1:])
            if "libsmb2" in dependencies.lower():
                raise RuntimeError("macOS smoke unexpectedly has a dynamic libsmb2 dependency")

            iphoneos_library, iphoneos_headers = slice_paths[("ios", None)]
            verify_link_smoke(
                root,
                iphoneos_library,
                iphoneos_headers,
                "iphoneos",
                "arm64-apple-ios17.0",
                temporary_path / "iphoneos-smoke",
            )
            simulator_library, simulator_headers = slice_paths[("ios", "simulator")]
            verify_link_smoke(
                root,
                simulator_library,
                simulator_headers,
                "iphonesimulator",
                f"{host_architecture}-apple-ios17.0-simulator",
                temporary_path / "iphonesimulator-smoke",
            )
    except (RuntimeError, OSError, plistlib.InvalidFileException, KeyError) as error:
        print(f"Apple libsmb2 XCFramework check failed: {error}")
        return 1

    print("Apple libsmb2 XCFramework check passed: macOS + iOS device/simulator")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

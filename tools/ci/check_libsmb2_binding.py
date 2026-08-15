#!/usr/bin/env python3
"""Validate pinned libsmb2 provenance and optionally compile/link the C ABI smoke test."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Any


REVISION_PATTERN = re.compile(r"^[0-9a-f]{40}$")
EXPECTED_REPOSITORY = "https://github.com/sahlberg/libsmb2.git"
EXPECTED_LICENSE = "LGPL-2.1-or-later"
EXPECTED_PKG_CONFIG = "stellar-libsmb2-private"
EXPECTED_ARCHIVE = "libstellar_libsmb2_private.a"
EXPECTED_SYMBOL_PREFIX = "stellar_user_media_sdk_libsmb2_"
ALLOWED_SYMBOLS = (
    "smb2_init_context",
    "smb2_close_context",
    "smb2_destroy_context",
    "smb2_set_timeout",
    "smb2_set_version",
    "smb2_set_security_mode",
    "smb2_set_sign",
    "smb2_set_seal",
    "smb2_set_authentication",
    "smb2_set_domain",
    "smb2_set_user",
    "smb2_set_password",
    "smb2_fd_event_callbacks",
    "smb2_connect_share",
    "smb2_disconnect_share",
    "smb2_get_dialect",
    "smb2_get_error",
    "smb2_get_nterror",
    "nterror_to_errno",
    "smb2_opendir",
    "smb2_readdir",
    "smb2_closedir",
    "smb2_stat",
    "smb2_open",
    "smb2_get_max_read_size",
    "smb2_pread",
    "smb2_close",
)
FORBIDDEN_SWIFT_IMPORT = re.compile(
    r"\bimport\s+(?:CLibsmb2System|CStellarLibsmb2Private)\b"
)


def run(command: list[str], *, environment: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"{' '.join(command)} failed: {detail}")
    return completed.stdout.strip()


def load_lock(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error
    required = {
        "schema_version",
        "name",
        "repository",
        "revision",
        "upstream_version",
        "archive",
        "pkg_config",
        "symbol_prefix",
        "license",
        "build",
    }
    missing = sorted(required - payload.keys())
    if missing:
        raise RuntimeError(f"{path} is missing: {', '.join(missing)}")
    return payload


def validate_lock(payload: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    if payload.get("schema_version") != 1:
        findings.append("unsupported lock schema")
    if payload.get("name") != "libsmb2":
        findings.append("dependency identity must be libsmb2")
    if payload.get("pkg_config") != EXPECTED_PKG_CONFIG:
        findings.append("pkg-config identity must remain project-private")
    if payload.get("repository") != EXPECTED_REPOSITORY:
        findings.append("repository must be the reviewed upstream")
    if not REVISION_PATTERN.fullmatch(str(payload.get("revision", ""))):
        findings.append("revision must be a full immutable Git SHA")
    if payload.get("license") != EXPECTED_LICENSE:
        findings.append("license must match reviewed upstream metadata")
    if payload.get("archive") != EXPECTED_ARCHIVE:
        findings.append("unexpected private static archive name")
    if payload.get("symbol_prefix") != EXPECTED_SYMBOL_PREFIX:
        findings.append("unexpected private symbol prefix")
    build = payload.get("build")
    expected_build = {"shared": False, "examples": False, "kerberos": False, "gssapi": False}
    if build != expected_build:
        findings.append("build flags do not match ADR-0003")
    return findings


def validate_binding_boundary(root: Path) -> list[str]:
    findings: list[str] = []
    module_root = root / "platforms/swift/Sources/CStellarLibsmb2Private"
    module_map = module_root / "module.modulemap"
    shim = module_root / "shim.h"
    if not module_map.is_file() or not shim.is_file():
        return ["CStellarLibsmb2Private module map and shim.h are required"]
    if "link " in module_map.read_text(encoding="utf-8"):
        findings.append("private C module must not request a public linker library")
    shim_text = shim.read_text(encoding="utf-8")
    if "<smb2/libsmb2.h>" not in shim_text:
        findings.append("private shim must include the reviewed high-level header")
    if "libsmb2-raw.h" in shim_text:
        findings.append("raw libsmb2 API is not allowed in the system shim")
    for symbol in ALLOWED_SYMBOLS:
        expected_mapping = f"#define {symbol} {EXPECTED_SYMBOL_PREFIX}{symbol}"
        if expected_mapping not in shim_text:
            findings.append(f"private shim is missing symbol mapping for {symbol}")
    smoke = root / "tools/ci/libsmb2_binding_smoke.c"
    if not smoke.is_file():
        findings.append("libsmb2 C ABI smoke source is required")
    else:
        smoke_symbols = set(
            re.findall(
                r"^REQUIRE_SYMBOL\(([A-Za-z][A-Za-z0-9_]+)\);$",
                smoke.read_text(encoding="utf-8"),
                flags=re.MULTILINE,
            )
        )
        if smoke_symbols != set(ALLOWED_SYMBOLS):
            findings.append("C ABI smoke symbols must exactly match the reviewed allowlist")
    wrapper_root = root / "platforms/swift/Sources/CStellarSMB2Wrapper"
    wrapper_header = wrapper_root / "include/stellar_smb2_wrapper.h"
    wrapper_source = wrapper_root / "stellar_smb2_wrapper.c"
    if not wrapper_header.is_file() or not wrapper_source.is_file():
        findings.append("the project-owned C SMB2 wrapper is required")
    else:
        wrapper_header_text = wrapper_header.read_text(encoding="utf-8")
        if re.search(r"(?:<smb2/|struct\s+smb2_|\bsmb2_context\b)", wrapper_header_text):
            findings.append("the public C wrapper header exposes private libsmb2 types")
        wrapper_source_text = wrapper_source.read_text(encoding="utf-8")
        if "CStellarLibsmb2Private/shim.h" not in wrapper_source_text:
            findings.append("the C wrapper must consume libsmb2 only through the private shim")
        if "libsmb2-raw.h" in wrapper_source_text:
            findings.append("the C wrapper must not consume the raw libsmb2 API")
    wrapper_smoke = root / "tools/ci/stellar_smb2_wrapper_smoke.c"
    if not wrapper_smoke.is_file():
        findings.append("the project-owned C SMB2 wrapper smoke source is required")
    cancel_smoke = root / "tools/ci/stellar_smb2_wrapper_cancel_smoke.c"
    if not cancel_smoke.is_file():
        findings.append("the in-flight C cancellation smoke source is required")
    for path in (root / "platforms/swift/Sources").rglob("*.swift"):
        source_text = path.read_text(encoding="utf-8")
        if FORBIDDEN_SWIFT_IMPORT.search(source_text):
            findings.append(f"{path.relative_to(root)} imports the private libsmb2 C module directly")
        if "import CStellarSMB2Wrapper" in source_text and "StellarSMB2Linux" not in path.parts:
            findings.append(
                f"{path.relative_to(root)} imports the C wrapper outside StellarSMB2Linux"
            )
    return findings


def defined_symbols(output: str) -> set[str]:
    symbols: set[str] = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 2 and len(parts[1]) == 1:
            symbols.add(parts[0])
    return symbols


def verify_installed(root: Path, payload: dict[str, Any]) -> None:
    pkg_config = shutil.which("pkg-config")
    compiler = shutil.which(os.environ.get("CC", "cc"))
    if not pkg_config:
        raise RuntimeError("pkg-config is required")
    if not compiler:
        raise RuntimeError("a C compiler is required")
    symbol_tool = shutil.which("nm")
    if not symbol_tool:
        raise RuntimeError("nm is required")
    package_name = str(payload["pkg_config"])
    version = run([pkg_config, "--modversion", package_name])
    if version != payload["upstream_version"]:
        raise RuntimeError(
            f"pkg-config version {version!r} does not match lock {payload['upstream_version']!r}"
        )
    flags_text = run([pkg_config, "--cflags", "--libs", package_name])
    archive_name = str(payload["archive"])
    link_name = archive_name.removeprefix("lib").removesuffix(".a")
    link_flag = f"-l{link_name}"
    flags = shlex.split(flags_text)
    if (
        link_flag not in flags
        or archive_name in flags_text
        or any(flag.startswith("-Wl,") for flag in flags)
        or ".so" in flags_text
        or "-lsmb2" in flags
    ):
        raise RuntimeError(
            "pkg-config must use SwiftPM-safe -L/-l flags for only the private archive"
        )
    libdir = Path(run([pkg_config, "--variable=libdir", package_name]))
    archive = libdir / archive_name
    if not archive.is_file():
        raise RuntimeError(f"private static archive is missing: {archive}")
    if list(libdir.glob(f"lib{link_name}.so*")):
        raise RuntimeError("private libsmb2 link directory must not contain a shared library")
    prefix = Path(run([pkg_config, "--variable=prefix", package_name]))
    compliance_root = prefix / "share/stellar-libsmb2-private"
    compliance_metadata = compliance_root / "metadata.json"
    if not compliance_metadata.is_file():
        raise RuntimeError("libsmb2 LGPL build metadata is missing")
    metadata = json.loads(compliance_metadata.read_text(encoding="utf-8"))
    source_archive = compliance_root / str(metadata.get("source_archive", ""))
    if (
        metadata.get("revision") != payload["revision"]
        or metadata.get("license") != payload["license"]
        or not source_archive.is_file()
        or not (compliance_root / "licenses/COPYING").is_file()
        or not (compliance_root / "licenses/LICENCE-LGPL-2.1.txt").is_file()
        or not (compliance_root / "build/symbol-map.txt").is_file()
    ):
        raise RuntimeError("libsmb2 LGPL source/license/build materials are incomplete")
    source_hash = hashlib.sha256(source_archive.read_bytes()).hexdigest()
    if source_hash != metadata.get("source_sha256"):
        raise RuntimeError("libsmb2 corresponding source archive hash does not match metadata")
    with tarfile.open(source_archive, "r:gz") as source_tar:
        source_names = source_tar.getnames()
    if not any(name.endswith("/LICENCE-LGPL-2.1.txt") for name in source_names):
        raise RuntimeError("libsmb2 corresponding source archive omits the LGPL text")
    symbols = defined_symbols(run([symbol_tool, "-g", "--defined-only", "-P", str(archive)]))
    unprefixed = sorted(symbol for symbol in symbols if not symbol.startswith(payload["symbol_prefix"]))
    if unprefixed:
        raise RuntimeError(f"static archive exports unprefixed symbols: {', '.join(unprefixed[:10])}")
    required = {
        f"{payload['symbol_prefix']}smb2_init_context",
        f"{payload['symbol_prefix']}smb2_pread",
    }
    if not required.issubset(symbols):
        raise RuntimeError("private static archive is missing required prefixed ABI symbols")

    exclude_flag = f"-Wl,--exclude-libs,{archive_name}"
    source = root / "tools/ci/libsmb2_binding_smoke.c"
    shim_include = root / "platforms/swift/Sources/CStellarLibsmb2Private"
    with tempfile.TemporaryDirectory(prefix="stellar-libsmb2-smoke-") as temporary:
        temporary_path = Path(temporary)
        binary = temporary_path / "libsmb2-binding-smoke"
        run(
            [
                compiler,
                "-I",
                str(shim_include),
                str(source),
                "-Wl,--export-dynamic",
                "-o",
                str(binary),
                exclude_flag,
                *flags,
            ]
        )
        run([str(binary)])
        dynamic_symbols = defined_symbols(
            run([symbol_tool, "-D", "-g", "--defined-only", "-P", str(binary)])
        )
        leaked = sorted(
            symbol
            for symbol in dynamic_symbols
            if symbol.startswith(str(payload["symbol_prefix"]))
        )
        if leaked:
            raise RuntimeError(
                "private libsmb2 symbols leaked into the dynamic export table: "
                + ", ".join(leaked[:10])
            )
        dynamic_dependencies = shutil.which("ldd")
        if dynamic_dependencies:
            linked = run([dynamic_dependencies, str(binary)])
            if "libsmb2" in linked.lower():
                raise RuntimeError("smoke binary unexpectedly depends on a shared libsmb2")
        wrapper_binary = temporary_path / "stellar-smb2-wrapper-smoke"
        wrapper_source = root / "platforms/swift/Sources/CStellarSMB2Wrapper/stellar_smb2_wrapper.c"
        wrapper_include = root / "platforms/swift/Sources/CStellarSMB2Wrapper/include"
        wrapper_smoke = root / "tools/ci/stellar_smb2_wrapper_smoke.c"
        run(
            [
                compiler,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-I",
                str(wrapper_include),
                str(wrapper_source),
                str(wrapper_smoke),
                "-Wl,--export-dynamic",
                "-o",
                str(wrapper_binary),
                exclude_flag,
                *flags,
            ]
        )
        run([str(wrapper_binary)])
        wrapper_dynamic_symbols = defined_symbols(
            run([symbol_tool, "-D", "-g", "--defined-only", "-P", str(wrapper_binary)])
        )
        wrapper_leaks = sorted(
            symbol
            for symbol in wrapper_dynamic_symbols
            if symbol.startswith(str(payload["symbol_prefix"]))
        )
        if wrapper_leaks:
            raise RuntimeError(
                "private libsmb2 symbols leaked through the C wrapper: "
                + ", ".join(wrapper_leaks[:10])
            )
        if dynamic_dependencies:
            linked = run([dynamic_dependencies, str(wrapper_binary)])
            if "libsmb2" in linked.lower():
                raise RuntimeError("C wrapper unexpectedly depends on a shared libsmb2")
        cancellation_binary = temporary_path / "stellar-smb2-wrapper-cancel-smoke"
        cancellation_source = root / "tools/ci/stellar_smb2_wrapper_cancel_smoke.c"
        run(
            [
                compiler,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-pthread",
                "-I",
                str(wrapper_include),
                str(wrapper_source),
                str(cancellation_source),
                "-o",
                str(cancellation_binary),
                exclude_flag,
                *flags,
            ]
        )
        run([str(cancellation_binary)])
    print(f"isolated static libsmb2 C binding smoke passed: pkg-config {version}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--require-installed", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        lock = load_lock(root / "third_party/libsmb2.lock.json")
        findings = validate_lock(lock) + validate_binding_boundary(root)
        if findings:
            for finding in findings:
                print(f"libsmb2 binding check failed: {finding}")
            return 1
        print(f"libsmb2 provenance check passed: {lock['revision']}")
        if args.require_installed:
            verify_installed(root, lock)
    except RuntimeError as error:
        print(f"libsmb2 binding check failed: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

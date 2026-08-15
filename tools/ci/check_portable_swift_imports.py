#!/usr/bin/env python3
"""Keep Apple-only frameworks out of Swift targets that must compile on Linux."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PORTABLE_TARGETS = (
    "StellarCore",
    "StellarRemoteMedia",
    "StellarLocalMedia",
    "StellarWebDAV",
    "StellarMediaLibrary",
    "StellarSMB2Core",
    "StellarUserMediaSDK",
    "StellarMediaCLI",
)

APPLE_ONLY_MODULES = {
    "AppKit",
    "AuthenticationServices",
    "AVFoundation",
    "Combine",
    "CryptoKit",
    "LocalAuthentication",
    "OSLog",
    "Security",
    "SwiftUI",
    "UIKit",
}

IMPORT_PATTERN = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(\w+)", re.MULTILINE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    sources = args.root.resolve() / "platforms/swift/Sources"
    findings: list[tuple[Path, str]] = []

    for target in PORTABLE_TARGETS:
        target_root = sources / target
        if not target_root.exists():
            continue
        for path in target_root.rglob("*.swift"):
            for module in IMPORT_PATTERN.findall(path.read_text(encoding="utf-8")):
                if module in APPLE_ONLY_MODULES:
                    findings.append((path.relative_to(args.root.resolve()), module))

    for path, module in findings:
        print(f"{path}: Apple-only import {module} is not allowed in a portable target")
    if findings:
        return 1
    print("portable Swift import check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

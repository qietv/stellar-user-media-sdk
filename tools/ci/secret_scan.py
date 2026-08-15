#!/usr/bin/env python3
"""Fail on high-confidence secrets without printing the matched value."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


PATTERNS = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "AWS access key": re.compile(rb"(?<![A-Z0-9])AKIA[A-Z0-9]{16}(?![A-Z0-9])"),
    "GitHub token": re.compile(rb"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{36,}(?![A-Za-z0-9])"),
    "Slack token": re.compile(rb"(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9-]{20,}(?![A-Za-z0-9])"),
    "Google API key": re.compile(rb"(?<![A-Za-z0-9])AIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9])"),
    "Stripe live key": re.compile(rb"(?<![A-Za-z0-9])(?:sk|rk)_live_[A-Za-z0-9]{16,}(?![A-Za-z0-9])"),
}

EXCLUDED_DIRECTORIES = {".git", ".build", ".swiftpm", "DerivedData", "node_modules"}
EXCLUDED_FILES = {Path("tools/ci/secret_scan.py")}
SENSITIVE_FILENAMES = {".env", ".npmrc", ".pypirc", "id_rsa", "id_ed25519"}


def repository_files(root: Path) -> list[Path]:
    completed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=False,
        capture_output=True,
    )
    if completed.returncode == 0 and completed.stdout:
        return [root / Path(value.decode()) for value in completed.stdout.split(b"\0") if value]
    return [
        path
        for path in root.rglob("*")
        if path.is_file() and not any(part in EXCLUDED_DIRECTORIES for part in path.parts)
    ]


def scan(root: Path) -> list[tuple[Path, int, str]]:
    findings: list[tuple[Path, int, str]] = []
    for path in repository_files(root):
        relative = path.relative_to(root)
        if relative in EXCLUDED_FILES or not path.is_file():
            continue
        if path.name in SENSITIVE_FILENAMES or path.name.startswith("secrets."):
            findings.append((relative, 1, "sensitive filename"))
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        for line_number, line in enumerate(data.splitlines(), start=1):
            for label, pattern in PATTERNS.items():
                if pattern.search(line):
                    findings.append((relative, line_number, label))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    findings = scan(root)
    for path, line, label in findings:
        print(f"{path}:{line}: possible {label}")
    if findings:
        print(f"secret scan failed with {len(findings)} finding(s)")
        return 1
    print("secret scan passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

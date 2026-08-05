#!/usr/bin/env python3
"""Small, dependency-free scanner for exported test artifacts.

It is intentionally conservative: a match is a review failure, not proof that
the artifact contains personal information. Run it on a report/bundle export
directory, never on the repository itself (documentation contains examples).
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

PATTERNS = (
    ("absolute path", re.compile(rb"/(?:Users|private/var|var/folders)/")),
    ("file URL", re.compile(rb"file://")),
    ("IPv4 address", re.compile(rb"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])")),
    ("token-like field", re.compile(rb"(?i)(?:pairing|session|auth|access)[_-]?token\s*[:=]")),
    ("security bookmark", re.compile(rb"(?i)securityScopedBookmark|bookmark_blob")),
)


def files(root: pathlib.Path):
    if root.is_file():
        yield root
        return
    for path in root.rglob("*"):
        if path.is_file() and ".git" not in path.parts and ".build" not in path.parts:
            yield path


def scan(root: pathlib.Path) -> list[str]:
    findings: list[str] = []
    for path in files(root):
        try:
            data = path.read_bytes()
        except OSError as exc:
            findings.append(f"{path}: unreadable ({exc})")
            continue
        for label, pattern in PATTERNS:
            if pattern.search(data):
                findings.append(f"{path}: {label}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan exported AudioLink artifacts for sensitive identifiers.")
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    findings = [finding for path in args.paths for finding in scan(path)]
    if findings:
        print("Privacy scan failed:", file=sys.stderr)
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("Privacy scan passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

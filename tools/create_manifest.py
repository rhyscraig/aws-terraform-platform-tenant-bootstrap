#!/usr/bin/env python3
"""
Holistic Repository Manifest Builder with Secret Redaction and Smart-Scan.
Strictly formatted for Ruff/Mypy compliance.
"""

from __future__ import annotations

import hashlib
import os
import re
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Final

# ==============================================================================
# ⚙️ CUSTOMIZATION & CONFIGURATION
# ==============================================================================

OUTPUT_DIR_NAME: Final[str] = "output"
MANIFEST_PREFIX: Final[str] = "seed_manifest"
TIMESTAMP: Final[str] = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
OUTPUT_FILENAME: Final[str] = f"{MANIFEST_PREFIX}_{TIMESTAMP}.txt"

SECRET_PATTERNS: Final[dict[str, re.Pattern[str]]] = {
    "AWS_ACCESS_KEY": re.compile(r"AKIA[0-9A-Z]{16}"),
    "AWS_SECRET_KEY": re.compile(r"([^A-Z0-9a-z/+=][A-Za-z0-9/+=]{40}[^A-Z0-9a-z/+=])"),
    "AWS_SESSION_TOKEN": re.compile(r"(?i)aws_session_token\s*[:=]\s*['\"]([A-Za-z0-9/+=]{100,})['\"]"),
    "GENERIC_SECRET": re.compile(
        r"(?i)(password|passphrase|secret|token|api_key|client_secret)\s*[:=]\s*['\"]([^'\"]+)['\"]"
    ),
}

GLOBAL_EXCLUDE_DIRS: Final[set[str]] = {
    ".git",
    ".terraform",
    "__pycache__",
    "node_modules",
    ".pytest_cache",
    ".ruff_cache",
    "venv",
    ".venv",
    "dist",
    "build",
    ".mypy_cache",
    "output",
}

GLOBAL_EXCLUDE_FILES: Final[set[str]] = {
    "AI.md",
    "uv.lock",
    "create_manifest.py",
    "terraform.lock.hcl",
    ".secrets.baseline",
    "seed-terraform/.terraform.lock.hcl",
    "cloudformation/member-role-stackset/.terraform.lock.hcl",
    "*/.terraform.lock.hcl",
}

# ==============================================================================
# 🛠️ CORE IMPLEMENTATION
# ==============================================================================


def _redact_secrets(content: str) -> str:
    redacted = content
    for label, pattern in SECRET_PATTERNS.items():
        redacted = pattern.sub(f"[REDACTED_{label}]", redacted)
    return redacted


def _hash_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _safe_text(b: bytes) -> str:
    try:
        if b"\0" in b:
            return ""
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return ""


def create_manifest() -> None:
    """Generates a snapshot of the repo with smart-scan warnings for missed files."""
    script_location: Path = Path(__file__).resolve().parent
    repo_root: Path = script_location.parent

    output_path: Path = script_location / OUTPUT_DIR_NAME
    output_path.mkdir(exist_ok=True)
    final_output_file: Path = output_path / OUTPUT_FILENAME

    # 🧹 Cleanup
    for old in repo_root.rglob("*.txt"):
        if MANIFEST_PREFIX in old.name or "*_manifest" in old.name:
            try:
                old.unlink()
            except OSError:
                pass

    manifest_entries: list[dict[str, Any]] = []
    file_blocks: list[str] = []

    # 🕵️ Smart Scan Tracking
    ignored_extensions: Counter[str] = Counter()
    total_files_discovered: int = 0

    print(f"🚀 Scanning entire repository: {repo_root}")

    for root_path, dirs, files in os.walk(repo_root):
        dirs[:] = sorted(d for d in dirs if d not in GLOBAL_EXCLUDE_DIRS)

        for file in sorted(files):
            total_files_discovered += 1

            if file in GLOBAL_EXCLUDE_FILES:
                continue

            if MANIFEST_PREFIX in file or "*_manifest" in file:
                continue

            file_path: Path = Path(root_path) / file
            rel_path: Path = file_path.relative_to(repo_root)

            try:
                content_bytes: bytes = file_path.read_bytes()
                raw_text: str = _safe_text(content_bytes)

                if not raw_text:
                    ignored_extensions["binary/non-utf8"] += 1
                    continue

                clean_text: str = _redact_secrets(raw_text)

                entry: dict[str, Any] = {
                    "path": str(rel_path),
                    "lines": len(clean_text.splitlines()),
                    "bytes": len(content_bytes),
                    "sha256": _hash_bytes(content_bytes),
                }
                manifest_entries.append(entry)
                file_blocks.append(
                    f"---FILE-START: {rel_path} | LINES: {entry['lines']}\n{clean_text}\n---FILE-END: {rel_path}\n"
                )

            except Exception as e:
                print(f"❌ Error processing {rel_path}: {e}")

    # Assemble Final Content (no manifest header)
    manifest_body: str = "".join(file_blocks)

    final_output_file.write_text(manifest_body, encoding="utf-8")

    # ⚠️ Smart Scan Summary
    print(f"✅ Full Manifest generated: {final_output_file.name}")
    print(f"📊 Included: {len(manifest_entries)} files | Ignored: {sum(ignored_extensions.values())} files")

    if ignored_extensions:
        print("\n🔍 Smart-Scan Ignored Extensions (Top 5):")
        for ext, count in ignored_extensions.most_common(5):
            print(f"  - {ext}: {count} files")
        print("💡 Hint: Add extensions to TEXT_EXTENSIONS in the script if they are missing.")


if __name__ == "__main__":
    create_manifest()

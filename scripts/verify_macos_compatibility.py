#!/usr/bin/env python3
"""Verify that a built Cotabby bundle can load on the declared macOS baseline."""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def run(*arguments: str) -> str:
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    return result.stdout


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(piece) for piece in value.split("."))


def architectures(binary: Path) -> list[str]:
    return run("/usr/bin/lipo", "-archs", str(binary)).strip().split()


def minimum_version(binary: Path, architecture: str) -> str:
    output = run("/usr/bin/vtool", "-arch", architecture, "-show-build", str(binary))
    active_command: str | None = None
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line.startswith("cmd "):
            active_command = line.removeprefix("cmd ")
            continue
        if active_command == "LC_BUILD_VERSION" and line.startswith("minos "):
            return line.removeprefix("minos ").strip()
        if active_command == "LC_VERSION_MIN_MACOSX" and line.startswith("version "):
            return line.removeprefix("version ").strip()
    raise RuntimeError(f"No macOS minimum-version load command in {binary} ({architecture})")


def is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    output = run("/usr/bin/file", "-b", str(path))
    return "Mach-O" in output


def bundled_binaries(app_path: Path, main_binary: Path) -> list[Path]:
    binaries = [main_binary]
    frameworks = app_path / "Contents" / "Frameworks"
    if not frameworks.exists():
        return binaries

    seen = {main_binary.resolve()}
    for root, _, filenames in os.walk(frameworks):
        for filename in filenames:
            candidate = Path(root) / filename
            if not is_macho(candidate):
                continue
            resolved = candidate.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            binaries.append(candidate)
    return binaries


def foundation_models_load_commands(binary: Path, architecture: str) -> list[str]:
    output = run("/usr/bin/otool", "-l", "-arch", architecture, str(binary))
    active_command: str | None = None
    commands: list[str] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line.startswith("cmd "):
            active_command = line.removeprefix("cmd ")
            continue
        if line.startswith("name ") and "FoundationModels.framework" in line:
            commands.append(active_command or "unknown")
    return commands


def verify(app_path: Path, expected_minimum: str, require_universal: bool) -> None:
    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.is_file():
        raise RuntimeError(f"Info.plist not found: {info_path}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    plist_minimum = str(info.get("LSMinimumSystemVersion", ""))
    if plist_minimum != expected_minimum:
        raise RuntimeError(
            f"LSMinimumSystemVersion is {plist_minimum!r}, expected {expected_minimum!r}"
        )

    executable = info.get("CFBundleExecutable")
    if not executable:
        raise RuntimeError("CFBundleExecutable is missing from Info.plist")
    main_binary = app_path / "Contents" / "MacOS" / str(executable)
    if not main_binary.is_file():
        raise RuntimeError(f"Main executable not found: {main_binary}")

    main_architectures = architectures(main_binary)
    if require_universal and not {"arm64", "x86_64"}.issubset(main_architectures):
        raise RuntimeError(
            "Release executable must contain arm64 and x86_64; found "
            + ", ".join(main_architectures)
        )

    expected_tuple = version_tuple(expected_minimum)
    checked = 0
    for binary in bundled_binaries(app_path, main_binary):
        for architecture in architectures(binary):
            minimum = minimum_version(binary, architecture)
            checked += 1
            if version_tuple(minimum) > expected_tuple:
                relative = binary.relative_to(app_path)
                raise RuntimeError(
                    f"{relative} ({architecture}) requires macOS {minimum}, "
                    f"above the supported {expected_minimum} baseline"
                )

    for architecture in main_architectures:
        for command in foundation_models_load_commands(main_binary, architecture):
            if command != "LC_LOAD_WEAK_DYLIB":
                raise RuntimeError(
                    "FoundationModels must be weak-linked for macOS 14: "
                    f"{architecture} uses {command}"
                )

    print(
        f"Verified {app_path}: LSMinimumSystemVersion={expected_minimum}, "
        f"architectures={','.join(main_architectures)}, Mach-O slices checked={checked}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app_path", type=Path)
    parser.add_argument("--minimum", default="14.0")
    parser.add_argument("--require-universal", action="store_true")
    arguments = parser.parse_args()

    try:
        verify(arguments.app_path, arguments.minimum, arguments.require_universal)
    except (RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"macOS compatibility verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

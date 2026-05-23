#!/usr/bin/env python3
"""Generate a Sparkle appcast entry for a notarized Tabby DMG.

This script intentionally does not depend on Sparkle's `generate_appcast` helper because Tabby's
release flow is small and predictable:
1. a notarized `Tabby.dmg` is uploaded to GitHub Releases
2. `sign_update` produces the EdDSA enclosure signature and archive length
3. this script renders one `appcast.xml` from a checked-in template

The script prefers explicit inputs over "magic":
- release version and build number are required arguments
- the archive path is required
- the signing tool may be provided explicitly or discovered in common DerivedData locations
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
from pathlib import Path
import re
import subprocess
import sys


DEFAULT_OWNER = "FuJacob"
DEFAULT_REPOSITORY = "tabby"
SIGNATURE_PATTERN = re.compile(r'sparkle:edSignature="([^"]+)"\s+length="([^"]+)"')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate Tabby's Sparkle appcast XML.")
    parser.add_argument("--release-version", required=True, help="Marketing version, eg. 1.0.0")
    parser.add_argument("--build-number", required=True, help="CURRENT_PROJECT_VERSION value")
    parser.add_argument("--archive", required=True, help="Path to the notarized Tabby.dmg")
    parser.add_argument(
        "--output",
        default="build/appcast.xml",
        help="Output path for the rendered appcast.xml",
    )
    parser.add_argument(
        "--template",
        default="scripts/appcast.template.xml",
        help="Path to the checked-in appcast XML template",
    )
    parser.add_argument(
        "--sign-update-tool",
        default=None,
        help="Explicit path to Sparkle's sign_update tool",
    )
    parser.add_argument(
        "--ed-key-file",
        default=None,
        help=(
            "Optional path to the Sparkle Ed25519 private key file. "
            "Useful in CI where the key is supplied from a repository secret."
        ),
    )
    parser.add_argument(
        "--archive-filename",
        default=None,
        help="Filename in the GitHub Release download URL. Defaults to basename of --archive.",
    )
    parser.add_argument(
        "--github-owner",
        default=DEFAULT_OWNER,
        help="GitHub owner used to build release and repository URLs",
    )
    parser.add_argument(
        "--github-repository",
        default=DEFAULT_REPOSITORY,
        help="GitHub repository name used to build release and repository URLs",
    )
    return parser.parse_args()


def escape_xml(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def candidate_sign_update_paths(explicit_path: str | None) -> list[Path]:
    candidates: list[Path] = []

    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    env_override = os.environ.get("SPARKLE_SIGN_UPDATE_TOOL")
    if env_override:
        candidates.append(Path(env_override).expanduser())

    try:
        xcrun_path = subprocess.run(
            ["xcrun", "--find", "sign_update"],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        xcrun_path = None

    if xcrun_path and xcrun_path.returncode == 0:
        candidates.append(Path(xcrun_path.stdout.strip()))

    derived_data_root = Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived_data_root.exists():
        candidates.extend(
            derived_data_root.glob("*/SourcePackages/artifacts/**/Sparkle/bin/sign_update")
        )

    return candidates


def resolve_sign_update_tool(explicit_path: str | None) -> Path:
    for candidate in candidate_sign_update_paths(explicit_path):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate

    raise SystemExit(
        "Could not locate Sparkle's sign_update tool. Run an Xcode build that resolves the "
        "Sparkle package first, or pass --sign-update-tool /path/to/sign_update."
    )


def sign_archive(sign_update_tool: Path, archive: Path, ed_key_file: Path | None) -> tuple[str, str]:
    command = [str(sign_update_tool)]
    if ed_key_file is not None:
        command.extend(["--ed-key-file", str(ed_key_file)])
    command.append(str(archive))

    process = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    output = process.stdout.strip()
    match = SIGNATURE_PATTERN.search(output)
    if match is None:
        raise SystemExit(
            "sign_update returned output in an unexpected format:\n"
            f"{output}"
        )

    return match.group(1), match.group(2)


def render_appcast(
    template_path: Path,
    repository_url: str,
    release_page_url: str,
    archive_url: str,
    short_version: str,
    build_version: str,
    archive_length: str,
    ed_signature: str,
) -> str:
    template = template_path.read_text(encoding="utf-8")
    pub_date = dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")

    replacements = {
        "{{REPOSITORY_URL}}": escape_xml(repository_url),
        "{{RELEASE_PAGE_URL}}": escape_xml(release_page_url),
        "{{ARCHIVE_URL}}": escape_xml(archive_url),
        "{{SHORT_VERSION}}": escape_xml(short_version),
        "{{BUILD_VERSION}}": escape_xml(build_version),
        "{{ARCHIVE_LENGTH}}": escape_xml(archive_length),
        "{{ED_SIGNATURE}}": escape_xml(ed_signature),
        "{{PUB_DATE}}": escape_xml(pub_date),
    }

    rendered = template
    for needle, value in replacements.items():
        rendered = rendered.replace(needle, value)

    return rendered


def main() -> int:
    args = parse_args()

    archive = Path(args.archive).expanduser().resolve()
    if not archive.is_file():
        raise SystemExit(f"Archive does not exist: {archive}")

    template_path = Path(args.template).expanduser().resolve()
    if not template_path.is_file():
        raise SystemExit(f"Template does not exist: {template_path}")

    sign_update_tool = resolve_sign_update_tool(args.sign_update_tool)

    ed_key_file = None
    if args.ed_key_file:
        ed_key_file = Path(args.ed_key_file).expanduser().resolve()
        if not ed_key_file.is_file():
            raise SystemExit(f"Sparkle Ed25519 private key file does not exist: {ed_key_file}")

    ed_signature, archive_length = sign_archive(sign_update_tool, archive, ed_key_file)

    repository_url = f"https://github.com/{args.github_owner}/{args.github_repository}"
    release_tag = f"v{args.release_version}"
    release_page_url = f"{repository_url}/releases/tag/{release_tag}"
    archive_filename = args.archive_filename or archive.name
    archive_url = f"{repository_url}/releases/download/{release_tag}/{archive_filename}"

    rendered_appcast = render_appcast(
        template_path=template_path,
        repository_url=repository_url,
        release_page_url=release_page_url,
        archive_url=archive_url,
        short_version=args.release_version,
        build_version=args.build_number,
        archive_length=archive_length,
        ed_signature=ed_signature,
    )

    output_path = Path(args.output).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered_appcast, encoding="utf-8")

    print(f"Generated appcast: {output_path}")
    print(f"Release page: {release_page_url}")
    print(f"Archive URL: {archive_url}")
    print(f"Used sign_update tool: {sign_update_tool}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

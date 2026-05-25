#!/usr/bin/env python3
"""Build a styled release DMG for Cotabby.

This script owns the DMG packaging policy so the GitHub Actions workflow can
stay focused on orchestration. The workflow decides *when* to package, while
this script decides *how* the installer disk image is assembled:

1. Validate the archived app bundle that release CI produced.
2. Stage a copy of the app plus the Applications shortcut source.
3. Normalize the committed background art to the Finder window size we want.
4. Resolve a best-effort badge icon from the built app bundle.
5. Generate a temporary dmgbuild settings file and invoke dmgbuild.

The extra boundary matters because installer DMGs are mostly layout policy.
Keeping that policy in one file makes local reproduction and future tweaks much
safer than scattering geometry and temporary-file behavior through YAML.
"""

from __future__ import annotations

import argparse
import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from textwrap import dedent


# The committed background art is authored at 2x. Finder window dimensions use point-sized
# coordinates so the mounted DMG opens compactly without scrollbars while preserving crisp art.
WINDOW_WIDTH = 540
WINDOW_HEIGHT = 760
ICON_SIZE = 128
APP_ICON_LOCATION = (270, 280)
APPLICATIONS_ICON_LOCATION = (270, 635)


def parse_args() -> argparse.Namespace:
    """Parse the small CLI contract used by local releases and CI."""

    parser = argparse.ArgumentParser(
        description="Build a styled Cotabby release DMG with dmgbuild."
    )
    parser.add_argument(
        "--app-path",
        required=True,
        help="Path to the signed Cotabby.app bundle that should be packaged.",
    )
    parser.add_argument(
        "--output-path",
        required=True,
        help="Path where the final Cotabby.dmg should be written.",
    )
    parser.add_argument(
        "--background-path",
        required=True,
        help="Path to the committed 1x DMG background PNG source asset.",
    )
    parser.add_argument(
        "--background-2x-path",
        required=True,
        help="Path to the committed @2x DMG background PNG source asset.",
    )
    parser.add_argument(
        "--volume-name",
        required=True,
        help="Mounted volume name shown by Finder, for example Cotabby.",
    )
    return parser.parse_args()


def run_command(command: list[str], *, allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    """Run a subprocess and surface stderr in a release-friendly way.

    The packaging flow crosses several system-tool boundaries: `ditto`,
    `sips`, and `dmgbuild`. Centralizing process execution keeps failure output
    consistent and makes it obvious which command actually failed.
    """

    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 and not allow_failure:
        if result.stdout:
            print(result.stdout, file=sys.stderr, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        raise RuntimeError(f"Command failed with exit code {result.returncode}: {' '.join(command)}")
    return result


def require_existing_path(path: Path, *, kind: str) -> Path:
    """Fail fast when the release workflow points at a missing input."""

    if not path.exists():
        raise FileNotFoundError(f"{kind} not found at {path}")
    return path.resolve()


def ensure_dmgbuild_available() -> None:
    """Fail early when the release machine is missing the DMG builder dependency."""

    if importlib.util.find_spec("dmgbuild") is None:
        raise RuntimeError(
            "dmgbuild is not installed. Run `python3 -m pip install "
            "\"dmgbuild[badge_icons]==1.6.7\"` before packaging."
        )


def resolve_app_icon_path(app_path: Path) -> Path | None:
    """Resolve the app icon inside the built bundle for best-effort DMG badging.

    Why pull from the built app bundle instead of hardcoding a repo asset path?
    The bundle is the shipping truth. If the release target ever changes its
    icon metadata, using the bundle keeps the DMG badge aligned with the actual
    product users install.
    """

    info_path = app_path / "Contents" / "Info.plist"
    resource_dir = app_path / "Contents" / "Resources"
    if not resource_dir.exists():
        return None

    candidates: list[Path] = []
    if info_path.exists():
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)

        icon_name = info.get("CFBundleIconFile") or info.get("CFBundleIconName")
        if isinstance(icon_name, str) and icon_name:
            candidates.extend(
                [
                    resource_dir / icon_name,
                    resource_dir / f"{icon_name}.icns",
                    resource_dir / f"{icon_name}.png",
                ]
            )

    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()

    for candidate in sorted(resource_dir.glob("*.icns")):
        if candidate.is_file():
            return candidate.resolve()

    return None


def normalize_background_image(
    source_1x_path: Path,
    source_2x_path: Path,
    destination_path: Path,
) -> None:
    """Combine 1x and @2x PNGs into a multi-rep TIFF for Finder.

    A single PNG can't carry multiple resolutions, and DPI-tagging tricks are
    fragile across macOS versions. A multi-image TIFF (the same format Apple's
    own installers use) lets Finder pick the right rep per display.
    """

    run_command(
        [
            "tiffutil",
            "-cathidpicheck",
            str(source_1x_path),
            str(source_2x_path),
            "-out",
            str(destination_path),
        ]
    )


def stage_release_root(app_path: Path, staging_root: Path) -> Path:
    """Create a temporary release root matching the visible DMG contents.

    The staging directory is a deliberate boundary. It gives us one folder that
    answers the question “what should exist at the root of this image?” and
    makes local inspection easier when packaging changes later.
    """

    staged_app_path = staging_root / app_path.name
    run_command(["ditto", str(app_path), str(staged_app_path)])
    (staging_root / "Applications").symlink_to("/Applications")
    return staged_app_path


def write_settings_file(
    settings_path: Path,
    *,
    staged_app_path: Path,
    normalized_background_path: Path,
    badge_icon_path: Path | None,
) -> None:
    """Write the temporary dmgbuild settings module for this packaging run."""

    settings = dedent(
        f"""
        # Generated by scripts/build_release_dmg.py.
        # This settings module is ephemeral on purpose: the Python script owns
        # the data flow, while dmgbuild consumes a concrete snapshot of those
        # decisions for a single packaging run.

        app_path = {str(staged_app_path)!r}
        app_name = {staged_app_path.name!r}

        files = [app_path]
        symlinks = {{"Applications": "/Applications"}}
        format = "UDZO"
        default_view = "icon-view"
        include_icon_view_settings = True
        arrange_by = None
        icon_size = {ICON_SIZE}
        text_size = 14
        label_pos = "bottom"
        icon_locations = {{
            app_name: {APP_ICON_LOCATION},
            "Applications": {APPLICATIONS_ICON_LOCATION},
        }}

        background = {str(normalized_background_path)!r}
        window_rect = ((120, 120), ({WINDOW_WIDTH}, {WINDOW_HEIGHT}))
        show_status_bar = False
        show_tab_view = False
        show_toolbar = False
        show_pathbar = False
        show_sidebar = False
        show_icon_preview = False
        grid_spacing = 96
        """
    ).strip() + "\n"

    if badge_icon_path is not None:
        settings += f"badge_icon = {str(badge_icon_path)!r}\n"

    settings_path.write_text(settings, encoding="utf-8")


def build_dmg(
    *,
    volume_name: str,
    output_path: Path,
    settings_path: Path,
) -> None:
    """Invoke dmgbuild through the active Python interpreter."""

    if output_path.exists():
        output_path.unlink()

    run_command(
        [
            sys.executable,
            "-m",
            "dmgbuild",
            "-s",
            str(settings_path),
            volume_name,
            str(output_path),
        ]
    )


def main() -> int:
    """Coordinate the end-to-end packaging flow for one DMG build."""

    args = parse_args()
    ensure_dmgbuild_available()
    app_path = require_existing_path(Path(args.app_path), kind="App bundle")
    background_1x_path = require_existing_path(Path(args.background_path), kind="Background asset (1x)")
    background_2x_path = require_existing_path(Path(args.background_2x_path), kind="Background asset (@2x)")
    output_path = Path(args.output_path).resolve()

    if app_path.suffix != ".app":
        raise ValueError(f"Expected a .app bundle, got {app_path}")
    if background_1x_path.suffix.lower() != ".png":
        raise ValueError(f"Expected a PNG background asset, got {background_1x_path}")
    if background_2x_path.suffix.lower() != ".png":
        raise ValueError(f"Expected a PNG background asset, got {background_2x_path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="Cotabby-dmgbuild-") as temporary_root:
        temporary_root_path = Path(temporary_root)
        staging_root = temporary_root_path / "staging-root"
        staging_root.mkdir()

        staged_app_path = stage_release_root(app_path, staging_root)
        normalized_background_path = temporary_root_path / "dmg-background.tiff"
        normalize_background_image(
            background_1x_path,
            background_2x_path,
            normalized_background_path,
        )

        badge_icon_path = resolve_app_icon_path(app_path)

        settings_path = temporary_root_path / "dmgbuild-settings.py"
        write_settings_file(
            settings_path,
            staged_app_path=staged_app_path,
            normalized_background_path=normalized_background_path,
            badge_icon_path=badge_icon_path,
        )

        build_dmg(
            volume_name=args.volume_name,
            output_path=output_path,
            settings_path=settings_path,
        )

    print(f"Built styled DMG at {output_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # pragma: no cover - exercised by manual release validation.
        print(f"Failed to build release DMG: {error}", file=sys.stderr)
        raise SystemExit(1)

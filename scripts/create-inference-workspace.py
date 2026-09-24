#!/usr/bin/env python3
"""Create an ignored Xcode workspace for paired app/native-package development.

Xcode resolves a package referenced by the workspace locally in preference to the
same remote package identity. The canonical project and package declaration stay
unchanged, so a contributor never needs to commit a machine-specific path.
"""

import argparse
from pathlib import Path
import xml.etree.ElementTree as ET


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inference_checkout", type=Path, help="local CotabbyInference checkout")
    parser.add_argument("--output", type=Path, help="workspace destination (defaults to the development workspace)")
    args = parser.parse_args()
    checkout = args.inference_checkout.expanduser().resolve()
    if not (checkout / "Package.swift").is_file():
        parser.error(f"No Package.swift in {checkout}")

    root = Path(__file__).resolve().parent.parent
    project = root / "CoHamster.xcodeproj"
    if not project.is_dir():
        parser.error("Generate CoHamster.xcodeproj with XcodeGen first")

    destination = args.output.resolve() if args.output else root / "build" / "CoHamsterDevelopment.xcworkspace"
    destination.mkdir(parents=True, exist_ok=True)
    workspace = ET.Element("Workspace", version="1.0")
    for path in (project, checkout):
        ET.SubElement(workspace, "FileRef", location=f"absolute:{path}")
    ET.ElementTree(workspace).write(
        destination / "contents.xcworkspacedata", encoding="UTF-8", xml_declaration=True
    )
    print(destination)
    print("Use -workspace with this path instead of -project when running xcodebuild.")


if __name__ == "__main__":
    main()

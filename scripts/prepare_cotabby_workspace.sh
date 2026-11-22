#!/bin/bash
# Prepares the reproducible app/native boundary shared by local builds, CI, and releases.
# Cotabby.xcodeproj already pins CotabbyInference to the same revision, so a plain project build
# compiles against identical native code. This workspace additionally copies Config/Package.resolved,
# which pins every other package exactly, and overrides the remote package with a local checkout
# without committing a machine-specific path or modifying the upstream dependency repository.
set -euo pipefail
cd "$(dirname "$0")/.."
workspace_root="${1:-$PWD/build/cotabby-dependencies}"
mkdir -p "$workspace_root"
workspace_root="$(cd "$workspace_root" && pwd)"
native_dir="$workspace_root/CotabbyInference"
# Keep in sync with the CotabbyInference revision in project.yml (and the generated project.pbxproj).
revision=0db6b1f293e9c9e3fcc96a1ae26ebedc7745b239
if [[ ! -d "$native_dir/.git" ]]; then
    git clone https://github.com/FuJacob/cotabbyinference.git "$native_dir"
    git -C "$native_dir" checkout --detach "$revision"
fi
stale_checkout() {
    echo "error: $native_dir $1." >&2
    echo "It is never reset automatically. Remove that directory (after saving any local work) and rerun $0." >&2
    exit 1
}
[[ "$(git -C "$native_dir" rev-parse HEAD)" == "$revision" ]] || stale_checkout "is not at the pinned revision $revision"
# Untracked files count as drift too: a leftover source file would still be compiled into the package.
[[ -z "$(git -C "$native_dir" status --porcelain --untracked-files=all -- Package.swift README.md Sources Tests)" ]] \
    || stale_checkout "has local modifications"
workspace="$workspace_root/Cotabby.xcworkspace"
python3 scripts/create-inference-workspace.py "$native_dir" --output "$workspace"
mkdir -p "$workspace/xcshareddata/swiftpm"
cp Config/Package.resolved "$workspace/xcshareddata/swiftpm/Package.resolved"

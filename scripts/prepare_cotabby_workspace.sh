#!/bin/bash
# Prepares the reproducible app/native boundary shared by local builds, CI, and releases.
# The checked-in patch supplies APIs used by the app. A workspace overrides the remote package
# without committing a machine-specific path or modifying the upstream dependency repository.
set -euo pipefail
cd "$(dirname "$0")/.."
workspace_root="${1:-$PWD/build/cotabby-dependencies}"
mkdir -p "$workspace_root"
workspace_root="$(cd "$workspace_root" && pwd)"
native_dir="$workspace_root/CotabbyInference"
revision=7574a21516c65fc31f5cf8ef7380a03412eed480
if [[ ! -d "$native_dir/.git" ]]; then
    git clone https://github.com/FuJacob/cotabbyinference.git "$native_dir"
    git -C "$native_dir" checkout --detach "$revision"
    git -C "$native_dir" apply "$PWD/patches/cotabbyinference-upstream-pending.patch"
fi
[[ "$(git -C "$native_dir" rev-parse HEAD)" == "$revision" ]]
# Include newly added patch files when comparing; never reset or overwrite a modified checkout.
git -C "$native_dir" add -N Sources Tests
git -C "$native_dir" diff HEAD -- README.md Sources Tests > "$workspace_root/native.patch"
cmp patches/cotabbyinference-upstream-pending.patch "$workspace_root/native.patch"
workspace="$workspace_root/Cotabby.xcworkspace"
python3 scripts/create-inference-workspace.py "$native_dir" --output "$workspace"
mkdir -p "$workspace/xcshareddata/swiftpm"
cp Config/Package.resolved "$workspace/xcshareddata/swiftpm/Package.resolved"

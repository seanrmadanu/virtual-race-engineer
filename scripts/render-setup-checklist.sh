#!/bin/bash
# Off-screen render of the setup checklist. Usage: render-setup-checklist.sh OUTPUT.png [scale]
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-setup-render.XXXXXX)"
# Frozen copies: the project lives in iCloud Documents, which can touch inputs mid-build.
for source in "Racing Trainer/SetupChecklist.swift" "Racing Trainer/SetupScreenText.swift" \
    "Racing Trainer/SetupChecklistView.swift" \
    "Training/setup/SetupChecklistRender.swift"; do
    cp -X "$project_dir/$source" "$build_dir/"
done
xcrun swiftc -swift-version 5 -parse-as-library -O "$build_dir"/*.swift -o "$build_dir/render"
"$build_dir/render" "$@"

#!/bin/bash
# Prints the text the setup reader finds on a frame. Usage: dump-screen-text.sh VIDEO SECONDS | IMAGE
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${RACING_DUMP_BUILD:-$(mktemp -d /private/tmp/racing-screen-text.XXXXXX)}"
if [[ ! -x "$build_dir/dump" ]]; then
    for source in "Racing Trainer/SetupChecklist.swift" "Racing Trainer/SetupScreenText.swift" \
        "Racing Trainer/SetupScreenReader.swift" "Training/setup/ScreenTextDump.swift"; do
        cp -X "$project_dir/$source" "$build_dir/"
    done
    xcrun swiftc -swift-version 5 -parse-as-library -O "$build_dir"/*.swift -o "$build_dir/dump"
fi
"$build_dir/dump" "$@"

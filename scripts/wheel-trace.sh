#!/bin/bash
# Record wheel target and drawn angle at 60 fps through the real analyzer.
# Usage: wheel-trace.sh VIDEO START SECONDS OUT.csv
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-wheel-trace.XXXXXX)"
eval "$(grep -A3 '^sources=' "$project_dir/scripts/check-live-guidance.sh")"
paths=()
for source in "${sources[@]}" SteeringWheelMotion; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$project_dir/Training/road/WheelTrace.swift" -o "$build_dir/wheel-trace" 2>&1 | grep -E "error" -A3 || true
"$build_dir/wheel-trace" "$@"

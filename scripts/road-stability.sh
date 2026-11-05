#!/bin/bash
# Road-line steadiness on fixed clips (stopped and moving). Usage: road-stability.sh [extra swift files]
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-road-stability.XXXXXX)"
xcrun swiftc -swift-version 5 -parse-as-library -O "$project_dir/Racing Trainer/RoadLineDetector.swift" \
    "$project_dir/Racing Trainer/RoadLineTracker.swift" "$project_dir/Training/road/RoadStability.swift" -o "$build_dir/stab"
videos="$project_dir/../Training Video"
for clip in "2 69 7 stopped" "2 217 6 stopped-tunnel" "2 160 10 forest-shade" "2 116 10 forest-shade-2" "2 540 10 shade-3" "2 335 10 moving" "1 100 10 moving" "1 300 10 moving-low-cam"; do
    set -- $clip
    printf '%-26s' "V$1 @$2s ($4)"; "$build_dir/stab" "$videos/Video $1.mp4" "$2" "$3" | sed "s/^  /    /"
done

#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_check_root="$(mktemp -d /private/tmp/racing-pilot-check.XXXXXX)"
xcrun swiftc -swift-version 5 -parse-as-library \
    "$project_dir/Racing Trainer/RoadLineDetector.swift" \
    "$project_dir/Racing Trainer/TurnGuidance.swift" \
    "$project_dir/Racing Trainer/CornerTechnique.swift" \
    "$project_dir/Racing Trainer/LinkedTurns.swift" \
    "$project_dir/Racing Trainer/ModelReviewModels.swift" \
    "$project_dir/Training/guidance/modular/ValidatePilot.swift" \
    -o "$task_check_root/validate-pilot"
"$task_check_root/validate-pilot" \
    "$project_dir/data/guidance/modular/video2-v4/pilot.review.json" \
    "$project_dir/../Training Video/Video 2.mp4" \
    "$project_dir/data/guidance/modular/video2-v4/observations.jsonl"

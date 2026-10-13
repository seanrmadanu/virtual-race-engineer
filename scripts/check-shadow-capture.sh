#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_build_root="$(mktemp -d /private/tmp/racing-shadow-smoke.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach ModularVideoModules MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 ShadowCaptureState ShadowCapturePipeline ShadowSessionRecorder)
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$task_build_root/cache" \
    "${paths[@]}" "$project_dir/Training/guidance/modular/ShadowCaptureSmoke.swift" -o "$task_build_root/smoke"
"$task_build_root/smoke" "$project_dir/../Training Video/Video 2.mp4" \
    "$project_dir/data/guidance/shadow-smoke"

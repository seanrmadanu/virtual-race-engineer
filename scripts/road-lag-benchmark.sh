#!/bin/bash
# Measure road-line update rate and age with the real FrameAnalyzer at video speed.
# Usage: road-lag-benchmark.sh VIDEO START SECONDS [-O|-Onone]
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-road-lag.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach MinimapCoachModels RoadLineDetector RouteTurnSelector MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer MinimapMotionTracker MinimapDrivingCoachEngine LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights TurnGuidance TurnGuidanceTracker LiveTurnGuidance CornerTechnique CornerTechniqueTracker ModelReviewModels FrameAnalyzer RoadLineTracker)
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library "${4:--O}" -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$project_dir/Training/road/RoadLagBenchmark.swift" -o "$build_dir/road-lag-benchmark"
"$build_dir/road-lag-benchmark" "$1" "$2" "$3"

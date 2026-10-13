#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-live-guidance.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer MinimapMotionTracker MinimapDrivingCoachEngine
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 TurnGuidance TurnGuidanceTracker LiveTurnGuidance ModelReviewModels FrameAnalyzer)
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$project_dir/Training/guidance/modular/LiveGuidanceSmoke.swift" -o "$build_dir/check-live-guidance"
printf '%s\n' "Live analyzer smoke: $build_dir/check-live-guidance"
"$build_dir/check-live-guidance" "$@"

#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-turn-timing.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach ModularVideoModules MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 TurnGuidance TurnGuidanceTracker CornerTechnique CornerTechniqueTracker ModelReviewModels GuidanceVideoAnalyzer)
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$project_dir/Training/guidance/modular/ReplayTurnTiming.swift" -o "$build_dir/replay-turn-timing"
printf '%s\n' "Timing replay: $build_dir/replay-turn-timing"
"$build_dir/replay-turn-timing" "$@"

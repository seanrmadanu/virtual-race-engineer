#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-review-visibility.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach ModularVideoModules MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 TurnGuidance TurnGuidanceTracker CornerTechnique CornerTechniqueTracker ModelReviewModels AIReviewModels GuidanceVideoAnalyzer ModelReviewStore)
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$project_dir/Training/guidance/modular/ReviewVisibilityChecks.swift" -o "$build_dir/check-review-visibility"
"$build_dir/check-review-visibility" "$@"

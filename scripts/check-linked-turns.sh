#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-linked-check.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach ModularVideoModules MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 TurnGuidance TurnGuidanceTracker CornerTechnique CornerTechniqueTracker LinkedTurns LinkedTurnReadout
 ModelReviewModels AIReviewModels GuidanceVideoAnalyzer ModelReviewStore)
paths=()
for source in "${sources[@]}"; do
    cp -X "$project_dir/Racing Trainer/$source.swift" "$build_dir/$source.swift"
    paths+=("$build_dir/$source.swift")
done
cp -X "$project_dir/Training/guidance/modular/LinkedTurnChecks.swift" "$build_dir/LinkedTurnChecks.swift"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$build_dir/LinkedTurnChecks.swift" -o "$build_dir/check-linked-turns"
"$build_dir/check-linked-turns" "$@"

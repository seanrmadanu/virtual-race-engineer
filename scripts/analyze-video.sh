#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-video-analysis.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach ModularVideoModules MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 TurnGuidance TurnGuidanceTracker CornerTechnique CornerTechniqueTracker LinkedTurns ModelReviewModels GuidanceVideoAnalyzer)
paths=()
# Freeze compiler inputs outside iCloud, which can update mtimes during a build.
for source in "${sources[@]}"; do
    cp -X "$project_dir/Racing Trainer/$source.swift" "$build_dir/$source.swift"
    paths+=("$build_dir/$source.swift")
done
cp -X "$project_dir/Training/guidance/modular/AnalyzeVideo.swift" "$build_dir/AnalyzeVideo.swift"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$build_dir/AnalyzeVideo.swift" -o "$build_dir/analyze-video"
printf '%s\n' "Analyzer: $build_dir/analyze-video"
"$build_dir/analyze-video" "$@"

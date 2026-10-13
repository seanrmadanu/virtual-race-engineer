#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-modules.XXXXXX)"
# Compiler output is retained for diagnostics; never overwrite an existing replay.
sources=(CoachSafetyPolicy ModularCoach ModularVideoModules MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights)
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/Racing Trainer/$source.swift"); done
export RACING_MODULE_PIPELINE_SHA256="$(shasum -a 256 "${paths[@]}" \
 "$project_dir/Training/guidance/modular/ReplayModules.swift" \
 "$project_dir/Training/guidance/modular/NativeModuleChecks.swift" | shasum -a 256 | awk '{print $1}')"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${paths[@]}" "$project_dir/Training/guidance/modular/ReplayModules.swift" \
 "$project_dir/Training/guidance/modular/NativeModuleChecks.swift" -o "$build_dir/replay-modules"
"$build_dir/replay-modules" "$@"

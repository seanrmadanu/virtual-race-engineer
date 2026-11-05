#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/racing-wheel-check.XXXXXX)"
sources=(CoachSafetyPolicy ModularCoach MinimapCoachModels RoadLineDetector RouteTurnSelector
 MotorfestHUDLayout MotorfestSpeedRecognizer MinimapRouteDetector MinimapGeometryAnalyzer MinimapMotionTracker MinimapDrivingCoachEngine
 LearnedRouteSegmenter LearnedRouteSegmenterWeights RouteComponentVerifier RouteComponentVerifierWeights
 TurnGuidance TurnGuidanceTracker LiveTurnGuidance CornerTechnique CornerTechniqueTracker LinkedTurns ModelReviewModels FrameAnalyzer
 SteeringWheelMotion SteeringWheelView TrainerSidebar)
paths=(); flags=(-D WHEEL_CHECKS)
# Freeze compiler inputs outside the shared/iCloud-backed checkout.
mkdir -p "$build_dir/source"
for source in "${sources[@]}"; do
    cp -X "$project_dir/Racing Trainer/$source.swift" "$build_dir/source/"
    paths+=("$build_dir/source/$source.swift")
done
cp -X "$project_dir/Training/guidance/modular/SteeringWheelChecks.swift" "$build_dir/source/"
# Optional archived implementation for a same-frame before/after comparison.
if [[ -n "${RACING_WHEEL_BASELINE_SOURCE:-}" ]]; then
    cp -X "$RACING_WHEEL_BASELINE_SOURCE" "$build_dir/source/BaselineWheel.swift"
    paths+=("$build_dir/source/BaselineWheel.swift"); flags+=(-D WHEEL_BASELINE)
fi
app="$build_dir/WheelChecks.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WheelChecks</string>
<key>CFBundleIdentifier</key><string>local.racing.WheelChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
mkdir -p "$build_dir/Assets.xcassets"
cp -X "$project_dir/Racing Trainer/Assets.xcassets/Contents.json" "$build_dir/Assets.xcassets/"
cp -RX "$project_dir/Racing Trainer/Assets.xcassets/SteeringWheel.imageset" "$build_dir/Assets.xcassets/"
xcrun actool "$build_dir/Assets.xcassets" --compile "$app/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --output-format human-readable-text > "$build_dir/assets.log"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$build_dir/cache" \
 "${flags[@]}" "${paths[@]}" "$build_dir/source/SteeringWheelChecks.swift" -o "$app/MacOS/WheelChecks"
"$app/MacOS/WheelChecks" "$@"

#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_build_root="$(mktemp -d /private/tmp/racing-modular-source.XXXXXX)"
configuration="${RACING_BUILD_CONFIGURATION:-Debug}"
printf '%s\n' "Local verification copy: $task_build_root"
# Build only exact source copies. Exclude iCloud metadata, user state, recordings and Git.
cp -RX "$project_dir/Racing Trainer" "$project_dir/RacingTrainerSafetyTests" "$task_build_root/"
mkdir -p "$task_build_root/Racing Trainer.xcodeproj/xcshareddata/xcschemes"
cp -X "$project_dir/Racing Trainer.xcodeproj/project.pbxproj" "$task_build_root/Racing Trainer.xcodeproj/"
cp -X "$project_dir/Racing Trainer.xcodeproj/xcshareddata/xcschemes/Racing Trainer.xcscheme" \
    "$task_build_root/Racing Trainer.xcodeproj/xcshareddata/xcschemes/"
xcodebuild -project "$task_build_root/Racing Trainer.xcodeproj" -scheme 'Racing Trainer' \
    -configuration "$configuration" -destination 'platform=macOS' -derivedDataPath "$task_build_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO test
printf '%s\n' "Verified app: $task_build_root/DerivedData/Build/Products/$configuration/Racing Trainer.app"

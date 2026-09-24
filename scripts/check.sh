#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-test}"
case "$action" in
    build|test) ;;
    *) printf 'Usage: bash scripts/check.sh [build|test]\n' >&2; exit 2 ;;
esac

exec xcodebuild \
    -project "$project_root/Racing Trainer.xcodeproj" \
    -scheme "Racing Trainer" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${RACING_TRAINER_DERIVED_DATA:-$project_root/DerivedData}" \
    CODE_SIGNING_ALLOWED=NO \
    "$action"

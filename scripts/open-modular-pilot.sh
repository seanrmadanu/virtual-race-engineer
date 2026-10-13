#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/data/guidance/modular/verified-app-20261009-comparison/Racing Trainer.app"
pilot_path="$project_dir/data/guidance/modular/video2-v4/pilot.review.json"
video_path="$project_dir/../Training Video/Video 2.mp4"
if [[ ! -d "$app_path" || ! -f "$pilot_path" || ! -f "$video_path" ]]; then
    printf '%s\n' 'The verified app, pilot, or recording is missing. See docs/MODULAR_COACH.md.' >&2
    exit 1
fi
open -n "$app_path" --args --model-review --review-bundle "$pilot_path" --review-video "$video_path" \
    --review-storage "$project_dir/data/guidance/modular/user-reviews"

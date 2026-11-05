#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/data/guidance/modular/verified-app-20261014-stable-guidance/Racing Trainer.app"
test_path="$project_dir/data/guidance/turn-timing-20261009/video2-final/video.review.json"
video_path="$project_dir/../Training Video/Video 2.mp4"
if [[ ! -d "$app_path" || ! -f "$test_path" || ! -f "$video_path" ]]; then
    printf '%s\n' 'The updated app or prepared video test is missing. See docs/GUIDANCE_REVIEW_UPDATE.md.' >&2
    exit 1
fi
open -n "$app_path" --args --model-review --review-bundle "$test_path" --review-video "$video_path" \
    --review-storage "$project_dir/data/guidance/modular/user-reviews"

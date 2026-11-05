#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/data/guidance/category1-reliability-20261018/verified-app-release/chatgpt.app"
test_path="$project_dir/data/guidance/category1-reliability-20261018/video2-full/video.review.json"
video_path="$project_dir/../Training Video/Video 2.mp4"
if [[ ! -d "$app_path" || ! -f "$test_path" || ! -f "$video_path" ]]; then
    printf '%s\n' 'The updated app or prepared video test is missing. See docs/GUIDANCE_REVIEW_UPDATE.md.' >&2
    exit 1
fi
open -n "$app_path" --args --model-review --review-bundle "$test_path" --review-video "$video_path" \
    --review-storage "$project_dir/data/guidance/modular/user-reviews"

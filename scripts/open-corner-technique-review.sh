#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
review_dir="$project_dir/data/guidance/category2-20261015"
app_path="$project_dir/data/guidance/category1-reliability-20261018/verified-app-release/chatgpt.app"
bundle_path="$review_dir/video2-final/video.review.json"
video_path="$project_dir/../Training Video/Video 2.mp4"
if [[ ! -d "$app_path" || ! -f "$bundle_path" || ! -f "$video_path" ]]; then
    printf '%s\n' 'The Category 2 review build or recording is missing. See docs/CORNER_TECHNIQUE.md.' >&2
    exit 1
fi
open -n "$app_path" --args --model-review --review-category corner_technique \
    --review-bundle "$bundle_path" --review-video "$video_path" \
    --review-storage "$review_dir/user-reviews" "$@"

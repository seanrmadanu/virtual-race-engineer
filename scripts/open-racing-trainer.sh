#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/data/guidance/modular/verified-app-20261013-simple-guidance/Racing Trainer.app"
if [[ ! -d "$app_path" ]]; then
    printf '%s\n' 'The integrated app build is missing. See docs/GUIDANCE_REVIEW_UPDATE.md.' >&2
    exit 1
fi
if [[ "${1:-}" == "--test" ]]; then
    shift
    open -n "$app_path" --args --test-video "$project_dir/../Training Video/Video 2.mp4" --test-start 94 \
        --guidance-profile reference-video2-v1 --guidance-speed-unit km/h "$@"
else
    open -n "$app_path" --args "$@"
fi

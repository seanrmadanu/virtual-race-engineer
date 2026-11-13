#!/bin/bash
# Open the latest verified "Claude" build of this copy on Video 2 (default 2:40; pass a start second).
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/data/guidance/setup-checklist-20261112/app-claude-v2/Claude.app"
open -n "$app_path" --args --test-video "$project_dir/../Training Video/Video 2.mp4" --test-start "${1:-160}" \
    --guidance-profile reference-video2-v1 --guidance-speed-unit km/h

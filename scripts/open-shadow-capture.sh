#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/data/guidance/shadow-build-20261005-v2/Racing Trainer.app"
log_root="$project_dir/data/guidance/shadow-sessions"
if [[ ! -d "$app_path" ]]; then
    printf '%s\n' 'The shadow build is missing. See docs/SHADOW_CAPTURE.md.' >&2
    exit 1
fi
# Do not reuse the review app or its storage. Recording is explicitly opt-in via this launcher.
# A new capture window may use the input already selected in the app settings.
open -n "$app_path" --args --shadow-log-root "$log_root" --shadow-record-hud \
    --shadow-car-setup "${1:-unconfirmed}" --shadow-hud-profile "${2:-unconfirmed}" \
    "${@:3}"
printf '%s\n' "Shadow logs: $log_root (new UUID folder per launch). No shadow cues are emitted."

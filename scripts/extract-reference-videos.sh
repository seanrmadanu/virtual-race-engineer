#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf '%s\n' \
        'Usage: extract-reference-videos.sh --input PATH --output DIRECTORY --unit kmh|mph [--start SECONDS] [--end SECONDS]' \
        '' \
        'Extract reference-only speed observations from local .mp4/.mov/.m4v files.' \
        'Input may be one file or a directory (no recursive search).' \
        'Check the visible HUD unit and explicitly pass --unit kmh or --unit mph.' \
        'Without --start/--end, process each complete recording in bounded 60-second chunks.' \
        'Use a short --start/--end pilot first. Maximum 100,000 samples per source.' \
        'Requires uncropped 16:9 Motorfest footage with the standard visible speed HUD.' \
        'Outputs per-source JSON with SHA256 provenance, actual source timestamps and unreviewed candidates.' \
        'No player recording is needed. No model is trained and no driving actions are labeled.' \
        'Existing output files are never overwritten; use a new output directory for a new run.' \
        'Requires macOS and the Xcode Swift command-line tools.'
    exit 0
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# This private, unique directory contains only this invocation's compiler outputs.
build_dir="$(mktemp -d /private/tmp/racing-reference-extractor.XXXXXX)"
trap 'rm -rf -- "$build_dir"' EXIT

printf '%s\n' 'Compiling local reference extractor...'
xcrun swiftc -swift-version 5 -parse-as-library -O \
    -module-cache-path "$build_dir/module-cache" \
    "$project_dir/Racing Trainer/MotorfestHUDLayout.swift" \
    "$project_dir/Racing Trainer/MotorfestSpeedRecognizer.swift" \
    "$project_dir/Racing Trainer/CornerReplayModels.swift" \
    "$project_dir/Racing Trainer/ReferenceVideoDataset.swift" \
    "$project_dir/Racing Trainer/ReplayVideoSampler.swift" \
    "$project_dir/Training/ExtractReferenceDataset.swift" \
    -o "$build_dir/extract-reference-dataset"

"$build_dir/extract-reference-dataset" "$@"

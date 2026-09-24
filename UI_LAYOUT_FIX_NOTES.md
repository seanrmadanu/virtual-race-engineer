# UI overflow and fullscreen panel fix

This build starts from `Racing_Trainer_Minimap_Coach_V5_1` and updates the UI layout in `ContentView.swift`.

## Fixed

- Top coach/minimap banners and bottom preview controls now stay inside the preview bounds.
- The windowed bottom status strip keeps its full height instead of being compressed by the gameplay preview.
- Native safe areas are respected in video fullscreen mode.
- Frame Analyzer and Route Mask Dataset are draggable while video fullscreen is active.
- Draggable panels are clamped to the visible preview and are re-clamped after a resize or section expansion.
- Frame Analyzer is divided into four collapsible sections:
  - Performance
  - Minimap / Route
  - Driving Coach
  - Speed OCR
- The analyzer uses internal scrolling when expanded content is taller than the available preview.

## Compiler cleanup

- Fixed the escaping content-closure error in the collapsible analyzer sections.
- Migrated deprecated one-parameter `onChange` handlers to the macOS 14+ API.
- Made dataset metadata value types explicitly nonisolated for background JSON encoding and decoding.
- Removed deprecated pre-macOS-14 capture-device constants that are unreachable at this project's macOS 26.3 deployment target.

## Quick test

1. Build and run the project in Xcode.
2. Resize and maximize the normal window; confirm the bottom status strip remains visible.
3. Enter video fullscreen; confirm the top banner and bottom control buttons have an inset from every edge.
4. Turn Analyzer on, drag both debug panels, and expand every analyzer section.
5. Resize the fullscreen window or exit fullscreen; no overlay should extend outside the visible preview.

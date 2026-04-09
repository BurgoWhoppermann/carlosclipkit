# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

FramePull is a native macOS SwiftUI application that extracts still frames, animated GIFs, and video clips from source videos using intelligent scene detection. Zero external dependencies — only Apple frameworks (AVFoundation, Vision, CoreImage, ImageIO, AppKit, Combine).

User documentation lives in [`docs/documentation.md`](docs/documentation.md).

## Build Commands

```bash
# Always prefix with DEVELOPER_DIR if xcodebuild isn't found
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build (Debug)
xcodebuild -scheme FramePull -configuration Debug

# Build (Release)
xcodebuild -scheme FramePull -configuration Release

# Clean
xcodebuild clean -scheme FramePull

# Build and run
xcodebuild -scheme FramePull -configuration Debug -derivedDataPath ./build && open ./build/Build/Products/Debug/FramePull.app
```

There are no tests, linting, or CI/CD configured.

## Architecture

### App Entry & State

- **`FramePullApp.swift`** — App entry point. Defines `AppState` (central `ObservableObject`), all export enums (`OutputFormat`, `GIFResolution`, `StillFormat`, `StillSize`, `ClipQuality`, `StillPlacement`), brand colors, and the menu bar commands.
- **`AppState`** — Holds video URL, export settings, scene detection results, LUT state, and a `MarkingState` child object. Owns the unified app-level undo stack.

### Views

| File | Role |
|------|------|
| `ContentView.swift` | Drop zone / import screen. Shown until a video is loaded, then replaced by `ManualMarkingView`. |
| `ManualMarkingView.swift` | **Main UI.** Video player, timeline, marker controls, inline auto-generate panel, stills/clips list, export trigger. Also contains `ManualTimelineView`, `MarkerPreviewView`, `KeyboardShortcutsView`, and `AnimatedGIFView`. |
| `ExportSettingsView.swift` | Sheet for configuring and running exports (format, quality, crop variants, output folder). |
| `BetaSplashView.swift` | Launch splash / What's New screen (`SplashView`). Plays `VideoTutorial1.mp4` from the app bundle. |

### Processing Pipeline

| Processor | Output | Notes |
|-----------|--------|-------|
| `VideoProcessor.swift` | Still images (JPEG/PNG/TIFF) | Face detection (Vision), blur rejection, per-still `reframeOffset` for 4:5/9:16 crops |
| `VideoSnippetProcessor.swift` | MP4 clips **and** animated GIFs | Handles both via `exportClipAndGIF()`; per-clip `reframeOffset` for crop positioning |
| `ProcessingUtilities.swift` | Shared helpers | `cropImageToAspectRatio(horizontalOffset:)`, `resizeImage`, `findNextAvailableIndex`, `ensureSubdirectory` |
| `LUTProcessor.swift` | `.cube` LUT loading | Parses cube files, builds `CIFilter` for real-time preview and export baking |
| `SceneDetector.swift` | Scene cut timestamps | Bhattacharyya distance on 8×8×8 RGB histograms; async with downsampled frames |

### Marking State

**`MarkingState.swift`** — ObservableObject owned by `AppState`. Tracks:
- `markedStills: [MarkedStill]` — each with `timestamp`, `isManual`, `reframeOffset`
- `markedClips: [MarkedClip]` — each with `inPoint`, `outPoint`, `isManual`, `reframeOffset`
- `pendingInPoint` — waiting for the user to set an OUT point
- `detectedCuts` — scene cut timestamps used for snap-to-cut
- 50-step undo stack (`UndoAction` enum)

### Video Player

**`VideoPlayerRepresentable.swift`** — `NSViewRepresentable` wrapping `AVPlayer` via a `LoopingPlayerController`. Features: looping, LUT composition via `AVMutableVideoComposition`, keyboard event forwarding, time observation, clip loop range, volume control, frame-step.

## Key Data Flow

```
Drop video → AppState.videoURL set → ContentView → ManualMarkingView
                                                         │
                            ┌──── SceneDetector (async) ─┤
                            │                            │
                            ▼                            ▼
                    markingState.detectedCuts    video player loads
                            │
                    Auto-generate or manual S/I/O keystrokes
                            │
                    markingState.markedStills / markedClips
                            │
                    ExportSettingsView → VideoProcessor / VideoSnippetProcessor
                                                         │
                                              /stills, /gifs, /videos
                                           (+ /4x5 and /9x16 subdirs)
```

## Export Output Structure

```
<output folder>/
├── stills/
│   ├── videoname_still_001.jpg
│   ├── 4x5/videoname_still_001.jpg   (if export4x5 enabled)
│   └── 9x16/videoname_still_001.jpg  (if export9x16 enabled)
├── gifs/
│   ├── videoname_clip_001.gif
│   ├── 4x5/videoname_clip_001.gif
│   └── 9x16/videoname_clip_001.gif
└── videos/
    ├── videoname_clip_001.mp4
    ├── 4x5/videoname_clip_001.mp4
    └── 9x16/videoname_clip_001.mp4
```

Sequential numbering (`_001`, `_002` …) prevents overwrites.

## Per-Item Reframe Offset

Each `MarkedStill` and `MarkedClip` stores a `reframeOffset: CGFloat` (0.0 = far left, 0.5 = center, 1.0 = far right). This controls the horizontal crop position when exporting 4:5 or 9:16 variants. Set via the drag gesture or slider in `MarkerPreviewView`.

- `ProcessingUtilities.cropImageToAspectRatio(_:targetRatio:horizontalOffset:)` uses it for still crops.
- `VideoSnippetProcessor.exportCroppedClip` uses it via `CGAffineTransform` translation for video crops.
- When both 4:5 and 9:16 are enabled, 9:16 gets the reframe offset; 4:5 stays centered.

## LUT System

LUTs live in two places:
- **Built-in**: `FramePull/LUTs/*.cube` (bundled in the app, ARRI / Canon / Sony log transforms)
- **User folder**: Any folder the user points to via "Choose LUT Folder…" (stored as a security-scoped bookmark in `UserDefaults`)

`LUTProcessor` parses `.cube` files into a flat `[Float]` array passed to `CIColorCubeWithColorSpace`. The player applies this via `AVVideoCompositionCoreAnimationTool`; exporters apply it via `CIContext`.

## Recent Work (2026-03-15)

### Per-clip reframe offset
- Added `reframeOffset: CGFloat = 0.5` to both `MarkedStill` and `MarkedClip` structs in `MarkingState.swift`
- Added `updateReframeOffset(forStill:offset:)` and `updateReframeOffset(forClip:offset:)` mutation methods
- `VideoProcessor` now takes `reframeOffsets: [CGFloat]?` — offsets are paired with timestamps before sorting to maintain correct mapping
- `VideoSnippetProcessor.exportClipAndGIF` takes `reframeOffset: CGFloat = 0.5`; passed through to `exportCroppedClip` and `createGIF`
- Priority rule: when both 4:5 and 9:16 are enabled, 9:16 gets the reframe offset; 4:5 stays centered

### Preview & Reframe UI (MarkerPreviewView in ManualMarkingView.swift)
- Renamed "Preview" button/header to "Preview & Reframe"
- `MarkerPreviewView` now takes `@ObservedObject var markingState: MarkingState` + `let reframeRatio: VideoSnippetProcessor.AspectRatioCrop?`
- Lightbox shows a crop overlay (GeometryReader-based dim outside crop window) when `reframeRatio != nil`
- Slider and drag gesture both control `localReframeOffset`; committed to `MarkingState` on release via `commitReframeOffset()`
- Drag direction: positive translation → increase offset (crop frame moves right)
- `NSCursor.resizeLeftRight` applied on hover over the image area

### UI compression
- Bottom export bar uses `.controlSize(.regular)` (was `.large`), padding reduced
- Version footer uses `.system(size: 9)`, top padding reduced to 2pt

### Tooltips
- `.help()` modifiers added to ~40 interactive elements across `ExportSettingsView.swift`, `ManualMarkingView.swift`, and `ContentView.swift`

### Documentation
- `docs/documentation.md` — full user guide written and linked from README and Help menu
- `FramePullApp.swift` Help menu command opens the local docs file via `NSWorkspace`

### Cleanup
- Deleted `AnalysisSettingsView.swift` (dead code — superseded by inline generate panel)
- Deleted `GIFProcessor.swift` (dead code — GIF export lives in `VideoSnippetProcessor`)
- Deleted root `/LUTs/` and root `VideoTutorial1.mp4` (duplicates not in app bundle)
- Removed deleted files from `project.pbxproj`

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Carlo's Clipkit is a native macOS SwiftUI application that extracts still frames, animated GIFs, and video clips from source videos using intelligent scene detection. It has zero external dependencies — only Apple frameworks (AVFoundation, Vision, CoreImage, ImageIO, AppKit, Combine).

## Build Commands

```bash
# Build (Debug)
xcodebuild -scheme CarlosClipkit -configuration Debug

# Build (Release)
xcodebuild -scheme CarlosClipkit -configuration Release

# Clean
xcodebuild clean -scheme CarlosClipkit

# Build and run
xcodebuild -scheme CarlosClipkit -configuration Debug -derivedDataPath ./build && open ./build/Build/Products/Debug/CarlosClipkit.app
```

There are no tests, linting, or CI/CD configured.

## Architecture

### Two-Mode Design

The app has two extraction modes sharing a single `AppState` (ObservableObject):

- **Auto Mode** (`ContentView.swift`) — Automatic scene detection places markers across detected scenes. Timeline visualization with draggable markers.
- **Manual Mode** (`ManualMarkingView.swift`) — Frame-by-frame marking via keyboard shortcuts (S=still, I=in-point, O=out-point). Scene cut snapping, full undo/redo via `MarkingState`.

Mode switching syncs markers between the two views.

### Processing Pipeline

Three independent processor classes handle export:

| Processor | Output | Key Details |
|-----------|--------|-------------|
| `VideoProcessor` | Still images (JPEG/PNG/TIFF) | Optional face detection (Vision) and blur rejection |
| `GIFProcessor` | Animated GIFs | Configurable resolution (320w/480w/640w), frame rate |
| `VideoSnippetProcessor` | MP4 clips | Quality presets (480p–4K), optional 4:5 and 9:16 aspect ratio variants |

### Scene Detection (`SceneDetector.swift`)

Uses histogram-based frame comparison with **Bhattacharyya distance** on 8×8×8 RGB color histograms (512 bins). Key parameters: configurable thresholds for real cuts vs. motion, minimum scene duration to avoid micro-scenes. Runs asynchronously with downsampled frames.

### State Management

- `AppState` (`CarlosClipkitApp.swift`) — Central ObservableObject holding video URL, extraction settings, detected scenes, still positions, export config.
- `MarkingState` (`MarkingState.swift`) — Observable state for manual mode with undo/redo stack and pending clip ranges.

### Video Player (`VideoPlayerRepresentable.swift`)

Custom `NSViewRepresentable` wrapping AVPlayer with looping playback, keyboard event capture, time observation for UI sync, and video dimension detection.

## Key Enums (in `CarlosClipkitApp.swift`)

`ExtractionMode`, `OutputFormat`, `GIFResolution`, `StillFormat`, `StillSize`, `ClipQuality`, `PlaybackSpeed` — all defined alongside `AppState`.

## Export Workflow

Files are output to organized subdirectories (`/stills/`, `/gifs/`, `/videos/`) with optional `/4x5` and `/9x16` subdirectories for aspect ratio variants. Sequential numbering prevents overwrites.

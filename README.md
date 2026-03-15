<p align="center">
  <img src="FramePull/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="FramePull icon" />
</p>

<h1 align="center">FramePull</h1>

<p align="center">
  <strong>Extract stills, GIFs, and clips from any video — fast, local, no subscriptions.</strong>
</p>

<p align="center">
  A native macOS app for filmmakers, editors, and content creators who need to pull frames from footage without roundtripping through a full NLE.
</p>

---

## What it does

Drop a video file into FramePull and it automatically detects every scene cut. From there you can mark stills, define clip ranges, and export — all from a single, focused interface.

- **Still frames** — JPEG, PNG, or TIFF at full or half resolution
- **Animated GIFs** — configurable resolution (320w–640w), frame rate, and quality
- **Video clips** — MP4 at 480p through 4K, with optional 4:5 and 9:16 crop variants
- **LUT support** — load `.cube` files for real-time color correction preview, baked into exports

<p align="center">
  <img src=".github/screenshots/timeline.png" width="720" alt="FramePull timeline with markers and clips" />
</p>

<p align="center">
  <img src=".github/screenshots/timeline-2.png" width="720" alt="FramePull scene detection and manual marking" />
</p>

## Scene detection

FramePull uses histogram-based frame comparison (Bhattacharyya distance on 8x8x8 RGB color histograms) to find cuts in your footage. No cloud processing, no API calls — everything runs locally on your Mac using Apple frameworks.

Detected cuts appear as markers on the timeline. You can then auto-generate stills and clips spread across scenes, or manually place them exactly where you want with keyboard shortcuts.

<p align="center">
  <img src=".github/screenshots/export.png" width="420" alt="FramePull export settings" />
</p>

## Key features

| | |
|---|---|
| **Auto-generate** | One click to place stills and clips across detected scenes |
| **Manual marking** | `S` = mark still, `I` = in-point, `O` = out-point |
| **Draggable timeline** | Drag markers and clip edges, snap to playhead or scene cuts |
| **Timeline zoom** | Zoom in up to 20x for precision editing with auto-follow playhead |
| **LUT preview** | Apply `.cube` LUTs in real-time — exported files include the color grade |
| **Face detection** | Optionally prefer frames with faces using Apple Vision |
| **Blur rejection** | Skip blurry frames automatically |
| **Mute audio** | Strip audio from exported clips with one toggle |
| **Multi-lane clips** | Overlapping clip ranges stack on separate lanes |
| **Aspect ratio crops** | Export 4:5 and 9:16 variants alongside originals |

## Built with

Zero external dependencies. FramePull is built entirely on Apple frameworks:

`AVFoundation` · `Vision` · `CoreImage` · `ImageIO` · `AppKit` · `SwiftUI` · `Combine`

<p align="center">
  <img src=".github/screenshots/drop.jpg" width="720" alt="FramePull drop zone" />
</p>

## Install

**Mac App Store** — *coming soon*

## Documentation

Full user documentation is available in [`docs/documentation.md`](docs/documentation.md).

Topics covered: getting started, cut detection, manual and auto-generated markers, timeline interaction, LUT color grading, Preview & Reframe, export settings, keyboard shortcuts, and common workflows.

## Feedback

FramePull is in active development. Bugs and feature requests welcome at [mail@carlooppermann.com](mailto:mail@carlooppermann.com).

## License

Copyright &copy; 2026 Carlo Oppermann. All rights reserved. See [LICENSE](LICENSE) for details.

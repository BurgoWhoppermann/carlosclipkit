<p align="center">
  <img src="FramePull/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="FramePull icon" />
</p>

<h1 align="center">FramePull</h1>

<p align="center">
  <strong>Extract stills, GIFs, clips, and social-format grids from any video — fast, local, no subscriptions.</strong>
</p>

<p align="center">
  A native macOS app for filmmakers, editors, and content creators who need to pull frames from footage without roundtripping through a full NLE.
</p>

---

## What it does

Drop a video file into FramePull and it automatically detects every scene cut — frame-precise. From there you can mark stills, define clip ranges, build grids, and export — all from a single, focused interface.

- **Still frames** — JPEG, PNG, or TIFF at full or half resolution
- **Animated GIFs** — configurable resolution (480w–1080p), frame rate, and quality
- **Video clips** — MP4 at 480p through 4K, with optional 4:5 and 9:16 crop variants
- **Grids** — compose stills and clips into 1×1 through 3×2 layouts at 1:1 / 4:5 / 9:16 / 16:9, exported as JPEG (all stills) or MP4 (any clip)
- **LUT support** — load `.cube` files for real-time color correction preview, baked into exports

<p align="center">
  <img src=".github/screenshots/timeline.png" width="720" alt="FramePull timeline with markers and clips" />
</p>

## Documentation

Full user guide: **[docs/documentation.md](docs/documentation.md)**

Topics: cut detection · manual & auto marking · timeline · LUT grading · Process workflow (Review · Grids · Export) · keyboard shortcuts · workflows

## Scene detection — frame-precise

FramePull samples every frame of your video at the source's actual frame rate (no hardcoded 25/30) and uses histogram-based frame comparison (Bhattacharyya distance on 8×8×8 RGB color histograms) to find cuts. Cuts land exactly on frame boundaries — no "1–2 frames behind the actual cut" drift. No cloud processing, no API calls — everything runs locally on your Mac using Apple frameworks.

Detected cuts appear as markers on the timeline. You can then auto-generate stills and clips spread across scenes, or manually place them with keyboard shortcuts.

## The Process workflow

Once you're done marking, click **Process** to walk through three optional phases:

1. **Review & Select** — thumbnail grid (S / M / L sizes) of every marked item; untick anything you don't want exported.
2. **Create Grids** — collage composer with draggable splitter, per-cell pan / pinch / scroll-wheel zoom, drag-and-drop assign and swap, loop counts for clip cells. Export grids land in `<output>/grids/`.
3. **Export** — settings sheet with format/quality/crop options, scrollable form with pinned action bar, cancel-during-export.

The Process timeline at the top is bidirectional — jump between phases freely.

<p align="center">
  <img src=".github/screenshots/export.png" width="420" alt="FramePull export settings" />
</p>

## Key features

| | |
|---|---|
| **Auto-generate** | One click to place stills and clips across detected scenes |
| **Manual marking** | `S` = mark still, `I` / `O` = in / out — either order works (I→O or O→I both close a clip) |
| **Frame-precise cut detection** | Cuts land exactly on frame boundaries, at the source's actual fps |
| **Smart snap** | Manual markers snap within 3 frames of a cut. IN exact, OUT minus 1 frame so the cut frame isn't included in the clip |
| **Draggable timeline** | Drag markers and clip edges, snap to cuts, drag-to-rearrange in the grid composer |
| **Timeline zoom & scroll** | Up to 20×, with horizontal mouse-wheel pan and a real scroll thumb. Playhead-anchored zoom — content under your cursor stays put |
| **Grid composer** | 1×1 through 3×2, per-cell crop with pan/pinch/scroll/slider, loop counts, drag-and-drop assignment + swap, autosaved divider |
| **Image & video grids** | All-still grids export as JPEG (2160×3840 for 9:16); any-clip grids export as MP4 with shorter clips looping |
| **LUT preview** | Apply `.cube` LUTs in real-time — exported files include the color grade |
| **Face detection** | Optionally prefer frames with faces using Apple Vision |
| **Blur rejection** | Skip blurry frames automatically |
| **Mute audio** | Strip audio from exported clips with one toggle |
| **Multi-lane clips** | Overlapping clip ranges stack on separate lanes |
| **Aspect ratio crops** | Export 4:5 and 9:16 variants alongside originals, with per-clip reframe control |
| **Fullscreen-friendly** | Resizable window, content scales with available space |

## Built with

Zero external dependencies. FramePull is built entirely on Apple frameworks:

`AVFoundation` · `Vision` · `CoreImage` · `ImageIO` · `AppKit` · `SwiftUI` · `Combine`

<p align="center">
  <img src=".github/screenshots/drop.jpg" width="720" alt="FramePull drop zone" />
</p>

## Install

**TestFlight** — see [TestFlight invite](#) (coming soon)
**Mac App Store** — *in review*

## Feedback

FramePull is in active development. Bugs and feature requests welcome at [mail@carlooppermann.com](mailto:mail@carlooppermann.com).

## License

Copyright &copy; 2026 Carlo Oppermann. All rights reserved. See [LICENSE](LICENSE) for details.

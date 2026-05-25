# Grid Creation — Concept & Implementation

> **Status:** the macOS port has shipped. This doc is preserved as the original iOS
> design reference. For the user-facing guide to the macOS grid composer see
> [`docs/documentation.md § 7.2 Create Grids`](docs/documentation.md#72-create-grids).
> For the macOS architecture (sparse cells, `CellTransform`, frame-by-frame video
> compositor, etc.) see [`CLAUDE.md` / `AGENTS.md`](CLAUDE.md).

This document explains the design and implementation of the grid creation feature in FramePull Mobile, written so the same feature could be ported to the macOS version of FramePull.

---

## Why this exists

People who pull frames from video footage often want to **arrange a few of them together** as a single deliverable — a 2×2 still grid for Instagram feed, a 1×3 strip for stories, a looping video grid for reels. Doing this currently means roundtripping through Photoshop / Premiere / a separate app.

Grid creation lives at the end of the app's three-phase flow (Detection → Selection → **Creation**). After the user has marked items in the player and approved a subset in the Tinder-style review, they land in a grid composer where each kept item is a cell in their layout.

---

## What it does

- **Arrange** stills and clips into a layout: `1×2`, `2×1`, `1×3`, `3×1`, `2×2`, `2×3`
- **Output ratio**: `1:1`, `4:5`, `9:16`, `16:9` (the social formats)
- **Adaptive output type**:
  - All cells are stills → exports as a **JPEG**
  - Any cell is a clip → exports as an **MP4** with shorter clips looping to match the longest
- **Per-cell pan & zoom** so the user can frame each cell's crop without leaving the composer
- **Up to 3 grids per session** — same source items, different layouts/ratios, exported together
- **Auto fill** to distribute items by timestamp across empty slots

The export lands in the user's **FramePull** album in Photos.

---

## Architecture

### Data model

Five small types do the heavy lifting. All live in `Sources/App/GridBuilderView.swift`.

```swift
struct GridLayout: Identifiable, Equatable {
    var id: String { name }       // "2×2"
    let name: String
    let cols: Int
    let rows: Int
    var slots: Int { cols * rows }
}

struct OutputRatio: Identifiable, Equatable {
    var id: String { name }       // "9:16"
    let name: String
    let width: CGFloat
    let height: CGFloat
    var aspectRatio: CGFloat { width / height }

    func outputSize() -> CGSize {
        // Always 1080 on the shorter side
        let base: CGFloat = 1080
        return width >= height
            ? CGSize(width: base * width / height, height: base)
            : CGSize(width: base, height: base * height / width)
    }
}

enum GridCellSource: Equatable, Hashable {
    case still(Int)              // index into stills array
    case clip(Int)               // index into clips array
}

struct CellTransform: Equatable {
    var offsetX: CGFloat = 0     // normalized [-1, 1]: pan within cropped area
    var offsetY: CGFloat = 0
    var scale:   CGFloat = 1.0   // 1.0 = base fill, max 4.0
    static let identity = CellTransform()
}

struct GridConfig: Identifiable {
    let id = UUID()
    var layout: GridLayout
    var ratio: OutputRatio
    var selectedCells: [GridCellSource] = []
    var cellTransforms: [GridCellSource: CellTransform] = [:]
}
```

### Two design choices worth stealing

**1. `GridCellSource` references items by index, not by value.**

Cells store `.still(7)`, not the entire `MarkedStill`. This keeps the model lightweight and lets transforms persist across cell reordering — pan/zoom Grid 1's `.still(3)`, swap the slot order, and the same transform still applies to the same source.

**2. `CellTransform` uses normalized coords `[-1, 1]`, not pixels.**

Resolution-independent. The same `CellTransform { offsetX: 0.4, scale: 2.1 }` produces the same visual result whether previewing at 280pt or exporting at 1080pt. The math:

```swift
func drawRect(srcSize: CGSize, cellRect: CGRect) -> CGRect {
    let baseScale = max(cellRect.width / srcSize.width,
                        cellRect.height / srcSize.height)
    let baseW = srcSize.width  * baseScale          // image scaled to fill cell
    let baseH = srcSize.height * baseScale
    let s = max(1.0, min(4.0, scale))               // user zoom
    let scaledW = baseW * s
    let scaledH = baseH * s
    let maxPanX = max(0, (scaledW - cellRect.width)  / 2)   // pan headroom
    let maxPanY = max(0, (scaledH - cellRect.height) / 2)
    let cx = cellRect.midX + maxPanX * max(-1, min(1, offsetX))
    let cy = cellRect.midY + maxPanY * max(-1, min(1, offsetY))
    return CGRect(x: cx - scaledW/2, y: cy - scaledH/2,
                  width: scaledW, height: scaledH)
}
```

`drawRect()` is the **single source of truth** for crop math, called from both:
- The SwiftUI live preview (where it computes equivalent `.scaleEffect()` + `.offset()` values)
- The CG drawing path (in `composeImage` / `composeVideo`)

### Output: image vs. video

The export branches on whether any selected cell is a clip:

```swift
let isVideo = selectedCells.contains { if case .clip = $0 { return true }; false }
```

Image path is fast (one frame). Video path is the interesting one.

### Video compositor — the part that took two tries

**First attempt (broken, removed):** `AVMutableComposition` with one video track per cell + `AVMutableVideoCompositionLayerInstruction.setTransform` + `setCropRectangle`. Stills became 1fps "still video" tracks via a synthetic `AVAssetWriter`.

This approach has well-documented coordinate-system traps when stacking multiple tracks in a grid. Even with the preferred-transform handling correct on paper, the result was visually garbage — cells positioned wrong, content missing, sometimes upside-down.

**Second attempt (final, works):** **Manual frame-by-frame compositing.** Same drawing logic as the image path, just extended over time.

```
for frame in 0..<totalFrames:
    let outputTime = Double(frame) / fps
    for each cell:
        cellImage = (still ? cached UIImage
                           : extract from AVAssetImageGenerator
                             at (outputTime mod clip.duration) + clip.inPoint)
    composite = UIGraphicsImageRenderer.image:
        fill black
        for each cell:
            clip to cellRect
            draw cellImage in CellTransform.drawRect(...)
    pixelBuffer = pixelBuffer(from: composite)
    adaptor.append(pixelBuffer, withPresentationTime: ...)
finalize writer
```

Trade-offs vs. AVMutableVideoComposition:
- ✅ **Predictable.** Same code path as the image export. What you see in preview is what you get.
- ✅ **Loops naturally.** `outputTime mod clip.duration` does it for free.
- ✅ **Per-cell crops apply transparently** — they're just `CellTransform.drawRect()`.
- ❌ **Slower** — typically 5–15s for a 7s output on iPhone 17. Acceptable for the use case; Mac will be faster.

### The `pixelBuffer(from: UIImage)` gotcha

This bit me hard. The canonical Apple pattern for rendering a `UIImage` into a `CVPixelBuffer` for `AVAssetWriter`:

```swift
let ctx = CGContext(data: ..., bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue, ...)
ctx.translateBy(x: 0, y: size.height)   // flip Y to UIKit convention (origin top-left)
ctx.scaleBy(x: 1, y: -1)
UIGraphicsPushContext(ctx)
image.draw(in: CGRect(origin: .zero, size: size))   // ← UIImage.draw, NOT ctx.draw(cgImage)
UIGraphicsPopContext()
```

What I did wrong first time: `ctx.draw(image.cgImage!, in: rect)` with the same Y-flip. **That double-flips** because `CGContext.draw` for a `CGImage` already inverts (Quartz convention). Result: every video frame upside-down.

Use `image.draw` instead — it expects the UIKit-convention context the Y-flip provides.

### Auto fill

```
emptySlots   = layout.slots - selectedCells.count
pool         = (all stills + all clips) - already selected
sort pool by timestamp (stills: .timestamp, clips: .inPoint + .duration/2)
pickCount    = min(emptySlots, pool.count)
picked       = [pool[i * pool.count / pickCount] for i in 0..<pickCount]
selectedCells.append(contentsOf: picked)
```

Even distribution across the timeline gives a chronological "thin slice" feel rather than clustering.

### Multi-grid

`GridBuilderView` holds `@State var grids: [GridConfig]` (1–3) plus `@State var activeIndex: Int`. All UI reads/writes go through `grids[activeIndex].xxx`. Tab pills at the top switch the active grid; "+ Add" appends a new `GridConfig` that **inherits the current layout & ratio** but starts with no cells selected.

Export iterates fully-filled grids only (partial/empty grids are silently skipped). Status overlay shows `Grid 2 of 3 — Rendering 90 / 149`.

### Live preview ↔ export consistency

Both code paths use `CellTransform.drawRect(srcSize:cellRect:)` for the crop math. SwiftUI preview wraps this in `.scaleEffect()` + `.offset()`; export draws the rect directly into a `CGContext`. **Same input → same output**, which is what makes "what you see is what you get" actually true.

---

## macOS Integration Hints

### What ports unchanged

- All five data types (`GridLayout`, `OutputRatio`, `GridCellSource`, `CellTransform`, `GridConfig`)
- `CellTransform.drawRect()` — pure geometry
- `GridExporter.composeImage()` and `composeVideo()` — AVFoundation APIs are identical on macOS
- The auto-fill algorithm
- The frame-by-frame compositing approach

### What needs platform adaptation

| iOS | macOS replacement |
|-----|-----|
| `UIImage` | `NSImage` (or use a `PlatformImage` typealias) |
| `UIGraphicsImageRenderer` | `NSImage(size:flipped:drawingHandler:)` or direct `CGContext` |
| `UIGraphicsPushContext` + `image.draw` | Push an `NSGraphicsContext`, then `image.draw(in:)` |
| `UIColor.black.setFill()` | `NSColor.black.setFill()` |
| `UIImpactFeedbackGenerator` | drop it (no haptics on Mac), or use `NSHapticFeedbackManager` on trackpad-equipped devices |
| `PHPhotoLibrary` save | `NSSavePanel` → write to disk; or write to `~/Pictures/FramePull/` directly |
| `.fullScreenCover` | `.sheet` or a separate window |
| Bottom-sheet pickers (`LayoutPickerSheet`, `RatioPickerSheet`) | `Menu` / `Picker` / `NSPopover`-style dropdowns |

### `pixelBuffer(from:)` on macOS

The same pattern works, but:

```swift
let ctx = CGContext(data: ..., bitmapInfo: ...)
ctx.translateBy(x: 0, y: size.height)
ctx.scaleBy(x: 1, y: -1)

let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
```

`NSImage.draw` honors the current `NSGraphicsContext` similarly to how `UIImage.draw` honors the UIKit context.

### Gestures

SwiftUI's `DragGesture` and `MagnificationGesture` already work on macOS — they map to mouse drag and trackpad pinch. The current preview-cell gesture code should compile unchanged. Worth adding for Mac:

- **Scroll-wheel zoom** via `.onContinuousHover` + `.scrollGesture` for users without a trackpad
- **Right-click context menu** per cell: *Replace*, *Remove*, *Reset crop*
- **Keyboard shortcuts**: `⌘1/2/3` to switch grids, `⌫` to remove the last selected cell, `R` to reset the active cell's crop

### macOS-specific opportunities

1. **Drag-and-drop**: drag thumbnails from the picker straight into preview cells, or rearrange cells by dragging within the preview
2. **Higher-resolution outputs**: macOS hardware handles 4K+ comfortably. Bump `OutputRatio.outputSize()`'s `base` from 1080 to e.g. 2160 for "high quality" mode
3. **Real-time clip preview in cells**: instead of static thumbnails, run actual `AVPlayer` instances with synchronized playback heads
4. **Inspector panels**: each grid in its own panel rather than tabs — Mac users have screen real estate
5. **Export presets**: a `Settings`/`Preferences` pane for default ratio, default layout, default output folder, frame rate, codec choice (H.265 / ProRes)

### Suggested port order

If you want to do this incrementally, port in this dependency order:

1. The five data types (header-only — no behavior to port)
2. `CellTransform.drawRect` (pure function — verify with a quick unit test)
3. `GridExporter.composeImage` (single frame, easy to verify visually)
4. `pixelBuffer(from:)` adapted for `NSImage` + `NSGraphicsContext`
5. `GridExporter.composeVideo` (mostly works once `pixelBuffer` is right)
6. `GridSchematic`, `RatioIcon` (reusable SwiftUI views)
7. `LayoutPickerSheet`, `RatioPickerSheet` → adapt to macOS dropdowns
8. `GridBuilderView` body (largest piece, but mostly unchanged once helpers work)
9. Multi-grid tab bar (UI-only, ports cleanly)
10. Auto fill (pure logic, copies straight over)

### What I'd do differently knowing what I know now

- Wrap `UIImage`/`NSImage` in a `PlatformImage` typealias up front so `GridExporter` can be truly cross-platform without `#if`
- Make `GridExporter` an `actor` so it can run on a background thread without ceremony
- Cache extracted clip frames keyed by `(clip, frameIndex)` — a cheap LRU would let the same compositor produce smooth previews, not just exports
- For Mac, consider Metal-based compositing via `CIImage` + `CIContext` if performance becomes an issue with high-res outputs

---

## File map (current iOS implementation)

```
Sources/App/
├── GridBuilderView.swift         # Everything — view + GridExporter + helpers
│   ├── GridLayout, OutputRatio, GridCellSource, CellTransform, GridConfig, ExportProgress
│   ├── GridBuilderView                       # main composer view
│   ├── LayoutPickerSheet, RatioPickerSheet   # bottom sheets
│   ├── GridSchematic, RatioIcon              # icon helpers
│   └── GridExporter                          # composeImage, composeVideo, save*, helpers
└── PhaseIndicator.swift           # 1·2·3 stepper used across all phases
```

If splitting up for the Mac port, a sensible breakdown would be:

- `GridModels.swift` — the five types
- `GridExporter.swift` — image/video composition + Photos save
- `GridBuilderView.swift` — just the SwiftUI view
- `GridPickerSheets.swift` — picker UI
- `PhaseIndicator.swift` — already standalone

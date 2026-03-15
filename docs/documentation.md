# FramePull — Documentation

> Extract stills, GIFs, and video clips from any video. Fast, local, no subscriptions.

---

## Table of Contents

1. [Getting Started](#1-getting-started)
2. [The Interface](#2-the-interface)
3. [Cut Detection](#3-cut-detection)
4. [Placing Markers](#4-placing-markers)
   - [Manual Marking](#41-manual-marking)
   - [Auto-Generate](#42-auto-generate)
5. [The Timeline](#5-the-timeline)
6. [LUT Color Grading](#6-lut-color-grading)
7. [Preview & Reframe](#7-preview--reframe)
8. [Export Settings](#8-export-settings)
   - [Stills](#81-stills)
   - [GIFs](#82-gifs)
   - [Video Clips](#83-video-clips)
   - [Aspect Ratio Crops](#84-aspect-ratio-crops)
   - [Output Folder](#85-output-folder)
9. [Keyboard Shortcuts](#9-keyboard-shortcuts)
10. [Tips & Workflows](#10-tips--workflows)

---

## 1. Getting Started

1. Launch FramePull. The drop zone appears on first open.
2. **Drag a video file** onto the window, or click **Import…** to browse.
3. Supported formats: MP4, MOV (any codec your Mac can decode).
4. The video loads into the player and you're ready to mark.

---

## 2. The Interface

```
┌─────────────────────────────────────────────────┐
│  [S] [I] [O]   Auto-Generate   Reset All        │  ← Marker bar
├─────────────────────────────────────────────────┤
│                                                 │
│              Video Player                       │  ← Drag bottom edge to resize
│                                                 │
├─────────────────────────────────────────────────┤
│  0.5x  1x  2x   ■ Cuts  ● Auto  ● Manual  Snap │  ← Controls
│  ════════════════timeline══════════════════════ │
├─────────────────────────────────────────────────┤
│  STILLS (3)  ▾                                  │  ← Marker list (scrollable)
│  CLIPS (2)   ▾                                  │
├─────────────────────────────────────────────────┤
│  [ Export Settings… ]              [⌨]          │  ← Export bar
└─────────────────────────────────────────────────┘
```

**Video player overlay controls:**

| Control | Action |
|---|---|
| **Detect Cuts** button (top-left) | Open cut detection panel |
| **Filename × ** (top-right) | Remove the current video |
| **▶ / ⏸** (bottom-left) | Play / Pause |
| **🔊** (bottom-left) | Mute toggle; hover to reveal volume slider |
| **Frame / timecode** (bottom-right) | Current position display |
| **Drag divider** (below player) | Resize the player vertically |

---

## 3. Cut Detection

FramePull analyzes your video to find every scene change. This powers timeline markers, snap-to-cut, and smarter auto-generation.

**To detect cuts:**
1. Click the **Detect Cuts** button (top-left of the player).
2. Adjust **Sensitivity** — slide right for more cuts, left for fewer.
3. Click **Detect Cuts** (or **Re-detect**) inside the popover.
4. Progress shows inline. Cancel anytime.

**After detection**, cut markers (grey ticks) appear on the timeline and the button shows a count (*e.g. "12 Cuts"*).

> **Tip:** Run cut detection before using Auto-Generate or the "Prefer faces" placement mode — both work best when scenes are known.

---

## 4. Placing Markers

### 4.1 Manual Marking

Use keyboard shortcuts while the video plays (or is paused):

| Key | Action |
|---|---|
| `S` | Mark a still at the current frame |
| `I` | Set clip IN point |
| `O` | Set clip OUT point (creates the clip) |
| `Esc` | Cancel a pending IN point |
| `Delete` / `Backspace` | Remove marker at current playhead position |
| `Space` | Play / Pause |
| `↑` / `↓` | Jump to previous / next marker |
| `Shift ←` / `Shift →` | Step back / forward 10 frames |
| `Cmd Z` | Undo last action |

You can also click the **S**, **I**, **O** key-cap buttons in the marker bar.

**Clips** require an IN point (`I`) followed by an OUT point (`O`). A pending IN point is shown in the orange indicator bar below the player — press `Esc` to cancel it.

### 4.2 Auto-Generate

Click **Auto-Generate** to open the generation panel:

**Stills**
- Toggle **Stills** on/off (affects export, not the markers themselves).
- Set **Count** — total number of stills to place.
- Choose **Placement**:
  - *Spread evenly* — distributed at equal intervals across the full video.
  - *Per scene* — that many stills inside each detected scene.
  - *Prefer faces* — one still per scene, choosing the sharpest frame containing a face (requires cut detection).

**Clips**
- Toggle **Clips** on/off.
- Set **Count** — how many clips to generate.
- **Scenes per clip** — how many consecutive scenes each clip should span (1 = single scene, higher = longer clips crossing multiple scenes).
- **Allow overlapping** — lets generated clips share time ranges.

Click **Generate!** (or **Re-Generate**) to place markers. Manual markers are always preserved; only auto-generated markers are replaced.

> **Tip:** You can mix auto and manual markers freely. Auto-generated markers are orange; manual ones are blue.

---

## 5. The Timeline

The timeline below the controls shows the full video duration with all markers overlaid.

| Element | Color | Meaning |
|---|---|---|
| Thin grey ticks | Grey | Detected scene cuts |
| Triangle markers | Orange | Auto-generated stills |
| Triangle markers | Blue | Manually placed stills |
| Shaded range bar | Green | Auto-generated clip |
| Shaded range bar | Blue | Manually placed clip |
| Vertical line | Blue | Current playhead |

**Interactions:**
- **Click** anywhere to seek.
- **Drag a still marker** left/right to reposition it.
- **Drag a clip edge** (IN or OUT handle) to trim.
- **Right-click a marker or clip** to delete it.
- **Scroll wheel** to zoom in/out (up to 20×); the timeline follows the playhead.
- **Loop a clip** — right-click a clip bar and choose Loop, or click the loop icon in the clips list.

---

## 6. LUT Color Grading

Apply a `.cube` LUT file to preview and bake color grades into all exports.

**To apply a LUT:**
1. Click the **LUT** menu in the controls bar (shows current LUT name or "LUT").
2. Choose a **Built-in** LUT or select **Choose LUT Folder…** to load your own `.cube` files.
3. The player updates in real time.
4. All exported stills, GIFs, and video clips will include the color grade.

**To remove a LUT:** Open the LUT menu → select **None**.

**User LUT folders:** FramePull remembers your folder across sessions. To remove a folder, open the LUT menu → **Clear User Folder**.

> Built-in LUTs ship with the app. Place custom `.cube` files in any folder and point FramePull to it.

---

## 7. Preview & Reframe

Before exporting, click **Preview & Reframe** (in Export Settings, or from the summary row).

The preview shows thumbnails and animated GIF previews of every marked still and clip.

**Click any thumbnail** to open the lightbox. Navigate with `←` / `→` arrow keys or the chevron buttons.

### Reframe Slider (9:16 and 4:5 crops)

When **9:16** or **4:5** crop is enabled in export settings, a reframe slider appears below each item in the lightbox:

- **Drag the image** left/right to reposition the crop window.
- **Use the slider** for fine-tuned control.
- **Reset** returns the crop to center.
- The orange overlay shows exactly what will be cropped.
- Each still and clip stores its own offset — set them independently.

> **Priority:** When both 9:16 and 4:5 are enabled, the reframe slider controls the 9:16 crop; 4:5 stays centered.

---

## 8. Export Settings

Click **Export Settings…** at the bottom of the window. Choose what to export, then click **Export**.

### 8.1 Stills

| Setting | Options | Notes |
|---|---|---|
| **Format** | JPEG, PNG, TIFF | JPEG = smallest; TIFF = lossless maximum quality |
| **Size** | Full, Half | Scale factor applied to source resolution |

Stills are saved to `<output>/stills/`.

### 8.2 GIFs

| Setting | Options | Notes |
|---|---|---|
| **Resolution** | 480w, 720p, 1080p | Maximum output width |
| **Frame rate** | 10–30 fps | Higher = smoother but larger file |
| **Quality** | 30–100% | Color palette quality |

The estimated file size per clip updates as you adjust settings.

GIFs are saved to `<output>/gifs/`.

### 8.3 Video Clips

| Setting | Options | Notes |
|---|---|---|
| **Quality** | 480p, 720p, 1080p, 4K, Source | Source preserves original resolution |
| **Mute audio** | On / Off | Strips the audio track |

Video clips are saved to `<output>/videos/`.

### 8.4 Aspect Ratio Crops

| Toggle | Ratio | Use case |
|---|---|---|
| **Original** | Source ratio | Always exported (not togglable) |
| **4:5** | 4:5 vertical | Instagram portrait feed |
| **9:16** | 9:16 vertical | Stories, Reels, TikTok |

Cropped variants are saved in subdirectories: `.../4x5/` and `.../9x16/`.

Use [Preview & Reframe](#7-preview--reframe) to control the horizontal crop position per item before exporting.

### 8.5 Output Folder

Click **Choose…** to select an output folder. FramePull remembers your last choice.

Files are **always added, never overwritten** — sequential numbering (`_001`, `_002`, …) prevents conflicts.

---

## 9. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `S` | Mark still |
| `I` | Set IN point |
| `O` | Set OUT point |
| `Space` | Play / Pause |
| `Esc` | Cancel pending IN point |
| `Delete` / `Backspace` | Remove marker at playhead |
| `↑` | Jump to previous marker |
| `↓` | Jump to next marker |
| `Shift ←` | Step back 10 frames |
| `Shift →` | Step forward 10 frames |
| `Cmd Z` | Undo |
| `Cmd E` | Open Export Settings |
| `←` / `→` | Navigate lightbox (when open) |

Click the **⌨** button (bottom-right) to view shortcuts in-app.

---

## 10. Tips & Workflows

**Social content workflow**
1. Import your footage → Run cut detection.
2. Click Auto-Generate → set 1 still per scene, Placement = *Prefer faces*.
3. Enable 9:16 crop → open Preview & Reframe → adjust crop position per shot.
4. Export. You'll get an original + 9:16 variant for every face still.

**Quick clip extraction**
1. Play the video, press `I` at a good moment, `O` a few seconds later.
2. Repeat for each clip you want.
3. Cmd E → choose output folder → Export.

**LUT-baked exports**
1. Load a LUT from the controls bar.
2. The player shows the graded preview in real time.
3. All exports — stills, GIFs, and video — include the grade automatically.

**Undo**
FramePull tracks every marker change with a 50-step undo stack. Press `Cmd Z` or click the ↩ button to step back. Auto-generation is a single undo step (one undo restores all previous markers).

**Batch reframing**
Open Preview & Reframe, use arrow keys to cycle through all items, and drag-adjust the crop on each one before closing. Offsets are saved immediately and used at export time.

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// Composer for the Create Grids phase. Mirrors the iOS `GridBuilderView` but adapted to macOS:
/// split layout (source items on the left, preview on the right), Pickers instead of bottom sheets.
struct GridBuilderView: View {
    let videoURL: URL
    @ObservedObject var markingState: MarkingState

    @State private var activeIndex: Int = 0
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var thumbnailsLoaded = false
    @State private var clipGIFURLs: [UUID: URL] = [:]

    private var grids: [GridConfig] { markingState.grids }
    private var activeGrid: GridConfig? {
        guard activeIndex < grids.count else { return nil }
        return grids[activeIndex]
    }

    private var approvedSources: [GridCellSource] {
        markingState.approvedStills.map { GridCellSource.still($0.id) } +
        markingState.approvedClips.map  { GridCellSource.clip($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            toolbar
            Divider()

            if grids.isEmpty {
                emptyState
            } else if let grid = activeGrid {
                // HSplitView is the AppKit-backed splitter — drag handle, native feel,
                // and `autosaveName` persists the divider position across launches.
                HSplitView {
                    sourcePane(grid: grid)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 480)
                    previewPane(grid: grid)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(SplitViewAutosave(name: "GridBuilderSplit"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadThumbnailsIfNeeded()
            await generateClipGIFsIfNeeded()
        }
        .onChange(of: markingState.approvedStills.map(\.id)) { _ in
            Task { await loadThumbnailsIfNeeded(force: true) }
        }
        .onChange(of: markingState.approvedClips.map(\.id)) { _ in
            Task {
                await loadThumbnailsIfNeeded(force: true)
                await generateClipGIFsIfNeeded()
            }
        }
        .onDisappear { cleanupClipGIFs() }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(grids.enumerated()), id: \.element.id) { idx, grid in
                    let isActive = idx == activeIndex
                    Button {
                        activeIndex = idx
                    } label: {
                        HStack(spacing: 6) {
                            Text("Grid \(idx + 1)")
                                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            if grid.isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            } else {
                                Text("\(grid.filledCount)/\(grid.layout.slots)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(isActive ? Color.framePullBlue.opacity(0.15) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isActive ? Color.framePullBlue.opacity(0.6) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(gridSwitchShortcut(for: idx), modifiers: .command)
                }

                Button {
                    addGridAndFocus()
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.framePullBlue.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add another grid (⌘N)")
                .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func defaultLayout() -> GridLayout { activeGrid?.layout ?? .oneByThree }
    private func defaultRatio()  -> OutputRatio { activeGrid?.ratio  ?? .nineSixteen }

    /// Add a new grid via the toolbar / ⌘N — inherits the current grid's layout & ratio when present.
    private func addGridAndFocus() {
        let newID = markingState.addGrid(layout: defaultLayout(), ratio: defaultRatio())
        if let newIdx = markingState.grids.firstIndex(where: { $0.id == newID }) {
            activeIndex = newIdx
        }
    }

    /// ⌘1 / ⌘2 / ⌘3 select the first three grids. Beyond that, no shortcut.
    /// Falls back to a no-op equivalent (⌘0) — SwiftUI ignores duplicates harmlessly.
    private func gridSwitchShortcut(for index: Int) -> KeyEquivalent {
        switch index {
        case 0: return "1"
        case 1: return "2"
        case 2: return "3"
        default: return "0"  // unreachable shortcut keeps the API tidy
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        if let grid = activeGrid {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Layout").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: layoutBinding(for: grid)) {
                        ForEach(GridLayout.all) { layout in
                            Text(layout.name).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Cell arrangement (cols × rows)")
                }

                HStack(spacing: 6) {
                    Text("Ratio").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: ratioBinding(for: grid)) {
                        ForEach(OutputRatio.all) { ratio in
                            Text(ratio.name).tag(ratio)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Output canvas aspect ratio")
                }

                Button {
                    markingState.autoFill(gridID: grid.id)
                } label: {
                    Label("Auto Fill", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(grid.isComplete || approvedSources.isEmpty)
                .help("Distribute approved items across empty slots in chronological order")

                Spacer()

                if grid.containsClip {
                    Label("Video grid (will export as MP4)", systemImage: "film.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(role: .destructive) {
                    let removedIndex = activeIndex
                    markingState.removeGrid(id: grid.id)
                    activeIndex = max(0, min(removedIndex, markingState.grids.count - 1))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .help("Remove this grid")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func layoutBinding(for grid: GridConfig) -> Binding<GridLayout> {
        Binding(
            get: { grid.layout },
            set: { newLayout in
                guard var g = markingState.grids.first(where: { $0.id == grid.id }) else { return }
                // GridConfig's didSet handles resize / truncation automatically.
                g.layout = newLayout
                markingState.updateGrid(g)
            }
        )
    }

    private func ratioBinding(for grid: GridConfig) -> Binding<OutputRatio> {
        Binding(
            get: { grid.ratio },
            set: { newRatio in
                guard var g = markingState.grids.first(where: { $0.id == grid.id }) else { return }
                g.ratio = newRatio
                markingState.updateGrid(g)
            }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.framePullBlue.opacity(0.6))
            Text("No grids yet")
                .font(.title3.weight(.semibold))
            Text("Add a grid to compose stills and clips into social-format layouts.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                let id = markingState.addGrid()
                if let idx = markingState.grids.firstIndex(where: { $0.id == id }) {
                    activeIndex = idx
                }
            } label: {
                Label("Add a grid", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.borderedProminent)
            .tint(.framePullBlue)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Source pane

    private func sourcePane(grid: GridConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("APPROVED ITEMS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(approvedSources.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)], spacing: 8) {
                    ForEach(approvedSources, id: \.self) { source in
                        sourceCard(source: source, grid: grid)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }

            if approvedSources.isEmpty {
                Text("No approved items.\nGo back to Review & Select to keep some.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.3))
    }

    private func sourceCard(source: GridCellSource, grid: GridConfig) -> some View {
        let id = sourceID(source)
        let isInGrid = grid.contains(source)
        let isFull = grid.isComplete && !isInGrid
        // Explicit gestures (not Button) so .onDrag reliably initiates for clip cards too —
        // Button + .onDrag has known timing issues when the label contains NSViewRepresentable.
        return sourceCardContent(source: source, id: id, isInGrid: isInGrid, isFull: isFull)
            .contentShape(Rectangle())
            .onTapGesture { toggleSource(source, in: grid) }
            .onDrag {
                NSItemProvider(object: GridDropPayload.source(source).encoded as NSString)
            }
            .help(helpText(for: source, isInGrid: isInGrid, isFull: isFull))
    }

    @ViewBuilder
    private func sourceCardContent(source: GridCellSource, id: UUID, isInGrid: Bool, isFull: Bool) -> some View {
        // Layout anchor: a plain Rectangle with the cell's frame. Unlike Image+aspectRatio(.fill),
        // a Rectangle has NO intrinsic size preference, so it doesn't propagate a width up to
        // LazyVGrid based on the source image's aspect (which made some selected cells render
        // wider than others when their thumbnail aspects differed). The image is drawn as an
        // overlay on top, clipped to the rounded rect.
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(Color.black)
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
                .overlay {
                    if let gifURL = clipGIFURL(for: source) {
                        AnimatedGIFView(url: gifURL)
                    } else if let img = thumbnails[id] {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.18)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    // .strokeBorder strokes entirely inside the path so the selection ring stays
                    // within the cell — no bleed into neighbours.
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isInGrid ? Color.framePullAmber : .clear, lineWidth: 2)
                )
                .opacity(isFull ? 0.35 : 1)

            if isInGrid {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.framePullAmber)
                    .background(Circle().fill(Color.black.opacity(0.4)).padding(-1))
                    .padding(3)
            }

            if case .clip = source {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "film.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                        Spacer()
                    }
                }
                .padding(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
    }

    private func helpText(for source: GridCellSource, isInGrid: Bool, isFull: Bool) -> String {
        if isInGrid { return "Click to remove · drag onto a cell to assign" }
        if isFull { return "Grid is full — clear a cell first, or drag onto a cell to replace" }
        return "Click to add to next empty cell · drag onto a specific cell to assign"
    }

    private func toggleSource(_ source: GridCellSource, in grid: GridConfig) {
        var g = grid
        if let idx = g.index(of: source) {
            // Already in grid → remove (leaves an empty hole at that slot; other cells don't shift).
            g.setCell(nil, at: idx)
        } else if let emptyIdx = g.firstEmptyIndex {
            g.setCell(source, at: emptyIdx)
        }
        markingState.updateGrid(g)
    }

    // MARK: - Preview pane

    private func previewPane(grid: GridConfig) -> some View {
        GeometryReader { geo in
            // Inset is 24pt minimum (small windows), capped at 5% of the smaller dimension —
            // so on a fullscreen display the canvas keeps growing instead of being eaten by padding.
            let inset = max(24, min(geo.size.width, geo.size.height) * 0.05)
            let canvasArea = CGSize(
                width: max(1, geo.size.width - inset * 2),
                height: max(1, geo.size.height - inset * 2)
            )
            let canvasSize = sizeFitting(grid.ratio, in: canvasArea)
            let cellSize = CGSize(
                width: canvasSize.width / CGFloat(grid.layout.cols),
                height: canvasSize.height / CGFloat(grid.layout.rows)
            )

            VStack(spacing: 8) {
                Spacer(minLength: 0)
                ZStack {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: canvasSize.width, height: canvasSize.height)

                    VStack(spacing: 0) {
                        ForEach(0..<grid.layout.rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<grid.layout.cols, id: \.self) { col in
                                    cellView(grid: grid, index: row * grid.layout.cols + col, size: cellSize)
                                }
                            }
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                }
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)

                Text(previewMetaText(for: grid))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func cellView(grid: GridConfig, index: Int, size: CGSize) -> some View {
        let source: GridCellSource? = grid.cell(at: index)
        if let source, let img = thumbnails[sourceID(source)] {
            FilledGridCell(
                grid: grid,
                index: index,
                source: source,
                image: img,
                gifURL: clipGIFURL(for: source),
                size: size,
                markingState: markingState
            )
        } else {
            EmptyGridCell(
                gridID: grid.id,
                index: index,
                size: size,
                markingState: markingState
            )
        }
    }

    private func previewMetaText(for grid: GridConfig) -> String {
        let size = grid.ratio.outputSize()
        var parts = [
            grid.layout.name,
            grid.ratio.name,
            "output \(Int(size.width))×\(Int(size.height))"
        ]
        // Compute looped output duration only if any cell is a clip
        let clipById = Dictionary(uniqueKeysWithValues: markingState.markedClips.map { ($0.id, $0) })
        let weighted: [Double] = grid.filledCells.compactMap { source in
            guard case .clip(let id) = source, let clip = clipById[id] else { return nil }
            return clip.duration * Double(grid.loopCount(for: source))
        }
        if let dur = weighted.max(), dur > 0 {
            parts.append(String(format: "duration %.1fs", dur))
        }
        return parts.joined(separator: " · ")
    }

    private func sizeFitting(_ ratio: OutputRatio, in area: CGSize) -> CGSize {
        let target = ratio.aspectRatio
        let areaRatio = area.width / max(area.height, 1)
        if areaRatio > target {
            // Area is wider than target — limit by height
            let h = area.height
            return CGSize(width: h * target, height: h)
        } else {
            let w = area.width
            return CGSize(width: w, height: w / target)
        }
    }

    // MARK: - Thumbnail loading

    private func sourceID(_ source: GridCellSource) -> UUID {
        switch source {
        case .still(let id), .clip(let id): return id
        }
    }

    private func loadThumbnailsIfNeeded(force: Bool = false) async {
        if thumbnailsLoaded && !force { return }
        let stills = markingState.approvedStills
        let clips = markingState.approvedClips
        guard !stills.isEmpty || !clips.isEmpty else {
            await MainActor.run { thumbnailsLoaded = true }
            return
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 1080 short side: looks crisp in the preview canvas at any window size, while keeping
        // memory bounded (~5MB per RGBA frame at 1920×1080 worst case).
        generator.maximumSize = CGSize(width: 1080, height: 1080)

        let entries: [(UUID, CMTime)] =
            stills.map { ($0.id, CMTime(seconds: $0.timestamp, preferredTimescale: 600)) } +
            clips.map  { ($0.id, CMTime(seconds: $0.inPoint + $0.duration / 2, preferredTimescale: 600)) }

        var index = 0
        for await result in generator.images(for: entries.map(\.1)) {
            if case let .success(_, cg, _) = result {
                let id = entries[index].0
                // Use the cgImage's actual pixel size so transform math has correct aspect.
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                await MainActor.run { thumbnails[id] = img }
            }
            index += 1
        }
        await MainActor.run { thumbnailsLoaded = true }
    }

    // MARK: - Clip GIF generation (animated previews)

    /// Generate small looping GIFs for each approved clip so the composer can autoplay them
    /// in the source pane and inside grid cells. Each clip's encoding runs on a detached
    /// background task so the synchronous CGImageDestination calls don't hitch the main thread.
    private func generateClipGIFsIfNeeded() async {
        let clips = markingState.approvedClips
        guard !clips.isEmpty else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullGridGIFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let url = videoURL
        for clip in clips.prefix(20) where clipGIFURLs[clip.id] == nil {
            // Bail if the composer disappeared mid-generation — otherwise CGImageDestination
            // races with cleanupClipGIFs() removing the directory.
            if Task.isCancelled { break }
            let result = await Task.detached(priority: .utility) { [clip, tempDir, url] in
                await encodeLoopingGIF(
                    sourceVideoURL: url,
                    clipID: clip.id,
                    inPoint: clip.inPoint,
                    duration: clip.duration,
                    maxDuration: 5.0,
                    fps: 10,
                    maxSize: 720,
                    tempDir: tempDir
                )
            }.value
            if let result {
                clipGIFURLs[clip.id] = result
            }
        }
    }

    private func cleanupClipGIFs() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullGridGIFs", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Convenience: returns the GIF URL for a clip source, or nil for stills.
    private func clipGIFURL(for source: GridCellSource) -> URL? {
        if case .clip(let id) = source { return clipGIFURLs[id] }
        return nil
    }
}

// MARK: - Split view autosave

/// Persists the `HSplitView` divider position across app launches.
///
/// `HSplitView` doesn't expose `autosaveName` in SwiftUI — but it's just a wrapper around
/// `NSSplitView`. This zero-size NSViewRepresentable embeds itself behind the split view,
/// walks up the AppKit hierarchy to find the enclosing NSSplitView, and sets its
/// `autosaveName`. AppKit handles persistence to UserDefaults automatically after that.
private struct SplitViewAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let v else { return }
            // Walk up until we hit the enclosing NSSplitView.
            var node: NSView? = v
            while let n = node, !(n is NSSplitView) { node = n.superview }
            (node as? NSSplitView)?.autosaveName = NSSplitView.AutosaveName(name)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Off-main GIF encoding

/// Encode a small looping GIF for a clip preview. Pure function, runs anywhere — meant to be
/// called from a `Task.detached` so the synchronous CGImageDestination calls don't block the
/// main thread. Returns the resulting URL on success, nil on failure.
func encodeLoopingGIF(
    sourceVideoURL: URL,
    clipID: UUID,
    inPoint: Double,
    duration: Double,
    maxDuration: Double,
    fps: Int,
    maxSize: CGFloat,
    tempDir: URL
) async -> URL? {
    let gifURL = tempDir.appendingPathComponent("\(clipID).gif")
    let maxDur = min(duration, maxDuration)
    let frames = max(1, Int(maxDur * Double(fps)))
    let interval = maxDur / Double(frames)
    let delay = 1.0 / Double(fps)

    let asset = AVURLAsset(url: sourceVideoURL)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: maxSize, height: maxSize)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

    guard let dest = CGImageDestinationCreateWithURL(
        gifURL as CFURL, UTType.gif.identifier as CFString, frames, nil
    ) else { return nil }

    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
    ] as CFDictionary)

    let frameProp: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay],
        kCGImageDestinationLossyCompressionQuality as String: 0.5
    ]

    var ok = true
    let frameTimes = (0..<frames).map { f in
        CMTime(seconds: inPoint + Double(f) * interval, preferredTimescale: 600)
    }

    for await result in gen.images(for: frameTimes) {
        switch result {
        case .success(_, let cg, _):
            CGImageDestinationAddImage(dest, cg, frameProp as CFDictionary)
        case .failure:
            ok = false
        }
    }

    return (ok && CGImageDestinationFinalize(dest)) ? gifURL : nil
}

// MARK: - Drag-and-drop payload protocol

/// String-encoded payload for grid drag operations. Two flavours:
/// - `cell:N` — dragging an existing cell, by index, to swap with the drop target
/// - `src:still:UUID` / `src:clip:UUID` — dragging a source-pane item onto a target cell
enum GridDropPayload: Equatable {
    case cell(Int)
    case source(GridCellSource)

    var encoded: String {
        switch self {
        case .cell(let index):
            return "cell:\(index)"
        case .source(.still(let id)):
            return "src:still:\(id.uuidString)"
        case .source(.clip(let id)):
            return "src:clip:\(id.uuidString)"
        }
    }

    init?(string: String) {
        if let n = string.prefix("cell:") {
            guard let index = Int(n) else { return nil }
            self = .cell(index)
            return
        }
        if let body = string.prefix("src:") {
            let parts = body.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let uuid = UUID(uuidString: String(parts[1]))
            else { return nil }
            switch parts[0] {
            case "still": self = .source(.still(uuid))
            case "clip":  self = .source(.clip(uuid))
            default:      return nil
            }
            return
        }
        return nil
    }
}

private extension String {
    /// Returns the substring after `prefix` if `self` starts with it, else nil.
    func prefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Apply a drop payload to a grid. Centralised so `FilledGridCell` and `EmptyGridCell` share logic.
@MainActor
private func applyGridDrop(payload: GridDropPayload, targetIndex: Int, gridID: UUID, markingState: MarkingState) {
    guard let current = markingState.grids.first(where: { $0.id == gridID }) else { return }
    var g = current

    switch payload {
    case .cell(let from):
        guard from != targetIndex,
              g.selectedCells.indices.contains(from),
              g.selectedCells.indices.contains(targetIndex)
        else { return }
        // Cells are sparse: swapping handles all four combinations correctly —
        // filled↔filled (swap), filled↔empty (move), empty↔filled (move), empty↔empty (no-op).
        g.swapCells(from, targetIndex)

    case .source(let source):
        guard g.selectedCells.indices.contains(targetIndex) else { return }

        if let existing = g.index(of: source) {
            // Already in the grid — swap positions so other cells stay put.
            if existing == targetIndex { return }
            g.swapCells(existing, targetIndex)
        } else {
            // New source for this grid — place at target. If the target was filled, the
            // displaced item is dropped; setCell cleans up its transform / loop count.
            g.setCell(source, at: targetIndex)
        }
    }

    markingState.updateGrid(g)
}

// MARK: - Empty cell (drop target only)

/// Empty grid slot. Renders the placeholder and accepts drops from the source pane (assigns)
/// or from another cell (moves it here when there's room — empty slots fill contiguously).
private struct EmptyGridCell: View {
    let gridID: UUID
    let index: Int
    let size: CGSize
    @ObservedObject var markingState: MarkingState

    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.18))
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.secondary.opacity(0.6))
            if dropTargeted {
                Rectangle()
                    .stroke(Color.framePullAmber, lineWidth: 3)
                    .background(Color.framePullAmber.opacity(0.18))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
        .onDrop(of: [.text], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            let to = self.index
            let gridID = self.gridID
            let ms = self.markingState
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let str = obj as? NSString,
                      let payload = GridDropPayload(string: str as String) else { return }
                DispatchQueue.main.async {
                    applyGridDrop(payload: payload, targetIndex: to, gridID: gridID, markingState: ms)
                }
            }
            return true
        }
        .help("Drop a source item here to fill this slot")
    }
}

// MARK: - Filled cell wrapper (drag handle, drop target, context menu)

/// One filled cell in the grid composer. Hosts the live `GridCellPreview` and adds the
/// outer interactions: drag-handle for rearrange, drop target for incoming swaps, and
/// the right-click menu.
private struct FilledGridCell: View {
    let grid: GridConfig
    let index: Int
    let source: GridCellSource
    let image: NSImage
    /// Animated GIF URL for clip sources; nil for stills.
    let gifURL: URL?
    let size: CGSize
    @ObservedObject var markingState: MarkingState

    @State private var hovered = false
    @State private var hoveredHandle = false
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            GridCellPreview(
                cellSize: size,
                image: image,
                gifURL: gifURL,
                transform: grid.transform(for: source),
                onTransformChange: { newT in
                    var g = grid
                    if newT == .identity {
                        g.cellTransforms.removeValue(forKey: source)
                    } else {
                        g.cellTransforms[source] = newT
                    }
                    markingState.updateGrid(g)
                }
            )

            // Drop target visual
            if dropTargeted {
                Rectangle()
                    .stroke(Color.framePullAmber, lineWidth: 3)
                    .background(Color.framePullAmber.opacity(0.18))
            }

            // Top strip — Move pill (left) and Loop pill (right, clip cells only)
            VStack {
                HStack {
                    // Move pill — always rendered (low opacity off-hover) so drag-to-rearrange is discoverable.
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Move")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(hoveredHandle ? 0.85 : (hovered ? 0.65 : 0.4))))
                    .opacity(hovered || hoveredHandle ? 1.0 : 0.7)
                    .padding(6)
                    .onHover { hoveredHandle = $0 }
                    .onDrag {
                        NSItemProvider(object: GridDropPayload.cell(index).encoded as NSString)
                    }
                    .help("Drag onto another cell to swap")

                    Spacer()

                    if case .clip = source {
                        loopPill
                    }
                }
                Spacer()
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
        .onHover { hovered = $0 }
        .onDrop(of: [.text], isTargeted: $dropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .contextMenu {
            Button {
                var g = grid
                g.cellTransforms.removeValue(forKey: source)
                markingState.updateGrid(g)
            } label: { Label("Reset Crop", systemImage: "arrow.counterclockwise") }
            .disabled(grid.transform(for: source) == .identity)

            if case .clip = source {
                Menu {
                    ForEach(1...8, id: \.self) { n in
                        Button("\(n)×") { setLoopCount(n) }
                    }
                } label: { Label("Loop \(grid.loopCount(for: source))×", systemImage: "repeat") }

                Button {
                    setLoopCount(1)
                } label: { Label("Reset Loop", systemImage: "arrow.counterclockwise") }
                .disabled(grid.loopCount(for: source) == 1)
            }

            Divider()

            Button(role: .destructive) {
                var g = grid
                if let idx = g.index(of: source) {
                    // Empty the slot in place — other cells stay where they are.
                    g.setCell(nil, at: idx)
                    markingState.updateGrid(g)
                }
            } label: { Label("Remove from Grid", systemImage: "minus.circle") }
        }
        .help("Drag to pan · pinch / scroll to zoom · drag handle to rearrange")
    }

    /// Click-to-cycle loop pill (1×→8×→1×). Visible only on clip cells; subtler when at 1×.
    private var loopPill: some View {
        let count = grid.loopCount(for: source)
        let isDefault = count == 1
        return Button {
            let next = count >= 8 ? 1 : count + 1
            setLoopCount(next)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "repeat")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(count)×")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.black.opacity(hovered ? (isDefault ? 0.55 : 0.75) : (isDefault ? 0.35 : 0.6)))
            )
            .overlay(
                Capsule().stroke(Color.framePullBlue.opacity(isDefault ? 0 : 0.7), lineWidth: 1)
            )
            .opacity(isDefault && !hovered ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .padding(6)
        .help("Loop count: click to cycle 1× → 8× → 1×. Right-click for explicit values.")
    }

    private func setLoopCount(_ n: Int) {
        var g = grid
        let clamped = max(1, min(8, n))
        if clamped == 1 {
            g.cellLoopCounts.removeValue(forKey: source)
        } else {
            g.cellLoopCounts[source] = clamped
        }
        markingState.updateGrid(g)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let to = self.index
        let gridID = self.grid.id
        let ms = self.markingState
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? NSString,
                  let payload = GridDropPayload(string: str as String) else { return }
            DispatchQueue.main.async {
                applyGridDrop(payload: payload, targetIndex: to, gridID: gridID, markingState: ms)
            }
        }
        return true
    }
}

// MARK: - Per-cell pan & zoom

/// Mutable reference holder so the scrollWheel NSEvent monitor closure always reads the current
/// transform / commit closure, not a stale capture from when it was installed.
private final class CellInteractionBox {
    var transform: CellTransform = .identity
    var commit: ((CellTransform) -> Void)?
}

/// Renders a cell's source image positioned by `CellTransform` and lets the user pan with drag,
/// zoom with pinch (trackpad) or scroll wheel (mouse). Writes back via `onTransformChange` on commit.
private struct GridCellPreview: View {
    let cellSize: CGSize
    let image: NSImage
    /// When set, an autoplaying GIF replaces the static image inside the same drawRect frame.
    var gifURL: URL? = nil
    let transform: CellTransform
    let onTransformChange: (CellTransform) -> Void

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var liveMagnify: CGFloat = 1.0
    @State private var hovered = false
    @State private var box = CellInteractionBox()
    @State private var scrollMonitor: Any? = nil

    private var srcSize: CGSize {
        // NSImage.size is in points; for resolution-independent crop math we just need the aspect.
        let s = image.size
        return s.width > 0 && s.height > 0 ? s : CGSize(width: 16, height: 9)
    }

    /// Compute a transform for a given drag translation + magnification factor (both in gesture-local
    /// units). Centralised so `liveTransform` (rendering) and `.onEnded` (commit) use the same math.
    private func computeTransform(translation: CGSize, magnification: CGFloat) -> CellTransform {
        var t = transform
        t.scale = max(1.0, min(4.0, transform.scale * magnification))

        let baseScale = max(cellSize.width / srcSize.width, cellSize.height / srcSize.height)
        let scaledW = srcSize.width * baseScale * t.scale
        let scaledH = srcSize.height * baseScale * t.scale
        let maxPanX = max(0, (scaledW - cellSize.width) / 2)
        let maxPanY = max(0, (scaledH - cellSize.height) / 2)
        let dxNorm = maxPanX > 0 ? translation.width / maxPanX : 0
        let dyNorm = maxPanY > 0 ? translation.height / maxPanY : 0
        t.offsetX = max(-1, min(1, transform.offsetX + dxNorm))
        t.offsetY = max(-1, min(1, transform.offsetY + dyNorm))
        return t
    }

    /// Live transform = stored + in-flight @GestureState deltas. Used for rendering only.
    private var liveTransform: CellTransform {
        computeTransform(translation: dragTranslation, magnification: liveMagnify)
    }

    /// Binding for the zoom slider — writes back through `onTransformChange` immediately.
    private var scaleBinding: Binding<CGFloat> {
        Binding(
            get: { transform.scale },
            set: { newScale in
                var t = transform
                t.scale = max(1.0, min(4.0, newScale))
                onTransformChange(t)
            }
        )
    }

    var body: some View {
        let cellRect = CGRect(origin: .zero, size: cellSize)
        let drawRect = liveTransform.drawRect(srcSize: srcSize, cellRect: cellRect)
        let isModified = transform != .identity

        // Top strip reserved for the Move pill (drag-to-rearrange). Pan gesture must NOT cover
        // this area, otherwise it eats the drag events meant for `.onDrag` on the pill.
        let reservedTop: CGFloat = 30

        return ZStack {
            Color.black

            // Clip sources autoplay as a GIF; stills render as Image. Both honor the same
            // drawRect framing so the visible crop matches the export pixel-for-pixel.
            if let gifURL {
                AnimatedGIFView(url: gifURL, allowScaleUp: true)
                    .frame(width: drawRect.width, height: drawRect.height)
                    .position(x: drawRect.midX, y: drawRect.midY)
                    .allowsHitTesting(false)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drawRect.width, height: drawRect.height)
                    .position(x: drawRect.midX, y: drawRect.midY)
                    .allowsHitTesting(false)
            }

            // Pan-capture layer — covers the cell EXCEPT the top reserved strip, so the Move pill
            // (which lives in that strip via FilledGridCell) can win the drag race for `.onDrag`.
            VStack(spacing: 0) {
                Spacer().frame(height: reservedTop)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .updating($dragTranslation) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                // @GestureState resets before .onEnded reads it; use the value's translation directly.
                                onTransformChange(computeTransform(translation: value.translation, magnification: 1.0))
                            }
                    )
            }

            if hovered {
                VStack {
                    HStack {
                        Spacer()
                        if isModified {
                            Button {
                                onTransformChange(.identity)
                            } label: {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .help("Reset crop to centred fill")
                        }
                    }
                    Spacer()
                    zoomSlider
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .clipped()
        .onAppear {
            box.transform = transform
            box.commit = onTransformChange
        }
        .onChange(of: transform) { box.transform = $0 }
        .onHover { hovering in
            hovered = hovering
            box.transform = transform
            box.commit = onTransformChange
            if hovering {
                installScrollMonitor()
            } else {
                removeScrollMonitor()
            }
        }
        .onDisappear { removeScrollMonitor() }
        .simultaneousGesture(
            MagnificationGesture()
                .updating($liveMagnify) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    onTransformChange(computeTransform(translation: .zero, magnification: value))
                }
        )
    }

    /// Hover-revealed zoom slider — discoverable alternative to pinch / scroll-wheel.
    private var zoomSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            Slider(value: scaleBinding, in: 1.0...4.0)
                .controlSize(.mini)
                .tint(.framePullBlue)
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            Text(String(format: "%.1f×", transform.scale))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.6))
        )
        .help("Zoom this cell · pinch or scroll-wheel also works")
    }

    // MARK: - Scroll-wheel zoom (mouse users)

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let box = self.box
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only consume scroll events while the cell is hovered AND the cursor is inside the
            // event's window — `.onHover` already gates this, but a stray hover desync shouldn't
            // hijack scrolls in other panes.
            let dy = event.scrollingDeltaY
            guard dy != 0, let commit = box.commit else { return event }
            let factor = 1.0 + (dy * 0.0025)
            var t = box.transform
            t.scale = max(1.0, min(4.0, t.scale * factor))
            commit(t)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }
}

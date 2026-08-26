//
//  GridComposerView.swift
//  FramePull (iOS)
//
//  Touch grid composer, built on the SHARED GridModels / GridExporter rather than the
//  standalone grid code the old FramePull Mobile prototype carried. That prototype had its
//  own GridConfig and its own exporter; reviving it would have meant two grid models and
//  two crop maths drifting apart. The interaction design is borrowed, the plumbing is not.
//
//  Cell crop uses CellTransform.drawRect — the exact function GridExporter renders with, so
//  what you arrange here is what comes out.
//
//  Assignment is by tap, not drag: tap a source to drop it in the next empty slot, tap it
//  again to pull it back out. Dragging thumbnails around a phone screen is fiddly, and the
//  Mac target already covers that style of work.
//

import SwiftUI
import AVFoundation

struct GridComposerView: View {
    @ObservedObject var markingState: MarkingState
    let videoURL: URL
    var onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbnails = GridThumbnailStore()

    @State private var activeGridID: UUID?
    @State private var selectedSlot: Int?

    // Gesture sessions. Each records the transform as it was when the gesture began, so
    // deltas are applied to a fixed base instead of compounding on every change event.
    @State private var panStart: [GridCellSource: CellTransform] = [:]
    @State private var zoomStart: [GridCellSource: CGFloat] = [:]

    // Hold-and-drag swap.
    //
    // @GestureState, not @State: SwiftUI resets it automatically when the gesture ends OR
    // is cancelled. With plain @State a long press that never became a drag left the cell
    // stuck at 0.25 opacity with a stray drop-target border, and — because panning is
    // guarded on "no swap in progress" — reframing stopped working entirely.
    struct SwapSession: Equatable {
        var slot: Int
        var point: CGPoint?
    }

    @GestureState private var swapSession: SwapSession?
    @State private var lastCanvasSize: CGSize?

    private var draggingSlot: Int? { swapSession?.slot }

    private func dropTarget(in grid: GridConfig) -> Int? {
        guard let point = swapSession?.point, let size = lastCanvasSize else { return nil }
        return slot(at: point, grid: grid, canvasSize: size)
    }

    private var grids: [GridConfig] { markingState.grids }

    private var activeGrid: GridConfig? {
        guard let activeGridID else { return grids.first }
        return grids.first { $0.id == activeGridID } ?? grids.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let grid = activeGrid {
                    gridTabs
                    settingsRow(grid: grid)
                    canvas(grid: grid)
                    selectedCellBar(grid: grid)
                    actionRow(grid: grid)
                    sourceStrip(grid: grid)
                } else {
                    emptyState
                }
            }
            .background(Color.black.opacity(0.94))
            .navigationTitle("Grids")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(markingState.completedGrids.isEmpty)
                }
            }
        }
        .onAppear {
            thumbnails.prepare(url: videoURL)
            if markingState.grids.isEmpty {
                activeGridID = markingState.addGrid()
            } else if activeGridID == nil {
                activeGridID = markingState.grids.first?.id
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundStyle(Color.framePullBlue)
            Text("No grids yet")
                .font(.headline)
                .foregroundStyle(.white)
            Button("Add a grid") { activeGridID = markingState.addGrid() }
                .buttonStyle(.borderedProminent)
                .tint(Color.framePullBlue)
            Spacer()
        }
    }

    // MARK: - Grid tabs

    private var gridTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(grids.enumerated()), id: \.element.id) { index, grid in
                    let isActive = grid.id == activeGrid?.id
                    Button {
                        activeGridID = grid.id
                        selectedSlot = nil
                    } label: {
                        HStack(spacing: 5) {
                            Text("Grid \(index + 1)")
                                .font(.footnote.weight(.semibold))
                            Text("\(grid.filledCount)/\(grid.layout.slots)")
                                .font(.caption2)
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            Capsule().fill(isActive ? Color.framePullBlue.opacity(0.85) : .white.opacity(0.12))
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete grid", role: .destructive) {
                            markingState.removeGrid(id: grid.id)
                            activeGridID = markingState.grids.first?.id
                        }
                    }
                }

                Button {
                    activeGridID = markingState.addGrid()
                    selectedSlot = nil
                } label: {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Layout + ratio

    private func settingsRow(grid: GridConfig) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(GridLayout.all) { layout in
                    Button(layout.name) { setLayout(layout, on: grid) }
                }
            } label: {
                settingChip(icon: "square.grid.3x3", text: grid.layout.name)
            }

            Menu {
                ForEach(OutputRatio.all) { ratio in
                    Button(ratio.name) { setRatio(ratio, on: grid) }
                }
            } label: {
                settingChip(icon: "aspectratio", text: grid.ratio.name)
            }

            Spacer()

            let size = grid.ratio.outputSize()
            Text("\(Int(size.width))×\(Int(size.height))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func settingChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.footnote.weight(.semibold))
            Image(systemName: "chevron.down").font(.system(size: 9))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(.white.opacity(0.12)))
        .foregroundStyle(.white)
    }

    // MARK: - Canvas

    private func canvas(grid: GridConfig) -> some View {
        GeometryReader { geo in
            let canvasSize = fittedSize(ratio: grid.ratio, in: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)

                ForEach(0..<grid.layout.slots, id: \.self) { slot in
                    let rect = grid.cellRect(index: slot, in: canvasSize)
                    cell(grid: grid, slot: slot, rect: rect)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        // The lifted cell is drawn again on top, so hide the original.
                        .opacity(draggingSlot == slot ? 0.25 : 1)
                        .overlay {
                            if dropTarget(in: grid) == slot && draggingSlot != slot {
                                Rectangle().strokeBorder(Color.framePullAmber, lineWidth: 3)
                            }
                        }
                }

                // Lifted cell follows the finger.
                if let session = swapSession, let point = session.point {
                    let rect = grid.cellRect(index: session.slot, in: canvasSize)
                    cell(grid: grid, slot: session.slot, rect: rect)
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(1.06)
                        .shadow(color: .black.opacity(0.5), radius: 12)
                        .position(point)
                        .allowsHitTesting(false)
                        .zIndex(10)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .coordinateSpace(name: canvasSpace)
            .onAppear { lastCanvasSize = canvasSize }
            .onChange(of: canvasSize) { lastCanvasSize = $0 }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
    }

    private let canvasSpace = "gridCanvas"

    /// Slot whose cell rect contains `point`, for drop targeting.
    private func slot(at point: CGPoint, grid: GridConfig, canvasSize: CGSize) -> Int? {
        (0..<grid.layout.slots).first {
            grid.cellRect(index: $0, in: canvasSize).contains(point)
        }
    }

    private func fittedSize(ratio: OutputRatio, in available: CGSize) -> CGSize {
        let aspect = ratio.aspectRatio
        let byWidth = CGSize(width: available.width, height: available.width / aspect)
        return byWidth.height <= available.height
            ? byWidth
            : CGSize(width: available.height * aspect, height: available.height)
    }

    @ViewBuilder
    private func cell(grid: GridConfig, slot: Int, rect: CGRect) -> some View {
        let source = grid.selectedCells[slot]
        let isSelected = selectedSlot == slot

        ZStack {
            if let source {
                filledCell(grid: grid, source: source, rect: rect)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.35))
                    )
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(isSelected ? Color.framePullAmber : .white.opacity(0.15),
                              lineWidth: isSelected ? 2 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedSlot = (selectedSlot == slot) ? nil : slot }
        // Hold to lift a cell out for swapping; move straight away to reframe instead.
        .gesture(source == nil ? nil : swapGesture(grid: grid, slot: slot))
        .simultaneousGesture(source == nil ? nil : panGesture(grid: grid, source: source!, rect: rect))
        .simultaneousGesture(source == nil ? nil : zoomGesture(grid: grid, source: source!))
    }

    @ViewBuilder
    private func filledCell(grid: GridConfig, source: GridCellSource, rect: CGRect) -> some View {
        let transform = grid.transform(for: source)
        if let image = thumbnail(for: source) {
            let src = image.size
            let draw = transform.drawRect(srcSize: src, cellRect: CGRect(origin: .zero, size: rect.size))
            Image(uiImage: image)
                .resizable()
                .frame(width: draw.width, height: draw.height)
                .offset(x: draw.minX, y: draw.minY)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .clipped()
                .overlay(alignment: .topTrailing) { badges(grid: grid, source: source) }
        } else {
            Rectangle().fill(Color.white.opacity(0.08))
                .overlay(ProgressView().tint(.white))
                .task { loadThumbnail(for: source) }
        }
    }

    @ViewBuilder
    private func badges(grid: GridConfig, source: GridCellSource) -> some View {
        if case .clip = source {
            let loops = grid.loopCount(for: source)
            Text(loops > 1 ? "▶︎ ×\(loops)" : "▶︎")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.6)))
                .foregroundStyle(.white)
                .padding(4)
        }
    }

    // MARK: - Cell gestures

    /// Pan that tracks the finger exactly.
    ///
    /// `value.translation` is the total movement since the gesture began, not an
    /// increment — adding it every change event compounded the offset and made dragging
    /// feel disconnected. The transform is now captured once at gesture start and the
    /// translation applied to that base.
    ///
    /// Pixels convert to the normalised offset via the same slack drawRect uses:
    /// offset ±1 corresponds to (scaledSize − cellSize) / 2 pixels. Divide by that and the
    /// image moves precisely as far as the finger does.
    private func panGesture(grid: GridConfig, source: GridCellSource, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard draggingSlot == nil else { return }   // a swap is in progress

                let base = panStart[source] ?? grid.transform(for: source)
                if panStart[source] == nil { panStart[source] = base }

                guard let srcSize = thumbnail(for: source)?.size, srcSize.width > 0 else { return }
                let slack = panSlack(scale: base.scale, srcSize: srcSize, cellSize: rect.size)

                updateTransform(grid: grid, source: source) { t in
                    // No slack on an axis means the image exactly fills it; nothing to pan.
                    if slack.width > 0 {
                        t.offsetX = clampUnit(base.offsetX + value.translation.width / slack.width)
                    }
                    if slack.height > 0 {
                        t.offsetY = clampUnit(base.offsetY + value.translation.height / slack.height)
                    }
                }
            }
            .onEnded { _ in panStart[source] = nil }
    }

    /// Pannable slack in points, mirroring drawRect's maxPanX / maxPanY.
    private func panSlack(scale: CGFloat, srcSize: CGSize, cellSize: CGSize) -> CGSize {
        let baseScale = max(cellSize.width / srcSize.width, cellSize.height / srcSize.height)
        let s = max(1, min(4, scale))
        return CGSize(
            width:  max(0, (srcSize.width  * baseScale * s - cellSize.width)  / 2),
            height: max(0, (srcSize.height * baseScale * s - cellSize.height) / 2)
        )
    }

    private func zoomGesture(grid: GridConfig, source: GridCellSource) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard draggingSlot == nil else { return }
                let base = zoomStart[source] ?? grid.transform(for: source).scale
                if zoomStart[source] == nil { zoomStart[source] = base }
                updateTransform(grid: grid, source: source) { t in
                    t.scale = min(4, max(1, base * value))
                }
            }
            .onEnded { _ in zoomStart[source] = nil }
    }

    /// Hold, then drag onto another cell to swap the two.
    private func swapGesture(grid: GridConfig, slot: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(coordinateSpace: .named(canvasSpace)))
            .updating($swapSession) { value, state, _ in
                switch value {
                case .first(true):
                    state = SwapSession(slot: slot, point: nil)
                case .second(true, let drag):
                    state = SwapSession(slot: slot, point: drag?.location)
                default:
                    state = nil
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      let size = lastCanvasSize,
                      let to = self.slot(at: drag.location, grid: grid, canvasSize: size),
                      to != slot else { return }

                var updated = grid
                updated.swapCells(slot, to)
                markingState.updateGrid(updated)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
    }

    private func clampUnit(_ v: CGFloat) -> CGFloat { min(1, max(-1, v)) }

    // MARK: - Actions

    /// Actions for the tapped cell. These used to sit in a contextMenu, which is a long
    /// press — the same gesture that now picks a cell up for swapping.
    @ViewBuilder
    private func selectedCellBar(grid: GridConfig) -> some View {
        if let slot = selectedSlot, let source = grid.selectedCells[slot] {
            VStack(spacing: 6) {
                // Zoom slider, because pinching a small cell is imprecise and — more to the
                // point — a 16:9 frame in one of these cells overfills it by only a few
                // points at 1x. There is almost nothing to pan until you zoom in, which is
                // why dragging felt dead. The Mac target exposes a slider for the same reason.
                HStack(spacing: 8) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))

                    Slider(
                        value: Binding(
                            get: { Double(grid.transform(for: source).scale) },
                            set: { newValue in
                                updateTransform(grid: grid, source: source) {
                                    $0.scale = CGFloat(newValue)
                                }
                            }
                        ),
                        in: 1...4
                    )
                    .tint(Color.framePullBlue)

                    Text(String(format: "%.1f×", grid.transform(for: source).scale))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 34, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text("Cell \(slot + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    cellActionButton("Reset crop", icon: "arrow.counterclockwise") {
                        updateTransform(grid: grid, source: source) { $0 = .identity }
                    }

                    if case .clip = source {
                        cellActionButton("Loop ×\(grid.loopCount(for: source))", icon: "repeat") {
                            cycleLoop(grid: grid, source: source)
                        }
                    }

                    cellActionButton("Remove", icon: "trash", destructive: true) {
                        setCell(nil, at: slot, on: grid)
                        selectedSlot = nil
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func cellActionButton(_ title: String, icon: String, destructive: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(0.12)))
            .foregroundStyle(destructive ? .red : .white)
        }
        .buttonStyle(.plain)
    }

    private func actionRow(grid: GridConfig) -> some View {
        HStack(spacing: 8) {
            Button {
                markingState.autoFill(gridID: grid.id)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Label(grid.isComplete ? "Re-roll" : "Auto Fill", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.framePullAmber.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(Color.framePullAmber)
            }
            .buttonStyle(.plain)
            .disabled(markingState.approvedStills.isEmpty && markingState.approvedClips.isEmpty)

            Button {
                var updated = grid
                updated.clearCells()
                markingState.updateGrid(updated)
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .disabled(grid.filledCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Source strip

    private func sourceStrip(grid: GridConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedSlot == nil
                 ? "Tap a cell to zoom and reframe it · hold a cell to swap · tap a frame below to place it"
                 : "Tap a frame to place it in the selected cell")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(markingState.approvedStills) { still in
                        sourceThumb(grid: grid, source: .still(still.id), time: still.timestamp, isClip: false)
                    }
                    ForEach(markingState.approvedClips) { clip in
                        sourceThumb(grid: grid, source: .clip(clip.id),
                                    time: clip.inPoint + clip.duration / 2, isClip: true)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 74)
        }
        .padding(.bottom, 8)
    }

    private func sourceThumb(grid: GridConfig, source: GridCellSource, time: Double, isClip: Bool) -> some View {
        let placed = grid.contains(source)
        return Button {
            place(source, in: grid)
        } label: {
            ZStack {
                if let image = thumbnail(for: source) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.08))
                        .task { loadThumbnail(for: source) }
                }
            }
            .frame(width: 96, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(placed ? Color.framePullBlue : .white.opacity(0.15),
                                  lineWidth: placed ? 2 : 0.5)
            )
            .overlay(alignment: .bottomLeading) {
                if isClip {
                    Image(systemName: "film.fill")
                        .font(.system(size: 8))
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if placed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.framePullBlue)
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations

    private func place(_ source: GridCellSource, in grid: GridConfig) {
        var updated = grid
        if let existing = updated.index(of: source) {
            // Tapping a placed frame takes it back out, so one tap undoes the last.
            _ = updated.setCell(nil, at: existing)
        } else if let slot = selectedSlot {
            _ = updated.setCell(source, at: slot)
            selectedSlot = nil
        } else if let empty = updated.firstEmptyIndex {
            _ = updated.setCell(source, at: empty)
        } else {
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        markingState.updateGrid(updated)
    }

    private func setCell(_ source: GridCellSource?, at slot: Int, on grid: GridConfig) {
        var updated = grid
        _ = updated.setCell(source, at: slot)
        markingState.updateGrid(updated)
    }

    private func setLayout(_ layout: GridLayout, on grid: GridConfig) {
        var updated = grid
        updated.layout = layout
        markingState.updateGrid(updated)
        selectedSlot = nil
    }

    private func setRatio(_ ratio: OutputRatio, on grid: GridConfig) {
        var updated = grid
        updated.ratio = ratio
        markingState.updateGrid(updated)
    }

    private func updateTransform(grid: GridConfig, source: GridCellSource, _ change: (inout CellTransform) -> Void) {
        var updated = grid
        var transform = updated.transform(for: source)
        change(&transform)
        updated.cellTransforms[source] = transform
        markingState.updateGrid(updated)
    }

    private func nextLoop(grid: GridConfig, source: GridCellSource) -> Int {
        let current = grid.loopCount(for: source)
        return current >= 8 ? 1 : current * 2
    }

    private func cycleLoop(grid: GridConfig, source: GridCellSource) {
        var updated = grid
        updated.cellLoopCounts[source] = nextLoop(grid: grid, source: source)
        markingState.updateGrid(updated)
    }

    // MARK: - Thumbnails

    private func thumbnail(for source: GridCellSource) -> UIImage? {
        thumbnails.image(for: id(of: source))
    }

    private func loadThumbnail(for source: GridCellSource) {
        guard let time = time(of: source) else { return }
        thumbnails.load(id: id(of: source), at: time)
    }

    private func id(of source: GridCellSource) -> UUID {
        switch source {
        case .still(let id): return id
        case .clip(let id):  return id
        }
    }

    private func time(of source: GridCellSource) -> Double? {
        switch source {
        case .still(let id):
            return markingState.markedStills.first { $0.id == id }?.timestamp
        case .clip(let id):
            guard let clip = markingState.markedClips.first(where: { $0.id == id }) else { return nil }
            return clip.inPoint + clip.duration / 2
        }
    }
}

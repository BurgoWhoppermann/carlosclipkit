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
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
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
        .gesture(source == nil ? nil : panGesture(grid: grid, source: source!, rect: rect))
        .gesture(source == nil ? nil : zoomGesture(grid: grid, source: source!))
        .contextMenu {
            if let source {
                Button("Reset crop") { updateTransform(grid: grid, source: source) { $0 = .identity } }
                if case .clip = source {
                    Button("Loop ×\(nextLoop(grid: grid, source: source))") { cycleLoop(grid: grid, source: source) }
                }
                Button("Remove from grid", role: .destructive) { setCell(nil, at: slot, on: grid) }
            }
        }
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

    private func panGesture(grid: GridConfig, source: GridCellSource, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                updateTransform(grid: grid, source: source) { t in
                    // Translation is normalised against the cell, so the image tracks the
                    // finger at any zoom level.
                    t.offsetX = clampUnit(t.offsetX + (value.translation.width / max(rect.width, 1)) * 0.6)
                    t.offsetY = clampUnit(t.offsetY + (value.translation.height / max(rect.height, 1)) * 0.6)
                }
            }
    }

    private func zoomGesture(grid: GridConfig, source: GridCellSource) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                updateTransform(grid: grid, source: source) { t in
                    t.scale = min(4, max(1, t.scale * value / max(0.01, lastMagnitude)))
                }
                lastMagnitude = value
            }
            .onEnded { _ in lastMagnitude = 1 }
    }

    @State private var lastMagnitude: CGFloat = 1

    private func clampUnit(_ v: CGFloat) -> CGFloat { min(1, max(-1, v)) }

    // MARK: - Actions

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
                 ? "Tap a frame to place it in the next empty cell"
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

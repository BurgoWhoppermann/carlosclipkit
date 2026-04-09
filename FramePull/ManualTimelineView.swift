import SwiftUI

// MARK: - Manual Timeline View
struct ManualTimelineView: View {
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void
    let sceneCuts: [Double]
    let markedStills: [MarkedStill]
    let markedClips: [MarkedClip]
    let pendingInPoint: Double?
    let onStillPositionChanged: (UUID, Double) -> Void
    let onStillRemoved: (UUID) -> Void
    let onClipRemoved: (UUID) -> Void
    let onClipRangeChanged: (UUID, Double?, Double?) -> Void
    let onLoopClip: (UUID) -> Void
    var loopingClipId: UUID? = nil
    var selectedStillId: UUID? = nil
    var activeMarker: ActiveMarker? = nil
    var snapEnabled: Bool = true

    // Drag state (separate offsets prevent clip operations from leaking into still drags)
    @State private var draggingStillId: UUID? = nil
    @State private var draggingClipId: UUID? = nil
    @State private var draggingClipEdge: ClipEdge? = nil
    @State private var stillDragOffset: CGFloat = 0
    @State private var clipDragOffset: CGFloat = 0

    // Selection state
    @State private var isDragging: Bool = false
    private let snapThresholdPx: CGFloat = 12

    // Hover state
    @State private var hoveredStillId: UUID? = nil
    @State private var hoveredClipEdge: (UUID, ClipEdge)? = nil
    @State private var hoveredClipBarId: UUID? = nil

    // Zoom state
    @State private var zoomLevel: Double = 1.0

    // Scroll offset frozen at drag-start so the view doesn't shift under the user's cursor
    @State private var dragStartScrollOffset: CGFloat = 0

    enum ClipEdge {
        case inPoint
        case outPoint
    }

    // Colors — manual markers are blue, auto-generated are orange/green
    private let autoStillColor = Color.orange
    private let manualMarkerColor = Color.framePullBlue
    private let autoClipColor = Color.green
    private let cutColor = Color.secondary.opacity(0.5)
    private let playheadColor = Color.framePullBlue
    private let pendingColor = Color.orange

    /// Color for a still marker based on its origin (manual vs auto)
    private func stillColor(for still: MarkedStill) -> Color {
        still.isManual ? manualMarkerColor : autoStillColor
    }

    /// Color for a clip marker based on its origin (manual vs auto)
    private func clipColor(for clip: MarkedClip) -> Color {
        clip.isManual ? manualMarkerColor : autoClipColor
    }

    /// Greedy interval scheduling: assigns overlapping clips to separate lanes (max 3)
    /// so they stack vertically instead of overlapping on the timeline.
    private var clipLaneAssignments: [UUID: Int] {
        let sorted = markedClips.sorted { $0.inPoint < $1.inPoint }
        var lanes: [[MarkedClip]] = [[]]
        var result: [UUID: Int] = [:]
        for clip in sorted {
            var assigned = false
            for (laneIndex, lane) in lanes.enumerated() {
                if let last = lane.last, last.outPoint > clip.inPoint {
                    continue // This lane has a conflict, try next
                }
                lanes[laneIndex].append(clip)
                result[clip.id] = laneIndex
                assigned = true
                break
            }
            if !assigned {
                let newLane = min(lanes.count, 2) // Cap at 3 lanes (indices 0-2)
                if newLane == lanes.count { lanes.append([]) }
                lanes[newLane].append(clip)
                result[clip.id] = newLane
            }
        }
        return result
    }

    private var maxLane: Int {
        clipLaneAssignments.values.max() ?? 0
    }

    private var timelineHeight: CGFloat {
        56 + CGFloat(maxLane) * 22
    }

    private var totalHeight: CGFloat {
        timelineHeight + 20
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let width = viewportWidth * CGFloat(zoomLevel)
            let scrollOffset = computedScrollOffset(contentWidth: width, viewportWidth: viewportWidth)
            VStack(spacing: 2) {

            ZStack(alignment: .topLeading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: timelineHeight - 4)
                    .padding(.top, 2)

                // Scene cut markers (vertical lines)
                ForEach(sceneCuts, id: \.self) { cut in
                    let x = xPosition(for: cut, width: width)
                    Rectangle()
                        .fill(cutColor)
                        .frame(width: 1, height: timelineHeight - 4)
                        .position(x: x, y: timelineHeight / 2)
                }

                // Marked clips (blue=manual, green=auto, ranges with draggable edges)
                ForEach(markedClips) { clip in
                    let inX = xPosition(for: clip.inPoint, width: width)
                    let outX = xPosition(for: clip.outPoint, width: width)
                    let isDragging = draggingClipId == clip.id
                    let lane = clipLaneAssignments[clip.id] ?? 0
                    let clipY: CGFloat = 40 + CGFloat(lane) * 22
                    let barColor = clipColor(for: clip)

                    // Compute display positions that follow the drag handle
                    let displayInX = isDragging && draggingClipEdge == .inPoint ? inX + clipDragOffset : inX
                    let displayOutX = isDragging && draggingClipEdge == .outPoint ? outX + clipDragOffset : outX
                    let clipWidth = max(4, displayOutX - displayInX)

                    // Clip range background — follows drag (bottom lane)
                    let isLooping = loopingClipId == clip.id
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor.opacity(isLooping ? 0.7 : (isDragging ? 0.6 : 0.4)))
                        if clipWidth > 30 {
                            Button(action: { onLoopClip(clip.id) }) {
                                Image(systemName: isLooping ? "stop.fill" : "repeat.circle")
                                    .font(.system(size: isLooping ? 12 : 14))
                                    .foregroundColor(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: clipWidth, height: 20)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        hoveredClipBarId = hovering ? clip.id : nil
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { onClipRemoved(clip.id) }
                    )
                    .contextMenu {
                        Button(role: .destructive) { onClipRemoved(clip.id) } label: {
                            Label("Delete Clip", systemImage: "trash")
                        }
                        Divider()
                        Text("Double-click to delete").foregroundColor(.secondary)
                    }
                    .position(x: displayInX + clipWidth / 2, y: clipY)

                    // In point handle (left edge)
                    let isInActive = activeMarker == .clipInPoint(clip.id)
                    let isInHovered = hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .inPoint
                    let inHandleWidth: CGFloat = isInActive ? 10 : (isInHovered ? 8 : 6)
                    let inHandleHeight: CGFloat = isInActive ? 28 : (isInHovered ? 26 : 22)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isInActive ? Color.white : barColor)
                        .frame(width: inHandleWidth, height: inHandleHeight)
                        .shadow(color: isInActive ? Color.white.opacity(0.6) : (isInHovered ? barColor.opacity(0.6) : .clear), radius: isInActive ? 6 : 4)
                        .animation(.easeInOut(duration: 0.15), value: isInHovered)
                        .animation(.easeInOut(duration: 0.15), value: isInActive)
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard draggingClipId == nil else { return }
                            if hovering {
                                hoveredClipEdge = (clip.id, .inPoint)
                                NSCursor.resizeLeftRight.push()
                            } else {
                                if hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .inPoint {
                                    hoveredClipEdge = nil
                                }
                                NSCursor.pop()
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    if draggingClipId != clip.id { dragStartScrollOffset = scrollOffset }
                                    draggingClipId = clip.id
                                    draggingClipEdge = .inPoint
                                    clipDragOffset = value.location.x - inX
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    var newTime = (Double(clampedX) / Double(width)) * duration
                                    // Snap to playhead if within threshold
                                    if snapEnabled {
                                        let playheadX = xPosition(for: currentTime, width: width)
                                        if abs(clampedX - playheadX) < snapThresholdPx {
                                            newTime = currentTime
                                        }
                                    }
                                    onClipRangeChanged(clip.id, max(0, newTime), nil)
                                    draggingClipId = nil
                                    draggingClipEdge = nil
                                    clipDragOffset = 0
                                }
                        )
                        .contextMenu {
                            Button(role: .destructive) { onClipRemoved(clip.id) } label: {
                                Label("Delete Clip", systemImage: "trash")
                            }
                        }
                        .position(x: displayInX, y: clipY)
                        .zIndex(isDragging && draggingClipEdge == .inPoint ? 50 : 5)

                    // Out point handle (right edge)
                    let isOutActive = activeMarker == .clipOutPoint(clip.id)
                    let isOutHovered = hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .outPoint
                    let outHandleWidth: CGFloat = isOutActive ? 10 : (isOutHovered ? 8 : 6)
                    let outHandleHeight: CGFloat = isOutActive ? 28 : (isOutHovered ? 26 : 22)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isOutActive ? Color.white : barColor)
                        .frame(width: outHandleWidth, height: outHandleHeight)
                        .shadow(color: isOutActive ? Color.white.opacity(0.6) : (isOutHovered ? barColor.opacity(0.6) : .clear), radius: isOutActive ? 6 : 4)
                        .animation(.easeInOut(duration: 0.15), value: isOutHovered)
                        .animation(.easeInOut(duration: 0.15), value: isOutActive)
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard draggingClipId == nil else { return }
                            if hovering {
                                hoveredClipEdge = (clip.id, .outPoint)
                                NSCursor.resizeLeftRight.push()
                            } else {
                                if hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .outPoint {
                                    hoveredClipEdge = nil
                                }
                                NSCursor.pop()
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    if draggingClipId != clip.id { dragStartScrollOffset = scrollOffset }
                                    draggingClipId = clip.id
                                    draggingClipEdge = .outPoint
                                    clipDragOffset = value.location.x - outX
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    var newTime = (Double(clampedX) / Double(width)) * duration
                                    // Snap to playhead if within threshold
                                    if snapEnabled {
                                        let playheadX = xPosition(for: currentTime, width: width)
                                        if abs(clampedX - playheadX) < snapThresholdPx {
                                            newTime = currentTime
                                        }
                                    }
                                    onClipRangeChanged(clip.id, nil, min(duration, newTime))
                                    draggingClipId = nil
                                    draggingClipEdge = nil
                                    clipDragOffset = 0
                                }
                        )
                        .contextMenu {
                            Button(role: .destructive) { onClipRemoved(clip.id) } label: {
                                Label("Delete Clip", systemImage: "trash")
                            }
                        }
                        .position(x: displayOutX, y: clipY)
                        .zIndex(isDragging && draggingClipEdge == .outPoint ? 50 : 5)
                }

                // Pending IN point (orange dashed line — clip lane)
                if let pendingIn = pendingInPoint {
                    let x = xPosition(for: pendingIn, width: width)
                    Rectangle()
                        .fill(pendingColor)
                        .frame(width: 3, height: 24)
                        .position(x: x, y: 40)
                        .zIndex(15)
                }

                // Still markers (dots - blue=manual, orange=auto, draggable, selectable)
                ForEach(markedStills) { still in
                    let baseX = xPosition(for: still.timestamp, width: width)
                    let isDragging = draggingStillId == still.id
                    let isHovered = hoveredStillId == still.id
                    let isSelected = selectedStillId == still.id
                    let currentX = isDragging ? baseX + stillDragOffset : baseX
                    let size: CGFloat = isDragging ? 14 : (isSelected ? 14 : (isHovered ? 12 : 10))
                    let markerColor = stillColor(for: still)

                    Circle()
                        .fill(markerColor)
                        .frame(width: size, height: size)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
                                .frame(width: size, height: size)
                        )
                        .shadow(color: (isDragging || isHovered || isSelected) ? markerColor.opacity(0.8) : .clear, radius: isSelected ? 6 : 4)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard draggingStillId == nil else { return }
                            if hovering {
                                hoveredStillId = still.id
                                NSCursor.openHand.push()
                            } else {
                                if hoveredStillId == still.id { hoveredStillId = nil }
                                NSCursor.pop()
                            }
                        }
                        .onTapGesture(count: 2) {
                            onStillRemoved(still.id)
                        }
                        .contextMenu {
                            Button(role: .destructive) { onStillRemoved(still.id) } label: {
                                Label("Delete Still", systemImage: "trash")
                            }
                            Divider()
                            Text("Double-click to delete").foregroundColor(.secondary)
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    if draggingStillId != still.id {
                                        dragStartScrollOffset = scrollOffset
                                        NSCursor.closedHand.push()
                                    }
                                    draggingStillId = still.id
                                    stillDragOffset = value.location.x - baseX
                                    let newTime = (Double(max(0, min(width, value.location.x))) / Double(width)) * duration
                                    onSeek(max(0, min(duration, newTime)))
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    let newTime = (Double(clampedX) / Double(width)) * duration
                                    onStillPositionChanged(still.id, max(0, min(duration, newTime)))
                                    draggingStillId = nil
                                    stillDragOffset = 0
                                    NSCursor.pop()
                                }
                        )
                        .position(x: currentX, y: 16)
                        .zIndex(isDragging ? 100 : (isSelected ? 50 : (isHovered ? 50 : 10)))
                        .animation(.easeInOut(duration: 0.15), value: isSelected)
                }

                // Playhead (current position) - highest z-index
                let playheadX = xPosition(for: currentTime, width: width)
                RoundedRectangle(cornerRadius: 1)
                    .fill(playheadColor)
                    .frame(width: 3, height: timelineHeight)
                    .position(x: playheadX, y: timelineHeight / 2)
                    .zIndex(200)

            }
            .coordinateSpace(name: "timeline")
            .frame(width: width, height: timelineHeight)
            // Shift content so the playhead stays centred; offset IS included in the
            // "timeline" coordinate space transform, so all gesture coordinates remain
            // in content space — no gesture math changes needed.
            .offset(x: -scrollOffset)
            .frame(width: viewportWidth, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .onHover { isHovering in
                if !isHovering && draggingStillId == nil && draggingClipId == nil {
                    hoveredStillId = nil
                    hoveredClipEdge = nil
                    NSCursor.arrow.set()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        guard draggingStillId == nil && draggingClipId == nil else { return }
                        let x = value.location.x
                        let movement = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))

                        if movement > 3 {
                            isDragging = true
                        }

                        if !isDragging, let snapId = nearestStillId(at: x, width: width),
                           let still = markedStills.first(where: { $0.id == snapId }) {
                            onSeek(still.timestamp)
                        } else {
                            let newTime = (Double(x) / Double(width)) * duration
                            onSeek(max(0, min(duration, newTime)))
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )

            // Zoom controls + scroll indicator
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Slider(value: $zoomLevel, in: 1...20)
                    .controlSize(.mini)
                    .frame(width: 80)

                scrollIndicator(viewportWidth: viewportWidth, contentWidth: width, scrollOffset: scrollOffset)
            }
            .frame(height: 16)
            .padding(.horizontal, 4)
            } // VStack
        }
        .frame(height: totalHeight)
    }

    private func nearestStillId(at xPosition: CGFloat, width: CGFloat) -> UUID? {
        guard !markedStills.isEmpty, width > 0 else { return nil }
        var bestId: UUID? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for still in markedStills {
            let markerX = self.xPosition(for: still.timestamp, width: width)
            let distance = abs(xPosition - markerX)
            if distance < snapThresholdPx && distance < bestDistance {
                bestDistance = distance
                bestId = still.id
            }
        }
        return bestId
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat((time / duration) * Double(width))
    }

    /// Returns the scroll offset that keeps the playhead centred in the viewport.
    /// During marker drags the offset is frozen so the view doesn't jump under the cursor.
    private func computedScrollOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard zoomLevel > 1.0, contentWidth > viewportWidth else { return 0 }
        if draggingStillId != nil || draggingClipId != nil {
            return dragStartScrollOffset
        }
        let playheadX = xPosition(for: currentTime, width: contentWidth)
        let raw = playheadX - viewportWidth / 2
        return max(0, min(contentWidth - viewportWidth, raw))
    }

    @ViewBuilder
    private func scrollIndicator(viewportWidth: CGFloat, contentWidth: CGFloat, scrollOffset: CGFloat) -> some View {
        if zoomLevel > 1.01 {
            let thumbFraction = viewportWidth / contentWidth
            let offsetFraction = contentWidth > viewportWidth
                ? scrollOffset / (contentWidth - viewportWidth)
                : 0

            GeometryReader { barGeo in
                let barWidth = barGeo.size.width
                let thumbWidth = max(12, barWidth * thumbFraction)
                let maxOffset = barWidth - thumbWidth

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: thumbWidth, height: 3)
                        .offset(x: min(maxOffset, max(0, offsetFraction * maxOffset)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / barWidth))
                            let time = Double(fraction) * duration
                            onSeek(max(0, min(duration, time)))
                        }
                )
            }
        } else {
            Spacer()
        }
    }
}

import SwiftUI
import AppKit

/// Mutable holder shared with the NSEvent scroll-wheel monitor so the monitor's closure always
/// reads fresh values (closures freeze the View struct at install time; this gives us a stable
/// reference whose contents we update each render).
private final class TimelineScrollBox {
    var scrollTimeBinding: Binding<Double>?
    var visibleDuration: Double = 1
    var maxScrollTime: Double = 0
    var viewportWidth: CGFloat = 1
    /// Set to false when a marker drag or scroll-thumb drag is active so the wheel doesn't
    /// fight the gesture in progress.
    var enabled: Bool = true
}

// MARK: - Manual Timeline View
struct ManualTimelineView: View {
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void
    let sceneCuts: [Double]
    let markedStills: [MarkedStill]
    let markedClips: [MarkedClip]
    let pendingInPoint: Double?
    let pendingOutPoint: Double?
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
    @Binding var zoomLevel: Double

    // Visible-window scroll anchor (in seconds): time displayed at the LEFT edge of the
    // viewport. When zoomLevel == 1, scrollTime == 0 and the whole timeline fits.
    @State private var scrollTime: Double = 0

    // scrollTime frozen at drag-start so the view doesn't shift under the user's cursor while
    // they're dragging a marker.
    @State private var dragStartScrollTime: Double = 0

    // Cursor x recorded at the start of a scroll-thumb drag (nil when no thumb drag is active).
    // Used to compute drag delta so the thumb follows the cursor exactly — no jump when the
    // user grabs the thumb off-center.
    @State private var scrollDragStartCursorX: CGFloat? = nil

    // Previous zoom level — captured so onChange can compute the OLD visible window's center
    // and keep that center put when the user moves the zoom slider (no jump to playhead).
    @State private var prevZoomLevel: Double = 1.0

    // Reference box that the NSEvent scroll-wheel monitor reads from. We can't have the
    // monitor's closure capture @State directly (closures freeze the View struct at install
    // time), so we forward a reference type and update its fields each render.
    @State private var scrollBox = TimelineScrollBox()
    @State private var scrollWheelMonitor: Any? = nil
    @State private var timelineHovered: Bool = false

    /// Seconds visible at the current zoom level (i.e. the width of the visible window).
    private var visibleDuration: Double {
        max(0.01, duration / max(1, Double(zoomLevel)))
    }

    /// scrollTime clamped to [0, duration - visibleDuration] so we never scroll past either edge.
    private var clampedScrollTime: Double {
        max(0, min(max(0, duration - visibleDuration), scrollTime))
    }

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
            // Visible-window model: the timeline always renders at viewport width. Zoom shrinks
            // the visible time range (visibleDuration) rather than growing the rendered width.
            // No .offset / .clipped — markers/cuts are filtered to the visible range instead.
            let viewportWidth = geometry.size.width
            let width = viewportWidth      // legacy name retained for the math helpers below
            // Keep the scroll-wheel box in sync with the latest viewport (re-runs on each layout).
            let _ = { scrollBox.viewportWidth = viewportWidth }()
            let visStart = clampedScrollTime
            let visEnd = visStart + visibleDuration
            VStack(spacing: 2) {

            ZStack(alignment: .topLeading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: timelineHeight - 4)
                    .padding(.top, 2)

                // Scene cut markers — filter to visible range so we never spend cycles laying
                // out thousands of cuts at high zoom, and avoid the floating-point clip-edge
                // glitches that made some markers disappear.
                ForEach(sceneCuts.filter { $0 >= visStart && $0 <= visEnd }, id: \.self) { cut in
                    let x = xPosition(for: cut, width: width)
                    Rectangle()
                        .fill(cutColor)
                        .frame(width: 1, height: timelineHeight - 4)
                        .position(x: x, y: timelineHeight / 2)
                }

                // Marked clips — show any clip that overlaps the visible range. We DON'T filter
                // the clip currently being dragged (it might temporarily move outside the window).
                ForEach(markedClips.filter { clip in
                    draggingClipId == clip.id || (clip.inPoint <= visEnd && clip.outPoint >= visStart)
                }) { clip in
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
                                    if draggingClipId != clip.id { dragStartScrollTime = scrollTime }
                                    draggingClipId = clip.id
                                    draggingClipEdge = .inPoint
                                    clipDragOffset = value.location.x - inX
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    var newTime = timeForX(clampedX, width: width)
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
                                    if draggingClipId != clip.id { dragStartScrollTime = scrollTime }
                                    draggingClipId = clip.id
                                    draggingClipEdge = .outPoint
                                    clipDragOffset = value.location.x - outX
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    var newTime = timeForX(clampedX, width: width)
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

                // Pending IN point (orange line — clip lane). Either kind of pending marker
                // (IN or OUT) renders the same way; the user sees a single orange line waiting
                // for the matching keystroke to complete the clip.
                if let pendingIn = pendingInPoint, pendingIn >= visStart, pendingIn <= visEnd {
                    let x = xPosition(for: pendingIn, width: width)
                    Rectangle()
                        .fill(pendingColor)
                        .frame(width: 3, height: 24)
                        .position(x: x, y: 40)
                        .zIndex(15)
                }
                if let pendingOut = pendingOutPoint, pendingOut >= visStart, pendingOut <= visEnd {
                    let x = xPosition(for: pendingOut, width: width)
                    Rectangle()
                        .fill(pendingColor)
                        .frame(width: 3, height: 24)
                        .position(x: x, y: 40)
                        .zIndex(15)
                }

                // Still markers — filter to visible range, but keep the one currently being
                // dragged so the drag isn't interrupted if the user pulls it past the edge.
                ForEach(markedStills.filter { still in
                    draggingStillId == still.id || (still.timestamp >= visStart && still.timestamp <= visEnd)
                }) { still in
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
                                        dragStartScrollTime = scrollTime
                                        NSCursor.closedHand.push()
                                    }
                                    draggingStillId = still.id
                                    stillDragOffset = value.location.x - baseX
                                    let clampedX = max(0, min(width, value.location.x))
                                    onSeek(timeForX(clampedX, width: width))
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    let newTime = timeForX(clampedX, width: width)
                                    onStillPositionChanged(still.id, newTime)
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
                            onSeek(timeForX(x, width: width))
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )

            // Scroll thumb — drags scrollTime directly (true pan, no seeking).
            scrollIndicator(viewportWidth: viewportWidth)
                .frame(height: 24)
                .padding(.horizontal, 4)
            } // VStack
        }
        .frame(height: totalHeight)
        .onChange(of: currentTime) { newTime in
            autoPageIfNeeded(playheadTime: newTime)
        }
        .onChange(of: zoomLevel) { newZoom in
            recenterOnZoomChange(from: prevZoomLevel)
            prevZoomLevel = newZoom
            updateScrollBox()
        }
        .onChange(of: duration) { _ in
            // If the loaded video changes, reset scroll.
            scrollTime = 0
            updateScrollBox()
        }
        .onChange(of: scrollTime) { _ in updateScrollBox() }
        .onChange(of: draggingStillId) { _ in updateScrollBox() }
        .onChange(of: draggingClipId) { _ in updateScrollBox() }
        .onChange(of: scrollDragStartCursorX) { _ in updateScrollBox() }
        .onHover { hovering in
            timelineHovered = hovering
            if hovering { installScrollWheelMonitor() } else { removeScrollWheelMonitor() }
        }
        .onAppear {
            prevZoomLevel = zoomLevel
            scrollBox.scrollTimeBinding = $scrollTime
            updateScrollBox()
        }
        .onDisappear { removeScrollWheelMonitor() }
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

    /// Maps a time to its x in the viewport. Returns a value outside [0, width] for times
    /// not in the visible window — callers should filter before drawing if perf matters,
    /// but SwiftUI's renderer drops offscreen .position() values safely.
    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard visibleDuration > 0 else { return 0 }
        return CGFloat((time - clampedScrollTime) / visibleDuration) * width
    }

    /// Inverse of `xPosition`: maps a viewport-x coord to a time, clamped to the video duration.
    private func timeForX(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let frac = max(0, min(1, Double(x / width)))
        let t = clampedScrollTime + frac * visibleDuration
        return max(0, min(duration, t))
    }

    /// Page-style auto-scroll: when the playhead crosses outside the visible window, jump
    /// scrollTime so the playhead lands at ~10% from the left (or right when scrubbing back).
    /// Inside the window the playhead moves freely — no per-frame offset chase.
    private func autoPageIfNeeded(playheadTime: Double) {
        guard zoomLevel > 1.0 else {
            scrollTime = 0
            return
        }
        if draggingStillId != nil || draggingClipId != nil { return }
        let visStart = clampedScrollTime
        let visEnd = visStart + visibleDuration
        if playheadTime > visEnd {
            scrollTime = max(0, playheadTime - visibleDuration * 0.1)
        } else if playheadTime < visStart {
            scrollTime = max(0, playheadTime - visibleDuration * 0.1)
        }
    }

    /// Mirror the current scroll-related state into the shared reference box so the NSEvent
    /// monitor closure can read fresh values when wheel events fire.
    private func updateScrollBox() {
        scrollBox.visibleDuration = visibleDuration
        scrollBox.maxScrollTime = max(0, duration - visibleDuration)
        scrollBox.enabled = (draggingStillId == nil && draggingClipId == nil && scrollDragStartCursorX == nil)
    }

    /// Install a local NSEvent monitor that captures horizontal scroll while the cursor is over
    /// the timeline and translates it to a `scrollTime` change. Trackpad / Magic Mouse two-axis
    /// scrolling works natively; on a regular mouse, holding Shift while scrolling vertically
    /// is mapped to horizontal pan (the macOS convention).
    private func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        let box = scrollBox
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard box.enabled, let binding = box.scrollTimeBinding else { return event }
            // Pick the horizontal axis. If the user is shift-scrolling, take the vertical delta.
            let dx: CGFloat
            if abs(event.scrollingDeltaX) > 0.1 {
                dx = event.scrollingDeltaX
            } else if event.modifierFlags.contains(.shift), abs(event.scrollingDeltaY) > 0.1 {
                dx = event.scrollingDeltaY
            } else {
                return event   // pure vertical scroll without shift — not for us
            }
            guard box.viewportWidth > 0, box.visibleDuration > 0, box.maxScrollTime > 0 else {
                return event
            }
            // Natural-scroll convention: positive deltaX = user swiped finger right = content
            // moves right = we want to see content from the LEFT = scrollTime decreases.
            let deltaTime = -Double(dx / box.viewportWidth) * box.visibleDuration
            let newTime = max(0, min(box.maxScrollTime, binding.wrappedValue + deltaTime))
            if newTime != binding.wrappedValue {
                binding.wrappedValue = newTime
            }
            return nil  // consume — don't let the event bubble up to other handlers
        }
    }

    private func removeScrollWheelMonitor() {
        if let m = scrollWheelMonitor {
            NSEvent.removeMonitor(m)
            scrollWheelMonitor = nil
        }
    }

    /// Anchor zoom on the playhead's CURRENT screen-fraction position. If the playhead is
    /// visible at 30% from the left, it stays at 30% from the left after zoom — the window
    /// just shrinks/grows around it. If the playhead is offscreen, it stays offscreen at the
    /// same proportional distance (no sudden snap into view, no jumpy jump-to-playhead).
    private func recenterOnZoomChange(from oldZoom: Double) {
        let oldVisible = max(0.01, duration / max(1, oldZoom))
        let newVisible = visibleDuration
        // Playhead's screen fraction in the OLD window. < 0 = offscreen left, in [0,1] = visible,
        // > 1 = offscreen right. We preserve this fraction across the zoom change.
        let f = (currentTime - scrollTime) / oldVisible
        let newScrollTime = currentTime - f * newVisible
        scrollTime = max(0, min(max(0, duration - newVisible), newScrollTime))
    }

    @ViewBuilder
    private func scrollIndicator(viewportWidth: CGFloat) -> some View {
        if zoomLevel > 1.01 && duration > 0 {
            // Thumb width = fraction of the timeline that's visible. Position = scrollTime
            // mapped over the scrollable range [0, duration - visibleDuration].
            let thumbFraction = visibleDuration / duration
            let maxScrollTime = max(0.0001, duration - visibleDuration)
            let positionFraction = clampedScrollTime / maxScrollTime

            GeometryReader { barGeo in
                let barWidth = barGeo.size.width
                let thumbWidth = max(20, barWidth * CGFloat(thumbFraction))
                let maxOffset = barWidth - thumbWidth

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: thumbWidth, height: 8)
                        .offset(x: min(maxOffset, max(0, CGFloat(positionFraction) * maxOffset)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let trackRange = max(1, barWidth - thumbWidth)
                            if scrollDragStartCursorX == nil {
                                // First .onChanged of this drag. Decide: did the user grab
                                // the thumb (keep current scrollTime, follow cursor delta)
                                // or click on empty track (jump thumb to cursor first)?
                                let thumbLeft = CGFloat(positionFraction) * trackRange
                                let thumbRight = thumbLeft + thumbWidth
                                let onThumb = value.location.x >= thumbLeft && value.location.x <= thumbRight
                                if !onThumb {
                                    // Click on track — jump thumb so its center lands under
                                    // the cursor, then continue with delta drag from there.
                                    let leftEdge = max(0, min(trackRange, value.location.x - thumbWidth / 2))
                                    let frac = Double(leftEdge / trackRange)
                                    scrollTime = frac * maxScrollTime
                                }
                                scrollDragStartCursorX = value.location.x
                                dragStartScrollTime = scrollTime
                                return
                            }
                            // Subsequent .onChanged calls: convert cursor delta to scrollTime delta.
                            // Thumb follows the cursor exactly — no off-center jump.
                            let deltaX = value.location.x - (scrollDragStartCursorX ?? value.location.x)
                            let deltaTime = Double(deltaX) / Double(trackRange) * maxScrollTime
                            scrollTime = max(0, min(maxScrollTime, dragStartScrollTime + deltaTime))
                        }
                        .onEnded { _ in
                            scrollDragStartCursorX = nil
                        }
                )
                .help("Drag to scroll the visible portion of the timeline")
            }
        } else {
            Spacer()
        }
    }
}

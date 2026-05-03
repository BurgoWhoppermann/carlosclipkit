import Foundation
import SwiftUI

/// Represents a marked still (screenshot) with its timestamp
struct MarkedStill: Identifiable, Equatable {
    let id: UUID
    var timestamp: Double
    /// Whether this marker was placed/edited manually by the user (vs auto-generated)
    var isManual: Bool
    /// Horizontal crop offset for 9:16 reframe (0.0 = far left, 0.5 = center, 1.0 = far right)
    var reframeOffset: CGFloat = 0.5
    /// Whether the user has kept this item for downstream processing (Review & Select).
    /// Defaults true so users who skip Review export everything as before.
    var isApproved: Bool = true

    init(timestamp: Double, id: UUID = UUID(), isManual: Bool = false, reframeOffset: CGFloat = 0.5, isApproved: Bool = true) {
        self.id = id
        self.timestamp = timestamp
        self.isManual = isManual
        self.reframeOffset = reframeOffset
        self.isApproved = isApproved
    }

    var formattedTime: String {
        formatTimestamp(timestamp)
    }
}

/// Represents a marked clip with in and out points
struct MarkedClip: Identifiable, Equatable {
    let id: UUID
    var inPoint: Double
    var outPoint: Double
    /// Whether this marker was placed/edited manually by the user (vs auto-generated)
    var isManual: Bool
    /// Horizontal crop offset for 9:16 reframe (0.0 = far left, 0.5 = center, 1.0 = far right)
    var reframeOffset: CGFloat = 0.5
    /// Whether the user has kept this item for downstream processing (Review & Select).
    /// Defaults true so users who skip Review export everything as before.
    var isApproved: Bool = true

    init(inPoint: Double, outPoint: Double, id: UUID = UUID(), isManual: Bool = false, reframeOffset: CGFloat = 0.5, isApproved: Bool = true) {
        self.id = id
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.isManual = isManual
        self.reframeOffset = reframeOffset
        self.isApproved = isApproved
    }

    var duration: Double {
        outPoint - inPoint
    }

    var formattedInPoint: String {
        formatTimestamp(inPoint)
    }

    var formattedOutPoint: String {
        formatTimestamp(outPoint)
    }

    var formattedDuration: String {
        String(format: "%.1fs", duration)
    }
}

/// Format a timestamp as MM:SS.ms
private func formatTimestamp(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds)
    let minutes = totalSeconds / 60
    let secs = totalSeconds % 60
    let ms = Int((seconds - Double(totalSeconds)) * 100)
    return String(format: "%02d:%02d.%02d", minutes, secs, ms)
}

/// Observable state for manual marking mode
class MarkingState: ObservableObject {
    /// Marked still timestamps
    @Published var markedStills: [MarkedStill] = []

    /// Marked clip ranges
    @Published var markedClips: [MarkedClip] = []

    /// User-built grids (Create Grids phase). Empty by default.
    @Published var grids: [GridConfig] = []

    /// Pending IN point (waiting for OUT)
    @Published var pendingInPoint: Double?

    /// Detected scene cuts from video analysis
    @Published var detectedCuts: [Double] = []

    /// Current playback speed
    @Published var playbackSpeed: PlaybackSpeed = .normal

    /// Video duration in seconds
    @Published var videoDuration: Double = 0

    /// Current playhead position
    @Published var currentTime: Double = 0

    /// Whether export is in progress
    @Published var isExporting: Bool = false

    /// Export progress (0.0 to 1.0)
    @Published var exportProgress: Double = 0

    /// Export status message
    @Published var exportStatusMessage: String = ""

    /// Number of detected scene cuts (for UI display)
    var detectedCutsCount: Int { detectedCuts.count }

    /// Playback speeds available
    enum PlaybackSpeed: Double, CaseIterable {
        case half = 0.5
        case normal = 1.0
        case double = 2.0

        var displayName: String {
            switch self {
            case .half: return "0.5x"
            case .normal: return "1x"
            case .double: return "2x"
            }
        }
    }

    private let frameDuration: Double = 1.0 / 25.0

    // MARK: - Undo

    enum UndoAction {
        case addedStill(MarkedStill)
        case removedStill(MarkedStill)
        case movedStill(id: UUID, from: Double, to: Double, wasManual: Bool)
        case addedClip(MarkedClip)
        case removedClip(MarkedClip)
        case modifiedClipRange(id: UUID, oldIn: Double, oldOut: Double, wasManual: Bool)
        case clearedAll(stills: [MarkedStill], clips: [MarkedClip])
        case toggledStillApproval(id: UUID, oldValue: Bool)
        case toggledClipApproval(id: UUID, oldValue: Bool)
        case addedGrid(GridConfig)
        case removedGrid(GridConfig, atIndex: Int)
        case modifiedGrid(id: UUID, previous: GridConfig)
    }

    /// Callback invoked when an undo action is recorded, so the parent (AppState) can mirror it
    var onUndoActionRecorded: ((UndoAction) -> Void)?

    /// When true, onUndoActionRecorded callback is suppressed (used during bulk regeneration)
    var suppressUndoCallback: Bool = false

    /// Last `.modifiedGrid` recording timestamp, keyed by grid id. Used for undo coalescing so
    /// continuous pan/zoom drags don't flood the unified undo stack and push out marker history.
    private var lastGridUndoTime: [UUID: TimeInterval] = [:]
    private let gridUndoCoalesceWindow: TimeInterval = 0.6

    /// Record an undo action and notify the parent.
    ///
    /// Special case for `.modifiedGrid`: if the topmost entry on the stack is a `.modifiedGrid`
    /// for the same grid id and was recorded within the coalesce window, the new mutation is
    /// folded into the existing entry (we keep the OLDER `previous` so undo still rewinds to
    /// the start of the gesture). This collapses dozens of pan/zoom commits into one undoable
    /// step instead of pushing marker history out of the 50-step cap.
    private func recordUndo(_ action: UndoAction) {
        if case .modifiedGrid(let id, _) = action,
           let last = undoStack.last,
           case .modifiedGrid(let lastID, _) = last,
           lastID == id,
           let lastTime = lastGridUndoTime[id],
           Date().timeIntervalSinceReferenceDate - lastTime < gridUndoCoalesceWindow {
            // Coalesce: the existing top entry already holds the older `previous`. Keep it.
            // Bump the timestamp so a long continuous gesture stays coalesced.
            lastGridUndoTime[id] = Date().timeIntervalSinceReferenceDate
            return
        }
        if case .modifiedGrid(let id, _) = action {
            lastGridUndoTime[id] = Date().timeIntervalSinceReferenceDate
        }
        undoStack.append(action)
        if !suppressUndoCallback {
            onUndoActionRecorded?(action)
        }
    }

    @Published var undoStack: [UndoAction] = [] {
        didSet {
            if undoStack.count > 50 {
                undoStack.removeFirst(undoStack.count - 50)
            }
        }
    }
    var canUndo: Bool { !undoStack.isEmpty }

    /// Pop the last action and apply the inverse
    func undo() {
        guard let action = undoStack.popLast() else { return }

        switch action {
        case .addedStill(let still):
            markedStills.removeAll { $0.id == still.id }

        case .removedStill(let still):
            markedStills.append(still)
            markedStills.sort { $0.timestamp < $1.timestamp }

        case .movedStill(let id, let from, _, let wasManual):
            if let index = markedStills.firstIndex(where: { $0.id == id }) {
                markedStills[index].timestamp = from
                markedStills[index].isManual = wasManual
                markedStills.sort { $0.timestamp < $1.timestamp }
            }

        case .addedClip(let clip):
            markedClips.removeAll { $0.id == clip.id }

        case .removedClip(let clip):
            markedClips.append(clip)
            markedClips.sort { $0.inPoint < $1.inPoint }

        case .modifiedClipRange(let id, let oldIn, let oldOut, let wasManual):
            if let index = markedClips.firstIndex(where: { $0.id == id }) {
                markedClips[index].inPoint = oldIn
                markedClips[index].outPoint = oldOut
                markedClips[index].isManual = wasManual
                markedClips.sort { $0.inPoint < $1.inPoint }
            }

        case .clearedAll(let stills, let clips):
            markedStills = stills
            markedClips = clips

        case .toggledStillApproval(let id, let oldValue):
            if let index = markedStills.firstIndex(where: { $0.id == id }) {
                markedStills[index].isApproved = oldValue
            }

        case .toggledClipApproval(let id, let oldValue):
            if let index = markedClips.firstIndex(where: { $0.id == id }) {
                markedClips[index].isApproved = oldValue
            }

        case .addedGrid(let grid):
            grids.removeAll { $0.id == grid.id }

        case .removedGrid(let grid, let index):
            let insertAt = min(max(0, index), grids.count)
            grids.insert(grid, at: insertAt)

        case .modifiedGrid(let id, let previous):
            if let index = grids.firstIndex(where: { $0.id == id }) {
                grids[index] = previous
            }
        }
    }

    // MARK: - Actions

    /// Add a still at the current time
    func addStill(at timestamp: Double, isManual: Bool = false) {
        guard !markedStills.contains(where: { abs($0.timestamp - timestamp) < frameDuration }) else { return }
        let still = MarkedStill(timestamp: timestamp, isManual: isManual)
        markedStills.append(still)
        markedStills.sort { $0.timestamp < $1.timestamp }
        recordUndo(.addedStill(still))
    }

    /// Remove a still by ID
    func removeStill(id: UUID) {
        if let still = markedStills.first(where: { $0.id == id }) {
            recordUndo(.removedStill(still))
        }
        markedStills.removeAll { $0.id == id }
        // Drop any grid cells that referenced this still so exports don't ship black holes.
        sweepGridsRemoving(.still(id))
    }

    /// Snap a time to the nearest scene cut if within threshold
    /// When forOutPoint is true, offsets 1 frame before the cut to avoid transition flicker
    /// When forOutPoint is false (in-point), offsets 1 frame after the cut
    func snapToNearestCut(_ time: Double, threshold: Double = 1.0, forOutPoint: Bool = false) -> Double {
        guard let nearest = detectedCuts.min(by: { abs($0 - time) < abs($1 - time) }) else {
            return time
        }
        guard abs(nearest - time) <= threshold else { return time }
        let safetyMargin = 2.0 * frameDuration  // 2 frames to reliably avoid the cut frame
        return forOutPoint ? nearest - safetyMargin : nearest + safetyMargin
    }

    /// Set the IN point for a new clip
    func setInPoint(at timestamp: Double, snapEnabled: Bool = false) {
        let time = snapEnabled ? snapToNearestCut(timestamp) : timestamp
        pendingInPoint = time
    }

    /// Set the OUT point and create a clip
    func setOutPoint(at timestamp: Double, snapEnabled: Bool = false, isManual: Bool = false) {
        guard let inPoint = pendingInPoint else { return }

        let time = snapEnabled ? snapToNearestCut(timestamp, forOutPoint: true) : timestamp
        guard time > inPoint else { return }

        let clip = MarkedClip(inPoint: inPoint, outPoint: time, isManual: isManual)
        markedClips.append(clip)
        markedClips.sort { $0.inPoint < $1.inPoint }
        pendingInPoint = nil
        recordUndo(.addedClip(clip))
    }

    /// Cancel the pending IN point
    func cancelPendingInPoint() {
        pendingInPoint = nil
    }

    /// Remove a clip by ID
    func removeClip(id: UUID) {
        if let clip = markedClips.first(where: { $0.id == id }) {
            recordUndo(.removedClip(clip))
        }
        markedClips.removeAll { $0.id == id }
        sweepGridsRemoving(.clip(id))
    }

    /// Remove a clip's out-point, reverting the in-point to pendingInPoint
    func removeClipOutPoint(id: UUID) {
        guard let clip = markedClips.first(where: { $0.id == id }) else { return }
        recordUndo(.removedClip(clip))
        markedClips.removeAll { $0.id == id }
        pendingInPoint = clip.inPoint
        sweepGridsRemoving(.clip(id))
    }

    /// Clear all marks
    func clearAll() {
        if hasMarkedItems {
            recordUndo(.clearedAll(stills: markedStills, clips: markedClips))
        }
        let stillIDs = markedStills.map(\.id)
        let clipIDs = markedClips.map(\.id)
        markedStills.removeAll()
        markedClips.removeAll()
        pendingInPoint = nil
        for id in stillIDs { sweepGridsRemoving(.still(id)) }
        for id in clipIDs  { sweepGridsRemoving(.clip(id)) }
    }

    /// Clear only stills (for auto-regeneration without touching clips)
    func clearStills() {
        let ids = markedStills.map(\.id)
        markedStills.removeAll()
        for id in ids { sweepGridsRemoving(.still(id)) }
    }

    /// Clear only clips (for auto-regeneration without touching stills)
    func clearClips() {
        let ids = markedClips.map(\.id)
        markedClips.removeAll()
        for id in ids { sweepGridsRemoving(.clip(id)) }
    }

    /// Check if there's anything to export
    var hasMarkedItems: Bool {
        !markedStills.isEmpty || !markedClips.isEmpty
    }

    /// Formatted pending IN point
    var formattedPendingInPoint: String? {
        guard let inPoint = pendingInPoint else { return nil }
        return formatTimestamp(inPoint)
    }

    /// Update a still's position (for drag editing) — promotes to manual
    func updateStillPosition(id: UUID, to newTime: Double) {
        guard let index = markedStills.firstIndex(where: { $0.id == id }) else { return }
        let oldTime = markedStills[index].timestamp
        let wasManual = markedStills[index].isManual
        let clampedTime = max(0, min(videoDuration > 0 ? videoDuration : newTime, newTime))
        markedStills[index].timestamp = clampedTime
        markedStills[index].isManual = true  // Dragging promotes to manual
        markedStills.sort { $0.timestamp < $1.timestamp }
        recordUndo(.movedStill(id: id, from: oldTime, to: clampedTime, wasManual: wasManual))
    }

    /// Update a clip's in/out points (for drag editing) — promotes to manual
    func updateClipRange(id: UUID, inPoint: Double?, outPoint: Double?, snapEnabled: Bool = false) {
        guard let index = markedClips.firstIndex(where: { $0.id == id }) else { return }
        let oldIn = markedClips[index].inPoint
        let oldOut = markedClips[index].outPoint
        let wasManual = markedClips[index].isManual
        var clip = markedClips[index]

        if let newIn = inPoint {
            let snapped = snapEnabled ? snapToNearestCut(newIn, forOutPoint: false) : newIn
            clip.inPoint = max(0, min(snapped, clip.outPoint - 0.1))
        }
        if let newOut = outPoint {
            let snapped = snapEnabled ? snapToNearestCut(newOut, forOutPoint: true) : newOut
            clip.outPoint = max(clip.inPoint + 0.1, snapped)
        }
        clip.isManual = true  // Dragging promotes to manual

        markedClips[index] = clip
        markedClips.sort { $0.inPoint < $1.inPoint }
        recordUndo(.modifiedClipRange(id: id, oldIn: oldIn, oldOut: oldOut, wasManual: wasManual))
    }

    /// Clear only auto-generated stills (preserves manual ones)
    func clearAutoStills() {
        let removedIDs = markedStills.filter { !$0.isManual }.map(\.id)
        markedStills.removeAll { !$0.isManual }
        for id in removedIDs { sweepGridsRemoving(.still(id)) }
    }

    /// Clear only auto-generated clips (preserves manual ones)
    func clearAutoClips() {
        let removedIDs = markedClips.filter { !$0.isManual }.map(\.id)
        markedClips.removeAll { !$0.isManual }
        for id in removedIDs { sweepGridsRemoving(.clip(id)) }
    }

    /// Remove a source from every grid it appears in. Called whenever the underlying still/clip
    /// is deleted, so grids don't ship orphan black holes at export time. Doesn't record undo —
    /// undoing the marker deletion will not restore the grid cell, the user re-attaches manually.
    private func sweepGridsRemoving(_ source: GridCellSource) {
        for i in grids.indices {
            var g = grids[i]
            var changed = false
            for slotIdx in g.selectedCells.indices where g.selectedCells[slotIdx] == source {
                g.setCell(nil, at: slotIdx)
                changed = true
            }
            if changed { grids[i] = g }
        }
    }

    // MARK: - Reframe Offset

    /// Update the 9:16 reframe offset for a still (no undo recording — export-time concern)
    func updateReframeOffset(forStill id: UUID, offset: CGFloat) {
        if let index = markedStills.firstIndex(where: { $0.id == id }) {
            markedStills[index].reframeOffset = offset
        }
    }

    /// Update the 9:16 reframe offset for a clip (no undo recording — export-time concern)
    func updateReframeOffset(forClip id: UUID, offset: CGFloat) {
        if let index = markedClips.firstIndex(where: { $0.id == id }) {
            markedClips[index].reframeOffset = offset
        }
    }

    // MARK: - Approval (Review & Select)

    /// Stills the user has kept for downstream processing
    var approvedStills: [MarkedStill] { markedStills.filter { $0.isApproved } }

    /// Clips the user has kept for downstream processing
    var approvedClips: [MarkedClip] { markedClips.filter { $0.isApproved } }

    /// Toggle approval for a still — records undo
    func setApproval(forStill id: UUID, approved: Bool) {
        guard let index = markedStills.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = markedStills[index].isApproved
        guard oldValue != approved else { return }
        markedStills[index].isApproved = approved
        recordUndo(.toggledStillApproval(id: id, oldValue: oldValue))
    }

    /// Toggle approval for a clip — records undo
    func setApproval(forClip id: UUID, approved: Bool) {
        guard let index = markedClips.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = markedClips[index].isApproved
        guard oldValue != approved else { return }
        markedClips[index].isApproved = approved
        recordUndo(.toggledClipApproval(id: id, oldValue: oldValue))
    }

    /// Approve all marked items (no undo — used as a bulk reset)
    func approveAll() {
        for i in markedStills.indices { markedStills[i].isApproved = true }
        for i in markedClips.indices { markedClips[i].isApproved = true }
    }

    // MARK: - Grids

    /// Grids ready to render (every slot filled).
    var completedGrids: [GridConfig] { grids.filter { $0.isComplete } }

    /// Append a new grid and return its id.
    @discardableResult
    func addGrid(layout: GridLayout = .oneByThree, ratio: OutputRatio = .nineSixteen) -> UUID {
        let grid = GridConfig(layout: layout, ratio: ratio)
        grids.append(grid)
        recordUndo(.addedGrid(grid))
        return grid.id
    }

    /// Remove a grid by id.
    func removeGrid(id: UUID) {
        guard let index = grids.firstIndex(where: { $0.id == id }) else { return }
        let removed = grids[index]
        grids.remove(at: index)
        recordUndo(.removedGrid(removed, atIndex: index))
    }

    /// Replace a grid wholesale, recording its previous state for undo.
    func updateGrid(_ updated: GridConfig) {
        guard let index = grids.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = grids[index]
        guard previous != updated else { return }
        grids[index] = updated
        recordUndo(.modifiedGrid(id: updated.id, previous: previous))
    }

    /// Auto-fill a grid from the approved item pool, distributing evenly across the timeline.
    /// Each click re-rolls: items are chosen randomly within chronological "buckets" so the
    /// timeline coverage stays even but the specific picks change. Items used in OTHER grids
    /// are excluded by default; if that empties the pool, fall back to allowing reuse from
    /// other grids (still excludes items already in THIS grid).
    func autoFill(gridID: UUID) {
        guard let index = grids.firstIndex(where: { $0.id == gridID }) else { return }
        var grid = grids[index]
        let emptyIndices = grid.selectedCells.enumerated().compactMap { i, s in s == nil ? i : nil }
        guard !emptyIndices.isEmpty else { return }

        // Build the pool with the strictest exclusion first: nothing already in any grid.
        let usedAcrossAllGrids = Set(grids.flatMap { $0.filledCells })
        var pool = candidatePool(excluding: usedAcrossAllGrids)

        // If exclusion across grids leaves nothing usable, relax to "not in THIS grid only".
        if pool.count < emptyIndices.count {
            let usedInThisGrid = Set(grid.filledCells)
            pool = candidatePool(excluding: usedInThisGrid)
        }
        guard !pool.isEmpty else { return }

        // Sort chronologically, then bucket the timeline into N slots and pick a random item
        // from each bucket. Re-clicking re-rolls because the random pick changes.
        pool.sort { $0.time < $1.time }
        let pickCount = min(emptyIndices.count, pool.count)
        for i in 0..<pickCount {
            let bucketStart = i * pool.count / pickCount
            let bucketEnd = max(bucketStart + 1, (i + 1) * pool.count / pickCount)
            let chosen = (bucketStart..<bucketEnd).randomElement() ?? bucketStart
            grid.setCell(pool[chosen].source, at: emptyIndices[i])
        }
        updateGrid(grid)
    }

    /// Build the candidate pool of approved items, excluding any source in `usedSources`.
    private func candidatePool(excluding usedSources: Set<GridCellSource>) -> [(source: GridCellSource, time: Double)] {
        var pool: [(source: GridCellSource, time: Double)] = []
        for still in approvedStills where !usedSources.contains(.still(still.id)) {
            pool.append((.still(still.id), still.timestamp))
        }
        for clip in approvedClips where !usedSources.contains(.clip(clip.id)) {
            pool.append((.clip(clip.id), clip.inPoint + clip.duration / 2))
        }
        return pool
    }
}

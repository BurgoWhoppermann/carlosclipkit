import Foundation
import SwiftUI

/// Represents a marked still (screenshot) with its timestamp
struct MarkedStill: Identifiable, Equatable {
    let id: UUID
    var timestamp: Double

    init(timestamp: Double, id: UUID = UUID()) {
        self.id = id
        self.timestamp = timestamp
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

    init(inPoint: Double, outPoint: Double, id: UUID = UUID()) {
        self.id = id
        self.inPoint = inPoint
        self.outPoint = outPoint
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

    private let frameDuration: Double = 1.0 / 30.0

    // MARK: - Undo

    enum UndoAction {
        case addedStill(MarkedStill)
        case removedStill(MarkedStill)
        case movedStill(id: UUID, from: Double, to: Double)
        case addedClip(MarkedClip)
        case removedClip(MarkedClip)
        case modifiedClipRange(id: UUID, oldIn: Double, oldOut: Double)
        case clearedAll(stills: [MarkedStill], clips: [MarkedClip])
    }

    @Published var undoStack: [UndoAction] = []
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

        case .movedStill(let id, let from, _):
            if let index = markedStills.firstIndex(where: { $0.id == id }) {
                markedStills[index].timestamp = from
                markedStills.sort { $0.timestamp < $1.timestamp }
            }

        case .addedClip(let clip):
            markedClips.removeAll { $0.id == clip.id }

        case .removedClip(let clip):
            markedClips.append(clip)
            markedClips.sort { $0.inPoint < $1.inPoint }

        case .modifiedClipRange(let id, let oldIn, let oldOut):
            if let index = markedClips.firstIndex(where: { $0.id == id }) {
                markedClips[index].inPoint = oldIn
                markedClips[index].outPoint = oldOut
                markedClips.sort { $0.inPoint < $1.inPoint }
            }

        case .clearedAll(let stills, let clips):
            markedStills = stills
            markedClips = clips
        }
    }

    // MARK: - Actions

    /// Add a still at the current time
    func addStill(at timestamp: Double) {
        guard !markedStills.contains(where: { abs($0.timestamp - timestamp) < frameDuration }) else { return }
        let still = MarkedStill(timestamp: timestamp)
        markedStills.append(still)
        markedStills.sort { $0.timestamp < $1.timestamp }
        undoStack.append(.addedStill(still))
    }

    /// Remove a still by ID
    func removeStill(id: UUID) {
        if let still = markedStills.first(where: { $0.id == id }) {
            undoStack.append(.removedStill(still))
        }
        markedStills.removeAll { $0.id == id }
    }

    /// Snap a time to the nearest scene cut if within threshold
    func snapToNearestCut(_ time: Double, threshold: Double = 1.0) -> Double {
        guard let nearest = detectedCuts.min(by: { abs($0 - time) < abs($1 - time) }) else {
            return time
        }
        return abs(nearest - time) <= threshold ? nearest : time
    }

    /// Set the IN point for a new clip
    func setInPoint(at timestamp: Double, snapEnabled: Bool = false) {
        let time = snapEnabled ? snapToNearestCut(timestamp) : timestamp
        pendingInPoint = time
    }

    /// Set the OUT point and create a clip
    func setOutPoint(at timestamp: Double, snapEnabled: Bool = false) {
        guard let inPoint = pendingInPoint else { return }

        let time = snapEnabled ? snapToNearestCut(timestamp) : timestamp
        guard time > inPoint else { return }

        let clip = MarkedClip(inPoint: inPoint, outPoint: time)
        markedClips.append(clip)
        markedClips.sort { $0.inPoint < $1.inPoint }
        pendingInPoint = nil
        undoStack.append(.addedClip(clip))
    }

    /// Cancel the pending IN point
    func cancelPendingInPoint() {
        pendingInPoint = nil
    }

    /// Remove a clip by ID
    func removeClip(id: UUID) {
        if let clip = markedClips.first(where: { $0.id == id }) {
            undoStack.append(.removedClip(clip))
        }
        markedClips.removeAll { $0.id == id }
    }

    /// Clear all marks
    func clearAll() {
        if hasMarkedItems {
            undoStack.append(.clearedAll(stills: markedStills, clips: markedClips))
        }
        markedStills.removeAll()
        markedClips.removeAll()
        pendingInPoint = nil
    }

    /// Clear only stills (for auto-regeneration without touching clips)
    func clearStills() {
        markedStills.removeAll()
    }

    /// Clear only clips (for auto-regeneration without touching stills)
    func clearClips() {
        markedClips.removeAll()
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

    /// Update a still's position (for drag editing)
    func updateStillPosition(id: UUID, to newTime: Double) {
        guard let index = markedStills.firstIndex(where: { $0.id == id }) else { return }
        let oldTime = markedStills[index].timestamp
        let clampedTime = max(0, min(videoDuration > 0 ? videoDuration : newTime, newTime))
        markedStills[index].timestamp = clampedTime
        markedStills.sort { $0.timestamp < $1.timestamp }
        undoStack.append(.movedStill(id: id, from: oldTime, to: clampedTime))
    }

    /// Update a clip's in/out points (for drag editing)
    func updateClipRange(id: UUID, inPoint: Double?, outPoint: Double?, snapEnabled: Bool = false) {
        guard let index = markedClips.firstIndex(where: { $0.id == id }) else { return }
        let oldIn = markedClips[index].inPoint
        let oldOut = markedClips[index].outPoint
        var clip = markedClips[index]

        if let newIn = inPoint {
            let snapped = snapEnabled ? snapToNearestCut(newIn) : newIn
            clip.inPoint = max(0, min(snapped, clip.outPoint - 0.1))
        }
        if let newOut = outPoint {
            let snapped = snapEnabled ? snapToNearestCut(newOut) : newOut
            clip.outPoint = max(clip.inPoint + 0.1, snapped)
        }

        markedClips[index] = clip
        markedClips.sort { $0.inPoint < $1.inPoint }
        undoStack.append(.modifiedClipRange(id: id, oldIn: oldIn, oldOut: oldOut))
    }
}

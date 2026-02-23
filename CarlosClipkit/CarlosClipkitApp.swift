import SwiftUI
import UniformTypeIdentifiers
import Combine
import AVFoundation

enum OutputFormat: String, CaseIterable {
    case mp4 = "MP4"

    var fileType: String {
        switch self {
        case .mp4: return "mp4"
        }
    }
}

enum GIFResolution: String, CaseIterable {
    case tiny = "320w"
    case small = "480w"
    case medium = "640w"

    var maxWidth: Int {
        switch self {
        case .tiny: return 320
        case .small: return 480
        case .medium: return 640
        }
    }

    var displayName: String {
        switch self {
        case .tiny: return "320w (Tiny)"
        case .small: return "480w (Small)"
        case .medium: return "640w (Medium)"
        }
    }

    /// Estimate GIF file size in bytes for a given frame rate and clip duration
    func estimatedSize(frameRate: Int, clipDuration: Double) -> Int {
        let w = Double(maxWidth)
        let h = w * 9.0 / 16.0  // Assume 16:9 source
        let frameCount = Double(frameRate) * clipDuration
        return Int(w * h * 0.3 * frameCount)
    }
}

enum StillFormat: String, CaseIterable {
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }
}

enum StillPlacement: String, CaseIterable {
    case sceneWeighted = "Per scene"
    case spreadEvenly = "Spread evenly"
    case preferFaces = "Prefer faces in focus"

    var description: String {
        switch self {
        case .sceneWeighted:
            return "Places stills proportionally across detected scenes."
        case .spreadEvenly:
            return "Distributes stills at equal intervals across the entire video."
        case .preferFaces:
            return "Spreads evenly, then shifts each still to the sharpest nearby frame with a face."
        }
    }
}

enum StillSize: String, CaseIterable {
    case full = "Full"
    case half = "Half"

    var scale: Double {
        switch self {
        case .full: return 1.0
        case .half: return 0.5
        }
    }
}

enum ClipQuality: String, CaseIterable {
    case sd480 = "480p"
    case hd720 = "720p"
    case fullHD = "1080p"
    case uhd = "4K (UHD)"
    case source = "Source"

    var exportPreset: String {
        switch self {
        case .sd480: return AVAssetExportPreset640x480
        case .hd720: return AVAssetExportPreset1280x720
        case .fullHD: return AVAssetExportPreset1920x1080
        case .uhd: return AVAssetExportPreset3840x2160
        case .source: return AVAssetExportPresetHighestQuality
        }
    }

    var displayName: String { rawValue }
}

// MARK: - Brand Colors
extension Color {
    static let clipkitBlue = Color(red: 0.29, green: 0.56, blue: 0.85)  // #4A90D9
    static let clipkitLightBlue = Color(red: 0.29, green: 0.56, blue: 0.85).opacity(0.1)
}

@main
struct ClipkitApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 420, minHeight: 580)
                .onOpenURL { url in
                    appState.videoURL = url
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

class AppState: ObservableObject {
    @Published var videoURL: URL?
    @Published var markingState = MarkingState()
    private var markingStateCancellable: AnyCancellable?

    // Independent export type toggles
    @Published var exportStillsEnabled: Bool = true
    @Published var exportMovingClipsEnabled: Bool = true

    // Format toggles for Clips (user can select any combination)
    @Published var exportGIF: Bool = true
    @Published var exportMP4: Bool = false
    // Computed convenience properties
    var exportStills: Bool { exportStillsEnabled }
    var exportGIFs: Bool { exportMovingClipsEnabled && exportGIF }
    var exportClips: Bool { exportMovingClipsEnabled && exportMP4 }

    // Stills settings
    @Published var stillCount: Int = 10
    @Published var stillFormat: StillFormat = .jpeg
    @Published var stillSize: StillSize = .full

    // Video metadata
    @Published var videoSize: CGSize = .zero

    // Stills placement strategy
    @Published var stillPlacement: StillPlacement = .spreadEvenly

    // Moving clips settings (unified for GIF + video)
    @Published var clipDuration: Double = 5.0
    @Published var clipCount: Int = 5
    @Published var avoidCrossingScenes: Bool = false
    @Published var allowOverlapping: Bool = false
    @Published var gifFrameRate: Int = 15
    @Published var gifResolution: GIFResolution = .small
    @Published var clipFormat: OutputFormat = .mp4
    @Published var clipQuality: ClipQuality = .source

    // Aspect ratio exports (for both GIFs and Clips)
    @Published var export4x5: Bool = false
    @Published var export9x16: Bool = false

    // Output
    @Published var saveURL: URL?

    // Scene detection (cached)
    @Published var detectedScenes: [(start: Double, end: Double)] = []
    @Published var scenesDetected: Bool = false
    @Published var isDetectingScenes: Bool = false
    @Published var detectionProgress: Double = 0
    @Published var detectionStatusMessage: String = ""
    @Published var detectionThreshold: Double = 0.35
    var sceneDetectionTask: Task<Void, Never>?

    // UI hint: settings changed, re-analyze needed
    @Published var needsReanalysis: Bool = false

    // Still positions (auto-calculated, read-only in auto mode)
    @Published var stillPositions: [Double] = []
    @Published var videoDuration: Double = 0

    // Snap clip in/out points to nearest scene cut
    @Published var snapToSceneCuts: Bool = false

    // Manual->Auto sync: overrides auto-computed clip ranges with manual edits
    @Published var clipRangeOverrides: [(start: Double, duration: Double)]? = nil

    init() {
        // Throttle forwarding to max 10Hz — prevents 20Hz time observer from causing
        // full app re-renders on every tick
        markingStateCancellable = markingState.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// Cancel any in-progress scene detection task
    func cancelSceneDetection() {
        sceneDetectionTask?.cancel()
        sceneDetectionTask = nil
        isDetectingScenes = false
        detectionProgress = 0
    }

    // Check if at least one export format is selected
    var hasSelectedExportType: Bool {
        if exportStillsEnabled { return true }
        if exportMovingClipsEnabled && (exportGIF || exportMP4) { return true }
        return false
    }

    // Get count of selected export types for progress tracking
    var selectedExportCount: Int {
        var count = 0
        if exportStillsEnabled { count += 1 }
        if exportGIFs { count += 1 }
        if exportClips { count += 1 }
        return count
    }

    /// Copy manual mode marks into auto mode state so they survive a mode switch
    func syncManualToAutoPositions() {
        if !markingState.markedStills.isEmpty {
            stillPositions = markingState.markedStills.map { $0.timestamp }.sorted()
        }
        if !markingState.markedClips.isEmpty {
            clipRangeOverrides = markingState.markedClips.map {
                (start: $0.inPoint, duration: $0.outPoint - $0.inPoint)
            }.sorted { $0.start < $1.start }
        }
    }

    func clearSceneCache() {
        cancelSceneDetection()
        detectedScenes = []
        scenesDetected = false
        needsReanalysis = false
        resetStillPositions()
        clipRangeOverrides = nil
        markingState.detectedCuts = []
    }

    /// Initialize still positions based on the current placement strategy
    /// - Parameters:
    ///   - scenes: Detected scene ranges
    ///   - count: Number of stills to position
    func initializeStillPositions(from scenes: [(start: Double, end: Double)], count: Int) {
        switch stillPlacement {
        case .sceneWeighted:
            let detector = SceneDetector()
            stillPositions = detector.selectTimestampsAcrossScenes(sceneRanges: scenes, count: count)
        case .spreadEvenly, .preferFaces:
            stillPositions = distributeEvenlyAcrossVideo(count: count)
        }
    }

    /// Distribute stills at equal intervals across the full video duration with slight randomness
    private func distributeEvenlyAcrossVideo(count: Int) -> [Double] {
        guard count > 0, videoDuration > 0 else { return [] }

        let margin = min(0.5, videoDuration * 0.02)  // Small buffer at start/end
        let usableStart = margin
        let usableEnd = videoDuration - margin

        guard usableEnd > usableStart else {
            return [videoDuration / 2]
        }

        if count == 1 {
            return [Double.random(in: usableStart...usableEnd)]
        }

        let interval = (usableEnd - usableStart) / Double(count)
        var positions: [Double] = []

        for i in 0..<count {
            let segmentStart = usableStart + Double(i) * interval
            let segmentEnd = segmentStart + interval
            // Random position within each segment for variety
            let jitter = interval * 0.3
            let center = (segmentStart + segmentEnd) / 2
            let lo = max(usableStart, center - jitter)
            let hi = min(usableEnd, center + jitter)
            positions.append(Double.random(in: lo...hi))
        }

        return positions.sorted()
    }

    /// Reset still positions
    func resetStillPositions() {
        stillPositions = []
    }

    /// Incrementally adjust still positions to match a new count.
    /// - If newCount > current: insert new positions at the midpoint of the largest gaps (never re-rolls existing)
    /// - If newCount < current: remove positions closest to another remaining position
    /// - If equal: no-op
    func adjustStillPositions(to newCount: Int, scenes: [(start: Double, end: Double)]) {
        guard !scenes.isEmpty, newCount > 0 else { return }
        let currentCount = stillPositions.count
        guard newCount != currentCount else { return }

        if newCount > currentCount {
            // Add new positions in the largest gaps — existing markers stay in place
            var positions = stillPositions
            let addCount = newCount - currentCount

            for _ in 0..<addCount {
                let boundaries = [0.0] + positions + [videoDuration]
                var largestGapStart = 0.0
                var largestGapSize = 0.0

                for i in 0..<(boundaries.count - 1) {
                    let gapSize = boundaries[i + 1] - boundaries[i]
                    if gapSize > largestGapSize {
                        largestGapSize = gapSize
                        largestGapStart = boundaries[i]
                    }
                }

                let newPosition = largestGapStart + largestGapSize / 2
                positions.append(newPosition)
                positions.sort()
            }

            stillPositions = positions
        } else {
            // Remove excess positions — drop those closest to another remaining position
            var positions = stillPositions
            let removeCount = currentCount - newCount

            for _ in 0..<removeCount {
                guard positions.count > 1 else { break }
                // Find the position with the smallest distance to its nearest neighbor
                var minDist = Double.greatestFiniteMagnitude
                var removeIndex = 0
                for i in 0..<positions.count {
                    var nearest = Double.greatestFiniteMagnitude
                    if i > 0 { nearest = min(nearest, positions[i] - positions[i - 1]) }
                    if i < positions.count - 1 { nearest = min(nearest, positions[i + 1] - positions[i]) }
                    if nearest < minDist {
                        minDist = nearest
                        removeIndex = i
                    }
                }
                positions.remove(at: removeIndex)
            }
            stillPositions = positions
        }
    }

    /// Reset all settings to defaults
    func resetAll() {
        exportStillsEnabled = true
        exportMovingClipsEnabled = true
        exportGIF = true
        exportMP4 = false
        stillCount = 10
        stillFormat = .jpeg
        stillSize = .full
        stillPlacement = .spreadEvenly
        clipDuration = 5.0
        clipCount = 5
        avoidCrossingScenes = false
        allowOverlapping = false
        gifFrameRate = 15
        gifResolution = .small
        clipFormat = .mp4
        clipQuality = .source
        export4x5 = false
        export9x16 = false
        detectionThreshold = 0.35
        clearSceneCache()
    }

    /// Extract scene cut timestamps from detected scenes
    var sceneCutTimestamps: [Double] {
        guard detectedScenes.count > 1 else { return [] }
        // Scene cuts are at scene.end positions (except the last one which is video end)
        return detectedScenes.dropLast().map { $0.end }
    }
}

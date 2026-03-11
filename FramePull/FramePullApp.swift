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
    case small = "480w"
    case hd720 = "720p"
    case hd1080 = "1080p"

    var maxWidth: Int {
        switch self {
        case .small: return 480
        case .hd720: return 1280
        case .hd1080: return 1920
        }
    }

    var displayName: String {
        switch self {
        case .small: return "480w (Small)"
        case .hd720: return "720p (HD)"
        case .hd1080: return "1080p (Full HD)"
        }
    }

    /// Estimate GIF file size in bytes for a given frame rate, clip duration, and quality
    func estimatedSize(frameRate: Int, clipDuration: Double, quality: Double = 0.7) -> Int {
        let w = Double(maxWidth)
        let h = w * 9.0 / 16.0  // Assume 16:9 source
        let frameCount = Double(frameRate) * clipDuration
        return Int(w * h * 0.3 * quality * frameCount)
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
    case spreadEvenly = "Spread evenly"
    case perScene = "Per scene"
    case preferFaces = "Prefer faces"

    var description: String {
        switch self {
        case .spreadEvenly:
            return "Distributes stills at equal intervals with some randomness."
        case .perScene:
            return "Places a fixed number of stills in every scene."
        case .preferFaces:
            return "One still per scene, picking the sharpest frame with a face. Skips scenes without faces."
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
    static let framePullNavy   = Color(red: 0.039, green: 0.122, blue: 0.247) // #0A1F3F Deep Navy
    static let framePullAmber  = Color(red: 0.949, green: 0.620, blue: 0.173) // #F29E2C Warm Amber
    static let framePullSilver = Color(red: 0.875, green: 0.902, blue: 0.929) // #DFE6ED Light Silver
    // Primary UI accent — bright blue for readability on dark backgrounds
    static let framePullBlue      = Color(red: 0.29, green: 0.56, blue: 0.85)   // #4A90D9
    static let framePullLightBlue = Color(red: 0.29, green: 0.56, blue: 0.85).opacity(0.1)
}

@main
struct FramePullApp: App {
    @StateObject private var appState = AppState()
    @State private var showSplash = true  // Always show on launch

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 600, minHeight: 600)
                .onOpenURL { url in
                    appState.videoURL = url
                }
                .sheet(isPresented: $showSplash) {
                    BetaSplashView(
                        version: currentVersion,
                        build: currentBuild,
                        onDismiss: {
                            showSplash = false
                        }
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("What's New…") {
                    showSplash = true
                }
            }
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
    @Published var exportMP4: Bool = true
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
    @Published var scenesPerClip: Int = 3
    @Published var clipCount: Int = 5
    @Published var allowOverlapping: Bool = false
    @Published var gifFrameRate: Int = 15
    @Published var gifResolution: GIFResolution = .small
    @Published var gifQuality: Double = 0.7
    @Published var clipFormat: OutputFormat = .mp4
    @Published var clipQuality: ClipQuality = .fullHD

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
    @Published var snapToSceneCuts: Bool = true

    // LUT (Look-Up Table) color correction
    @Published var selectedLUTName: String? = nil {
        didSet { UserDefaults.standard.set(selectedLUTName, forKey: "selectedLUTName") }
    }
    @Published var userLUTFolderURL: URL? = nil {
        didSet {
            if let url = userLUTFolderURL {
                // Store as security-scoped bookmark so the folder remains accessible across launches
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(bookmark, forKey: "userLUTFolderBookmark")
                }
            } else {
                UserDefaults.standard.removeObject(forKey: "userLUTFolderBookmark")
            }
        }
    }
    var lutCubeDimension: Int = 0
    var lutCubeData: Data? = nil
    var lutEnabled: Bool { lutCubeData != nil }

    /// All available LUTs: built-in (from app bundle) + user folder
    var availableLUTs: [(name: String, url: URL, isBuiltIn: Bool)] {
        var result: [(name: String, url: URL, isBuiltIn: Bool)] = []
        // Built-in LUTs from app bundle
        if let builtInDir = Bundle.main.resourceURL?.appendingPathComponent("LUTs") {
            let builtIn = LUTProcessor.scanForLUTs(in: builtInDir)
            result.append(contentsOf: builtIn.map { ($0.name, $0.url, true) })
        }
        // User LUTs from chosen folder
        if let userDir = userLUTFolderURL {
            _ = userDir.startAccessingSecurityScopedResource()
            let userLUTs = LUTProcessor.scanForLUTs(in: userDir)
            result.append(contentsOf: userLUTs.map { ($0.name, $0.url, false) })
            userDir.stopAccessingSecurityScopedResource()
        }
        return result
    }

    /// Load and cache a LUT from a .cube file URL
    func loadLUT(name: String, url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let (dim, data) = try LUTProcessor.parseCubeFile(at: url)
            lutCubeDimension = dim
            lutCubeData = data
            selectedLUTName = name
        } catch {
            print("Failed to load LUT: \(error.localizedDescription)")
            clearLUT()
        }
    }

    /// Clear the active LUT
    func clearLUT() {
        lutCubeDimension = 0
        lutCubeData = nil
        selectedLUTName = nil
    }

    /// Restore persisted LUT settings on launch
    private func restoreLUTSettings() {
        // Restore user LUT folder from bookmark
        if let bookmarkData = UserDefaults.standard.data(forKey: "userLUTFolderBookmark") {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                userLUTFolderURL = url
            }
        }
        // Restore selected LUT name and re-load it
        if let savedName = UserDefaults.standard.string(forKey: "selectedLUTName") {
            // Find the LUT URL by name in available LUTs
            if let match = availableLUTs.first(where: { $0.name == savedName }) {
                loadLUT(name: match.name, url: match.url)
            }
        }
    }

    // MARK: - Unified Undo Stack

    /// All undoable actions across the app (markers, LUT, settings regeneration)
    enum AppUndoAction {
        /// Marker change (wraps existing MarkingState undo action)
        case marking(MarkingState.UndoAction)
        /// LUT change — stores previous LUT state for restoration
        case lutChange(oldName: String?, oldDimension: Int, oldCubeData: Data?)
        /// Settings change that triggered marker regeneration — stores previous marker state
        case settingsRegeneration(previousStills: [MarkedStill], previousClips: [MarkedClip], description: String)
    }

    @Published var appUndoStack: [AppUndoAction] = [] {
        didSet {
            if appUndoStack.count > 50 {
                appUndoStack.removeFirst(appUndoStack.count - 50)
            }
        }
    }
    var canAppUndo: Bool { !appUndoStack.isEmpty }

    /// Pop the last unified undo action and apply its inverse
    func appUndo() {
        guard let action = appUndoStack.popLast() else { return }

        switch action {
        case .marking(let markingAction):
            applyMarkingUndoAction(markingAction)

        case .lutChange(let oldName, let oldDim, let oldData):
            if let data = oldData, let name = oldName {
                lutCubeDimension = oldDim
                lutCubeData = data
                selectedLUTName = name
            } else {
                clearLUT()
            }

        case .settingsRegeneration(let previousStills, let previousClips, _):
            markingState.markedStills = previousStills
            markingState.markedClips = previousClips
        }
    }

    /// Apply the inverse of a MarkingState.UndoAction directly (mirrors MarkingState.undo())
    private func applyMarkingUndoAction(_ action: MarkingState.UndoAction) {
        switch action {
        case .addedStill(let still):
            markingState.markedStills.removeAll { $0.id == still.id }
        case .removedStill(let still):
            markingState.markedStills.append(still)
            markingState.markedStills.sort { $0.timestamp < $1.timestamp }
        case .movedStill(let id, let from, _, let wasManual):
            if let index = markingState.markedStills.firstIndex(where: { $0.id == id }) {
                markingState.markedStills[index].timestamp = from
                markingState.markedStills[index].isManual = wasManual
                markingState.markedStills.sort { $0.timestamp < $1.timestamp }
            }
        case .addedClip(let clip):
            markingState.markedClips.removeAll { $0.id == clip.id }
        case .removedClip(let clip):
            markingState.markedClips.append(clip)
            markingState.markedClips.sort { $0.inPoint < $1.inPoint }
        case .modifiedClipRange(let id, let oldIn, let oldOut, let wasManual):
            if let index = markingState.markedClips.firstIndex(where: { $0.id == id }) {
                markingState.markedClips[index].inPoint = oldIn
                markingState.markedClips[index].outPoint = oldOut
                markingState.markedClips[index].isManual = wasManual
                markingState.markedClips.sort { $0.inPoint < $1.inPoint }
            }
        case .clearedAll(let stills, let clips):
            markingState.markedStills = stills
            markingState.markedClips = clips
        }
    }

    init() {
        // Throttle forwarding to max 10Hz — prevents 20Hz time observer from causing
        // full app re-renders on every tick
        markingStateCancellable = markingState.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        // Bridge marking undo actions to the unified app undo stack
        markingState.onUndoActionRecorded = { [weak self] action in
            self?.appUndoStack.append(.marking(action))
        }

        restoreLUTSettings()
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

    func clearSceneCache() {
        cancelSceneDetection()
        detectedScenes = []
        scenesDetected = false
        needsReanalysis = false
        resetStillPositions()
        markingState.detectedCuts = []
    }

    /// Initialize still positions based on the current placement strategy
    /// - Parameters:
    ///   - scenes: Detected scene ranges
    ///   - count: Number of stills to position
    func initializeStillPositions(from scenes: [(start: Double, end: Double)], count: Int) {
        switch stillPlacement {
        case .spreadEvenly:
            stillPositions = distributeEvenlyAcrossVideo(count: count)
        case .perScene:
            let detector = SceneDetector()
            stillPositions = detector.selectTimestampsPerScene(sceneRanges: scenes, countPerScene: count)
        case .preferFaces:
            // Positions are set asynchronously by findBestFacePerScene — leave empty for now
            stillPositions = []
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
        exportMP4 = true
        stillCount = 10
        stillFormat = .jpeg
        stillSize = .full
        stillPlacement = .spreadEvenly
        scenesPerClip = 3
        clipCount = 5
        allowOverlapping = false
        gifFrameRate = 15
        gifResolution = .small
        clipFormat = .mp4
        clipQuality = .fullHD
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

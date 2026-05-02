import SwiftUI
import AVFoundation

struct ExportSettingsView: View {
    private static let appIcon = (NSApplication.shared.applicationIconImage.copy() as? NSImage) ?? NSImage()

    let videoURL: URL
    let stillCount: Int
    let clipCount: Int
    var onExportComplete: () -> Void
    var onExportError: (String) -> Void
    /// When true, the view is hosted by `ProcessSheet`. The header close button and the
    /// "Preview & Select" action are hidden; selection is sourced from `markingState.approvedStills/Clips`
    /// instead of a local Set.
    var embedded: Bool = false

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportStatusMessage = ""
    @State private var showPreviewSelect = false
    /// Reference to the in-flight export Task so the Cancel button can call `.cancel()`.
    @State private var exportTask: Task<Void, Never>? = nil

    /// When set via "Preview & Select" in legacy (non-embedded) mode, only these items are exported.
    /// In embedded mode, selection is read directly from `appState.markingState`.
    @State private var selectedStillIDs: Set<UUID>? = nil
    @State private var selectedClipIDs: Set<UUID>? = nil

    private let videoProcessor = VideoProcessor()
    private let snippetProcessor = VideoSnippetProcessor()
    private let gridExporter = GridExporter()

    /// Display counts — filtered when a selection is active
    private var displayStillCount: Int {
        if embedded { return appState.markingState.approvedStills.count }
        if let ids = selectedStillIDs { return ids.count }
        return stillCount
    }
    private var displayClipCount: Int {
        if embedded { return appState.markingState.approvedClips.count }
        if let ids = selectedClipIDs { return ids.count }
        return clipCount
    }
    /// Underlying total before approval filter — used to indicate "filtered N of M"
    private var totalStillCount: Int { embedded ? appState.markingState.markedStills.count : stillCount }
    private var totalClipCount: Int { embedded ? appState.markingState.markedClips.count : clipCount }
    private var hasSelectionFilter: Bool {
        if embedded { return displayStillCount + displayClipCount < totalStillCount + totalClipCount }
        return selectedStillIDs != nil || selectedClipIDs != nil
    }

    /// Number of completed grids ready to render
    private var displayGridCount: Int { appState.markingState.completedGrids.count }
    /// Total grids the user has created (incomplete ones are skipped at export)
    private var totalGridCount: Int { appState.markingState.grids.count }

    var body: some View {
        if embedded {
            VStack(spacing: 0) {
                ScrollView {
                    bodyContent
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                actionBar
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .interactiveDismissDisabled(isExporting)
        } else {
            VStack(spacing: 8) {
                bodyContent
                actionBar
            }
            .padding()
            .frame(width: 400)
            .interactiveDismissDisabled(isExporting)
            .sheet(isPresented: $showPreviewSelect) {
                PreviewSelectWrapperView(
                    videoURL: videoURL,
                    markingState: appState.markingState,
                    reframeRatio: appState.export9x16 ? .ratio9x16 : (appState.export4x5 ? .ratio4x5 : nil),
                    showStills: appState.exportStillsEnabled,
                    showClips: appState.exportMovingClipsEnabled,
                    onConfirm: { stillIDs, clipIDs in
                        selectedStillIDs = stillIDs
                        selectedClipIDs = clipIDs
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Spacer()
                if !embedded {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                Text("Export Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                if !embedded {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                    .help("Close export settings")
                }
            }

            // Summary
            HStack(spacing: 16) {
                if appState.exportStillsEnabled && displayStillCount > 0 {
                    Label("\(displayStillCount) stills", systemImage: "photo")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if displayClipCount > 0 {
                    Label("\(displayClipCount) clips", systemImage: "film")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if appState.exportGridsEnabled && displayGridCount > 0 {
                    Label("\(displayGridCount) grid\(displayGridCount == 1 ? "" : "s")", systemImage: "square.grid.2x2")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if hasSelectionFilter {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundColor(.framePullAmber)
                    Text("Filtered — exporting \(displayStillCount + displayClipCount) of \(totalStillCount + totalClipCount) items")
                        .font(.caption)
                        .foregroundColor(.framePullAmber)
                    Spacer()
                    if !embedded {
                        Button("Reset") {
                            selectedStillIDs = nil
                            selectedClipIDs = nil
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Constants for crisp visual alignment across sections
            let groupIndent: CGFloat = 24
            let subLabelWidth: CGFloat = 85
            let mainLabelWidth: CGFloat = groupIndent + subLabelWidth

            // Stills settings
            if displayStillCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Export stills", isOn: $appState.exportStillsEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13, weight: .semibold))
                        .help("Include still frames in the export")

                    if appState.exportStillsEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Format:")
                                    .frame(width: subLabelWidth, alignment: .leading)
                                Picker("", selection: $appState.stillFormat) {
                                    ForEach(StillFormat.allCases, id: \.self) { format in
                                        Text(format.rawValue).tag(format)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 180)
                                .help("Choose image format — JPEG for smaller files, PNG for lossless, TIFF for maximum quality")
                            }

                            HStack {
                                Text("Still size:")
                                    .frame(width: subLabelWidth, alignment: .leading)
                                Picker("", selection: $appState.stillSize) {
                                    ForEach(StillSize.allCases, id: \.self) { size in
                                        Text(size.rawValue).tag(size)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 140)
                                .help("Scale factor for exported stills — 1x is full resolution")
                                
                                if appState.videoSize != .zero {
                                    let w = Int(appState.videoSize.width * appState.stillSize.scale)
                                    let h = Int(appState.videoSize.height * appState.stillSize.scale)
                                    Text("\(w) x \(h)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 4)
                                }
                            }
                        }
                        .padding(.leading, groupIndent)
                    }
                }
            }

            if displayStillCount > 0 && displayClipCount > 0 {
                Divider().padding(.vertical, 4)
            }

            // Clip export settings (only when clips exist)
            if displayClipCount > 0 {
                // GIF subsection
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Export GIFs", isOn: $appState.exportGIF)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13, weight: .semibold))
                        .help("Export each clip as an animated GIF")

                    if appState.exportGIF {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Resolution:")
                                    .frame(width: subLabelWidth, alignment: .leading)
                                Picker("", selection: $appState.gifResolution) {
                                    ForEach(GIFResolution.allCases, id: \.self) { resolution in
                                        Text(resolution.displayName).tag(resolution)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 160)
                                .help("Maximum width of the exported GIF in pixels")
                            }

                            HStack {
                                Text("Frame rate:")
                                    .frame(width: subLabelWidth, alignment: .leading)
                                Picker("", selection: $appState.gifFrameRate) {
                                    Text("10 fps").tag(10)
                                    Text("15 fps").tag(15)
                                    Text("20 fps").tag(20)
                                    Text("25 fps").tag(25)
                                    Text("30 fps").tag(30)
                                }
                                .pickerStyle(.menu)
                                .frame(width: 100)
                                .help("Frames per second — higher is smoother but larger file size")
                            }

                            HStack {
                                Text("Quality:")
                                    .frame(width: subLabelWidth, alignment: .leading)
                                Slider(value: $appState.gifQuality, in: 0.3...1.0, step: 0.1)
                                    .frame(width: 160)
                                    .tint(.framePullBlue)
                                    .help("Color quality — lower values reduce file size")
                                Text("\(Int(appState.gifQuality * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 35, alignment: .trailing)
                            }
                            
                            Text(gifSizeEstimate)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                        .padding(.leading, groupIndent)
                    }
                }

                Divider().padding(.vertical, 4)

                // MP4 subsection
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Export video clips", isOn: $appState.exportMP4)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13, weight: .semibold))
                        .help("Export each clip as an MP4 video file")

                    if appState.exportMP4 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Quality:")
                                    .frame(width: subLabelWidth, alignment: .leading)
                                Picker("", selection: $appState.clipQuality) {
                                    ForEach(ClipQuality.allCases, id: \.self) { quality in
                                        Text(quality.displayName).tag(quality)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 160)
                                .help("Video export resolution — higher quality means larger files")
                            }

                            Toggle("Mute audio track", isOn: $appState.muteAudio)
                                .toggleStyle(.checkbox)
                                .help("Strip audio track from exported clips")
                                .padding(.leading, subLabelWidth + 4) // Align checkbox exactly with Picker text
                        }
                        .padding(.leading, groupIndent)
                    }
                }

                Divider().padding(.vertical, 4)

                // Crop options
                HStack(spacing: 8) {
                    Text("Additional crops:")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: mainLabelWidth, alignment: .leading)
                    
                    Toggle("4:5", isOn: $appState.export4x5)
                        .toggleStyle(.checkbox)
                        .help("Also export a 4:5 vertical crop (Instagram portrait)")
                        
                    Toggle("9:16", isOn: $appState.export9x16)
                        .toggleStyle(.checkbox)
                        .padding(.leading, 8)
                        .help("Also export a 9:16 vertical crop (Stories / Reels / TikTok)")
                }
            }

            // Grids section (only when at least one grid exists)
            if totalGridCount > 0 {
                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Export grids", isOn: $appState.exportGridsEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13, weight: .semibold))
                        .help("Render configured grids and save them to /grids/ in the output folder")

                    if appState.exportGridsEnabled {
                        let incomplete = totalGridCount - displayGridCount
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(displayGridCount) of \(totalGridCount) grid\(totalGridCount == 1 ? "" : "s") ready to render")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if incomplete > 0 {
                                Text("\(incomplete) grid\(incomplete == 1 ? "" : "s") incomplete — open Create Grids to fill empty cells")
                                    .font(.caption)
                                    .foregroundColor(.framePullAmber)
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            // Save location
            HStack(spacing: 8) {
                Text("Save to:")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: mainLabelWidth, alignment: .leading)
                
                if let saveURL = appState.saveURL {
                    Text(saveURL.lastPathComponent)
                        .foregroundColor(.primary)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading) // Push "Choose" to the right edge
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Select output folder")
                            .foregroundColor(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                Button("Choose...") {
                    chooseLocation()
                }
                .tint(.framePullBlue)
                .help("Select the folder where exported files will be saved")
            }

        }
    }

    /// Pinned to the bottom of the sheet in embedded mode so the Export button is always visible
    /// regardless of how many settings sections are showing.
    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 8) {
            if isExporting {
                VStack(spacing: 6) {
                    ProgressView(value: exportProgress)
                        .progressViewStyle(.linear)
                        .tint(.framePullBlue)
                    Text(exportStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                if isExporting {
                    Button(role: .destructive, action: { cancelExport() }) {
                        Text("Cancel")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Stop the export. Already-written files are kept; the in-progress grid file is cleaned up.")
                } else {
                    if !embedded {
                        Button(action: { showPreviewSelect = true }) {
                            Label("Preview & Select", systemImage: "checklist")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.framePullAmber)
                        .controlSize(.large)
                        .help("Preview items, select which to export, and adjust crop positions")
                    }

                    Button(action: { startExport() }) {
                        HStack(spacing: 6) {
                            if appState.saveURL == nil {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text(appState.saveURL == nil ? "Choose Folder & Export" : "Export")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullBlue)
                    .controlSize(.large)
                    // Note: don't disable on saveURL==nil — clicking will open the folder picker.
                    .disabled(!appState.hasSelectedExportType || (displayStillCount + displayClipCount + displayGridCount) == 0)
                    .help(appState.saveURL == nil
                          ? "Pick an output folder, then export all marked items"
                          : "Export all marked stills and clips to the selected folder")
                }
            }

            Text("Files are always added — never overwritten")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000.0
        if mb < 1.0 {
            return "~\(Int(mb * 1000)) KB"
        } else {
            return "~\(String(format: "%.0f", mb)) MB"
        }
    }

    private var gifSizeEstimate: String {
        let clips = effectiveClips
        let frameRate = appState.gifFrameRate
        let quality = appState.gifQuality

        if clips.isEmpty {
            let bytes = appState.gifResolution.estimatedSize(
                frameRate: frameRate, clipDuration: 5.0, quality: quality
            )
            return "\(formatBytes(bytes)) per clip (est. 5 s)"
        }

        let perClipBytes = clips.map {
            appState.gifResolution.estimatedSize(
                frameRate: frameRate, clipDuration: $0.duration, quality: quality
            )
        }
        let totalBytes = perClipBytes.reduce(0, +)
        guard let minBytes = perClipBytes.min(),
              let maxBytes = perClipBytes.max() else { return "" }

        if clips.count == 1 {
            return "\(formatBytes(totalBytes)) total (1 clip)"
        }

        if minBytes == maxBytes {
            return "\(formatBytes(totalBytes)) total (\(clips.count) clips, \(formatBytes(minBytes)) each)"
        }

        return "\(formatBytes(totalBytes)) total (\(clips.count) clips, \(formatBytes(minBytes))–\(formatBytes(maxBytes)) each)"
    }

    /// Stills filtered by selection (if provided)
    private var effectiveStills: [MarkedStill] {
        if embedded { return appState.markingState.approvedStills }
        let all = appState.markingState.markedStills
        guard let ids = selectedStillIDs else { return all }
        return all.filter { ids.contains($0.id) }
    }

    /// Clips filtered by selection (if provided)
    private var effectiveClips: [MarkedClip] {
        if embedded { return appState.markingState.approvedClips }
        let all = appState.markingState.markedClips
        guard let ids = selectedClipIDs else { return all }
        return all.filter { ids.contains($0.id) }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.message = "Choose where to save the exported files"

        if panel.runModal() == .OK {
            appState.saveURL = panel.url
        }
    }

    private func startExport() {
        // If no output folder is set, prompt the user instead of silently no-op'ing.
        // This handles the case where the Export button got tapped before a folder was chosen.
        guard let outputDir = appState.saveURL else {
            chooseLocation()
            // If they picked a folder via the prompt, kick the export off automatically.
            if appState.saveURL != nil {
                startExport()
            }
            return
        }

        isExporting = true
        exportProgress = 0
        exportStatusMessage = "Starting export..."

        exportTask = Task {
            // Activate security-scoped access for the chosen folder. Required when the URL
            // came from a persisted bookmark, and important for iCloud Drive paths where
            // even a fresh NSOpenPanel grant doesn't always cover ImageIO's atomic-write
            // staging files (they fail with "Operation not permitted" otherwise).
            let didStart = outputDir.startAccessingSecurityScopedResource()
            defer { if didStart { outputDir.stopAccessingSecurityScopedResource() } }

            do {
                try await exportManual(to: outputDir)

                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    dismiss()
                    onExportComplete()
                }
            } catch is CancellationError {
                // User-initiated cancel — silent dismissal of the in-progress state.
                await MainActor.run {
                    isExporting = false
                    exportProgress = 0
                    exportStatusMessage = ""
                    exportTask = nil
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    onExportError(error.localizedDescription)
                }
            }
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
        exportStatusMessage = "Cancelling…"
    }

    // MARK: - Manual Export

    private func exportManual(to outputDir: URL) async throws {
        let stills = effectiveStills
        let clips = effectiveClips
        let exportableGrids = appState.exportGridsEnabled
            ? appState.markingState.completedGrids
            : []

        let stillsCount = (appState.exportStillsEnabled && !stills.isEmpty) ? stills.count : 0
        let clipsCount = appState.exportMovingClipsEnabled ? clips.count : 0
        let gridsCount = exportableGrids.count
        let totalItems = max(1, stillsCount + clipsCount + gridsCount)
        var completedItems = 0

        // Export stills
        if stillsCount > 0 {
            try Task.checkCancellation()
            let timestamps = stills.map { $0.timestamp }
            let reframeOffsets = stills.map { $0.reframeOffset }
            await MainActor.run {
                exportStatusMessage = "Exporting stills..."
            }

            try await videoProcessor.extractStillsAtTimestamps(
                from: videoURL,
                timestamps: timestamps,
                to: outputDir,
                scale: appState.stillSize.scale,
                format: appState.stillFormat,
                export4x5: appState.export4x5,
                export9x16: appState.export9x16,
                lutCubeDimension: appState.lutEnabled ? appState.lutCubeDimension : nil,
                lutCubeData: appState.lutCubeData,
                reframeOffsets: reframeOffsets
            ) { progress, message in
                Task { @MainActor in
                    let stillsProgress = progress * Double(stillsCount) / Double(totalItems)
                    exportProgress = stillsProgress
                    exportStatusMessage = message
                }
            }

            completedItems += stillsCount
        }

        // Export clips (as both video AND GIF) — only when moving clips enabled
        if appState.exportMovingClipsEnabled {
            for (index, clip) in clips.enumerated() {
                try Task.checkCancellation()
                await MainActor.run {
                    exportStatusMessage = "Exporting clip \(index + 1) of \(clips.count)..."
                }

                try await snippetProcessor.exportClipAndGIF(
                    from: videoURL,
                    startTime: clip.inPoint,
                    duration: clip.duration,
                    resolution: appState.gifResolution,
                    gifFrameRate: appState.gifFrameRate,
                    gifQuality: appState.gifQuality,
                    exportGIF: appState.exportGIF,
                    exportMP4: appState.exportMP4,
                    format: appState.clipFormat,
                    to: outputDir,
                    export4x5: appState.export4x5,
                    export9x16: appState.export9x16,
                    presetName: appState.clipQuality.exportPreset,
                    lutCubeDimension: appState.lutEnabled ? appState.lutCubeDimension : nil,
                    lutCubeData: appState.lutCubeData,
                    muteAudio: appState.muteAudio,
                    reframeOffset: clip.reframeOffset
                )

                completedItems += 1
                await MainActor.run {
                    exportProgress = Double(completedItems) / Double(totalItems)
                }
            }
        }

        // Export grids
        if !exportableGrids.isEmpty {
            let gridsDir = outputDir.appendingPathComponent("grids", isDirectory: true)
            try FileManager.default.createDirectory(at: gridsDir, withIntermediateDirectories: true)

            let videoBaseName = videoURL.deletingPathExtension().lastPathComponent
            let allMarkedStills = appState.markingState.markedStills
            let allMarkedClips = appState.markingState.markedClips

            for (gridIndex, grid) in exportableGrids.enumerated() {
                try Task.checkCancellation()
                await MainActor.run {
                    exportStatusMessage = "Exporting grid \(gridIndex + 1) of \(exportableGrids.count)..."
                }

                // Use a unified prefix so .jpg and .mp4 grids share the same numbering sequence.
                let next = nextGridIndex(in: gridsDir, baseName: videoBaseName)
                let indexStr = String(format: "%03d", next)
                let isVideo = grid.containsClip
                let ext = isVideo ? "mp4" : "jpg"
                let outFile = gridsDir.appendingPathComponent("\(videoBaseName)_grid_\(indexStr).\(ext)")

                if isVideo {
                    try await gridExporter.exportVideoGrid(
                        config: grid,
                        sourceVideoURL: videoURL,
                        markedStills: allMarkedStills,
                        markedClips: allMarkedClips,
                        outputURL: outFile,
                        lutCubeDimension: appState.lutEnabled ? appState.lutCubeDimension : nil,
                        lutCubeData: appState.lutCubeData,
                        progressHandler: { sub in
                            Task { @MainActor in
                                let perGrid = 1.0 / Double(totalItems)
                                let base = Double(completedItems) / Double(totalItems)
                                exportProgress = base + perGrid * sub
                            }
                        }
                    )
                } else {
                    try await gridExporter.exportImageGrid(
                        config: grid,
                        sourceVideoURL: videoURL,
                        markedStills: allMarkedStills,
                        markedClips: allMarkedClips,
                        outputURL: outFile,
                        lutCubeDimension: appState.lutEnabled ? appState.lutCubeDimension : nil,
                        lutCubeData: appState.lutCubeData
                    )
                }

                completedItems += 1
                await MainActor.run {
                    exportProgress = Double(completedItems) / Double(totalItems)
                }
            }
        }
    }

    /// Find the next available index across both .jpg and .mp4 grid files in a directory,
    /// so mixed image/video grids share one numbering sequence.
    private func nextGridIndex(in directory: URL, baseName: String) -> Int {
        let jpg = ProcessingUtilities.findNextAvailableIndex(in: directory, prefix: "\(baseName)_grid", suffix: ".jpg")
        let mp4 = ProcessingUtilities.findNextAvailableIndex(in: directory, prefix: "\(baseName)_grid", suffix: ".mp4")
        return max(jpg, mp4)
    }

}

// MARK: - Preview & Select Wrapper

/// Thin wrapper around MarkerPreviewView in select mode that reports selected IDs back via callback on dismiss
struct PreviewSelectWrapperView: View {
    let videoURL: URL
    @ObservedObject var markingState: MarkingState
    let reframeRatio: VideoSnippetProcessor.AspectRatioCrop?
    var showStills: Bool = true
    var showClips: Bool = true
    let onConfirm: (Set<UUID>, Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedStillIDs: Set<UUID> = []
    @State private var selectedClipIDs: Set<UUID> = []
    @State private var didInit = false

    var body: some View {
        MarkerPreviewView(
            videoURL: videoURL,
            markingState: markingState,
            reframeRatio: reframeRatio,
            showStills: showStills,
            showClips: showClips,
            selectMode: true,
            onSelectionConfirm: { stillIDs, clipIDs in
                onConfirm(stillIDs, clipIDs)
                dismiss()
            }
        )
    }
}

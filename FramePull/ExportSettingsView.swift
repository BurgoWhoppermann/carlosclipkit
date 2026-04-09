import SwiftUI
import AVFoundation

struct ExportSettingsView: View {
    private static let appIcon = (NSApplication.shared.applicationIconImage.copy() as? NSImage) ?? NSImage()

    let videoURL: URL
    let stillCount: Int
    let clipCount: Int
    var onExportComplete: () -> Void
    var onExportError: (String) -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportStatusMessage = ""
    @State private var showPreviewSelect = false

    /// When set via "Preview & Select", only these items are exported
    @State private var selectedStillIDs: Set<UUID>? = nil
    @State private var selectedClipIDs: Set<UUID>? = nil

    private let videoProcessor = VideoProcessor()
    private let snippetProcessor = VideoSnippetProcessor()

    /// Display counts — filtered when a selection is active
    private var displayStillCount: Int {
        if let ids = selectedStillIDs { return ids.count } else { return stillCount }
    }
    private var displayClipCount: Int {
        if let ids = selectedClipIDs { return ids.count } else { return clipCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Spacer()
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Export Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                .help("Close export settings")
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
                Spacer()
            }

            if selectedStillIDs != nil || selectedClipIDs != nil {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundColor(.framePullAmber)
                    Text("Filtered — exporting \(displayStillCount + displayClipCount) of \(stillCount + clipCount) items")
                        .font(.caption)
                        .foregroundColor(.framePullAmber)
                    Spacer()
                    Button("Reset") {
                        selectedStillIDs = nil
                        selectedClipIDs = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
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

            // Export progress
            if isExporting {
                VStack(spacing: 6) {
                    ProgressView(value: exportProgress)
                        .progressViewStyle(.linear)
                        .tint(.framePullBlue)
                    Text(exportStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }

            Spacer().frame(height: 8)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: { showPreviewSelect = true }) {
                    Label("Preview & Select", systemImage: "checklist")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullAmber)
                .controlSize(.large)
                .disabled(isExporting)
                .help("Preview items, select which to export, and adjust crop positions")

                Button(action: { startExport() }) {
                    Text("Export")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullBlue)
                .controlSize(.large)
                .disabled(appState.saveURL == nil || isExporting || !appState.hasSelectedExportType)
                .help("Export all marked stills and clips to the selected folder")
            }
            .padding(.top, 4)

            Text("Files are always added — never overwritten")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
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
        let all = appState.markingState.markedStills
        guard let ids = selectedStillIDs else { return all }
        return all.filter { ids.contains($0.id) }
    }

    /// Clips filtered by selection (if provided)
    private var effectiveClips: [MarkedClip] {
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
        guard let outputDir = appState.saveURL else { return }

        isExporting = true
        exportProgress = 0
        exportStatusMessage = "Starting export..."

        Task {
            do {
                try await exportManual(to: outputDir)

                await MainActor.run {
                    isExporting = false
                    dismiss()
                    onExportComplete()
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    onExportError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Manual Export

    private func exportManual(to outputDir: URL) async throws {
        let stills = effectiveStills
        let clips = effectiveClips

        let stillsCount = (appState.exportStillsEnabled && !stills.isEmpty) ? stills.count : 0
        let clipsCount = appState.exportMovingClipsEnabled ? clips.count : 0
        let totalItems = max(1, stillsCount + clipsCount)
        var completedItems = 0

        // Export stills
        if stillsCount > 0 {
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

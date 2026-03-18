import SwiftUI
import AVFoundation

struct ExportSettingsView: View {
    private static let appIcon = NSApplication.shared.applicationIconImage.copy() as! NSImage

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
    @State private var showPreview = false

    private let videoProcessor = VideoProcessor()
    private let snippetProcessor = VideoSnippetProcessor()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .frame(width: 24, height: 24)
                Text("Export Settings")
                    .font(.headline)
                Spacer()
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
                if appState.exportStillsEnabled && stillCount > 0 {
                    Label("\(stillCount) stills", systemImage: "photo")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if clipCount > 0 {
                    Label("\(clipCount) clips", systemImage: "film")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { showPreview = true }) {
                    Label("Preview & Reframe", systemImage: "eye")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullBlue)
                .controlSize(.small)
                .help("Preview markers and adjust 9:16 or 4:5 crop position")
            }

            Divider()

            // Stills settings
            if stillCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Export stills", isOn: $appState.exportStillsEnabled)
                        .toggleStyle(.checkbox)
                        .help("Include still frames in the export")

                    if appState.exportStillsEnabled {
                        HStack {
                            Text("Format:")
                            Spacer()
                            Picker("", selection: $appState.stillFormat) {
                                ForEach(StillFormat.allCases, id: \.self) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                            .help("Choose image format — JPEG for smaller files, PNG for lossless, TIFF for maximum quality")
                        }
                        .padding(.leading, 20)

                        HStack {
                            Text("Still size:")
                            Spacer()
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
                            }
                        }
                        .padding(.leading, 20)

                    }
                }
            }

            if stillCount > 0 && clipCount > 0 {
                Divider()
            }

            // Clip export settings (only when clips exist)
            if clipCount > 0 {
                // GIF subsection
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Export GIFs", isOn: $appState.exportGIF)
                        .toggleStyle(.checkbox)
                        .help("Export each clip as an animated GIF")

                    if appState.exportGIF {
                        HStack {
                            Text("Resolution:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Picker("", selection: $appState.gifResolution) {
                                ForEach(GIFResolution.allCases, id: \.self) { resolution in
                                    Text(resolution.displayName).tag(resolution)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                            .help("Maximum width of the exported GIF in pixels")
                        }
                        .padding(.leading, 20)

                        HStack {
                            Text("Frame rate:")
                                .foregroundColor(.secondary)
                            Spacer()
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
                        .padding(.leading, 20)

                        HStack {
                            Text("Quality:")
                                .foregroundColor(.secondary)
                            Slider(value: $appState.gifQuality, in: 0.3...1.0, step: 0.1)
                                .tint(.framePullBlue)
                                .help("Color quality — lower values reduce file size")
                            Text("\(Int(appState.gifQuality * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 35, alignment: .trailing)
                        }
                        .padding(.leading, 20)

                        Text(gifSizeEstimate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }
                }

                Divider()

                // MP4 subsection
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Export video clips", isOn: $appState.exportMP4)
                        .toggleStyle(.checkbox)
                        .help("Export each clip as an MP4 video file")

                    if appState.exportMP4 {
                        HStack {
                            Text("Quality:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Picker("", selection: $appState.clipQuality) {
                                ForEach(ClipQuality.allCases, id: \.self) { quality in
                                    Text(quality.displayName).tag(quality)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                            .help("Video export resolution — higher quality means larger files")
                        }
                        .padding(.leading, 20)

                        Toggle("Mute audio", isOn: $appState.muteAudio)
                            .toggleStyle(.checkbox)
                            .padding(.leading, 20)
                            .help("Strip audio track from exported clips")
                    }
                }

                Divider()

                // Crop options
                HStack {
                    Text("Crop:")
                    Spacer()
                    Toggle("Original", isOn: .constant(true))
                        .toggleStyle(.checkbox)
                        .disabled(true)
                        .help("Original aspect ratio is always exported")
                    Toggle("4:5", isOn: $appState.export4x5)
                        .toggleStyle(.checkbox)
                        .help("Also export a 4:5 vertical crop (Instagram portrait)")
                    Toggle("9:16", isOn: $appState.export9x16)
                        .toggleStyle(.checkbox)
                        .help("Also export a 9:16 vertical crop (Stories / Reels / TikTok)")
                }
            }

            Divider()

            // Save location
            HStack {
                Text("Save to:")
                Spacer()
                if let saveURL = appState.saveURL {
                    Text(saveURL.lastPathComponent)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Select output folder")
                            .foregroundColor(.orange)
                    }
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
            }

            // Export button
            Button(action: { startExport() }) {
                Text("Export")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.framePullBlue)
            .controlSize(.large)
            .disabled(appState.saveURL == nil || isExporting || !appState.hasSelectedExportType)
            .help("Export all marked stills and clips to the selected folder")

            Label("Files are always added — never overwritten", systemImage: "plus.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 400)
        .interactiveDismissDisabled(isExporting)
        .sheet(isPresented: $showPreview) {
            MarkerPreviewView(
                videoURL: videoURL,
                markingState: appState.markingState,
                reframeRatio: appState.export9x16 ? .ratio9x16 : (appState.export4x5 ? .ratio4x5 : nil),
                showStills: appState.exportStillsEnabled,
                showClips: appState.exportMovingClipsEnabled
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
        let clips = appState.markingState.markedClips
        let frameRate = appState.gifFrameRate
        let quality = appState.gifQuality

        if clips.isEmpty {
            // No clips yet — show estimate for a hypothetical 5s clip
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
        let minBytes = perClipBytes.min()!
        let maxBytes = perClipBytes.max()!

        if clips.count == 1 {
            return "\(formatBytes(totalBytes)) total (1 clip)"
        }

        if minBytes == maxBytes {
            return "\(formatBytes(totalBytes)) total (\(clips.count) clips, \(formatBytes(minBytes)) each)"
        }

        return "\(formatBytes(totalBytes)) total (\(clips.count) clips, \(formatBytes(minBytes))–\(formatBytes(maxBytes)) each)"
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
        let markingState = appState.markingState
        let stillsCount = (appState.exportStillsEnabled && !markingState.markedStills.isEmpty) ? markingState.markedStills.count : 0
        let clipsCount = appState.exportMovingClipsEnabled ? markingState.markedClips.count : 0
        let totalItems = max(1, stillsCount + clipsCount)
        var completedItems = 0

        // Export stills
        if stillsCount > 0 {
            let timestamps = markingState.markedStills.map { $0.timestamp }
            let reframeOffsets = markingState.markedStills.map { $0.reframeOffset }
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
            for (index, clip) in markingState.markedClips.enumerated() {
                await MainActor.run {
                    exportStatusMessage = "Exporting clip \(index + 1) of \(markingState.markedClips.count)..."
                }

                try await snippetProcessor.exportClipAndGIF(
                    from: videoURL,
                    startTime: clip.inPoint,
                    duration: clip.duration,
                    resolution: appState.gifResolution,
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

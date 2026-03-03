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

    private let videoProcessor = VideoProcessor()
    private let gifProcessor = GIFProcessor()
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
            }

            Divider()

            // Stills settings
            if stillCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Export stills", isOn: $appState.exportStillsEnabled)
                        .toggleStyle(.checkbox)

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
                            if appState.videoSize != .zero {
                                let w = Int(appState.videoSize.width * appState.stillSize.scale)
                                let h = Int(appState.videoSize.height * appState.stillSize.scale)
                                Text("\(w) x \(h)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 20)

                        Text("Color space: source video (sRGB / Rec. 709)")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        }
                        .padding(.leading, 20)
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
                    Toggle("4:5", isOn: $appState.export4x5)
                        .toggleStyle(.checkbox)
                    Toggle("9:16", isOn: $appState.export9x16)
                        .toggleStyle(.checkbox)
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
                .tint(.clipkitBlue)
            }

            // Export progress
            if isExporting {
                VStack(spacing: 6) {
                    ProgressView(value: exportProgress)
                        .progressViewStyle(.linear)
                        .tint(.clipkitBlue)
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
            .tint(.clipkitBlue)
            .controlSize(.large)
            .disabled(appState.saveURL == nil || isExporting || !appState.hasSelectedExportType)

            Label("Files are always added — never overwritten", systemImage: "plus.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 400)
        .interactiveDismissDisabled(isExporting)
    }

    private var gifSizeEstimate: String {
        let bytes = appState.gifResolution.estimatedSize(
            frameRate: appState.gifFrameRate,
            clipDuration: appState.clipDuration
        )
        let mb = Double(bytes) / 1_000_000.0
        if mb < 1.0 {
            return "~\(Int(mb * 1000)) KB per clip"
        } else {
            return "~\(String(format: "%.0f", mb)) MB per clip"
        }
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
        let totalItems = markingState.markedStills.count + markingState.markedClips.count
        var completedItems = 0

        // Export stills
        if appState.exportStillsEnabled && !markingState.markedStills.isEmpty {
            let timestamps = markingState.markedStills.map { $0.timestamp }
            await MainActor.run {
                exportStatusMessage = "Exporting stills..."
            }

            try await videoProcessor.extractStillsAtTimestamps(
                from: videoURL,
                timestamps: timestamps,
                to: outputDir,
                scale: appState.stillSize.scale,
                format: appState.stillFormat
            ) { progress, message in
                Task { @MainActor in
                    let stillsProgress = progress * Double(markingState.markedStills.count) / Double(totalItems)
                    exportProgress = stillsProgress
                    exportStatusMessage = message
                }
            }

            completedItems += markingState.markedStills.count
        }

        // Export clips (as both video AND GIF)
        for (index, clip) in markingState.markedClips.enumerated() {
            await MainActor.run {
                exportStatusMessage = "Exporting clip \(index + 1) of \(markingState.markedClips.count)..."
            }

            try await snippetProcessor.exportClipAndGIF(
                from: videoURL,
                startTime: clip.inPoint,
                duration: clip.duration,
                resolution: appState.gifResolution,
                format: appState.clipFormat,
                to: outputDir,
                export4x5: appState.export4x5,
                export9x16: appState.export9x16,
                presetName: appState.clipQuality.exportPreset
            )

            completedItems += 1
            await MainActor.run {
                exportProgress = Double(completedItems) / Double(totalItems)
            }
        }
    }

}

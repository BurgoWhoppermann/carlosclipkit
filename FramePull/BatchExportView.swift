import SwiftUI
import AVFoundation

// MARK: - Data Types

struct BatchVideoItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var isSelected: Bool = true
    var status: BatchItemStatus = .pending
}

enum BatchItemStatus: Equatable {
    case pending
    case detecting
    case generating
    case exporting
    case completed
    case failed(String)
}

// MARK: - View Model

class BatchExportViewModel: ObservableObject {
    @Published var videos: [BatchVideoItem] = []
    @Published var isRunning = false
    @Published var currentVideoName = ""
    @Published var currentPhase = ""
    @Published var videoProgress: Double = 0
    @Published var overallProgress: Double = 0
    @Published var completedCount = 0
    @Published var failedCount = 0

    private var batchTask: Task<Void, Never>?

    private let validExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "webm"])

    var folderName: String = ""

    func loadFolder(_ folderURL: URL) {
        folderName = folderURL.lastPathComponent
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return }

        videos = contents
            .filter { validExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { BatchVideoItem(url: $0, name: $0.deletingPathExtension().lastPathComponent) }
    }

    func cancel() {
        batchTask?.cancel()
    }

    func runBatch(appState: AppState, outputFolder: URL) {
        let selected = videos.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        isRunning = true
        completedCount = 0
        failedCount = 0

        let sceneDetector = SceneDetector()
        let videoProcessor = VideoProcessor()
        let snippetProcessor = VideoSnippetProcessor()

        // Snapshot settings from AppState on the main thread
        let threshold = appState.detectionThreshold
        let stillCount = appState.stillCount
        let stillPlacement = appState.stillPlacement
        let stillScale = appState.stillSize.scale
        let stillFormat = appState.stillFormat
        let clipCount = appState.clipCount
        let scenesPerClip = appState.scenesPerClip
        let allowOverlapping = appState.allowOverlapping
        let gifResolution = appState.gifResolution
        let gifFrameRate = appState.gifFrameRate
        let gifQuality = appState.gifQuality
        let exportGIF = appState.exportGIF
        let exportMP4 = appState.exportMP4
        let clipFormat = appState.clipFormat
        let clipPreset = appState.clipQuality.exportPreset
        let export4x5 = appState.export4x5
        let export9x16 = appState.export9x16
        let exportStills = appState.exportStillsEnabled
        let exportClips = appState.exportMovingClipsEnabled
        let lutDim: Int? = appState.lutEnabled ? appState.lutCubeDimension : nil
        let lutData: Data? = appState.lutCubeData
        let muteAudio = appState.muteAudio

        // Create one shared output folder: framepull_<foldername>
        let batchOutputFolder = ProcessingUtilities.ensureSubdirectory(outputFolder, path: "framepull_\(folderName)")

        let totalCount = selected.count
        let frameDuration = 1.0 / 25.0

        batchTask = Task {
            for (index, item) in selected.enumerated() {
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    currentVideoName = item.name
                    currentPhase = "Detecting scenes..."
                    videoProgress = 0
                    overallProgress = Double(index) / Double(totalCount)
                    updateStatus(for: item.id, to: .detecting)
                }

                do {
                    let asset = AVURLAsset(url: item.url)
                    let duration = try await asset.load(.duration)
                    let durationSeconds = CMTimeGetSeconds(duration)

                    // 1. Scene detection
                    let cuts = try await sceneDetector.detectSceneCuts(
                        from: asset,
                        threshold: threshold
                    ) { fraction in
                        Task { @MainActor in self.videoProgress = fraction * 0.3 }
                    }
                    let sceneRanges = sceneDetector.getSceneRanges(cuts: cuts, videoDuration: durationSeconds)

                    guard !Task.isCancelled else { break }

                    // 2. Generate stills
                    await MainActor.run {
                        currentPhase = "Generating markers..."
                        updateStatus(for: item.id, to: .generating)
                        videoProgress = 0.3
                    }

                    var stillTimestamps: [Double] = []
                    if exportStills {
                        switch stillPlacement {
                        case .spreadEvenly:
                            stillTimestamps = sceneDetector.selectTimestampsAcrossScenes(
                                sceneRanges: sceneRanges, count: stillCount)
                        case .perScene:
                            stillTimestamps = sceneDetector.selectTimestampsPerScene(
                                sceneRanges: sceneRanges, countPerScene: stillCount)
                        case .preferFaces:
                            // Fall back to per-scene in batch (face detection too slow)
                            stillTimestamps = sceneDetector.selectTimestampsPerScene(
                                sceneRanges: sceneRanges, countPerScene: 1)
                        }
                    }

                    // 3. Generate clips
                    var clipSpecs: [(start: Double, duration: Double)] = []
                    if exportClips {
                        clipSpecs = sceneDetector.selectRandomClips(
                            videoDuration: durationSeconds,
                            scenesPerClip: scenesPerClip,
                            count: clipCount,
                            allowOverlapping: allowOverlapping,
                            sceneRanges: sceneRanges
                        )
                    }

                    guard !Task.isCancelled else { break }

                    // 4. Export — all videos share the same output folder
                    await MainActor.run {
                        currentPhase = "Exporting..."
                        updateStatus(for: item.id, to: .exporting)
                        videoProgress = 0.4
                    }

                    // Export stills
                    if !stillTimestamps.isEmpty {
                        try await videoProcessor.extractStillsAtTimestamps(
                            from: item.url,
                            timestamps: stillTimestamps,
                            to: batchOutputFolder,
                            scale: stillScale,
                            format: stillFormat,
                            export4x5: export4x5,
                            export9x16: export9x16,
                            lutCubeDimension: lutDim,
                            lutCubeData: lutData
                        ) { progress, message in
                            Task { @MainActor in
                                self.videoProgress = 0.4 + progress * 0.3
                                self.currentPhase = message
                            }
                        }
                    }

                    // Export clips
                    let totalClips = clipSpecs.count
                    for (clipIndex, spec) in clipSpecs.enumerated() {
                        guard !Task.isCancelled else { break }

                        try await snippetProcessor.exportClipAndGIF(
                            from: item.url,
                            startTime: spec.start + frameDuration,
                            duration: spec.duration - 2 * frameDuration,
                            resolution: gifResolution,
                            gifFrameRate: gifFrameRate,
                            gifQuality: gifQuality,
                            exportGIF: exportGIF,
                            exportMP4: exportMP4,
                            format: clipFormat,
                            to: batchOutputFolder,
                            export4x5: export4x5,
                            export9x16: export9x16,
                            presetName: clipPreset,
                            lutCubeDimension: lutDim,
                            lutCubeData: lutData,
                            muteAudio: muteAudio
                        )

                        await MainActor.run {
                            let clipProgress = Double(clipIndex + 1) / Double(totalClips)
                            videoProgress = 0.7 + clipProgress * 0.3
                            currentPhase = "Exporting clip \(clipIndex + 1) of \(totalClips)..."
                        }
                    }

                    await MainActor.run {
                        updateStatus(for: item.id, to: .completed)
                        completedCount += 1
                    }

                } catch {
                    await MainActor.run {
                        updateStatus(for: item.id, to: .failed(error.localizedDescription))
                        failedCount += 1
                    }
                }
            }

            await MainActor.run {
                overallProgress = 1.0
                videoProgress = 1.0
                isRunning = false
                currentPhase = "Done"
            }
        }
    }

    private func updateStatus(for id: UUID, to status: BatchItemStatus) {
        if let index = videos.firstIndex(where: { $0.id == id }) {
            videos[index].status = status
        }
    }
}

// MARK: - Batch Process View

struct BatchExportView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = BatchExportViewModel()
    let folderURL: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Batch Process Folder")
                        .font(.title2.weight(.bold))
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption2)
                        Text(folderURL.lastPathComponent)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRunning)
            }

            Divider()

            // Select all / deselect all
            if !viewModel.isRunning {
                HStack(spacing: 12) {
                    Text("\(viewModel.videos.count) videos")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Select All") {
                        for i in viewModel.videos.indices { viewModel.videos[i].isSelected = true }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    Button("Deselect All") {
                        for i in viewModel.videos.indices { viewModel.videos[i].isSelected = false }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            // Video list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach($viewModel.videos) { $item in
                        HStack(spacing: 8) {
                            if !viewModel.isRunning {
                                Toggle("", isOn: $item.isSelected)
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                            }

                            Image(systemName: "film")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(item.url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            statusIcon(for: item.status)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                    }
                }
            }
            .frame(maxHeight: 200)

            Divider()

            // Settings summary
            settingsSummary

            // Output folder
            outputFolderRow

            // Progress
            if viewModel.isRunning {
                progressSection
            }

            // Done summary
            if !viewModel.isRunning && viewModel.overallProgress >= 1.0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("\(viewModel.completedCount) completed")
                        .font(.callout)
                    if viewModel.failedCount > 0 {
                        Text("· \(viewModel.failedCount) failed")
                            .font(.callout)
                            .foregroundColor(.red)
                    }
                }
            }

            Divider()

            // Action buttons
            HStack {
                if viewModel.isRunning {
                    Button("Cancel") { viewModel.cancel() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(viewModel.isRunning ? "Processing..." : "Process All") {
                    guard let output = appState.saveURL else { return }
                    viewModel.runBatch(appState: appState, outputFolder: output)
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullBlue)
                .disabled(viewModel.isRunning || appState.saveURL == nil || selectedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { viewModel.loadFolder(folderURL) }
    }

    private var selectedCount: Int {
        viewModel.videos.filter(\.isSelected).count
    }

    // MARK: - Subviews

    @ViewBuilder
    private func statusIcon(for status: BatchItemStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.4))
        case .detecting, .generating, .exporting:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        case .failed(let msg):
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
                .help(msg)
        }
    }

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings (from current session)")
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                if appState.exportStillsEnabled {
                    Label("\(appState.stillCount) stills · \(appState.stillFormat.rawValue) · \(appState.stillSize.rawValue)", systemImage: "photo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if appState.exportMovingClipsEnabled {
                    Label("\(appState.clipCount) clips · \(appState.scenesPerClip) scenes each", systemImage: "film")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if appState.lutEnabled {
                Label("LUT applied", systemImage: "paintpalette")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if appState.stillPlacement == .preferFaces {
                Text("Note: \"Prefer Faces\" uses Per Scene in batch mode")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }

    private var outputFolderRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Output:")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                if let url = appState.saveURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No output folder selected")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
                Button("Choose...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.message = "Select output folder for batch processing"
                    if panel.runModal() == .OK, let url = panel.url {
                        appState.saveURL = url
                    }
                }
                .controlSize(.small)
            }
            if appState.saveURL != nil {
                Text("→ framepull_\(folderURL.lastPathComponent)/stills, gifs, videos")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Processing: \(viewModel.currentVideoName) (\(viewModel.completedCount + viewModel.failedCount + 1) of \(selectedCount))")
                .font(.caption.weight(.medium))
            Text(viewModel.currentPhase)
                .font(.caption2)
                .foregroundColor(.secondary)

            ProgressView(value: viewModel.videoProgress)
                .tint(.framePullBlue)

            HStack {
                Text("Overall")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ProgressView(value: viewModel.overallProgress)
                    .tint(.framePullAmber)
            }
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

enum ExtractionMode: String, CaseIterable {
    case auto = "Auto"
    case manual = "Manual"
}

struct ContentView: View {
    private static let appIcon = NSApplication.shared.applicationIconImage.copy() as! NSImage

    @EnvironmentObject var appState: AppState
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var extractionComplete: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var extractionMode: ExtractionMode = .manual
    @State private var playerController: LoopingPlayerController?
    @State private var isSwitchingMode: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var refinementTask: Task<Void, Never>?
    @State private var videoPlayerHeight: CGFloat = 300
    @State private var videoDragStartHeight: CGFloat? = nil

    private let sceneDetector = SceneDetector()
    private let videoProcessor = VideoProcessor()

    private let supportedTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]

    var body: some View {
        VStack(spacing: 0) {
            // Mode toggle always visible at top
            modeToggle
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if let videoURL = appState.videoURL {
                if extractionMode == .manual {
                    ManualMarkingView(videoURL: videoURL, extractionMode: $extractionMode)
                } else {
                    videoLoadedView(videoURL: videoURL)
                }
            } else {
                dropZoneView
            }

            // Version footer (always visible)
            versionFooter
        }
        .padding()
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(isPresented: $showExportSheet) {
            if let videoURL = appState.videoURL {
                ExportSettingsView(
                    mode: extractionMode,
                    videoURL: videoURL,
                    stillCount: appState.stillCount,
                    clipCount: appState.exportMovingClipsEnabled ? calculateMovingClipRanges().count : 0,
                    onExportComplete: {
                        extractionComplete = true
                    },
                    onExportError: { message in
                        errorMessage = message
                        showError = true
                    }
                )
                .environmentObject(appState)
            }
        }
        .onChange(of: appState.videoURL) { newValue in
            // Clean up old player
            playerController?.pause()
            playerController = nil

            // Create new player if video is loaded
            if let url = newValue {
                playerController = LoopingPlayerController(url: url)
                // Auto-detect scenes for timeline preview
                detectScenesForTimeline(url: url)
            }
        }
        .onChange(of: extractionMode) { newValue in
            if newValue == .manual {
                // Pause player when switching to manual mode
                playerController?.pause()
            } else {
                // Switching to auto: cancel any in-progress detection from manual mode
                appState.cancelSceneDetection()
                // Sync manual edits back so they appear on auto timeline
                appState.syncManualToAutoPositions()
            }
        }
        .onChange(of: appState.stillCount) { newCount in
            if appState.scenesDetected, let url = appState.videoURL {
                let previousPositions = Set(appState.stillPositions)
                appState.adjustStillPositions(to: newCount, scenes: appState.detectedScenes)

                // Only refine newly added positions when "prefer faces" mode is active
                let newPositions = appState.stillPositions.filter { !previousPositions.contains($0) }
                guard !newPositions.isEmpty, appState.stillPlacement == .preferFaces else { return }

                refinementTask?.cancel()
                appState.isDetectingScenes = true
                appState.detectionStatusMessage = ""
                refinementTask = Task {
                    let refined = await videoProcessor.refineTimestamps(
                        from: url,
                        timestamps: newPositions,
                        videoDuration: appState.videoDuration,
                        progress: { fraction, message in
                            Task { @MainActor in
                                appState.detectionProgress = fraction
                                appState.detectionStatusMessage = message
                            }
                        }
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        // Replace the new unrefined positions with refined ones
                        var positions = appState.stillPositions.filter { previousPositions.contains($0) }
                        positions.append(contentsOf: refined.timestamps)
                        appState.stillPositions = positions.sorted()
                        appState.isDetectingScenes = false
                        appState.detectionStatusMessage = ""
                    }
                }
            }
        }
        .onChange(of: appState.stillPlacement) { _ in
            guard appState.scenesDetected, let url = appState.videoURL else { return }
            // Immediately redistribute stills with the new strategy
            appState.initializeStillPositions(from: appState.detectedScenes, count: appState.stillCount)
            // If switching to "prefer faces", also run face refinement
            if appState.stillPlacement == .preferFaces {
                applyFaceRefinement(url: url)
            }
        }
        .onChange(of: appState.clipDuration) { _ in
            if appState.scenesDetected {
                appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                    videoDuration: appState.videoDuration,
                    clipDuration: appState.clipDuration,
                    count: appState.clipCount,
                    avoidCrossingScenes: appState.avoidCrossingScenes,
                    allowOverlapping: appState.allowOverlapping,
                    sceneRanges: appState.detectedScenes
                )
            }
        }
        .onChange(of: appState.avoidCrossingScenes) { _ in
            if appState.scenesDetected {
                appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                    videoDuration: appState.videoDuration,
                    clipDuration: appState.clipDuration,
                    count: appState.clipCount,
                    avoidCrossingScenes: appState.avoidCrossingScenes,
                    allowOverlapping: appState.allowOverlapping,
                    sceneRanges: appState.detectedScenes
                )
            }
        }
        .onChange(of: appState.clipCount) { _ in
            if appState.scenesDetected {
                appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                    videoDuration: appState.videoDuration,
                    clipDuration: appState.clipDuration,
                    count: appState.clipCount,
                    avoidCrossingScenes: appState.avoidCrossingScenes,
                    allowOverlapping: appState.allowOverlapping,
                    sceneRanges: appState.detectedScenes
                )
            }
        }
        .onChange(of: appState.allowOverlapping) { _ in
            if appState.scenesDetected {
                appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                    videoDuration: appState.videoDuration,
                    clipDuration: appState.clipDuration,
                    count: appState.clipCount,
                    avoidCrossingScenes: appState.avoidCrossingScenes,
                    allowOverlapping: appState.allowOverlapping,
                    sceneRanges: appState.detectedScenes
                )
            }
        }
    }

    // MARK: - Drop Zone View
    private var dropZoneView: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .foregroundColor(isDropTargeted ? .clipkitBlue : .secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isDropTargeted ? Color.clipkitLightBlue : Color.clear)
                    )

                VStack(spacing: 12) {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .frame(width: 64, height: 64)

                    Text("Drop video here")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(isDropTargeted ? .clipkitBlue : .primary)

                    Text("or")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button("Import...") {
                        importVideo()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.clipkitBlue)

                    Text("MP4, MOV")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            Spacer()
        }
    }

    // MARK: - Video Loaded View
    private func videoLoadedView(videoURL: URL) -> some View {
        VStack(spacing: 0) {
            // Top section: video info + scene detection controls (fixed)
            VStack(spacing: 12) {
                videoHeader(videoURL: videoURL)
                sceneDetectionControls
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // Video player section (fixed)
            if let player = playerController {
                AutoVideoPlayerSection(player: player, clipRanges: appState.exportMovingClipsEnabled ? calculateMovingClipRanges() : [], videoHeight: $videoPlayerHeight)

                // Drag divider for resizing video player
                resizeDivider
            }

            // Scrollable content: export settings
            ScrollView {
                VStack(spacing: 20) {
                    // Export type toggle cards
                    exportToggleCards

                    // Detection settings (stills + clips, conditional)
                    detectionSettingsSection

                    Spacer().frame(height: 8)
                }
                .padding(.top, 12)
            }

            Divider()

            // Bottom: Export button (fixed)
            VStack(spacing: 8) {
                if extractionComplete {
                    completionView
                } else {
                    extractButton

                    Label("Files are always added — never overwritten", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Shared Resize Divider
    private var resizeDivider: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 40, height: 3)
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if videoDragStartHeight == nil {
                            videoDragStartHeight = videoPlayerHeight
                        }
                        videoPlayerHeight = max(120, min(600, (videoDragStartHeight ?? 300) + value.translation.height))
                    }
                    .onEnded { _ in
                        videoDragStartHeight = nil
                    }
            )
    }

    // MARK: - Scene Detection Controls (shared layout for above player)
    private var sceneDetectionControls: some View {
        VStack(spacing: 8) {
            // Cut sensitivity slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Cut Sensitivity")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.clipkitBlue)

                HStack(spacing: 4) {
                    Text("More")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    Slider(value: $appState.detectionThreshold, in: 0.10...0.70, step: 0.05)
                        .tint(.clipkitBlue)
                    Text("Fewer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .leading)
                }
            }

            HStack(spacing: 12) {
                Button(action: {
                    guard let url = appState.videoURL else { return }
                    appState.needsReanalysis = false
                    detectScenesForTimeline(url: url, force: true)
                }) {
                    HStack(spacing: 6) {
                        Label(
                            appState.scenesDetected ? "Re-detect Scenes" : "Detect Scenes",
                            systemImage: "wand.and.stars"
                        )
                        if appState.needsReanalysis {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.needsReanalysis ? .orange : .clipkitBlue)
                .controlSize(.regular)
                .disabled(appState.isDetectingScenes)

                Button(action: {
                    appState.resetAll()
                }) {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if appState.needsReanalysis {
                Label("Settings changed — re-detect to apply", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if appState.scenesDetected {
                Text("Re-detect to get different marker positions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // videoPlayerSection moved to AutoVideoPlayerSection struct

    // MARK: - Mode Toggle
    // MARK: - Version Footer
    private var versionFooter: some View {
        HStack {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    private var modeToggle: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                modeCard(mode: .manual, title: "Manual", subtitle: "Edit auto-generated markers or place them manually", icon: "hand.tap")
                modeCard(mode: .auto, title: "Auto", subtitle: "Detect scene cuts and place markers automatically", icon: "wand.and.stars")
            }
            .disabled(isSwitchingMode)

            if isSwitchingMode {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Switching...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func modeCard(mode: ExtractionMode, title: String, subtitle: String, icon: String) -> some View {
        let isSelected = extractionMode == mode
        return Button {
            guard extractionMode != mode else { return }
            isSwitchingMode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                extractionMode = mode
                isSwitchingMode = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .clipkitBlue : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isSelected ? .primary : .secondary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.clipkitLightBlue : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.clipkitBlue : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Video Header
    private func videoHeader(videoURL: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 32))
                .foregroundColor(.clipkitBlue)

            VStack(alignment: .leading, spacing: 2) {
                Text(videoURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button(action: clearVideo) {
                    Label("Remove", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.clipkitLightBlue)
        .cornerRadius(12)
    }

    // MARK: - Export Toggle Cards
    private var exportToggleCards: some View {
        HStack(spacing: 12) {
            exportToggleCard(
                title: "Stills",
                icon: "photo.on.rectangle",
                isOn: $appState.exportStillsEnabled
            )
            exportToggleCard(
                title: "Clips",
                icon: "film",
                isOn: $appState.exportMovingClipsEnabled
            )
        }
        .padding(.horizontal)
    }

    private func exportToggleCard(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isOn.wrappedValue ? .clipkitBlue : .secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
                Spacer()
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isOn.wrappedValue ? .clipkitBlue : .secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn.wrappedValue ? Color.clipkitLightBlue : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn.wrappedValue ? Color.clipkitBlue : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Export Settings (stills & clips)
    private var detectionSettingsSection: some View {
        VStack(spacing: 24) {
            if appState.exportStillsEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    // Section header with re-roll button
                    HStack {
                        Text("Still Detection")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.clipkitBlue)
                        Spacer()
                        Button(action: {
                            guard appState.scenesDetected, let url = appState.videoURL else { return }
                            reinitializeStillPositions(url: url)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "dice")
                                    .font(.system(size: 12))
                                Text("Re-generate random")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Re-roll: randomize still positions")
                        .disabled(!appState.scenesDetected)
                    }

                    HStack {
                        Text("Number of stills:")
                        TextField("", value: $appState.stillCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.center)
                        Stepper("", value: $appState.stillCount, in: 1...100)
                            .labelsHidden()
                        Spacer()
                    }

                    HStack {
                        Text("Placement:")
                        Picker("", selection: $appState.stillPlacement) {
                            ForEach(StillPlacement.allCases, id: \.self) { placement in
                                Text(placement.rawValue).tag(placement)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text(appState.stillPlacement.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if appState.exportMovingClipsEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    // Section header with re-roll button
                    HStack {
                        Text("Clip Detection")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.clipkitBlue)
                        Spacer()
                        Button(action: {
                            guard appState.scenesDetected else { return }
                            appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                                videoDuration: appState.videoDuration,
                                clipDuration: appState.clipDuration,
                                count: appState.clipCount,
                                avoidCrossingScenes: appState.avoidCrossingScenes,
                                allowOverlapping: appState.allowOverlapping,
                                sceneRanges: appState.detectedScenes
                            )
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "dice")
                                    .font(.system(size: 12))
                                Text("Re-generate random")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Re-roll: randomize clip positions")
                        .disabled(!appState.scenesDetected)
                    }

                    // Number of clips
                    HStack {
                        Text("Number of clips:")
                        TextField("", value: $appState.clipCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.center)
                        Stepper("", value: $appState.clipCount, in: 1...50)
                            .labelsHidden()
                        Spacer()
                    }

                    // Duration slider
                    HStack {
                        Text("Duration:")
                        Spacer()
                        Text("\(appState.clipDuration, specifier: "%.0f")s")
                            .foregroundColor(.secondary)
                            .frame(width: 40)
                        Slider(value: $appState.clipDuration, in: 1.0...30.0, step: 1.0)
                            .frame(width: 120)
                            .tint(.clipkitBlue)
                    }

                    // Clip count summary (live feedback)
                    if appState.scenesDetected {
                        let clips = calculateMovingClipRanges()
                        let totalDuration = clips.reduce(0.0) { $0 + $1.duration }
                        HStack(spacing: 4) {
                            Image(systemName: "film.stack")
                                .font(.caption)
                            Text("\(clips.count) clips · \(Int(totalDuration))s total")
                        }
                        .font(.caption)
                        .foregroundColor(.clipkitBlue)
                    }

                    // Checkboxes
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $appState.avoidCrossingScenes) {
                            Text("Avoid crossing scenes")
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: $appState.allowOverlapping) {
                            Text("Allow overlapping")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Action Area
    private var actionArea: some View {
        VStack(spacing: 12) {
            if extractionComplete {
                completionView
            } else {
                // Cut sensitivity + Detect / Reset
                if appState.videoURL != nil {
                    // Cut sensitivity slider
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cut Sensitivity")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.clipkitBlue)

                        HStack(spacing: 4) {
                            Text("More")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)
                            Slider(value: $appState.detectionThreshold, in: 0.10...0.70, step: 0.05)
                                .tint(.clipkitBlue)
                            Text("Fewer")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 36, alignment: .leading)
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            guard let url = appState.videoURL else { return }
                            appState.needsReanalysis = false
                            detectScenesForTimeline(url: url, force: true)
                        }) {
                            HStack(spacing: 6) {
                                Label(
                                    appState.scenesDetected ? "Re-detect Scenes" : "Detect Scenes",
                                    systemImage: "wand.and.stars"
                                )
                                if appState.needsReanalysis {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appState.needsReanalysis ? .orange : .clipkitBlue)
                        .controlSize(.large)
                        .disabled(appState.isDetectingScenes)

                        Button(action: {
                            appState.resetAll()
                        }) {
                            Label("Reset All", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    if appState.needsReanalysis {
                        Label("Settings changed — re-detect to apply", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else if appState.scenesDetected {
                        Text("Re-detect to get different marker positions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Label("Files are always added — never overwritten", systemImage: "plus.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                extractButton
            }
        }
        .padding(.horizontal)
    }

    private var completionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            Text("Extraction complete!")
                .font(.headline)
            HStack(spacing: 12) {
                Button("Open Folder") {
                    if let url = appState.saveURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Extract More") {
                    extractionComplete = false
                    appState.clearSceneCache()
                }
                Button("Done") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
                .tint(.clipkitBlue)
            }
        }
    }

    private var extractButton: some View {
        Button(action: { showExportSheet = true }) {
            Text("Export...")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.clipkitBlue)
        .controlSize(.large)
        .disabled(!appState.hasSelectedExportType)
    }

    // MARK: - Actions
    private func clearVideo() {
        playerController?.pause()
        playerController = nil
        appState.videoURL = nil
        appState.clearSceneCache()
        extractionComplete = false
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedTypes
        panel.message = "Select a video file to import"

        if panel.runModal() == .OK, let url = panel.url {
            appState.videoURL = url
            appState.clearSceneCache()
            extractionComplete = false
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard error == nil,
                  let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            // Validate it's a video file
            let fileExtension = url.pathExtension.lowercased()
            let validExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

            if validExtensions.contains(fileExtension) {
                DispatchQueue.main.async {
                    appState.videoURL = url
                    appState.clearSceneCache()
                    extractionComplete = false
                }
            }
        }

        return true
    }

    // MARK: - Timeline Helpers

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
        }
    }

    private func calculateMovingClipRanges() -> [(start: Double, duration: Double)] {
        // Always use cached overrides — never generate random clips during view body
        // (generating random in body causes different results on every SwiftUI redraw)
        return appState.clipRangeOverrides ?? []
    }

    private func reinitializeStillPositions(url: URL) {
        // Cancel any in-progress refinement
        refinementTask?.cancel()
        appState.isDetectingScenes = false

        // Re-roll: generate new positions based on current placement strategy
        appState.initializeStillPositions(from: appState.detectedScenes, count: appState.stillCount)

        guard appState.stillPlacement == .preferFaces else { return }

        applyFaceRefinement(url: url)
    }

    private func applyFaceRefinement(url: URL) {
        // Cancel any in-progress refinement
        refinementTask?.cancel()
        appState.isDetectingScenes = true
        appState.detectionStatusMessage = ""

        refinementTask = Task {
            let refined = await videoProcessor.refineTimestamps(
                from: url,
                timestamps: appState.stillPositions,
                videoDuration: appState.videoDuration,
                progress: { fraction, message in
                    Task { @MainActor in
                        appState.detectionProgress = fraction
                        appState.detectionStatusMessage = message
                    }
                }
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.stillPositions = refined.timestamps
                appState.isDetectingScenes = false
                appState.detectionStatusMessage = ""
            }
        }
    }

    private func detectScenesForTimeline(url: URL, force: Bool = false) {
        // Skip if scenes are already detected (unless forced)
        guard force || !appState.scenesDetected else { return }

        // Cancel any in-progress refinement task first
        refinementTask?.cancel()
        refinementTask = nil

        // Cancel any in-progress detection before starting a new one
        appState.cancelSceneDetection()

        if force {
            // Soft reset: only clear scene detection data, preserve user stills/clips
            appState.detectedScenes = []
            appState.scenesDetected = false
            appState.markingState.detectedCuts = []
        }

        appState.isDetectingScenes = true
        appState.detectionProgress = 0
        appState.detectionStatusMessage = ""

        appState.sceneDetectionTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)

                try Task.checkCancellation()

                let cuts = try await sceneDetector.detectSceneCuts(
                    from: asset,
                    threshold: appState.detectionThreshold,
                    progress: { fraction in
                        Task { @MainActor in
                            appState.detectionProgress = fraction
                        }
                    }
                )

                try Task.checkCancellation()

                let scenes = sceneDetector.getSceneRanges(cuts: cuts, videoDuration: durationSeconds)

                await MainActor.run {
                    appState.detectedScenes = scenes
                    appState.videoDuration = durationSeconds
                    appState.scenesDetected = true

                    // Cache clip ranges so they don't regenerate on every SwiftUI redraw
                    appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                        videoDuration: durationSeconds,
                        clipDuration: appState.clipDuration,
                        count: appState.clipCount,
                        avoidCrossingScenes: appState.avoidCrossingScenes,
                        allowOverlapping: appState.allowOverlapping,
                        sceneRanges: scenes
                    )
                }

                try Task.checkCancellation()

                // Distribute stills across scenes
                await MainActor.run {
                    appState.initializeStillPositions(from: scenes, count: appState.stillCount)
                }

                // Refine still positions if "prefer faces" placement is active
                if appState.stillPlacement == .preferFaces {
                    try Task.checkCancellation()
                    let currentPositions = await MainActor.run { appState.stillPositions }
                    let refined = await videoProcessor.refineTimestamps(
                        from: url,
                        timestamps: currentPositions,
                        videoDuration: durationSeconds,
                        progress: { fraction, message in
                            Task { @MainActor in
                                appState.detectionProgress = fraction
                                appState.detectionStatusMessage = message
                            }
                        }
                    )
                    try Task.checkCancellation()
                    await MainActor.run {
                        appState.stillPositions = refined.timestamps
                    }
                }

                await MainActor.run {
                    appState.isDetectingScenes = false
                    appState.detectionProgress = 0
                    appState.detectionStatusMessage = ""
                }
            } catch is CancellationError {
                // Task was cancelled — exit silently
                return
            } catch {
                await MainActor.run {
                    appState.isDetectingScenes = false
                    appState.detectionProgress = 0
                    appState.detectionStatusMessage = ""
                    appState.scenesDetected = true
                    if let player = playerController {
                        appState.detectedScenes = [(start: 0.0, end: player.duration)]
                        appState.videoDuration = player.duration
                        appState.initializeStillPositions(from: appState.detectedScenes, count: appState.stillCount)
                        appState.clipRangeOverrides = sceneDetector.selectRandomClips(
                            videoDuration: player.duration,
                            clipDuration: appState.clipDuration,
                            count: appState.clipCount,
                            avoidCrossingScenes: appState.avoidCrossingScenes,
                            allowOverlapping: appState.allowOverlapping,
                            sceneRanges: appState.detectedScenes
                        )
                    }
                }
            }
        }
    }

}

// MARK: - Auto Video Player Section
struct AutoVideoPlayerSection: View {
    @ObservedObject var player: LoopingPlayerController
    @EnvironmentObject var appState: AppState
    let clipRanges: [(start: Double, duration: Double)]
    @Binding var videoHeight: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            VideoPlayerRepresentable(
                player: player.player,
                onKeyPress: { _ in },
                onClick: { player.togglePlayPause() }
            )
            .aspectRatio(player.aspectRatio, contentMode: .fit)
            .frame(height: videoHeight)
            .background(Color.black)
            .cornerRadius(8)
            .clipped()

            // Basic playback controls
            HStack(spacing: 12) {
                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Play/Pause")

                Button(action: { player.toggleMute() }) {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(player.isMuted ? .red : nil)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help(player.isMuted ? "Unmute" : "Mute")

                Spacer()

                Text("\(player.formattedCurrentTime) / \(player.formattedDuration)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            // Extraction timeline preview (only show when duration is loaded)
            if appState.scenesDetected && player.duration > 0 {
                VStack(spacing: 4) {
                    ExtractionTimelineView(
                        player: player,
                        scenes: appState.detectedScenes,
                        sceneCuts: appState.sceneCutTimestamps,
                        stillPositions: appState.exportStillsEnabled ? appState.stillPositions : [],
                        videoDuration: appState.videoDuration,
                        clipRanges: appState.exportMovingClipsEnabled ? clipRanges : []
                    )

                    // Timeline legend
                    HStack(spacing: 12) {
                        if !appState.detectedScenes.isEmpty && appState.detectedScenes.count > 1 {
                            legendItem(color: .secondary.opacity(0.5), label: "Cuts")
                        }
                        if appState.exportStillsEnabled {
                            legendItem(color: .orange, label: "Stills")
                        }
                        if appState.exportMovingClipsEnabled {
                            legendItem(color: .clipkitBlue, label: "Clips")
                        }
                        Spacer()
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } else if appState.isDetectingScenes {
                VStack(spacing: 4) {
                    ProgressView(value: appState.detectionProgress)
                        .tint(.clipkitBlue)
                    Text(appState.detectionStatusMessage.isEmpty
                         ? "Detecting scene cuts… \(Int(appState.detectionProgress * 100))%"
                         : appState.detectionStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .onChange(of: player.videoSize) { newSize in
            appState.videoSize = newSize
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
        }
    }
}

// MARK: - Extraction Timeline View (read-only)
struct ExtractionTimelineView: View {
    @ObservedObject var player: LoopingPlayerController
    let scenes: [(start: Double, end: Double)]
    let sceneCuts: [Double]

    // Still positions (read-only in auto mode)
    let stillPositions: [Double]
    let videoDuration: Double

    // Moving clip ranges
    let clipRanges: [(start: Double, duration: Double)]

    // Selected marker for snap behavior
    @State private var selectedMarkerIndex: Int? = nil
    @State private var isDragging: Bool = false
    private let snapThresholdPx: CGFloat = 12

    // Marker colors
    private let stillColor = Color.orange
    private let clipColor = Color.clipkitBlue
    private let cutColor = Color.secondary.opacity(0.5)
    private let playheadColor = Color.clipkitBlue

    // Computed properties from player
    private var duration: Double { player.duration }
    private var currentTime: Double { player.currentTime }

    private func onSeek(_ time: Double) {
        player.seek(to: time)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .topLeading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 40)
                    .padding(.top, 2)

                // Scene cut markers (vertical lines)
                ForEach(sceneCutXPositions(width: width), id: \.self) { x in
                    Rectangle()
                        .fill(cutColor)
                        .frame(width: 1, height: 40)
                        .position(x: x, y: 22)
                }

                // Moving clip ranges (blue rectangles)
                ForEach(Array(clipRanges.enumerated()), id: \.offset) { _, range in
                    let xStart = xPosition(for: range.start, width: width)
                    let rangeWidth = max(4, (range.duration / duration) * width)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(clipColor.opacity(0.4))
                        .frame(width: rangeWidth, height: 24)
                        .position(x: xStart + rangeWidth / 2, y: 22)
                }

                // Still markers (orange circles, with snap-selection highlight)
                ForEach(Array(stillPositions.enumerated()), id: \.offset) { index, time in
                    let x = xPosition(for: time, width: width)
                    let isSelected = selectedMarkerIndex == index
                    Circle()
                        .fill(stillColor)
                        .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
                                .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                        )
                        .shadow(color: isSelected ? stillColor.opacity(0.8) : .clear, radius: 6)
                        .position(x: x, y: 22)
                        .zIndex(isSelected ? 20 : 10)
                        .animation(.easeInOut(duration: 0.15), value: isSelected)
                }

                // Playhead (current position) - highest z-index
                let playheadX = xPosition(for: currentTime, width: width)
                RoundedRectangle(cornerRadius: 1)
                    .fill(playheadColor)
                    .frame(width: 3, height: 48)
                    .position(x: playheadX, y: 22)
                    .zIndex(200)
            }
            .frame(height: 44)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = value.location.x
                        let movement = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))

                        // Once dragging is detected, stay in drag mode for this gesture
                        if movement > 3 {
                            isDragging = true
                        }

                        if !isDragging, let snapIndex = nearestStillIndex(at: x, width: width) {
                            // Click near a marker: snap to it
                            selectedMarkerIndex = snapIndex
                            onSeek(stillPositions[snapIndex])
                        } else {
                            // Dragging: free-form seeking, no snapping
                            selectedMarkerIndex = nil
                            let newTime = (x / width) * duration
                            let clampedTime = max(0, min(duration, newTime))
                            onSeek(clampedTime)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 44)
    }

    private func nearestStillIndex(at xPosition: CGFloat, width: CGFloat) -> Int? {
        guard !stillPositions.isEmpty, width > 0 else { return nil }
        var bestIndex: Int? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for (index, time) in stillPositions.enumerated() {
            let markerX = self.xPosition(for: time, width: width)
            let distance = abs(xPosition - markerX)
            if distance < snapThresholdPx && distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat((time / duration) * Double(width))
    }

    private func sceneCutXPositions(width: CGFloat) -> [CGFloat] {
        var cuts: [CGFloat] = []
        for (index, scene) in scenes.enumerated() {
            if index < scenes.count - 1 {
                cuts.append(xPosition(for: scene.end, width: width))
            }
        }
        return cuts
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}

import SwiftUI
import AVFoundation

struct ManualMarkingView: View {
    let videoURL: URL
    @Binding var extractionMode: ExtractionMode

    @EnvironmentObject var appState: AppState
    @StateObject private var playerController: LoopingPlayerController

    private var markingState: MarkingState { appState.markingState }

    @State private var showExportComplete = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isDetectingScenes = false
    @State private var showExportSheet = false
    @State private var lastPressedKey: String? = nil
    @State private var videoPlayerHeight: CGFloat = 300
    @State private var videoDragStartHeight: CGFloat? = nil

    private let sceneDetector = SceneDetector()

    init(videoURL: URL, extractionMode: Binding<ExtractionMode>) {
        self.videoURL = videoURL
        self._extractionMode = extractionMode
        _playerController = StateObject(wrappedValue: LoopingPlayerController(url: videoURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top: Scene detection controls (above player)
            manualSceneDetectionControls
                .padding(.horizontal)
                .padding(.bottom, 8)

            // Video Player
            videoPlayerSection

            // Controls bar
            controlsBar

            // Pending clip indicator
            if markingState.pendingInPoint != nil {
                pendingClipIndicator
            }

            Divider()

            // Marked items list
            ScrollView {
                VStack(spacing: 16) {
                    stillsSection
                    clipsSection
                }
                .padding()
            }

            Divider()

            // Bottom: Export button only
            VStack(spacing: 8) {
                Button("Export...") {
                    showExportSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.clipkitBlue)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!markingState.hasMarkedItems)
            }
            .padding()
        }
        .onAppear {
            // Reuse cached scene cuts from appState if available
            if markingState.detectedCuts.isEmpty && !appState.sceneCutTimestamps.isEmpty {
                markingState.detectedCuts = appState.sceneCutTimestamps
            } else if markingState.detectedCuts.isEmpty {
                detectScenes()
            }

            // Transfer auto mode positions into editable manual marks
            transferAutoMarksIfNeeded()

            // Don't autoplay — user can press Space or click to start
            appState.videoSize = playerController.videoSize
        }
        .onChange(of: playerController.videoSize) { newSize in
            appState.videoSize = newSize
        }
        .onDisappear {
            playerController.pause()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .alert("Export Complete", isPresented: $showExportComplete) {
            Button("Open Folder") {
                if let url = appState.saveURL {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("All marked items have been exported successfully.")
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSettingsView(
                mode: .manual,
                videoURL: videoURL,
                stillCount: markingState.markedStills.count,
                clipCount: markingState.markedClips.count,
                onExportComplete: {
                    showExportComplete = true
                },
                onExportError: { message in
                    errorMessage = message
                    showError = true
                }
            )
            .environmentObject(appState)
        }
    }

    // MARK: - Video Player Section

    private var videoPlayerSection: some View {
        VStack(spacing: 0) {
            VideoPlayerRepresentable(
                player: playerController.player,
                onKeyPress: handleKeyPress,
                onClick: { playerController.togglePlayPause() }
            )
            .aspectRatio(playerController.aspectRatio, contentMode: .fit)
            .frame(height: videoPlayerHeight)
            .background(Color.black)
            .clipped()

            // Drag divider for resizing video player
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
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        VStack(spacing: 8) {
            // Speed controls and time display
            HStack {
                // Play/Pause and Mute buttons
                HStack(spacing: 4) {
                    Button(action: { playerController.togglePlayPause() }) {
                        Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help("Play/Pause (Space)")

                    Button(action: { playerController.toggleMute() }) {
                        Image(systemName: playerController.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(playerController.isMuted ? .red : nil)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help(playerController.isMuted ? "Unmute" : "Mute")
                }

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                // Speed buttons
                HStack(spacing: 4) {
                    ForEach(MarkingState.PlaybackSpeed.allCases, id: \.self) { speed in
                        Button(speed.displayName) {
                            markingState.playbackSpeed = speed
                            playerController.setRate(Float(speed.rawValue))
                        }
                        .buttonStyle(.bordered)
                        .tint(markingState.playbackSpeed == speed ? .clipkitBlue : .secondary)
                        .controlSize(.small)
                    }
                }

                Spacer()

                // Scene cuts count
                if isDetectingScenes {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Detecting cuts...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if markingState.detectedCutsCount > 0 {
                    Image(systemName: "scissors")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(markingState.detectedCutsCount) cuts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                Text("\(playerController.formattedCurrentTime) / \(playerController.formattedDuration)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                // Action keycaps — clickable + keyboard-responsive
                HStack(spacing: 6) {
                    Button(action: { handleKeyPress(.still) }) {
                        keyCap("S", glowColor: .orange)
                    }
                    .buttonStyle(.plain)
                    .help("Snap Still (S)")

                    Button(action: { handleKeyPress(.inPoint) }) {
                        keyCap("I", glowColor: markingState.pendingInPoint != nil ? .orange : .green)
                    }
                    .buttonStyle(.plain)
                    .help("Mark IN point (I)")

                    Button(action: { handleKeyPress(.outPoint) }) {
                        keyCap("O", glowColor: .green)
                    }
                    .buttonStyle(.plain)
                    .disabled(markingState.pendingInPoint == nil)
                    .help("Mark OUT point (O)")

                    Text("Use your keyboard!")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
            }

            // Timeline with markers
            ManualTimelineView(
                duration: playerController.duration,
                currentTime: playerController.currentTime,
                onSeek: { playerController.seek(to: $0) },
                sceneCuts: markingState.detectedCuts,
                markedStills: markingState.markedStills,
                markedClips: markingState.markedClips,
                pendingInPoint: markingState.pendingInPoint,
                onStillPositionChanged: { id, newTime in
                    markingState.updateStillPosition(id: id, to: newTime)
                },
                onStillRemoved: { id in
                    markingState.removeStill(id: id)
                },
                onClipRangeChanged: { id, newIn, newOut in
                    markingState.updateClipRange(id: id, inPoint: newIn, outPoint: newOut, snapEnabled: appState.snapToSceneCuts)
                }
            )

            // Legend with reset button
            HStack(spacing: 12) {
                if !markingState.detectedCuts.isEmpty {
                    legendItem(color: .secondary.opacity(0.5), label: "Cuts")
                }
                if !markingState.markedStills.isEmpty {
                    legendItem(color: .orange, label: "Stills")
                }
                if !markingState.markedClips.isEmpty || markingState.pendingInPoint != nil {
                    legendItem(color: .green, label: "Clips")
                }
                Spacer()

                // Snap to cuts toggle
                if !markingState.detectedCuts.isEmpty {
                    Toggle(isOn: $appState.snapToSceneCuts) {
                        Label("Snap to cuts", systemImage: "magnet")
                            .font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }

                // Undo button
                if markingState.canUndo {
                    Button(action: { markingState.undo() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Undo (Cmd+Z)")
                }

                // Reset button (when items are marked)
                if markingState.hasMarkedItems {
                    Button(action: { markingState.clearAll() }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset timeline")
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
        }
    }

    private func keyCap(_ key: String, glowColor: Color) -> some View {
        let isActive = lastPressedKey == key
        return Text(key)
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundColor(isActive ? .white : .secondary)
            .frame(width: 30, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? glowColor : Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? glowColor.opacity(0.8) : Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: isActive ? glowColor.opacity(0.7) : .clear, radius: 6)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isActive)
    }

    // MARK: - Pending Clip Indicator

    private var pendingClipIndicator: some View {
        HStack {
            Image(systemName: "arrow.right.circle")
                .foregroundColor(.orange)
            Text("IN: \(markingState.formattedPendingInPoint ?? "") -> ?")
                .font(.system(.body, design: .monospaced))

            Spacer()
            Button("Cancel (Esc)") {
                markingState.cancelPendingInPoint()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Stills Section

    private var stillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STILLS (\(markingState.markedStills.count))")
                .font(.headline)
                .foregroundColor(.clipkitBlue)

            if markingState.markedStills.isEmpty {
                Text("Press S to snap stills")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(markingState.markedStills) { still in
                    HStack {
                        Text(still.formattedTime)
                            .font(.system(.body, design: .monospaced))

                        Spacer()

                        Button(action: { playerController.seek(to: still.timestamp) }) {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.clipkitBlue)
                        .help("Seek to this time")

                        Button(action: { markingState.removeStill(id: still.id) }) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Remove")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Clips Section

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CLIPS (\(markingState.markedClips.count))")
                    .font(.headline)
                    .foregroundColor(.clipkitBlue)
                Text("-> exports as clip + GIF")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if markingState.markedClips.isEmpty {
                Text("Press I to mark IN, O to mark OUT")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(markingState.markedClips) { clip in
                    HStack {
                        Text("\(clip.formattedInPoint) - \(clip.formattedOutPoint)")
                            .font(.system(.body, design: .monospaced))

                        Text("(\(clip.formattedDuration))")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button(action: { playerController.seek(to: clip.inPoint) }) {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.clipkitBlue)
                        .help("Seek to IN point")

                        Button(action: { markingState.removeClip(id: clip.id) }) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Remove")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Scene Detection Controls (above player)
    private var manualSceneDetectionControls: some View {
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
                Button(action: { detectScenes() }) {
                    Label(
                        appState.scenesDetected ? "Re-detect Scenes" : "Detect Scenes",
                        systemImage: "wand.and.stars"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.clipkitBlue)
                .controlSize(.regular)
                .disabled(isDetectingScenes)

                Button(action: {
                    markingState.clearAll()
                    appState.resetAll()
                }) {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Bottom Actions (legacy, no longer used from body)

    private var bottomActions: some View {
        VStack(spacing: 12) {
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

            // Detect / Reset row (matches auto mode)
            HStack(spacing: 12) {
                Button(action: { detectScenes() }) {
                    Label(
                        appState.scenesDetected ? "Re-detect Scenes" : "Detect Scenes",
                        systemImage: "wand.and.stars"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.clipkitBlue)
                .controlSize(.large)
                .disabled(isDetectingScenes)

                Button(action: {
                    markingState.clearAll()
                    appState.resetAll()
                }) {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Export button
            Button("Export...") {
                showExportSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.clipkitBlue)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!markingState.hasMarkedItems)
        }
        .padding()
    }

    // MARK: - Actions

    private func handleKeyPress(_ key: VideoPlayerRepresentable.KeyPress) {
        switch key {
        case .still:
            markingState.addStill(at: playerController.currentTime)
            flashKey("S")

        case .inPoint:
            markingState.setInPoint(at: playerController.currentTime, snapEnabled: appState.snapToSceneCuts)
            flashKey("I")

        case .outPoint:
            markingState.setOutPoint(at: playerController.currentTime, snapEnabled: appState.snapToSceneCuts)
            flashKey("O")

        case .playPause:
            playerController.togglePlayPause()

        case .cancelIn:
            markingState.cancelPendingInPoint()

        case .undo:
            markingState.undo()
        }
    }

    private func flashKey(_ key: String) {
        lastPressedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if lastPressedKey == key {
                lastPressedKey = nil
            }
        }
    }

    private func transferAutoMarksIfNeeded() {
        guard !markingState.hasMarkedItems else { return }

        // Transfer still positions as editable MarkedStill entries
        if !appState.stillPositions.isEmpty {
            for timestamp in appState.stillPositions {
                markingState.addStill(at: timestamp)
            }
        }

        // Transfer clip/GIF ranges as editable MarkedClip entries (use cached ranges)
        if let ranges = appState.clipRangeOverrides, !ranges.isEmpty {
            for range in ranges {
                markingState.markedClips.append(
                    MarkedClip(inPoint: range.start, outPoint: range.start + range.duration)
                )
            }
            markingState.markedClips.sort { $0.inPoint < $1.inPoint }
        }

        // Clear undo stack — transferred marks shouldn't be undoable
        markingState.undoStack.removeAll()
    }

    private func detectScenes() {
        // Cancel any in-progress detection
        appState.cancelSceneDetection()
        isDetectingScenes = true
        appState.isDetectingScenes = true
        appState.detectionProgress = 0

        appState.sceneDetectionTask = Task {
            let asset = AVURLAsset(url: videoURL)
            do {
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

                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                let scenes = sceneDetector.getSceneRanges(cuts: cuts, videoDuration: durationSeconds)
                await MainActor.run {
                    markingState.detectedCuts = cuts
                    // Cache results in appState so auto mode can reuse them
                    appState.detectedScenes = scenes
                    appState.videoDuration = durationSeconds
                    appState.scenesDetected = true
                    isDetectingScenes = false
                    appState.isDetectingScenes = false
                    appState.detectionProgress = 0
                }
            } catch is CancellationError {
                // Task was cancelled — exit silently
                return
            } catch {
                await MainActor.run {
                    isDetectingScenes = false
                    appState.isDetectingScenes = false
                    appState.detectionProgress = 0
                }
            }
        }
    }

}

// MARK: - Manual Timeline View
struct ManualTimelineView: View {
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void
    let sceneCuts: [Double]
    let markedStills: [MarkedStill]
    let markedClips: [MarkedClip]
    let pendingInPoint: Double?
    let onStillPositionChanged: (UUID, Double) -> Void
    let onStillRemoved: (UUID) -> Void
    let onClipRangeChanged: (UUID, Double?, Double?) -> Void

    // Drag state (separate offsets prevent clip operations from leaking into still drags)
    @State private var draggingStillId: UUID? = nil
    @State private var draggingClipId: UUID? = nil
    @State private var draggingClipEdge: ClipEdge? = nil
    @State private var stillDragOffset: CGFloat = 0
    @State private var clipDragOffset: CGFloat = 0

    // Hover state
    @State private var hoveredStillId: UUID? = nil
    @State private var hoveredClipEdge: (UUID, ClipEdge)? = nil

    enum ClipEdge {
        case inPoint
        case outPoint
    }

    // Colors
    private let stillColor = Color.orange
    private let clipColor = Color.green
    private let cutColor = Color.secondary.opacity(0.5)
    private let playheadColor = Color.clipkitBlue
    private let pendingColor = Color.orange

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
                ForEach(sceneCuts, id: \.self) { cut in
                    let x = xPosition(for: cut, width: width)
                    Rectangle()
                        .fill(cutColor)
                        .frame(width: 1, height: 40)
                        .position(x: x, y: 22)
                }

                // Marked clips (green ranges with draggable edges)
                ForEach(markedClips) { clip in
                    let inX = xPosition(for: clip.inPoint, width: width)
                    let outX = xPosition(for: clip.outPoint, width: width)
                    let isDragging = draggingClipId == clip.id

                    // Compute display positions that follow the drag handle
                    let displayInX = isDragging && draggingClipEdge == .inPoint ? inX + clipDragOffset : inX
                    let displayOutX = isDragging && draggingClipEdge == .outPoint ? outX + clipDragOffset : outX
                    let clipWidth = max(4, displayOutX - displayInX)

                    // Clip range background — follows drag
                    RoundedRectangle(cornerRadius: 2)
                        .fill(clipColor.opacity(isDragging ? 0.6 : 0.4))
                        .frame(width: clipWidth, height: 24)
                        .position(x: displayInX + clipWidth / 2, y: 22)

                    // In point handle (left edge)
                    let isInHovered = hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .inPoint
                    let inHandleWidth: CGFloat = isInHovered ? 8 : 6
                    let inHandleHeight: CGFloat = isInHovered ? 34 : 30
                    RoundedRectangle(cornerRadius: 2)
                        .fill(clipColor)
                        .frame(width: inHandleWidth, height: inHandleHeight)
                        .shadow(color: isInHovered ? clipColor.opacity(0.6) : .clear, radius: 4)
                        .animation(.easeInOut(duration: 0.15), value: isInHovered)
                        .frame(width: 20, height: 44)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard draggingClipId == nil else { return }
                            if hovering {
                                hoveredClipEdge = (clip.id, .inPoint)
                                NSCursor.resizeLeftRight.push()
                            } else {
                                if hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .inPoint {
                                    hoveredClipEdge = nil
                                }
                                NSCursor.pop()
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    draggingClipId = clip.id
                                    draggingClipEdge = .inPoint
                                    clipDragOffset = value.location.x - inX
                                    let newTime = (Double(max(0, min(width, value.location.x))) / Double(width)) * duration
                                    onSeek(max(0, min(duration, newTime)))
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    let newTime = (Double(clampedX) / Double(width)) * duration
                                    onClipRangeChanged(clip.id, max(0, newTime), nil)
                                    draggingClipId = nil
                                    draggingClipEdge = nil
                                    clipDragOffset = 0
                                }
                        )
                        .position(x: displayInX, y: 22)
                        .zIndex(isDragging && draggingClipEdge == .inPoint ? 50 : 5)

                    // Out point handle (right edge)
                    let isOutHovered = hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .outPoint
                    let outHandleWidth: CGFloat = isOutHovered ? 8 : 6
                    let outHandleHeight: CGFloat = isOutHovered ? 34 : 30
                    RoundedRectangle(cornerRadius: 2)
                        .fill(clipColor)
                        .frame(width: outHandleWidth, height: outHandleHeight)
                        .shadow(color: isOutHovered ? clipColor.opacity(0.6) : .clear, radius: 4)
                        .animation(.easeInOut(duration: 0.15), value: isOutHovered)
                        .frame(width: 20, height: 44)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard draggingClipId == nil else { return }
                            if hovering {
                                hoveredClipEdge = (clip.id, .outPoint)
                                NSCursor.resizeLeftRight.push()
                            } else {
                                if hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .outPoint {
                                    hoveredClipEdge = nil
                                }
                                NSCursor.pop()
                            }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    draggingClipId = clip.id
                                    draggingClipEdge = .outPoint
                                    clipDragOffset = value.location.x - outX
                                    let newTime = (Double(max(0, min(width, value.location.x))) / Double(width)) * duration
                                    onSeek(max(0, min(duration, newTime)))
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    let newTime = (Double(clampedX) / Double(width)) * duration
                                    onClipRangeChanged(clip.id, nil, min(duration, newTime))
                                    draggingClipId = nil
                                    draggingClipEdge = nil
                                    clipDragOffset = 0
                                }
                        )
                        .position(x: displayOutX, y: 22)
                        .zIndex(isDragging && draggingClipEdge == .outPoint ? 50 : 5)
                }

                // Pending IN point (orange dashed line)
                if let pendingIn = pendingInPoint {
                    let x = xPosition(for: pendingIn, width: width)
                    Rectangle()
                        .fill(pendingColor)
                        .frame(width: 3, height: 36)
                        .position(x: x, y: 22)
                        .zIndex(15)
                }

                // Still markers (orange dots - draggable)
                ForEach(markedStills) { still in
                    let baseX = xPosition(for: still.timestamp, width: width)
                    let isDragging = draggingStillId == still.id
                    let isHovered = hoveredStillId == still.id
                    let currentX = isDragging ? baseX + stillDragOffset : baseX
                    let size: CGFloat = isDragging ? 14 : (isHovered ? 12 : 10)

                    Circle()
                        .fill(stillColor)
                        .frame(width: size, height: size)
                        .shadow(color: (isDragging || isHovered) ? stillColor.opacity(0.6) : .clear, radius: 4)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard draggingStillId == nil else { return }
                            if hovering {
                                hoveredStillId = still.id
                                NSCursor.openHand.push()
                            } else {
                                if hoveredStillId == still.id { hoveredStillId = nil }
                                NSCursor.pop()
                            }
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    onStillRemoved(still.id)
                                }
                        )
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    if draggingStillId != still.id {
                                        NSCursor.closedHand.push()
                                    }
                                    draggingStillId = still.id
                                    stillDragOffset = value.location.x - baseX
                                    let newTime = (Double(max(0, min(width, value.location.x))) / Double(width)) * duration
                                    onSeek(max(0, min(duration, newTime)))
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    let newTime = (Double(clampedX) / Double(width)) * duration
                                    onStillPositionChanged(still.id, max(0, min(duration, newTime)))
                                    draggingStillId = nil
                                    stillDragOffset = 0
                                    NSCursor.pop()
                                }
                        )
                        .position(x: currentX, y: 22)
                        .zIndex(isDragging ? 100 : (isHovered ? 50 : 10))
                }

                // Playhead (current position) - highest z-index
                let playheadX = xPosition(for: currentTime, width: width)
                RoundedRectangle(cornerRadius: 1)
                    .fill(playheadColor)
                    .frame(width: 3, height: 48)
                    .position(x: playheadX, y: 22)
                    .zIndex(200)
            }
            .coordinateSpace(name: "timeline")
            .frame(height: 44)
            .clipped()
            .contentShape(Rectangle())
            .onHover { isHovering in
                if !isHovering && draggingStillId == nil && draggingClipId == nil {
                    hoveredStillId = nil
                    hoveredClipEdge = nil
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        guard draggingStillId == nil && draggingClipId == nil else { return }
                        let newTime = (Double(value.location.x) / Double(width)) * duration
                        onSeek(max(0, min(duration, newTime)))
                    }
            )
        }
        .frame(height: 44)
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat((time / duration) * Double(width))
    }
}

import SwiftUI
import AVFoundation

struct ManualMarkingView: View {
    let videoURL: URL

    @EnvironmentObject var appState: AppState
    @StateObject private var playerController: LoopingPlayerController

    private var markingState: MarkingState { appState.markingState }

    /// When no scenes are detected, treat the entire video as one scene so auto-generate works
    private var effectiveScenes: [(start: Double, end: Double)] {
        appState.detectedScenes.isEmpty
            ? [(start: 0, end: appState.videoDuration)]
            : appState.detectedScenes
    }

    @State private var showExportComplete = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isDetectingScenes = false
    @State private var showExportSheet = false
    @State private var showAnalysisDialog = false
    @State private var lastPressedKey: String? = nil
    @State private var videoPlayerHeight: CGFloat = 300
    @State private var videoDragStartHeight: CGFloat? = nil
    @State private var showVolumeSlider = false
    @State private var showCutDetectionPopover = false
    @State private var selectedStillId: UUID? = nil
    @State private var isCutDetectionHovered = false
    @State private var faceRefinementTask: Task<Void, Never>? = nil
    @State private var hasGenerated = false
    @State private var generateButtonGlow = false
    @State private var isSearchingFaces = false
    @State private var faceSearchProgress: Double = 0
    @State private var faceSearchMessage: String = ""
    @State private var faceStillsCount: Int = 0
    @State private var showFaceDetectionAlert = false
    @State private var cachedFaceTimestamps: [Double]? = nil

    private let sceneDetector = SceneDetector()
    private let videoProcessor = VideoProcessor()

    init(videoURL: URL) {
        self.videoURL = videoURL
        _playerController = StateObject(wrappedValue: LoopingPlayerController(url: videoURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Marker hint bar
            markerHintBar

            // Video Player
            videoPlayerSection

            // Controls bar
            controlsBar

            // Pending clip indicator
            if markingState.pendingInPoint != nil {
                pendingClipIndicator
            }

            Divider()

            // Inline generate markers panel
            if showAnalysisDialog {
                inlineGeneratePanel
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }

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
                Button("Export Settings...") {
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
            // Sync cached cuts from appState (if previously detected)
            if !appState.sceneCutTimestamps.isEmpty {
                markingState.detectedCuts = appState.sceneCutTimestamps
            }

            // Don't autoplay — user can press Space or click to start
            appState.videoSize = playerController.videoSize
        }
        .onChange(of: playerController.videoSize) { newSize in
            appState.videoSize = newSize
        }
        .onChange(of: playerController.duration) { newDuration in
            if newDuration > 0 {
                appState.videoDuration = newDuration
            }
        }
        // Live-update stills when still-only settings change
        .onChange(of: appState.stillCount) { _ in liveUpdateStills() }
        .onChange(of: appState.stillPlacement) { newPlacement in
            let sceneCount = max(1, effectiveScenes.count)
            if newPlacement == .perScene {
                // Switching TO per-scene: divide total by scene count so total stays ~same
                appState.stillCount = max(1, appState.stillCount / sceneCount)
            } else if newPlacement == .spreadEvenly {
                // Switching TO spread evenly: multiply back to a total count
                appState.stillCount = max(1, appState.stillCount * sceneCount)
            }
            liveUpdateStills()
        }
        .onChange(of: appState.exportStillsEnabled) { _ in liveUpdateStills() }
        // Live-update clips when clip-only settings change
        .onChange(of: appState.clipCount) { _ in liveUpdateClips() }
        .onChange(of: appState.clipDuration) { _ in liveUpdateClips() }
        .onChange(of: appState.exportMovingClipsEnabled) { _ in liveUpdateClips() }
        .onChange(of: appState.avoidCrossingScenes) { _ in liveUpdateClips() }
        .onChange(of: appState.allowOverlapping) { _ in liveUpdateClips() }
        .onDisappear {
            playerController.pause()
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .alert("Cut Detection Required", isPresented: $showFaceDetectionAlert) {
            Button("Detect Cuts") {
                detectScenes()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\"Prefer faces\" searches each scene for the best face frame. Run cut detection first so scenes can be analyzed individually.")
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

    // MARK: - Marker Hint Bar

    private var markerHintBar: some View {
        HStack(spacing: 8) {
            Text("Place markers with")
                .font(.headline)
                .foregroundColor(.secondary)

            Button(action: { handleKeyPress(.still) }) {
                keyCap("S", glowColor: .orange)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Snap Still (S)")

            Button(action: { handleKeyPress(.inPoint) }) {
                keyCap("I", glowColor: markingState.pendingInPoint != nil ? .orange : .green)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Mark IN point (I)")

            Button(action: { handleKeyPress(.outPoint) }) {
                keyCap("O", glowColor: .green)
            }
            .buttonStyle(.plain)
            .disabled(markingState.pendingInPoint == nil)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Mark OUT point (O)")

            Text("on your keyboard or")
                .font(.headline)
                .foregroundColor(.secondary)

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showAnalysisDialog.toggle() } }) {
                Label("Auto-Generate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(showAnalysisDialog ? .orange : .clipkitBlue)
            .controlSize(.regular)

            if markingState.hasMarkedItems {
                Button(action: { markingState.clearAll() }) {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.clipkitBlue.opacity(0.12),
                    Color.clipkitBlue.opacity(0.06)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.clipkitBlue.opacity(0.2))
                .frame(height: 1)
        }
    }

    // MARK: - Video Player Section

    private var videoPlayerSection: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                VideoPlayerRepresentable(
                    player: playerController.player,
                    onKeyPress: handleKeyPress,
                    onClick: { playerController.togglePlayPause() }
                )
                .aspectRatio(playerController.aspectRatio, contentMode: .fit)
                .frame(maxHeight: videoPlayerHeight)
                .background(Color.black)
                .clipped()

                // Overlay: cut detection top-left, filename top-right, playback controls bottom
                VStack {
                    HStack(alignment: .top) {
                        // Cut detection popover button
                        Button(action: { showCutDetectionPopover.toggle() }) {
                            HStack(spacing: 6) {
                                Image(systemName: cutDetectionIconName)
                                    .font(.system(size: 16, weight: .semibold))
                                Text(cutDetectionLabelText)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(cutDetectionButtonBackground)
                            .cornerRadius(8)
                            .scaleEffect(isCutDetectionHovered ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isCutDetectionHovered)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isCutDetectionHovered = hovering
                        }
                        .help("Cut detection & snapping settings")
                        .popover(isPresented: $showCutDetectionPopover, arrowEdge: .bottom) {
                            cutDetectionPopoverContent
                        }
                        .padding(8)

                        Spacer()

                        HStack(spacing: 6) {
                            Text(videoURL.lastPathComponent)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(action: {
                                appState.videoURL = nil
                                appState.clearSceneCache()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .help("Remove video")
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .cornerRadius(6)
                        .padding(6)
                    }

                    Spacer()

                    // Playback controls (floating buttons)
                    HStack(spacing: 10) {
                        Button(action: { playerController.togglePlayPause() }) {
                            Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Play/Pause (Space)")

                        Button(action: { showVolumeSlider.toggle() }) {
                            Image(systemName: playerController.volumeIconName)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(playerController.isMuted ? .red : .white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Volume")
                        .popover(isPresented: $showVolumeSlider, arrowEdge: .top) {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Slider(value: Binding(
                                    get: { Double(playerController.volume) },
                                    set: { playerController.setVolume(Float($0)) }
                                ), in: 0...1)
                                .frame(width: 100)
                                .tint(.clipkitBlue)
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                        }

                        Spacer()

                        Text("\(playerController.formattedCurrentTime) / \(playerController.formattedDuration)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.4))
                            .cornerRadius(8)
                    }
                    .padding(8)
                }
            }

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
                            videoPlayerHeight = max(180, min(600, (videoDragStartHeight ?? 300) + value.translation.height))
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
            // Speed controls, legend, and indicators — all in one row
            HStack(spacing: 8) {
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

                // Color legend (inline)
                HStack(spacing: 8) {
                    if !markingState.detectedCuts.isEmpty {
                        legendItem(color: .secondary.opacity(0.5), label: "Cuts")
                    }
                    if !markingState.markedStills.isEmpty {
                        legendItem(color: .orange, label: "Stills")
                    }
                    if !markingState.markedClips.isEmpty || markingState.pendingInPoint != nil {
                        legendItem(color: .green, label: "Clips")
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)

                Spacer()

                // Detection indicators
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

                if faceStillsCount > 0 && appState.stillPlacement == .preferFaces {
                    Image(systemName: "face.smiling")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(faceStillsCount) faces")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    if selectedStillId == id { selectedStillId = nil }
                },
                onClipRangeChanged: { id, newIn, newOut in
                    markingState.updateClipRange(id: id, inPoint: newIn, outPoint: newOut, snapEnabled: appState.snapToSceneCuts)
                },
                selectedStillId: selectedStillId,
                onStillSelected: { id in
                    selectedStillId = id
                }
            )
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

    // MARK: - Inline Generate Panel

    private var inlineGeneratePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "dice")
                    .font(.system(size: 14))
                    .foregroundColor(.clipkitBlue)
                Text("Random Generate Markers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showAnalysisDialog = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // ── Stills ──
            VStack(alignment: .leading, spacing: 8) {
                inlineSectionToggle(title: "Stills", icon: "photo.on.rectangle", isOn: $appState.exportStillsEnabled)

                HStack(spacing: 12) {
                    if appState.stillPlacement != .preferFaces {
                        HStack(spacing: 6) {
                            Text(appState.stillPlacement == .perScene ? "per scene" : "Count")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("", value: $appState.stillCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 40)
                                .multilineTextAlignment(.center)
                            Stepper("", value: $appState.stillCount, in: 1...100)
                                .labelsHidden()
                        }
                    }

                    HStack(spacing: 6) {
                        Text("Placement")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $appState.stillPlacement) {
                            ForEach(StillPlacement.allCases, id: \.self) { placement in
                                Text(placement.rawValue).tag(placement)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .disabled(!appState.exportStillsEnabled)
                .opacity(appState.exportStillsEnabled ? 1 : 0.4)
            }

            // ── Clips ──
            VStack(alignment: .leading, spacing: 8) {
                inlineSectionToggle(title: "Clips", icon: "film", isOn: $appState.exportMovingClipsEnabled)

                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Count")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("", value: $appState.clipCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 40)
                            .multilineTextAlignment(.center)
                        Stepper("", value: $appState.clipCount, in: 1...50)
                            .labelsHidden()
                    }

                    HStack(spacing: 6) {
                        Text("Length")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $appState.clipDuration, in: 1.0...30.0, step: 1.0)
                            .tint(.clipkitBlue)
                            .frame(minWidth: 80)
                        Text("\(appState.clipDuration, specifier: "%.0f")s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 22, alignment: .trailing)
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Avoid crossing cuts", isOn: $appState.avoidCrossingScenes)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle("Allow overlapping", isOn: $appState.allowOverlapping)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                .disabled(!appState.exportMovingClipsEnabled)
                .opacity(appState.exportMovingClipsEnabled ? 1 : 0.4)
            }

            // Generate button
            HStack {
                Spacer()
                Button(action: {
                    cachedFaceTimestamps = nil  // Force fresh search on explicit Generate
                    generateMarkersFromSettings()
                    hasGenerated = true
                }) {
                    Label(hasGenerated ? "Re-Generate" : "Generate!", systemImage: "dice")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.clipkitBlue)
                .controlSize(.regular)
                .disabled(!appState.exportStillsEnabled && !appState.exportMovingClipsEnabled)
                .scaleEffect(!hasGenerated && generateButtonGlow ? 1.06 : 1.0)
                .shadow(color: !hasGenerated ? Color.clipkitBlue.opacity(generateButtonGlow ? 0.7 : 0.0) : .clear, radius: 8)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        generateButtonGlow = true
                    }
                }
                Spacer()
            }

            // Face search progress
            if isSearchingFaces {
                VStack(spacing: 4) {
                    ProgressView(value: faceSearchProgress)
                        .tint(.clipkitBlue)
                    Text(faceSearchMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func inlineSectionToggle(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(isOn.wrappedValue ? .clipkitBlue : .secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
                Spacer()
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isOn.wrappedValue ? .clipkitBlue : .secondary.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn.wrappedValue ? Color.clipkitLightBlue : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOn.wrappedValue ? Color.clipkitBlue : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .onTapGesture(count: 2) {
                        markingState.removeStill(id: still.id)
                    }
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
                    .onTapGesture(count: 2) {
                        markingState.removeClip(id: clip.id)
                    }
                }
            }
        }
    }

    // MARK: - Cut Detection Popover

    private var cutDetectionIconName: String {
        if isDetectingScenes || appState.isDetectingScenes {
            return "circle.dotted"
        } else if appState.scenesDetected {
            return "scissors"
        } else {
            return "wand.and.stars"
        }
    }

    private var cutDetectionLabelText: String {
        if isDetectingScenes || appState.isDetectingScenes {
            return "Detecting..."
        } else if appState.scenesDetected {
            return "\(markingState.detectedCutsCount) Cuts"
        } else {
            return "Detect Cuts"
        }
    }

    private var cutDetectionButtonBackground: some ShapeStyle {
        if isDetectingScenes || appState.isDetectingScenes {
            return AnyShapeStyle(Color.clipkitBlue.opacity(0.7))
        } else if appState.scenesDetected {
            return AnyShapeStyle(Color.black.opacity(0.6))
        } else {
            return AnyShapeStyle(Color.clipkitBlue.opacity(0.55))
        }
    }

    private var cutDetectionPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cut Detection")
                .font(.headline)
                .foregroundColor(.clipkitBlue)

            // Purpose description
            Text("Analyze your video to find scene changes. Helps with timeline navigation, snapping edit points, and smarter auto-generation.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Sensitivity slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Sensitivity")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
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

            // Detect button
            Button(action: { detectScenes() }) {
                Label(
                    appState.scenesDetected ? "Re-detect Cuts" : "Detect Cuts",
                    systemImage: "wand.and.stars"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.clipkitBlue)
            .controlSize(.regular)
            .disabled(isDetectingScenes)

            // Inline progress
            if isDetectingScenes || appState.isDetectingScenes {
                VStack(spacing: 4) {
                    ProgressView(value: appState.detectionProgress)
                        .tint(.clipkitBlue)
                    Text(appState.detectionStatusMessage.isEmpty
                         ? "Detecting cuts… \(Int(appState.detectionProgress * 100))%"
                         : appState.detectionStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Snap toggle — always visible, disabled when no cuts detected
            Divider()
            Toggle(isOn: $appState.snapToSceneCuts) {
                Label("Snap video in/out points to cuts", systemImage: "magnet")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(markingState.detectedCuts.isEmpty)
            .opacity(markingState.detectedCuts.isEmpty ? 0.4 : 1)

            // Cut count summary
            if markingState.detectedCutsCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.caption)
                    Text("\(markingState.detectedCutsCount) cuts detected")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Actions

    private func liveUpdateStills() {
        guard showAnalysisDialog else { return }
        regenerateStills()
    }

    private func liveUpdateClips() {
        guard showAnalysisDialog else { return }
        regenerateClips()
    }

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

        case .delete:
            if let id = selectedStillId {
                markingState.removeStill(id: id)
                selectedStillId = nil
            }

        case .jumpToPreviousMarker:
            let allTimestamps = (
                markingState.markedStills.map { $0.timestamp } +
                markingState.markedClips.flatMap { [$0.inPoint, $0.outPoint] }
            ).sorted()
            if let t = allTimestamps.last(where: { $0 < playerController.currentTime - 0.05 }) {
                playerController.seek(to: t)
            }

        case .jumpToNextMarker:
            let allTimestamps = (
                markingState.markedStills.map { $0.timestamp } +
                markingState.markedClips.flatMap { [$0.inPoint, $0.outPoint] }
            ).sorted()
            if let t = allTimestamps.first(where: { $0 > playerController.currentTime + 0.05 }) {
                playerController.seek(to: t)
            }
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

    /// Regenerate only stills based on current settings (leaves clips untouched)
    private func regenerateStills() {
        // Cancel any in-progress face search
        faceRefinementTask?.cancel()
        faceRefinementTask = nil
        isSearchingFaces = false

        // Clear existing stills only
        markingState.clearStills()

        guard appState.exportStillsEnabled else {
            markingState.undoStack.removeAll()
            return
        }

        if appState.stillPlacement == .preferFaces {
            // Prefer Faces needs scene detection to work properly
            if appState.detectedScenes.isEmpty {
                showFaceDetectionAlert = true
                return
            }

            // Use cached results if available (e.g. switching back from another mode)
            if let cached = cachedFaceTimestamps {
                appState.stillPositions = cached
                markingState.clearStills()
                for t in cached {
                    markingState.addStill(at: t)
                }
                faceStillsCount = cached.count
                markingState.undoStack.removeAll()
                return
            }

            // Async: search each scene for the sharpest face frame
            let scenes = effectiveScenes
            isSearchingFaces = true
            faceSearchProgress = 0
            faceSearchMessage = "Searching for faces..."
            faceStillsCount = 0

            faceRefinementTask = Task {
                let timestamps = await videoProcessor.findBestFacePerScene(
                    from: videoURL,
                    scenes: scenes,
                    progress: { progress, message in
                        Task { @MainActor in
                            faceSearchProgress = progress
                            faceSearchMessage = message
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    appState.stillPositions = timestamps
                    markingState.clearStills()
                    for t in timestamps {
                        markingState.addStill(at: t)
                    }
                    markingState.undoStack.removeAll()
                    faceStillsCount = timestamps.count
                    isSearchingFaces = false
                    cachedFaceTimestamps = timestamps
                }
            }
        } else {
            // Synchronous: spread evenly or per scene
            appState.initializeStillPositions(from: effectiveScenes, count: appState.stillCount)
            for timestamp in appState.stillPositions {
                markingState.addStill(at: timestamp)
            }
        }

        markingState.undoStack.removeAll()
    }

    /// Regenerate only clips based on current settings (leaves stills untouched)
    private func regenerateClips() {
        markingState.clearClips()

        guard appState.exportMovingClipsEnabled else {
            markingState.undoStack.removeAll()
            return
        }

        let clipSpecs = sceneDetector.selectRandomClips(
            videoDuration: appState.videoDuration,
            clipDuration: appState.clipDuration,
            count: appState.clipCount,
            avoidCrossingScenes: appState.avoidCrossingScenes,
            allowOverlapping: appState.allowOverlapping,
            sceneRanges: effectiveScenes
        )
        for spec in clipSpecs {
            let clip = MarkedClip(inPoint: spec.start, outPoint: spec.start + spec.duration)
            markingState.markedClips.append(clip)
        }
        markingState.markedClips.sort { $0.inPoint < $1.inPoint }
        markingState.undoStack.removeAll()
    }

    /// Regenerate both stills and clips (used by Generate button)
    private func generateMarkersFromSettings() {
        regenerateStills()
        regenerateClips()
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
                    cachedFaceTimestamps = nil  // Invalidate face cache when scenes change
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
    var selectedStillId: UUID? = nil
    var onStillSelected: ((UUID?) -> Void)? = nil

    // Drag state (separate offsets prevent clip operations from leaking into still drags)
    @State private var draggingStillId: UUID? = nil
    @State private var draggingClipId: UUID? = nil
    @State private var draggingClipEdge: ClipEdge? = nil
    @State private var stillDragOffset: CGFloat = 0
    @State private var clipDragOffset: CGFloat = 0

    // Selection state
    @State private var isDragging: Bool = false
    private let snapThresholdPx: CGFloat = 12

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

                // Still markers (orange dots - draggable, selectable)
                ForEach(markedStills) { still in
                    let baseX = xPosition(for: still.timestamp, width: width)
                    let isDragging = draggingStillId == still.id
                    let isHovered = hoveredStillId == still.id
                    let isSelected = selectedStillId == still.id
                    let currentX = isDragging ? baseX + stillDragOffset : baseX
                    let size: CGFloat = isDragging ? 14 : (isSelected ? 14 : (isHovered ? 12 : 10))

                    Circle()
                        .fill(stillColor)
                        .frame(width: size, height: size)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
                                .frame(width: size, height: size)
                        )
                        .shadow(color: (isDragging || isHovered || isSelected) ? stillColor.opacity(0.8) : .clear, radius: isSelected ? 6 : 4)
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
                        .zIndex(isDragging ? 100 : (isSelected ? 50 : (isHovered ? 50 : 10)))
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
                        let x = value.location.x
                        let movement = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))

                        if movement > 3 {
                            isDragging = true
                        }

                        if !isDragging, let snapId = nearestStillId(at: x, width: width) {
                            onStillSelected?(snapId)
                            if let still = markedStills.first(where: { $0.id == snapId }) {
                                onSeek(still.timestamp)
                            }
                        } else {
                            if isDragging { onStillSelected?(nil) }
                            let newTime = (Double(x) / Double(width)) * duration
                            onSeek(max(0, min(duration, newTime)))
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 44)
    }

    private func nearestStillId(at xPosition: CGFloat, width: CGFloat) -> UUID? {
        guard !markedStills.isEmpty, width > 0 else { return nil }
        var bestId: UUID? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for still in markedStills {
            let markerX = self.xPosition(for: still.timestamp, width: width)
            let distance = abs(xPosition - markerX)
            if distance < snapThresholdPx && distance < bestDistance {
                bestDistance = distance
                bestId = still.id
            }
        }
        return bestId
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat((time / duration) * Double(width))
    }
}

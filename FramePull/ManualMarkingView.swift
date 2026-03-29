import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

enum ActiveMarker: Equatable {
    case still(UUID)
    case clipInPoint(UUID)
    case clipOutPoint(UUID)
}

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
    @State private var hasAutoSizedPlayer = false       // One-time flag: auto-size player to fill window on first layout
    @State private var videoDragStartHeight: CGFloat? = nil
    @State private var showVolumeSlider = false          // Volume slider overlay visibility
    @State private var volumeDismissWork: DispatchWorkItem? = nil  // Delayed dismiss for hover-to-interact
    @State private var showCutDetectionPopover = false
    private var activeMarker: ActiveMarker? {
        let tolerance = 0.05
        let time = playerController.currentTime
        if let still = markingState.markedStills.first(where: { abs($0.timestamp - time) < tolerance }) {
            return .still(still.id)
        }
        if let clip = markingState.markedClips.first(where: { abs($0.inPoint - time) < tolerance }) {
            return .clipInPoint(clip.id)
        }
        if let clip = markingState.markedClips.first(where: { abs($0.outPoint - time) < tolerance }) {
            return .clipOutPoint(clip.id)
        }
        return nil
    }
    private var selectedStillId: UUID? {
        if case .still(let id) = activeMarker { return id }
        return nil
    }
    @State private var isCutDetectionHovered = false
    @State private var faceRefinementTask: Task<Void, Never>? = nil
    @State private var hasGenerated = false
    @State private var generateButtonGlow = false
    @State private var isSearchingFaces = false
    @State private var faceSearchProgress: Double = 0
    @State private var faceSearchMessage: String = ""
    @State private var faceStillsCount: Int = 0
    @State private var showFaceDetectionAlert = false
    @State private var showCutDetectionHint = false
    @State private var cachedFaceTimestamps: [Double]? = nil
    @State private var keyMonitor: Any? = nil
    @State private var stillsExpanded = false
    @State private var clipsExpanded = false
    @State private var loopingClipId: UUID? = nil
    @State private var showShortcuts = false

    private let sceneDetector = SceneDetector()
    private let videoProcessor = VideoProcessor()

    init(videoURL: URL) {
        self.videoURL = videoURL
        _playerController = StateObject(wrappedValue: LoopingPlayerController(url: videoURL))
    }

    // Fixed UI chrome height: markerHintBar (~50) + controlsBar (~130) + dividers (~4) + export bar (~60)
    private let fixedChromeHeight: CGFloat = 260

    var body: some View {
        GeometryReader { geometry in
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

                // Marked items list — shrinks first so export bar always stays visible
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 16) {
                        if appState.exportStillsEnabled {
                            stillsSection
                        }
                        if appState.exportMovingClipsEnabled {
                            clipsSection
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.visible)
                .layoutPriority(-1)
                .frame(minHeight: 0)

                Divider()

                // Bottom: Export button + shortcuts button (always visible)
                HStack {
                    Button("Export Settings...") {
                        showExportSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullBlue)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .disabled(!markingState.hasMarkedItems)
                    .help("Configure and export marked stills and clips")

                    Button(action: { showShortcuts = true }) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("Keyboard Shortcuts")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .layoutPriority(1)
            }
            .onChange(of: geometry.size.height) { newHeight in
                let maxPlayerHeight = max(120, newHeight - fixedChromeHeight)
                if !hasAutoSizedPlayer {
                    // Auto-maximize video preview on first layout
                    hasAutoSizedPlayer = true
                    videoPlayerHeight = min(900, maxPlayerHeight)
                } else if videoPlayerHeight > maxPlayerHeight {
                    // Clamp video player height when window shrinks
                    videoPlayerHeight = maxPlayerHeight
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerExport)) { _ in
            guard markingState.hasMarkedItems else { return }
            showExportSheet = true
        }
        .onAppear {
            // Sync cached cuts from appState (if previously detected)
            if !appState.sceneCutTimestamps.isEmpty {
                markingState.detectedCuts = appState.sceneCutTimestamps
            }

            // Don't autoplay — user can press Space or click to start
            appState.videoSize = playerController.videoSize

            // Global key monitor ensures marking keys work even when focus is on UI controls
            let ms = markingState
            let pc = playerController
            let app = appState
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // When a text field has focus, only intercept marking keys (s/i/o/space/esc/delete)
                if let responder = event.window?.firstResponder, responder is NSTextView {
                    let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                    let isMarkingKey = ["s", "i", "o", " "].contains(chars)
                    let isEscape = event.keyCode == 53
                    let isDelete = event.keyCode == 51 || event.keyCode == 117
                    if !isMarkingKey && !isEscape && !isDelete {
                        return event // Let numbers, arrows, tab, etc. pass to text field
                    }
                }
                guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return event }
                switch chars {
                case "s":
                    ms.addStill(at: pc.currentTime, isManual: true)
                    return nil
                case "i":
                    ms.setInPoint(at: pc.currentTime, snapEnabled: app.snapToSceneCuts)
                    return nil
                case "o":
                    ms.setOutPoint(at: pc.currentTime, snapEnabled: app.snapToSceneCuts, isManual: true)
                    return nil
                case " ":
                    pc.togglePlayPause()
                    return nil
                case "z" where event.modifierFlags.contains(.command):
                    app.appUndo()
                    return nil
                default:
                    if event.keyCode == 53 { // Escape
                        // Let ESC through when a sheet is attached (e.g. keyboard cheat sheet)
                        if NSApp.mainWindow?.sheets.isEmpty == false { return event }
                        ms.cancelPendingInPoint()
                        return nil
                    } else if event.keyCode == 51 || event.keyCode == 117 { // Backspace / Forward Delete
                        let tolerance = 0.05
                        let time = pc.currentTime
                        if let still = ms.markedStills.first(where: { abs($0.timestamp - time) < tolerance }) {
                            ms.removeStill(id: still.id)
                        } else if let clip = ms.markedClips.first(where: { abs($0.inPoint - time) < tolerance }) {
                            ms.removeClip(id: clip.id)
                        } else if let clip = ms.markedClips.first(where: { abs($0.outPoint - time) < tolerance }) {
                            ms.removeClipOutPoint(id: clip.id)
                        }
                        return nil
                    } else if event.keyCode == 126 { // Up arrow
                        let allTimestamps = (
                            ms.markedStills.map { $0.timestamp } +
                            ms.markedClips.flatMap { [$0.inPoint, $0.outPoint] }
                        ).sorted()
                        if let t = allTimestamps.last(where: { $0 < pc.currentTime - 0.05 }) {
                            pc.seek(to: t)
                        }
                        return nil
                    } else if event.keyCode == 125 { // Down arrow
                        let allTimestamps = (
                            ms.markedStills.map { $0.timestamp } +
                            ms.markedClips.flatMap { [$0.inPoint, $0.outPoint] }
                        ).sorted()
                        if let t = allTimestamps.first(where: { $0 > pc.currentTime + 0.05 }) {
                            pc.seek(to: t)
                        }
                        return nil
                    } else if event.keyCode == 123 && event.modifierFlags.contains(.shift) {
                        pc.stepFrames(-10)
                        return nil
                    } else if event.keyCode == 124 && event.modifierFlags.contains(.shift) {
                        pc.stepFrames(10)
                        return nil
                    }
                    return event
                }
            }
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
            if newPlacement == .preferFaces {
                // Switching TO prefer faces: default 1 face per scene
                appState.stillCount = 1
            } else if newPlacement == .perScene {
                // Switching TO per-scene: divide total by scene count so total stays ~same
                appState.stillCount = max(1, appState.stillCount / sceneCount)
            } else if newPlacement == .spreadEvenly {
                // Switching TO spread evenly: reset to default 10
                appState.stillCount = 10
            }
            liveUpdateStills()
        }
        .onChange(of: appState.exportStillsEnabled) { _ in
            // Don't regenerate — just toggle visibility (markers persist)
        }
        // Live-update clips when clip-only settings change
        .onChange(of: appState.clipCount) { _ in liveUpdateClips() }
        .onChange(of: appState.scenesPerClip) { _ in liveUpdateClips() }
        .onChange(of: appState.exportMovingClipsEnabled) { _ in
            // Don't regenerate — just toggle visibility (markers persist)
        }
        .onChange(of: appState.allowOverlapping) { _ in liveUpdateClips() }
        // Sync player LUT composition when LUT changes (e.g. via undo)
        .onChange(of: appState.selectedLUTName) { _ in
            updatePlayerLUT()
        }
        .onDisappear {
            playerController.pause()
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
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
        .alert("Cut Detection Recommended", isPresented: $showCutDetectionHint) {
            Button("Detect Cuts") {
                showCutDetectionPopover = true
            }
            Button("Skip", role: .cancel) {
                withAnimation(.easeInOut(duration: 0.2)) { showAnalysisDialog = true }
                if !hasGenerated {
                    generateMarkersFromSettings()
                    hasGenerated = true
                }
            }
        } message: {
            Text("Auto-generate works best with detected scene cuts. Without them, the entire video is treated as one scene.\n\nRun cut detection first?")
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
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsView()
        }
    }

    // MARK: - Marker Hint Bar

    private var markerHintBar: some View {
        HStack(spacing: 8) {
            if !hasGenerated {
                Text("Place markers with")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

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

            if !hasGenerated {
                Text("on your keyboard or")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                if showAnalysisDialog {
                    withAnimation(.easeInOut(duration: 0.2)) { showAnalysisDialog = false }
                } else if !appState.scenesDetected {
                    showCutDetectionHint = true
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { showAnalysisDialog = true }
                    if !hasGenerated {
                        generateMarkersFromSettings()
                        hasGenerated = true
                    }
                }
            }) {
                Label("Auto-Generate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.framePullAmber)
            .controlSize(.regular)
            .help("Open auto-generation panel to create markers from scene analysis")

            if markingState.hasMarkedItems {
                Button(action: { markingState.clearAll() }) {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.regular)
                .help("Remove all stills and clips")
            }
        }
        .animation(.easeInOut(duration: 0.3), value: hasGenerated)
        .padding(.horizontal)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.framePullBlue.opacity(0.2))
                .frame(height: 1)
        }
    }

    // MARK: - Video Player Section

    private var videoPlayerSection: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.black // fills the entire allocated height

                VideoPlayerRepresentable(
                    player: playerController.player,
                    onKeyPress: handleKeyPress,
                    onClick: { playerController.togglePlayPause() }
                )
                .aspectRatio(playerController.aspectRatio, contentMode: .fit)

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

                        // Mute button — click to toggle, hover to reveal volume slider overlay
                        // Uses .overlay so the slider floats above without shifting the button's position
                        Button(action: { playerController.toggleMute() }) {
                            Image(systemName: playerController.volumeIconName)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(playerController.isMuted ? .red : .white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(playerController.isMuted ? "Unmute" : "Mute")
                        .onHover { hovering in
                            volumeDismissWork?.cancel()
                            if hovering {
                                withAnimation(.easeInOut(duration: 0.15)) { showVolumeSlider = true }
                            } else {
                                // Delayed dismiss allows moving mouse from button to slider
                                let work = DispatchWorkItem {
                                    withAnimation(.easeInOut(duration: 0.15)) { showVolumeSlider = false }
                                }
                                volumeDismissWork = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                            }
                        }
                        .overlay(alignment: .top) {
                            if showVolumeSlider {
                                HStack(spacing: 8) {
                                    Image(systemName: "speaker.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Slider(value: Binding(
                                        get: { Double(playerController.volume) },
                                        set: { playerController.setVolume(Float($0)) }
                                    ), in: 0...1)
                                    .frame(width: 100)
                                    .tint(.framePullBlue)
                                    Image(systemName: "speaker.wave.3.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .padding(8)
                                .background(.black.opacity(0.7))
                                .cornerRadius(8)
                                .onHover { hovering in
                                    volumeDismissWork?.cancel()
                                    if !hovering {
                                        let work = DispatchWorkItem {
                                            withAnimation(.easeInOut(duration: 0.15)) { showVolumeSlider = false }
                                        }
                                        volumeDismissWork = work
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                                    }
                                }
                                .offset(y: -48)
                                .transition(.opacity)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Frame \(playerController.currentFrame)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                            Text("\(playerController.formattedCurrentTime) / \(playerController.formattedDuration)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4))
                        .cornerRadius(8)
                    }
                    .padding(8)
                }
            }
            .frame(height: videoPlayerHeight)
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
                .help("Drag to resize video player")
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
                            videoPlayerHeight = max(120, min(900, (videoDragStartHeight ?? 300) + value.translation.height))
                        }
                        .onEnded { _ in
                            videoDragStartHeight = nil
                        }
                )
        }
    }

    // MARK: - LUT Menu

    /// Compact menu button for selecting a LUT — shows built-in and user folder LUTs
    private var lutMenuButton: some View {
        Menu {
            // "None" option
            Button(action: {
                let oldName = appState.selectedLUTName
                let oldDim = appState.lutCubeDimension
                let oldData = appState.lutCubeData
                appState.clearLUT()
                playerController.clearVideoComposition()
                if oldData != nil {
                    appState.appUndoStack.append(.lutChange(oldName: oldName, oldDimension: oldDim, oldCubeData: oldData))
                }
            }) {
                if appState.selectedLUTName == nil {
                    Label("None", systemImage: "checkmark")
                } else {
                    Text("None")
                }
            }

            let allLUTs = appState.availableLUTs
            let builtIn = allLUTs.filter { $0.isBuiltIn }
            let userLUTs = allLUTs.filter { !$0.isBuiltIn }

            if !builtIn.isEmpty {
                Divider()
                Section("Built-in") {
                    ForEach(builtIn, id: \.name) { lut in
                        Button(action: {
                            let oldName = appState.selectedLUTName
                            let oldDim = appState.lutCubeDimension
                            let oldData = appState.lutCubeData
                            appState.loadLUT(name: lut.name, url: lut.url)
                            updatePlayerLUT()
                            appState.appUndoStack.append(.lutChange(oldName: oldName, oldDimension: oldDim, oldCubeData: oldData))
                        }) {
                            if appState.selectedLUTName == lut.name {
                                Label(lut.name, systemImage: "checkmark")
                            } else {
                                Text(lut.name)
                            }
                        }
                    }
                }
            }

            if !userLUTs.isEmpty {
                Divider()
                Section("User") {
                    ForEach(userLUTs, id: \.name) { lut in
                        Button(action: {
                            let oldName = appState.selectedLUTName
                            let oldDim = appState.lutCubeDimension
                            let oldData = appState.lutCubeData
                            appState.loadLUT(name: lut.name, url: lut.url)
                            updatePlayerLUT()
                            appState.appUndoStack.append(.lutChange(oldName: oldName, oldDimension: oldDim, oldCubeData: oldData))
                        }) {
                            if appState.selectedLUTName == lut.name {
                                Label(lut.name, systemImage: "checkmark")
                            } else {
                                Text(lut.name)
                            }
                        }
                    }
                }
            }

            Divider()

            Button(action: chooseUserLUTFolder) {
                Label("Choose LUT Folder…", systemImage: "folder")
            }

            if appState.userLUTFolderURL != nil {
                Button(action: {
                    appState.userLUTFolderURL = nil
                    // If the active LUT was from the user folder, clear it
                    if let name = appState.selectedLUTName,
                       !appState.availableLUTs.contains(where: { $0.name == name }) {
                        let oldName = appState.selectedLUTName
                        let oldDim = appState.lutCubeDimension
                        let oldData = appState.lutCubeData
                        appState.clearLUT()
                        playerController.clearVideoComposition()
                        if oldData != nil {
                            appState.appUndoStack.append(.lutChange(oldName: oldName, oldDimension: oldDim, oldCubeData: oldData))
                        }
                    }
                }) {
                    Label("Clear User Folder", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "camera.filters")
                    .font(.caption)
                Text(appState.selectedLUTName ?? "LUT")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundColor(appState.lutEnabled ? .framePullBlue : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Apply a color LUT to the preview and exported files")
    }

    private func chooseUserLUTFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Select a folder containing .cube LUT files"

        if panel.runModal() == .OK, let url = panel.url {
            appState.userLUTFolderURL = url
        }
    }

    private func updatePlayerLUT() {
        if let data = appState.lutCubeData {
            playerController.updateVideoComposition(cubeDimension: appState.lutCubeDimension, cubeData: data)
        } else {
            playerController.clearVideoComposition()
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
                        .tint(markingState.playbackSpeed == speed ? .framePullBlue : .secondary)
                        .controlSize(.small)
                        .help("Playback speed \(speed.displayName)")
                    }
                }

                // Color legend (inline) — shows auto vs manual marker types
                HStack(spacing: 8) {
                    if !markingState.detectedCuts.isEmpty {
                        legendItem(color: .secondary.opacity(0.5), label: "Cuts")
                    }
                    let hasAutoStills = markingState.markedStills.contains { !$0.isManual }
                    let hasManualStills = markingState.markedStills.contains { $0.isManual }
                    if hasAutoStills {
                        legendItem(color: .orange, label: "Auto")
                    }
                    if hasManualStills {
                        legendItem(color: .framePullBlue, label: "Manual")
                    }
                    let hasAutoClips = markingState.markedClips.contains { !$0.isManual }
                    let hasManualClips = markingState.markedClips.contains { $0.isManual }
                    if hasAutoClips || (markingState.pendingInPoint != nil && !hasManualClips) {
                        legendItem(color: .green, label: "Clips")
                    }
                    if hasManualClips || (markingState.pendingInPoint != nil && hasManualClips) {
                        legendItem(color: .framePullBlue, label: "M.Clips")
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

                Toggle(isOn: $appState.snapToSceneCuts) {
                    Label("Snap", systemImage: "magnet")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Snap IN/OUT points to nearest detected cut")

                // LUT selector menu
                lutMenuButton

                if faceStillsCount > 0 && appState.stillPlacement == .preferFaces {
                    Image(systemName: "face.smiling")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(faceStillsCount) faces")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Undo button — uses unified app undo stack
                if appState.canAppUndo {
                    Button(action: { appState.appUndo() }) {
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
                onSeek: { playerController.scrub(to: $0) },
                sceneCuts: markingState.detectedCuts,
                markedStills: appState.exportStillsEnabled ? markingState.markedStills : [],
                markedClips: appState.exportMovingClipsEnabled ? markingState.markedClips : [],
                pendingInPoint: markingState.pendingInPoint,
                onStillPositionChanged: { id, newTime in
                    markingState.updateStillPosition(id: id, to: newTime)
                },
                onStillRemoved: { id in
                    markingState.removeStill(id: id)
                },
                onClipRemoved: { id in
                    markingState.removeClip(id: id)
                },
                onClipRangeChanged: { id, newIn, newOut in
                    markingState.updateClipRange(id: id, inPoint: newIn, outPoint: newOut, snapEnabled: appState.snapToSceneCuts)
                },
                onLoopClip: { clipId in
                    if loopingClipId == clipId {
                        playerController.clearLoopRange()
                        loopingClipId = nil
                    } else if let clip = markingState.markedClips.first(where: { $0.id == clipId }) {
                        playerController.setLoopRange(start: clip.inPoint, end: clip.outPoint)
                        loopingClipId = clipId
                    }
                },
                loopingClipId: loopingClipId,
                selectedStillId: selectedStillId,
                activeMarker: activeMarker,
                snapEnabled: appState.snapToSceneCuts
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
            // Close button
            HStack {
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showAnalysisDialog = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close auto-generation panel")
            }

            // ── Stills ──
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    inlineSectionToggle(title: "Stills", icon: "photo.on.rectangle", isOn: $appState.exportStillsEnabled)
                    if !markingState.markedStills.isEmpty {
                        Button(action: { markingState.clearStills() }) {
                            Label("Clear", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Clear all stills")
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text(appState.stillPlacement == .preferFaces ? "per scene" : (appState.stillPlacement == .perScene ? "per scene" : "Count"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("", value: $appState.stillCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 40)
                            .multilineTextAlignment(.center)
                            .help("Number of stills to generate")
                        Stepper("", value: $appState.stillCount, in: 1...100)
                            .labelsHidden()
                            .help("Adjust still count")
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
                        .help("How stills are distributed — evenly across video, per scene, or at detected faces")
                    }
                }
                .disabled(!appState.exportStillsEnabled)
                .opacity(appState.exportStillsEnabled ? 1 : 0.4)
            }

            // ── Clips ──
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    inlineSectionToggle(title: "Clips", icon: "film", isOn: $appState.exportMovingClipsEnabled)
                    if !markingState.markedClips.isEmpty {
                        Button(action: { markingState.clearClips() }) {
                            Label("Clear", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Clear all clips")
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Count")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("", value: $appState.clipCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 40)
                            .multilineTextAlignment(.center)
                            .help("Number of clips to generate")
                        Stepper("", value: $appState.clipCount, in: 1...50)
                            .labelsHidden()
                            .help("Adjust clip count")
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Scenes per clip")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(value: Binding(
                                get: { Double(appState.scenesPerClip) },
                                set: { appState.scenesPerClip = max(1, Int($0.rounded())) }
                            ), in: 1...Double(max(2, effectiveScenes.count)), step: 1)
                                .tint(.framePullBlue)
                                .frame(minWidth: 80)
                                .disabled(effectiveScenes.count <= 1)
                                .help("How many detected scenes each clip spans")
                        }
                        HStack(spacing: 6) {
                            // Invisible spacer matching the label width
                            Text("Scenes per clip")
                                .font(.caption)
                                .hidden()
                            let maxScenes = max(2, effectiveScenes.count)
                            HStack {
                                Text("1")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.6))
                                Spacer()
                                if appState.scenesPerClip > 1 && appState.scenesPerClip < maxScenes {
                                    Text("\(appState.scenesPerClip)")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                Spacer()
                                Text("\(maxScenes)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .frame(minWidth: 80)
                        }
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Allow overlapping", isOn: $appState.allowOverlapping)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Allow generated clips to overlap in time")
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
                .tint(.framePullAmber)
                .controlSize(.regular)
                .disabled(!appState.exportStillsEnabled && !appState.exportMovingClipsEnabled)
                .help("Generate markers based on current settings")
                .scaleEffect(!hasGenerated && generateButtonGlow ? 1.06 : 1.0)
                .shadow(color: !hasGenerated ? Color.framePullAmber.opacity(generateButtonGlow ? 0.7 : 0.0) : .clear, radius: 8)
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
                        .tint(.framePullBlue)
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
        Toggle(isOn: isOn) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(isOn.wrappedValue ? .framePullBlue : .secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
            }
        }
        .toggleStyle(.checkbox)
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
            .help("Cancel the pending IN point")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Stills Section

    private var stillsSection: some View {
        DisclosureGroup(isExpanded: $stillsExpanded) {
            if markingState.markedStills.isEmpty {
                Text("Press S to snap stills")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(markingState.markedStills) { still in
                    HStack {
                        Circle()
                            .fill(still.isManual ? Color.framePullBlue : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(still.formattedTime)
                            .font(.system(.body, design: .monospaced))

                        Spacer()

                        Button(action: { playerController.seek(to: still.timestamp) }) {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.framePullBlue)
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
        } label: {
            HStack {
                Text("STILLS (\(markingState.markedStills.count))")
                    .font(.headline)
                    .foregroundColor(.framePullBlue)
                Spacer()
                if !markingState.markedStills.isEmpty {
                    Button(action: { markingState.clearStills() }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Clear all stills")
                }
            }
        }
    }

    // MARK: - Clips Section

    private var clipsSection: some View {
        DisclosureGroup(isExpanded: $clipsExpanded) {
            if markingState.markedClips.isEmpty {
                Text("Press I to mark IN, O to mark OUT")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(markingState.markedClips) { clip in
                    HStack {
                        Circle()
                            .fill(clip.isManual ? Color.framePullBlue : Color.green)
                            .frame(width: 8, height: 8)
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
                        .foregroundColor(.framePullBlue)
                        .help("Seek to IN point")

                        Button(action: {
                            if loopingClipId == clip.id {
                                playerController.clearLoopRange()
                                loopingClipId = nil
                            } else {
                                playerController.setLoopRange(start: clip.inPoint, end: clip.outPoint)
                                loopingClipId = clip.id
                            }
                        }) {
                            Image(systemName: loopingClipId == clip.id ? "stop.circle.fill" : "repeat.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(loopingClipId == clip.id ? .orange : .framePullBlue)
                        .help(loopingClipId == clip.id ? "Stop looping" : "Play clip in loop")

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
        } label: {
            HStack {
                Text("CLIPS (\(markingState.markedClips.count))")
                    .font(.headline)
                    .foregroundColor(.framePullBlue)
                Text("→ exports as clip + GIF")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !markingState.markedClips.isEmpty {
                    Button(action: { markingState.clearClips() }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Clear all clips")
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
            return AnyShapeStyle(Color.framePullBlue.opacity(0.7))
        } else if appState.scenesDetected {
            return AnyShapeStyle(Color.black.opacity(0.6))
        } else {
            return AnyShapeStyle(Color.framePullBlue.opacity(0.55))
        }
    }

    private var cutDetectionPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cut Detection")
                .font(.headline)
                .foregroundColor(.framePullBlue)

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
                    Text("Fewer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    // Invert so slider-right = lower threshold = more cuts detected
                    Slider(
                        value: Binding(
                            get: { 0.80 - appState.detectionThreshold },
                            set: { appState.detectionThreshold = 0.80 - $0 }
                        ),
                        in: 0.10...0.70,
                        step: 0.05
                    )
                    .tint(.framePullBlue)
                    .help("Adjust how many scene changes are detected")
                    Text("More")
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
            .tint(.framePullBlue)
            .controlSize(.regular)
            .disabled(isDetectingScenes)
            .help("Analyze video for scene changes")

            // Inline progress
            if isDetectingScenes || appState.isDetectingScenes {
                VStack(spacing: 4) {
                    ProgressView(value: appState.detectionProgress)
                        .tint(.framePullBlue)
                    Text(appState.detectionStatusMessage.isEmpty
                         ? "Detecting cuts… \(Int(appState.detectionProgress * 100))%"
                         : appState.detectionStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Cut count summary
            if markingState.detectedCutsCount > 0 {
                Divider()
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

        // For prefer-faces mode, fall back to full regeneration (async)
        if appState.stillPlacement == .preferFaces {
            regenerateStills()
            return
        }

        // Only count/adjust auto-generated stills — manual ones are untouched
        let autoStills = markingState.markedStills.filter { !$0.isManual }
        let manualStills = markingState.markedStills.filter { $0.isManual }
        let currentPositions = autoStills.map { $0.timestamp }.sorted()
        appState.stillPositions = currentPositions

        let newCount: Int
        if appState.stillPlacement == .perScene {
            let targetCount = appState.stillCount * max(1, effectiveScenes.count)
            newCount = max(0, targetCount - manualStills.count)
        } else {
            newCount = max(0, appState.stillCount - manualStills.count)
        }

        appState.adjustStillPositions(to: newCount, scenes: effectiveScenes)

        let newPositions = Set(appState.stillPositions)
        let oldPositionSet = Set(currentPositions)
        let manualTimestamps = manualStills.map { $0.timestamp }

        // Suppress per-item undo callbacks during bulk update
        markingState.suppressUndoCallback = true

        // Add new auto stills (skip if too close to a manual marker)
        for pos in appState.stillPositions where !oldPositionSet.contains(pos) {
            let tooClose = manualTimestamps.contains { abs($0 - pos) < 0.5 }
            if !tooClose {
                markingState.addStill(at: pos, isManual: false)
            }
        }

        // Remove excess auto stills only (never remove manual)
        let positionsToRemove = oldPositionSet.subtracting(newPositions)
        for pos in positionsToRemove {
            if let still = markingState.markedStills.first(where: { abs($0.timestamp - pos) < 0.001 && !$0.isManual }) {
                markingState.removeStill(id: still.id)
            }
        }

        markingState.suppressUndoCallback = false
    }

    private func liveUpdateClips() {
        guard showAnalysisDialog else { return }
        regenerateClips()
    }

    private func handleKeyPress(_ key: VideoPlayerRepresentable.KeyPress) {
        switch key {
        case .still:
            markingState.addStill(at: playerController.currentTime, isManual: true)
            flashKey("S")

        case .inPoint:
            markingState.setInPoint(at: playerController.currentTime, snapEnabled: appState.snapToSceneCuts)
            flashKey("I")

        case .outPoint:
            markingState.setOutPoint(at: playerController.currentTime, snapEnabled: appState.snapToSceneCuts, isManual: true)
            flashKey("O")

        case .playPause:
            playerController.togglePlayPause()

        case .cancelIn:
            markingState.cancelPendingInPoint()

        case .undo:
            appState.appUndo()

        case .delete:
            switch activeMarker {
            case .still(let id):
                markingState.removeStill(id: id)
            case .clipInPoint(let id):
                markingState.removeClip(id: id)
            case .clipOutPoint(let id):
                markingState.removeClipOutPoint(id: id)
            case nil:
                break
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

        case .skipFramesBack:
            playerController.stepFrames(-10)

        case .skipFramesForward:
            playerController.stepFrames(10)
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
    /// Used by the Generate button — saves old state for undo, preserves manual markers
    private func regenerateStills() {
        // Cancel any in-progress face search
        faceRefinementTask?.cancel()
        faceRefinementTask = nil
        isSearchingFaces = false

        // Save full state for undo
        let previousStills = markingState.markedStills
        let previousClips = markingState.markedClips

        // Clear only auto-generated stills — manual markers survive
        markingState.clearAutoStills()
        let manualStills = markingState.markedStills // Only manual stills remain
        let manualTimestamps = manualStills.map { $0.timestamp }

        // Suppress per-item undo callbacks during bulk regeneration
        markingState.suppressUndoCallback = true

        guard appState.exportStillsEnabled else {
            markingState.suppressUndoCallback = false
            if !previousStills.isEmpty {
                appState.appUndoStack.append(.settingsRegeneration(
                    previousStills: previousStills, previousClips: previousClips,
                    description: "Stills disabled"))
            }
            return
        }

        if appState.stillPlacement == .preferFaces {
            // Prefer Faces needs scene detection to work properly
            if appState.detectedScenes.isEmpty {
                markingState.markedStills = previousStills
                markingState.suppressUndoCallback = false
                showFaceDetectionAlert = true
                return
            }

            // Use cached results if available
            if let cached = cachedFaceTimestamps {
                appState.stillPositions = cached
                for t in cached {
                    let tooClose = manualTimestamps.contains { abs($0 - t) < 0.5 }
                    if !tooClose {
                        markingState.addStill(at: t, isManual: false)
                    }
                }
                faceStillsCount = cached.count
                markingState.suppressUndoCallback = false
                markingState.undoStack.removeAll()
                appState.appUndoStack.append(.settingsRegeneration(
                    previousStills: previousStills, previousClips: previousClips,
                    description: "Face still regeneration"))
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
                    countPerScene: appState.stillCount,
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
                    markingState.clearAutoStills()
                    let manualTs = markingState.markedStills.map { $0.timestamp }
                    for t in timestamps {
                        let tooClose = manualTs.contains { abs($0 - t) < 0.5 }
                        if !tooClose {
                            markingState.addStill(at: t, isManual: false)
                        }
                    }
                    markingState.suppressUndoCallback = false
                    markingState.undoStack.removeAll()
                    appState.appUndoStack.append(.settingsRegeneration(
                        previousStills: previousStills, previousClips: previousClips,
                        description: "Face still regeneration"))
                    faceStillsCount = timestamps.count
                    isSearchingFaces = false
                    cachedFaceTimestamps = timestamps
                }
            }
            // Face path handles its own undo bookkeeping inside the Task above
            return
        } else {
            // Synchronous: spread evenly or per scene
            appState.initializeStillPositions(from: effectiveScenes, count: appState.stillCount)
            for timestamp in appState.stillPositions {
                let tooClose = manualTimestamps.contains { abs($0 - timestamp) < 0.5 }
                if !tooClose {
                    markingState.addStill(at: timestamp, isManual: false)
                }
            }
        }

        markingState.suppressUndoCallback = false
        // Replace per-item undo entries with single settings regeneration undo
        markingState.undoStack.removeAll()
        if !previousStills.isEmpty {
            appState.appUndoStack.append(.settingsRegeneration(
                previousStills: previousStills, previousClips: previousClips,
                description: "Still regeneration"))
        }
    }

    /// Regenerate only clips based on current settings (leaves stills untouched)
    /// Preserves manual clips, saves old state for undo
    private func regenerateClips() {
        let previousStills = markingState.markedStills
        let previousClips = markingState.markedClips

        // Clear only auto-generated clips — manual ones survive
        markingState.clearAutoClips()

        markingState.suppressUndoCallback = true

        guard appState.exportMovingClipsEnabled else {
            markingState.suppressUndoCallback = false
            if !previousClips.isEmpty {
                appState.appUndoStack.append(.settingsRegeneration(
                    previousStills: previousStills, previousClips: previousClips,
                    description: "Clips disabled"))
            }
            return
        }

        let clipSpecs = sceneDetector.selectRandomClips(
            videoDuration: appState.videoDuration,
            scenesPerClip: appState.scenesPerClip,
            count: appState.clipCount,
            allowOverlapping: appState.allowOverlapping,
            sceneRanges: effectiveScenes
        )
        for spec in clipSpecs {
            let clip = MarkedClip(inPoint: spec.start, outPoint: spec.start + spec.duration, isManual: false)
            markingState.markedClips.append(clip)
        }
        markingState.markedClips.sort { $0.inPoint < $1.inPoint }

        markingState.suppressUndoCallback = false
        // Single undo action to restore previous state
        if !previousClips.isEmpty || !previousStills.isEmpty {
            appState.appUndoStack.append(.settingsRegeneration(
                previousStills: previousStills, previousClips: previousClips,
                description: "Clip regeneration"))
        }
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
                // Task was cancelled — reset all UI state
                await MainActor.run {
                    isDetectingScenes = false
                    appState.isDetectingScenes = false
                    appState.detectionProgress = 0
                    appState.detectionStatusMessage = ""
                }
                return
            } catch {
                await MainActor.run {
                    isDetectingScenes = false
                    appState.isDetectingScenes = false
                    appState.detectionProgress = 0
                    appState.detectionStatusMessage = ""
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
    let onClipRemoved: (UUID) -> Void
    let onClipRangeChanged: (UUID, Double?, Double?) -> Void
    let onLoopClip: (UUID) -> Void
    var loopingClipId: UUID? = nil
    var selectedStillId: UUID? = nil
    var activeMarker: ActiveMarker? = nil
    var snapEnabled: Bool = true

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
    @State private var hoveredClipBarId: UUID? = nil

    // Zoom state
    @State private var zoomLevel: Double = 1.0

    // Scroll offset frozen at drag-start so the view doesn't shift under the user's cursor
    @State private var dragStartScrollOffset: CGFloat = 0

    enum ClipEdge {
        case inPoint
        case outPoint
    }

    // Colors — manual markers are blue, auto-generated are orange/green
    private let autoStillColor = Color.orange
    private let manualMarkerColor = Color.framePullBlue
    private let autoClipColor = Color.green
    private let cutColor = Color.secondary.opacity(0.5)
    private let playheadColor = Color.framePullBlue
    private let pendingColor = Color.orange

    /// Color for a still marker based on its origin (manual vs auto)
    private func stillColor(for still: MarkedStill) -> Color {
        still.isManual ? manualMarkerColor : autoStillColor
    }

    /// Color for a clip marker based on its origin (manual vs auto)
    private func clipColor(for clip: MarkedClip) -> Color {
        clip.isManual ? manualMarkerColor : autoClipColor
    }

    /// Greedy interval scheduling: assigns overlapping clips to separate lanes (max 3)
    /// so they stack vertically instead of overlapping on the timeline.
    private var clipLaneAssignments: [UUID: Int] {
        let sorted = markedClips.sorted { $0.inPoint < $1.inPoint }
        var lanes: [[MarkedClip]] = [[]]
        var result: [UUID: Int] = [:]
        for clip in sorted {
            var assigned = false
            for (laneIndex, lane) in lanes.enumerated() {
                if let last = lane.last, last.outPoint > clip.inPoint {
                    continue // This lane has a conflict, try next
                }
                lanes[laneIndex].append(clip)
                result[clip.id] = laneIndex
                assigned = true
                break
            }
            if !assigned {
                let newLane = min(lanes.count, 2) // Cap at 3 lanes (indices 0-2)
                if newLane == lanes.count { lanes.append([]) }
                lanes[newLane].append(clip)
                result[clip.id] = newLane
            }
        }
        return result
    }

    private var maxLane: Int {
        clipLaneAssignments.values.max() ?? 0
    }

    private var timelineHeight: CGFloat {
        56 + CGFloat(maxLane) * 22
    }

    private var totalHeight: CGFloat {
        timelineHeight + 20
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let width = viewportWidth * CGFloat(zoomLevel)
            let scrollOffset = computedScrollOffset(contentWidth: width, viewportWidth: viewportWidth)
            VStack(spacing: 2) {

            ZStack(alignment: .topLeading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: timelineHeight - 4)
                    .padding(.top, 2)

                // Scene cut markers (vertical lines)
                ForEach(sceneCuts, id: \.self) { cut in
                    let x = xPosition(for: cut, width: width)
                    Rectangle()
                        .fill(cutColor)
                        .frame(width: 1, height: timelineHeight - 4)
                        .position(x: x, y: timelineHeight / 2)
                }

                // Marked clips (blue=manual, green=auto, ranges with draggable edges)
                ForEach(markedClips) { clip in
                    let inX = xPosition(for: clip.inPoint, width: width)
                    let outX = xPosition(for: clip.outPoint, width: width)
                    let isDragging = draggingClipId == clip.id
                    let lane = clipLaneAssignments[clip.id] ?? 0
                    let clipY: CGFloat = 40 + CGFloat(lane) * 22
                    let barColor = clipColor(for: clip)

                    // Compute display positions that follow the drag handle
                    let displayInX = isDragging && draggingClipEdge == .inPoint ? inX + clipDragOffset : inX
                    let displayOutX = isDragging && draggingClipEdge == .outPoint ? outX + clipDragOffset : outX
                    let clipWidth = max(4, displayOutX - displayInX)

                    // Clip range background — follows drag (bottom lane)
                    let isLooping = loopingClipId == clip.id
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor.opacity(isLooping ? 0.7 : (isDragging ? 0.6 : 0.4)))
                        if clipWidth > 30 {
                            Button(action: { onLoopClip(clip.id) }) {
                                Image(systemName: isLooping ? "stop.fill" : "repeat.circle")
                                    .font(.system(size: isLooping ? 12 : 14))
                                    .foregroundColor(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: clipWidth, height: 20)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        hoveredClipBarId = hovering ? clip.id : nil
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { onClipRemoved(clip.id) }
                    )
                    .contextMenu {
                        Button(role: .destructive) { onClipRemoved(clip.id) } label: {
                            Label("Delete Clip", systemImage: "trash")
                        }
                        Divider()
                        Text("Double-click to delete").foregroundColor(.secondary)
                    }
                    .position(x: displayInX + clipWidth / 2, y: clipY)

                    // In point handle (left edge)
                    let isInActive = activeMarker == .clipInPoint(clip.id)
                    let isInHovered = hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .inPoint
                    let inHandleWidth: CGFloat = isInActive ? 10 : (isInHovered ? 8 : 6)
                    let inHandleHeight: CGFloat = isInActive ? 28 : (isInHovered ? 26 : 22)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isInActive ? Color.white : barColor)
                        .frame(width: inHandleWidth, height: inHandleHeight)
                        .shadow(color: isInActive ? Color.white.opacity(0.6) : (isInHovered ? barColor.opacity(0.6) : .clear), radius: isInActive ? 6 : 4)
                        .animation(.easeInOut(duration: 0.15), value: isInHovered)
                        .animation(.easeInOut(duration: 0.15), value: isInActive)
                        .frame(width: 20, height: 28)
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
                                    if draggingClipId != clip.id { dragStartScrollOffset = scrollOffset }
                                    draggingClipId = clip.id
                                    draggingClipEdge = .inPoint
                                    clipDragOffset = value.location.x - inX
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    var newTime = (Double(clampedX) / Double(width)) * duration
                                    // Snap to playhead if within threshold
                                    if snapEnabled {
                                        let playheadX = xPosition(for: currentTime, width: width)
                                        if abs(clampedX - playheadX) < snapThresholdPx {
                                            newTime = currentTime
                                        }
                                    }
                                    onClipRangeChanged(clip.id, max(0, newTime), nil)
                                    draggingClipId = nil
                                    draggingClipEdge = nil
                                    clipDragOffset = 0
                                }
                        )
                        .position(x: displayInX, y: clipY)
                        .zIndex(isDragging && draggingClipEdge == .inPoint ? 50 : 5)

                    // Out point handle (right edge)
                    let isOutActive = activeMarker == .clipOutPoint(clip.id)
                    let isOutHovered = hoveredClipEdge?.0 == clip.id && hoveredClipEdge?.1 == .outPoint
                    let outHandleWidth: CGFloat = isOutActive ? 10 : (isOutHovered ? 8 : 6)
                    let outHandleHeight: CGFloat = isOutActive ? 28 : (isOutHovered ? 26 : 22)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isOutActive ? Color.white : barColor)
                        .frame(width: outHandleWidth, height: outHandleHeight)
                        .shadow(color: isOutActive ? Color.white.opacity(0.6) : (isOutHovered ? barColor.opacity(0.6) : .clear), radius: isOutActive ? 6 : 4)
                        .animation(.easeInOut(duration: 0.15), value: isOutHovered)
                        .animation(.easeInOut(duration: 0.15), value: isOutActive)
                        .frame(width: 20, height: 28)
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
                                    if draggingClipId != clip.id { dragStartScrollOffset = scrollOffset }
                                    draggingClipId = clip.id
                                    draggingClipEdge = .outPoint
                                    clipDragOffset = value.location.x - outX
                                }
                                .onEnded { value in
                                    let clampedX = max(0, min(width, value.location.x))
                                    var newTime = (Double(clampedX) / Double(width)) * duration
                                    // Snap to playhead if within threshold
                                    if snapEnabled {
                                        let playheadX = xPosition(for: currentTime, width: width)
                                        if abs(clampedX - playheadX) < snapThresholdPx {
                                            newTime = currentTime
                                        }
                                    }
                                    onClipRangeChanged(clip.id, nil, min(duration, newTime))
                                    draggingClipId = nil
                                    draggingClipEdge = nil
                                    clipDragOffset = 0
                                }
                        )
                        .position(x: displayOutX, y: clipY)
                        .zIndex(isDragging && draggingClipEdge == .outPoint ? 50 : 5)
                }

                // Pending IN point (orange dashed line — clip lane)
                if let pendingIn = pendingInPoint {
                    let x = xPosition(for: pendingIn, width: width)
                    Rectangle()
                        .fill(pendingColor)
                        .frame(width: 3, height: 24)
                        .position(x: x, y: 40)
                        .zIndex(15)
                }

                // Still markers (dots - blue=manual, orange=auto, draggable, selectable)
                ForEach(markedStills) { still in
                    let baseX = xPosition(for: still.timestamp, width: width)
                    let isDragging = draggingStillId == still.id
                    let isHovered = hoveredStillId == still.id
                    let isSelected = selectedStillId == still.id
                    let currentX = isDragging ? baseX + stillDragOffset : baseX
                    let size: CGFloat = isDragging ? 14 : (isSelected ? 14 : (isHovered ? 12 : 10))
                    let markerColor = stillColor(for: still)

                    Circle()
                        .fill(markerColor)
                        .frame(width: size, height: size)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
                                .frame(width: size, height: size)
                        )
                        .shadow(color: (isDragging || isHovered || isSelected) ? markerColor.opacity(0.8) : .clear, radius: isSelected ? 6 : 4)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                        .frame(width: 30, height: 28)
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
                        .contextMenu {
                            Button(role: .destructive) { onStillRemoved(still.id) } label: {
                                Label("Delete Still", systemImage: "trash")
                            }
                            Divider()
                            Text("Double-click to delete").foregroundColor(.secondary)
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                                .onChanged { value in
                                    if draggingStillId != still.id {
                                        dragStartScrollOffset = scrollOffset
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
                        .position(x: currentX, y: 16)
                        .zIndex(isDragging ? 100 : (isSelected ? 50 : (isHovered ? 50 : 10)))
                        .animation(.easeInOut(duration: 0.15), value: isSelected)
                }

                // Playhead (current position) - highest z-index
                let playheadX = xPosition(for: currentTime, width: width)
                RoundedRectangle(cornerRadius: 1)
                    .fill(playheadColor)
                    .frame(width: 3, height: timelineHeight)
                    .position(x: playheadX, y: timelineHeight / 2)
                    .zIndex(200)

            }
            .coordinateSpace(name: "timeline")
            .frame(width: width, height: timelineHeight)
            // Shift content so the playhead stays centred; offset IS included in the
            // "timeline" coordinate space transform, so all gesture coordinates remain
            // in content space — no gesture math changes needed.
            .offset(x: -scrollOffset)
            .frame(width: viewportWidth, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .onHover { isHovering in
                if !isHovering && draggingStillId == nil && draggingClipId == nil {
                    hoveredStillId = nil
                    hoveredClipEdge = nil
                    NSCursor.arrow.set()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        guard draggingStillId == nil && draggingClipId == nil else { return }
                        let x = value.location.x
                        let movement = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))

                        if movement > 3 {
                            isDragging = true
                        }

                        if !isDragging, let snapId = nearestStillId(at: x, width: width),
                           let still = markedStills.first(where: { $0.id == snapId }) {
                            onSeek(still.timestamp)
                        } else {
                            let newTime = (Double(x) / Double(width)) * duration
                            onSeek(max(0, min(duration, newTime)))
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )

            // Zoom controls + scroll indicator
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Slider(value: $zoomLevel, in: 1...20)
                    .controlSize(.mini)
                    .frame(width: 80)

                scrollIndicator(viewportWidth: viewportWidth, contentWidth: width, scrollOffset: scrollOffset)
            }
            .frame(height: 16)
            .padding(.horizontal, 4)
            } // VStack
        }
        .frame(height: totalHeight)
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

    /// Returns the scroll offset that keeps the playhead centred in the viewport.
    /// During marker drags the offset is frozen so the view doesn't jump under the cursor.
    private func computedScrollOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard zoomLevel > 1.0, contentWidth > viewportWidth else { return 0 }
        if draggingStillId != nil || draggingClipId != nil {
            return dragStartScrollOffset
        }
        let playheadX = xPosition(for: currentTime, width: contentWidth)
        let raw = playheadX - viewportWidth / 2
        return max(0, min(contentWidth - viewportWidth, raw))
    }

    @ViewBuilder
    private func scrollIndicator(viewportWidth: CGFloat, contentWidth: CGFloat, scrollOffset: CGFloat) -> some View {
        if zoomLevel > 1.01 {
            let thumbFraction = viewportWidth / contentWidth
            let offsetFraction = contentWidth > viewportWidth
                ? scrollOffset / (contentWidth - viewportWidth)
                : 0

            GeometryReader { barGeo in
                let barWidth = barGeo.size.width
                let thumbWidth = max(12, barWidth * thumbFraction)
                let maxOffset = barWidth - thumbWidth

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: thumbWidth, height: 3)
                        .offset(x: min(maxOffset, max(0, offsetFraction * maxOffset)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / barWidth))
                            let time = Double(fraction) * duration
                            onSeek(max(0, min(duration, time)))
                        }
                )
            }
        } else {
            Spacer()
        }
    }
}

// MARK: - Keyboard Shortcuts Overlay

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [(key: String, action: String)] = [
        ("S", "Snap still frame"),
        ("I", "Mark clip IN point"),
        ("O", "Mark clip OUT point"),
        ("Space", "Play / Pause"),
        ("Delete", "Remove marker at playhead"),
        ("\u{2318}Z", "Undo"),
        ("Esc", "Cancel pending IN point"),
        ("\u{2191}", "Jump to previous marker"),
        ("\u{2193}", "Jump to next marker"),
        ("\u{21E7}\u{2190}", "Skip back 10 frames"),
        ("\u{21E7}\u{2192}", "Skip forward 10 frames"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Shortcuts list
            VStack(spacing: 6) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, shortcut in
                    HStack(spacing: 16) {
                        Text(shortcut.key)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundColor(.primary)
                            .frame(width: 80, alignment: .center)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )

                        Text(shortcut.action)
                            .font(.body)
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 16)

            Spacer()

            // Dismiss hint
            Text("Press Esc to close")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 14)
        }
        .frame(width: 400, height: 520)
        .onExitCommand { dismiss() }
    }
}

// MARK: - Marker Preview View
/// Shows a thumbnail grid of all marked stills and clips before export.
/// Stills show static thumbnails; clips render as looping animated GIFs (temp files, cleaned up on dismiss).

struct MarkerPreviewView: View {
    let videoURL: URL
    @ObservedObject var markingState: MarkingState
    /// Which aspect ratio to show the reframe slider for (nil = no reframe, 9:16 takes priority over 4:5)
    let reframeRatio: VideoSnippetProcessor.AspectRatioCrop?
    var showStills: Bool = true
    var showClips: Bool = true

    private var markedStills: [MarkedStill] { showStills ? markingState.markedStills : [] }
    private var markedClips: [MarkedClip] { showClips ? markingState.markedClips : [] }

    @Environment(\.dismiss) private var dismiss

    // Pre-generated at 640 px — good for both the grid and lightbox, avoids per-navigation reloads
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var clipGIFURLs: [String: URL] = [:]

    // Loading gate — grid only appears after ALL previews are ready
    @State private var isLoadingPreviews = true
    @State private var loadingProgress: Double = 0

    // Lightbox
    @State private var lightboxIndex: Int? = nil
    @State private var lightboxKeyMonitor: Any? = nil

    // Reframe
    @State private var localReframeOffset: CGFloat = 0.5
    @State private var dragStartOffset: CGFloat = 0.5
    @State private var isDraggingReframe = false

    private let thumbWidth: CGFloat = 160
    private let thumbHeight: CGFloat = 90
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 10)]

    /// Flat ordered list: stills first, then clips. Indices used by the lightbox.
    private var allItems: [(key: String, caption: String)] {
        markedStills.map { ("still_\($0.id)", $0.formattedTime) } +
        markedClips.map { ("clip_\($0.id)", "\($0.formattedInPoint) – \($0.formattedOutPoint)") }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                // Header — always visible
                HStack {
                    Text("Preview & Reframe").font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close preview")
                }

                if isLoadingPreviews {
                    // ── Loading screen ──────────────────────────────────────
                    Spacer()
                    VStack(spacing: 14) {
                        ProgressView(value: loadingProgress)
                            .progressViewStyle(.linear)
                            .tint(.framePullBlue)
                            .frame(maxWidth: 320)
                        Text("Generating previews… \(Int(loadingProgress * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    // ── Thumbnail grid ──────────────────────────────────────
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !markedStills.isEmpty {
                                Text("STILLS (\(markedStills.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(Array(markedStills.enumerated()), id: \.element.id) { i, still in
                                        VStack(spacing: 4) {
                                            if let img = thumbnails["still_\(still.id)"] {
                                                Image(nsImage: img)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: thumbWidth, height: thumbHeight)
                                                    .clipped()
                                                    .cornerRadius(6)
                                            } else {
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color.gray.opacity(0.15))
                                                    .frame(width: thumbWidth, height: thumbHeight)
                                            }
                                            Text(still.formattedTime)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { lightboxIndex = i }
                                        .help("Click to enlarge")
                                    }
                                }
                            }

                            if !markedClips.isEmpty {
                                Text("CLIPS (\(markedClips.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.green)
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(Array(markedClips.enumerated()), id: \.element.id) { j, clip in
                                        let clipKey = "clip_\(clip.id)"
                                        VStack(spacing: 4) {
                                            ZStack(alignment: .center) {
                                                if let gifURL = clipGIFURLs[clipKey] {
                                                    AnimatedGIFView(url: gifURL)
                                                        .frame(width: thumbWidth, height: thumbHeight)
                                                        .clipped()
                                                        .cornerRadius(6)
                                                } else if let img = thumbnails[clipKey] {
                                                    Image(nsImage: img)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .frame(width: thumbWidth, height: thumbHeight)
                                                        .clipped()
                                                        .cornerRadius(6)
                                                }
                                                // Duration badge
                                                VStack {
                                                    Spacer()
                                                    HStack {
                                                        Spacer()
                                                        Text(clip.formattedDuration)
                                                            .font(.system(size: 9, design: .monospaced))
                                                            .foregroundColor(.white)
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 2)
                                                            .background(.black.opacity(0.7))
                                                            .cornerRadius(3)
                                                            .padding(4)
                                                    }
                                                }
                                                .frame(width: thumbWidth, height: thumbHeight)
                                            }
                                            Text("\(clip.formattedInPoint) – \(clip.formattedOutPoint)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { lightboxIndex = markedStills.count + j }
                                        .help("Click to enlarge")
                                    }
                                }
                            }
                        }
                        .padding(.bottom)
                    }
                }
            }
            .padding()
            .frame(width: 560, height: 500)
            .task { await generateAllPreviews() }
            .onDisappear {
                cleanupTempGIFs()
                if let m = lightboxKeyMonitor { NSEvent.removeMonitor(m); lightboxKeyMonitor = nil }
            }
            .onChange(of: lightboxIndex) { newIdx in
                if let idx = newIdx {
                    // Sync reframe slider with current item's offset
                    let key = allItems[idx].key
                    if key.hasPrefix("still_"), let id = UUID(uuidString: String(key.dropFirst(6))) {
                        localReframeOffset = markedStills.first { $0.id == id }?.reframeOffset ?? 0.5
                    } else if key.hasPrefix("clip_"), let id = UUID(uuidString: String(key.dropFirst(5))) {
                        localReframeOffset = markedClips.first { $0.id == id }?.reframeOffset ?? 0.5
                    }

                    if lightboxKeyMonitor == nil {
                        lightboxKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            switch event.keyCode {
                            case 123: if let i = self.lightboxIndex, i > 0 { self.lightboxIndex = i - 1 }; return nil
                            case 124: if let i = self.lightboxIndex, i < self.allItems.count - 1 { self.lightboxIndex = i + 1 }; return nil
                            case 53: self.lightboxIndex = nil; return nil
                            default: return event
                            }
                        }
                    }
                } else if let m = lightboxKeyMonitor {
                    NSEvent.removeMonitor(m)
                    lightboxKeyMonitor = nil
                }
            }

            if lightboxIndex != nil { lightboxOverlay }

        } // ZStack
        .onExitCommand {
            if lightboxIndex != nil { lightboxIndex = nil } else { dismiss() }
        }
    }

    // MARK: - Lightbox overlay

    @ViewBuilder
    private var lightboxOverlay: some View {
        if let idx = lightboxIndex {
            let items = allItems
            ZStack {
                Color.black.opacity(0.88).onTapGesture { lightboxIndex = nil }
                VStack(spacing: 0) {
                    HStack {
                        Text("\(idx + 1) of \(items.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Button { lightboxIndex = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3).foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Close lightbox (Esc)")
                    }
                    .padding(.horizontal, 16).padding(.top, 16)

                    HStack(spacing: 0) {
                        Button { if idx > 0 { lightboxIndex = idx - 1 } } label: {
                            Image(systemName: "chevron.left")
                                .font(.title2.weight(.semibold))
                                .foregroundColor(idx > 0 ? .white : .white.opacity(0.15))
                                .frame(width: 44)
                        }
                        .buttonStyle(.plain).disabled(idx == 0)
                        .help("Previous (←)")

                        // Image is always pre-loaded — no async work here
                        Group {
                            let isClip = idx >= markedStills.count
                            let key = items[idx].key
                            if isClip, let gifURL = clipGIFURLs[key] {
                                ZStack {
                                    AnimatedGIFView(url: gifURL)
                                        .id(key) // Force recreation when switching clips
                                        .aspectRatio(contentMode: .fit).cornerRadius(8)
                                    if reframeRatio != nil { reframeCropOverlay }
                                }
                            } else if let img = thumbnails[key] {
                                ZStack {
                                    Image(nsImage: img).resizable()
                                        .aspectRatio(contentMode: .fit).cornerRadius(8)
                                    if reframeRatio != nil { reframeCropOverlay }
                                }
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .gesture(reframeRatio != nil ? reframeDragGesture(for: items[idx].key) : nil)
                        .onHover { hovering in
                            if reframeRatio != nil {
                                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                        }

                        Button { if idx < items.count - 1 { lightboxIndex = idx + 1 } } label: {
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .foregroundColor(idx < items.count - 1 ? .white : .white.opacity(0.15))
                                .frame(width: 44)
                        }
                        .buttonStyle(.plain).disabled(idx == items.count - 1)
                        .help("Next (→)")
                    }
                    .frame(maxHeight: .infinity)

                    Text(items[idx].caption)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))

                    // Reframe slider
                    if let ratio = reframeRatio {
                        let label = ratio == .ratio9x16 ? "9:16 Reframe" : "4:5 Reframe"
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.left.and.right")
                                    .foregroundColor(.white.opacity(0.5))
                                    .font(.caption2)
                                Text(label)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer()
                                if localReframeOffset != 0.5 {
                                    Button("Reset") {
                                        localReframeOffset = 0.5
                                        commitReframeOffset(for: items[idx].key)
                                    }
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.4))
                                    .buttonStyle(.plain)
                                    .help("Reset crop position to center")
                                }
                            }
                            Slider(value: $localReframeOffset, in: 0...1)
                                .tint(.orange)
                                .help("Slide to adjust crop position — or drag the image directly")
                                .onChange(of: localReframeOffset) { _ in
                                    commitReframeOffset(for: items[idx].key)
                                }
                        }
                        .padding(.horizontal, 60)
                    }

                    Spacer().frame(height: 12)
                }
            }
        }
    }

    // MARK: - Reframe helpers

    /// Drag gesture for reframing — dragging left/right moves the crop window
    private func reframeDragGesture(for key: String) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDraggingReframe {
                    isDraggingReframe = true
                    dragStartOffset = localReframeOffset
                }
                // Drag right = move crop frame right = increase offset
                let delta = value.translation.width / 300.0
                localReframeOffset = max(0, min(1, dragStartOffset + delta))
                commitReframeOffset(for: key)
            }
            .onEnded { _ in
                isDraggingReframe = false
                dragStartOffset = localReframeOffset
            }
    }

    /// Commit the current slider value back to the MarkingState model
    private func commitReframeOffset(for key: String) {
        if key.hasPrefix("still_"), let id = UUID(uuidString: String(key.dropFirst(6))) {
            markingState.updateReframeOffset(forStill: id, offset: localReframeOffset)
        } else if key.hasPrefix("clip_"), let id = UUID(uuidString: String(key.dropFirst(5))) {
            markingState.updateReframeOffset(forClip: id, offset: localReframeOffset)
        }
    }

    /// Overlay that dims the areas outside the crop window for the active reframe ratio
    private var reframeCropOverlay: some View {
        GeometryReader { geo in
            let viewW = geo.size.width
            let viewH = geo.size.height
            // Use the actual reframe ratio; assume 16:9 source (most common)
            let sourceRatio: CGFloat = 16.0 / 9.0
            let targetRatio: CGFloat = reframeRatio?.ratio ?? (9.0 / 16.0)

            let cropWidthFraction = targetRatio / sourceRatio
            let maxSlide = 1.0 - cropWidthFraction
            let leftEdge = maxSlide * localReframeOffset
            let rightEdge = leftEdge + cropWidthFraction

            // Left dim region
            Path { p in
                p.addRect(CGRect(x: 0, y: 0, width: viewW * leftEdge, height: viewH))
            }
            .fill(Color.black.opacity(0.55))

            // Right dim region
            Path { p in
                p.addRect(CGRect(x: viewW * rightEdge, y: 0, width: viewW * (1 - rightEdge), height: viewH))
            }
            .fill(Color.black.opacity(0.55))

            // Crop border
            Rectangle()
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
                .frame(width: viewW * cropWidthFraction, height: viewH)
                .position(x: viewW * (leftEdge + cropWidthFraction / 2), y: viewH / 2)
        }
        .allowsHitTesting(false)
        .cornerRadius(8)
    }

    // MARK: - Preview generation

    /// Phase 1: generates 640-px thumbnails (fast, behind the loading screen).
    /// Phase 2: generates lightweight animated GIFs (10 fps, max 5 s) lazily
    ///          *after* the grid is already visible — they pop in as they finish.
    private func generateAllPreviews() async {
        let stills    = Array(markedStills.prefix(30))
        let clipThumb = Array(markedClips.prefix(30))
        let total     = max(1, Double(stills.count + clipThumb.count))
        var done      = 0.0

        // ── Phase 1: thumbnails only (fast) ───────────────────────────────
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        for still in stills {
            let t = CMTime(seconds: still.timestamp, preferredTimescale: 600)
            if let cg = try? await generator.image(at: t).image {
                let img = NSImage(cgImage: cg, size: .zero)
                await MainActor.run { thumbnails["still_\(still.id)"] = img }
            }
            done += 1
            await MainActor.run { loadingProgress = done / total }
        }
        for clip in clipThumb {
            let t = CMTime(seconds: clip.inPoint, preferredTimescale: 600)
            if let cg = try? await generator.image(at: t).image {
                let img = NSImage(cgImage: cg, size: .zero)
                await MainActor.run { thumbnails["clip_\(clip.id)"] = img }
            }
            done += 1
            await MainActor.run { loadingProgress = done / total }
        }

        // Show the grid immediately — GIFs will appear as they finish
        await MainActor.run { loadingProgress = 1; isLoadingPreviews = false }

        // ── Phase 2: lightweight GIFs (10 fps, max 5 s) ───────────────────
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        for clip in markedClips.prefix(20) {
            let clipKey  = "clip_\(clip.id)"
            let gifURL   = tempDir.appendingPathComponent("\(clip.id).gif")
            let maxDur   = clip.duration
            let fps      = 10
            let frames   = max(1, Int(maxDur * Double(fps)))
            let interval = maxDur / Double(frames)
            let delay    = 1.0 / Double(fps)

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 320)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter  = CMTime(seconds: 0.05, preferredTimescale: 600)

            guard let dest = CGImageDestinationCreateWithURL(
                gifURL as CFURL, UTType.gif.identifier as CFString, frames, nil
            ) else { continue }

            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
            ] as CFDictionary)

            let frameProp: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay],
                kCGImageDestinationLossyCompressionQuality as String: 0.5
            ]

            var ok = true
            for f in 0..<frames {
                let t = CMTime(seconds: clip.inPoint + Double(f) * interval, preferredTimescale: 600)
                guard let (cg, _) = try? await gen.image(at: t) else { ok = false; break }
                CGImageDestinationAddImage(dest, cg, frameProp as CFDictionary)
            }

            if ok && CGImageDestinationFinalize(dest) {
                await MainActor.run { clipGIFURLs[clipKey] = gifURL }
            }
        }
    }

    private func cleanupTempGIFs() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - Animated GIF View
/// NSViewRepresentable that wraps NSImageView with `animates = true` to play GIF files as looping animations.

struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.canDrawSubviewsIntoLayer = true
        if let image = NSImage(contentsOf: url) {
            imageView.image = image
        }
        context.coordinator.currentURL = url
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Reload when the URL changes (e.g. navigating between clips in the lightbox)
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            nsView.image = NSImage(contentsOf: url)
        } else if nsView.image == nil {
            nsView.image = NSImage(contentsOf: url)
        }
        nsView.animates = true
    }

    class Coordinator { var currentURL: URL? }
}

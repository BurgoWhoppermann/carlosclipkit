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
    @State private var currentDetectionId: UUID?
    @State private var showProcessSheet = false
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

    @State private var showFaceDetectionAlert = false
    @State private var showCutDetectionHint = false
    @State private var cachedFaceTimestamps: [Double]? = nil
    @State private var keyMonitor: Any? = nil
    @State private var stillsExpanded = false
    @State private var clipsExpanded = false
    @State private var loopingClipId: UUID? = nil
    @State private var showShortcuts = false
    @State private var showOnboarding = false
    @State private var forceGuidedOnboarding = false
    @State private var onboardingHighlights: [OnboardingHighlightID: CGRect] = [:]
    @State private var showAutoDetectPrompt = false
    @State private var previewingItemId: UUID? = nil
    @State private var previewDismissTask: Task<Void, Never>? = nil
    @State private var timelineZoomLevel: Double = 1.0
    private let sceneDetector = SceneDetector()
    private let videoProcessor = VideoProcessor()

    init(videoURL: URL) {
        self.videoURL = videoURL
        _playerController = StateObject(wrappedValue: LoopingPlayerController(url: videoURL))
    }

    // Fixed UI chrome height: markerHintBar (~50) + controlsBar (~130) + dividers (~4) + export bar (~60)
    private let fixedChromeHeight: CGFloat = 260

    var body: some View {
        mainContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomExportBar
            }
            .onPreferenceChange(OnboardingHighlightKey.self) { entries in
                var dict: [OnboardingHighlightID: CGRect] = [:]
                for entry in entries { dict[entry.id] = entry.rect }
                onboardingHighlights = dict
            }
            .coordinateSpace(name: "onboarding")
            .overlay(onboardingOverlay)
            .overlay(autoDetectPromptOverlay)
    }

    private var bottomExportBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))

                Button("Process...") {
                    showProcessSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullBlue)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .disabled(!markingState.hasMarkedItems)
                .help("Review, build grids, and export your marked items")
                .onboardingHighlight(.exportSettings)

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
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Video Player
                videoPlayerSection

                // Controls bar
                controlsBar

                // Pending clip indicator
                if markingState.pendingInPoint != nil {
                    pendingClipIndicator
                }

                Divider()

                // Everything below the controls bar scrolls together
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 0) {
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
                }
                .scrollIndicators(.visible)
                .layoutPriority(-1)
                .frame(minHeight: 60)
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
            showProcessSheet = true
        }
        .onAppear {
            // Show onboarding on first video load
            if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showOnboarding = true
                }
            } else {
                // Onboarding already done — prompt for auto-detect directly
                maybeShowAutoDetectPrompt()
            }

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
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                // Don't intercept keys when a sheet, overlay, popup, or alert is open
                if self.showProcessSheet || self.showShortcuts || self.showOnboarding || self.showAutoDetectPrompt ||
                   self.showExportComplete || self.showError || self.showFaceDetectionAlert || self.showCutDetectionHint {
                    return event
                }
                
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
                    app.exportStillsEnabled = true
                    self.flashKey("S")
                    return nil
                case "i":
                    ms.setInPoint(at: pc.currentTime, snapEnabled: app.snapToSceneCuts)
                    app.exportMovingClipsEnabled = true
                    self.flashKey("I")
                    return nil
                case "o":
                    ms.setOutPoint(at: pc.currentTime, snapEnabled: app.snapToSceneCuts, isManual: true)
                    app.exportMovingClipsEnabled = true
                    self.flashKey("O")
                    return nil
                case " ":
                    pc.togglePlayPause()
                    return nil
                case "z" where event.modifierFlags.contains(.command):
                    app.appUndo()
                    return nil
                default:
                    if event.keyCode == 53 { // Escape
                        ms.cancelPendingInPoint()
                        return nil
                    } else if event.keyCode == 51 || event.keyCode == 117 { // Backspace / Forward Delete
                        let tolerance = 0.05
                        let time = pc.currentTime
                        if let still = ms.markedStills.first(where: { abs($0.timestamp - time) < tolerance }) {
                            ms.removeStill(id: still.id)
                        } else if let clip = ms.markedClips.first(where: { abs($0.inPoint - time) < tolerance }) {
                            self.removeClipAndStopLoop(clip.id)
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
            DispatchQueue.main.async { appState.videoSize = newSize }
        }
        .onChange(of: appState.showCoachMarks) { show in
            if show {
                forceGuidedOnboarding = true
                showOnboarding = true
                DispatchQueue.main.async { appState.showCoachMarks = false }
            }
        }
        .onChange(of: showOnboarding) { showing in
            if !showing {
                forceGuidedOnboarding = false
                // After onboarding finishes, prompt for auto-detect
                maybeShowAutoDetectPrompt()
            }
        }
        .onChange(of: playerController.duration) { newDuration in
            if newDuration > 0 {
                DispatchQueue.main.async { appState.videoDuration = newDuration }
            }
        }
        // Live-update stills when still-only settings change
        .onChange(of: appState.stillCount) { _ in liveUpdateStills() }
        .onChange(of: appState.stillPlacement) { newPlacement in
            let sceneCount = max(1, effectiveScenes.count)
            DispatchQueue.main.async {
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
                showCutDetectionPopover = true
                detectScenes()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\"Prefer faces\" searches each scene for the best face frame. Run cut detection first so scenes can be analyzed individually.")
        }
        .alert("Cut Detection Recommended", isPresented: $showCutDetectionHint) {
            Button("Detect Cuts") {
                showCutDetectionPopover = true
                detectScenes()
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
        .sheet(isPresented: $showProcessSheet) {
            ProcessSheet(
                videoURL: videoURL,
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

    // MARK: - Onboarding Overlay

    @ViewBuilder
    private var onboardingOverlay: some View {
        if showOnboarding {
            OnboardingOverlayView(
                highlights: onboardingHighlights,
                isPresented: $showOnboarding,
                forceGuided: forceGuidedOnboarding
            )
        }
    }

    // MARK: - Auto-Detect Cuts Prompt

    /// Centered overlay shown while scene-cut detection is running, so the activity is visible
    /// without having to open the cuts menu.
    @ViewBuilder
    private var sceneDetectionPlayerOverlay: some View {
        if isDetectingScenes || appState.isDetectingScenes {
            ZStack {
                Color.black.opacity(0.35).allowsHitTesting(false)

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                        Text("Detecting scene cuts…")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    if appState.detectionProgress > 0 {
                        ProgressView(value: appState.detectionProgress)
                            .progressViewStyle(.linear)
                            .tint(.framePullBlue)
                            .frame(width: 220)
                        Text("\(Int(appState.detectionProgress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                    }

                    Button {
                        appState.cancelSceneDetection()
                        isDetectingScenes = false
                        appState.isDetectingScenes = false
                        appState.detectionProgress = 0
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Stop scene-cut detection")
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: isDetectingScenes || appState.isDetectingScenes)
        }
    }

    @ViewBuilder
    private var autoDetectPromptOverlay: some View {
        if showAutoDetectPrompt {
            ZStack {
                Color.black.opacity(0.3)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { showAutoDetectPrompt = false }
                    }

                AutoDetectPromptView(
                    onDetect: {
                        withAnimation(.easeOut(duration: 0.2)) { showAutoDetectPrompt = false }
                        detectScenes()
                    },
                    onSkip: {
                        withAnimation(.easeOut(duration: 0.2)) { showAutoDetectPrompt = false }
                    }
                )
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            .ignoresSafeArea()
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

            HStack(spacing: 8) {
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
            }
            .onboardingHighlight(.manualControls)

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
            .onboardingHighlight(.autoGenerate)

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

    // MARK: - Video Player

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
                .overlay(sceneDetectionPlayerOverlay)

                // Overlay: filename top-left, close top-right, playback controls bottom
                VStack {
                    HStack(alignment: .top) {
                        // Filename badge
                        HStack(spacing: 6) {
                            Image(systemName: "film")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.framePullAmber)
                            Text(videoURL.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(".\(videoURL.pathExtension.lowercased())")
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        .padding(8)

                        Spacer()

                        Button(action: {
                            appState.videoURL = nil
                            appState.clearSceneCache()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove video")
                        .padding(8)
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

                        // Playback Speed Menu / Buttons inline
                        HStack(spacing: 4) {
                            ForEach(MarkingState.PlaybackSpeed.allCases, id: \.self) { speed in
                                Button(speed.displayName) {
                                    markingState.playbackSpeed = speed
                                    playerController.setRate(Float(speed.rawValue))
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(markingState.playbackSpeed == speed ? .black : .white)
                                .frame(minWidth: 28, minHeight: 20)
                                .padding(.horizontal, 3)
                                .background(markingState.playbackSpeed == speed ? Color.white : Color.black.opacity(0.45))
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                                .help("Playback speed \(speed.displayName)")
                            }
                        }
                        .padding(.leading, 4)

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
            // Unified toolbar: S I O | Auto-Generate | Undo | Cuts | Snap | LUT | Zoom
            HStack(spacing: 8) {
                // Keycaps
                HStack(spacing: 4) {
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
                }
                .onboardingHighlight(.manualControls)

                Divider().frame(height: 16)

                // Auto-generate triggers popover
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
                .controlSize(.small)
                .help("Open auto-generation panel to create markers from scene analysis")
                .onboardingHighlight(.autoGenerate)
                .popover(isPresented: $showAnalysisDialog, arrowEdge: .top) {
                    inlineGeneratePanel
                        .frame(width: 450)
                        .padding()
                }

                if markingState.hasMarkedItems {
                    Button(action: { markingState.clearAll() }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .help("Clear All Stills & Clips")
                }

                if appState.canAppUndo {
                    Button(action: { appState.appUndo() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Undo (Cmd+Z)")
                }

                Spacer()

                // Cut detection popover button
                Button(action: { showCutDetectionPopover.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: cutDetectionIconName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(cutDetectionLabelText)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(isCutDetectionHovered ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .scaleEffect(isCutDetectionHovered ? 1.02 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isCutDetectionHovered)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCutDetectionHovered = hovering
                }
                .help("Cut detection settings")
                .onboardingHighlight(.detectCuts)
                .popover(isPresented: $showCutDetectionPopover, arrowEdge: .top) {
                    cutDetectionPopoverContent
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

                Divider().frame(height: 16)

                // Zoom Slider
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Slider(value: $timelineZoomLevel, in: 1...20)
                    .controlSize(.mini)
                    .frame(width: 80)
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
                    removeClipAndStopLoop(id)
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
                snapEnabled: appState.snapToSceneCuts,
                zoomLevel: $timelineZoomLevel
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
            .font(.system(.subheadline, design: .monospaced).weight(.bold))
            .foregroundColor(isActive ? .black : .white)
            .frame(width: 28, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? glowColor : Color.white.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0.8 : 0.3), lineWidth: 1)
            )
            .overlay(
                // Inner top bevel for a "keycap" 3D feel
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0.0 : 0.4), lineWidth: 1)
                    .offset(y: -1)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            )
            .shadow(color: isActive ? glowColor.opacity(0.8) : .black.opacity(0.3), radius: isActive ? 8 : 2, y: isActive ? 0 : 2)
            .scaleEffect(isActive ? 0.92 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.6), value: isActive)
            .contentShape(Rectangle())
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

                VStack(alignment: .leading, spacing: 6) {
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

                    Picker("", selection: $appState.stillPlacement) {
                        ForEach(StillPlacement.allCases, id: \.self) { placement in
                            Text(placement.rawValue).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("How stills are distributed — evenly across video, per scene, or at detected faces")
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
                    Button(action: { fillTimelineGaps() }) {
                        Label("Fill Timeline", systemImage: "rectangle.split.3x1.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.framePullBlue)
                    .help("Add clips to fill gaps between existing segments, using the scenes-per-clip setting for target size")
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

                        Button(action: {
                            playerController.seek(to: still.timestamp)
                            withAnimation(.easeOut(duration: 0.15)) { previewingItemId = still.id }
                            previewDismissTask?.cancel()
                            previewDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                guard !Task.isCancelled else { return }
                                withAnimation(.easeOut(duration: 0.3)) {
                                    if previewingItemId == still.id { previewingItemId = nil }
                                }
                            }
                        }) {
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
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(previewingItemId == still.id
                                  ? Color.framePullBlue.opacity(0.15)
                                  : Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(previewingItemId == still.id ? Color.framePullBlue.opacity(0.4) : .clear, lineWidth: 1)
                    )
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

                        Button(action: {
                            playerController.seek(to: clip.inPoint)
                            withAnimation(.easeOut(duration: 0.15)) { previewingItemId = clip.id }
                            previewDismissTask?.cancel()
                            previewDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                guard !Task.isCancelled else { return }
                                withAnimation(.easeOut(duration: 0.3)) {
                                    if previewingItemId == clip.id { previewingItemId = nil }
                                }
                            }
                        }) {
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

                        Button(action: {
                            removeClipAndStopLoop(clip.id)
                        }) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("Remove")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(previewingItemId == clip.id
                                  ? Color.framePullBlue.opacity(0.15)
                                  : Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(previewingItemId == clip.id ? Color.framePullBlue.opacity(0.4) : .clear, lineWidth: 1)
                    )
                    .cornerRadius(6)
                    .onTapGesture(count: 2) {
                        removeClipAndStopLoop(clip.id)
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
            appState.exportStillsEnabled = true
            flashKey("S")

        case .inPoint:
            markingState.setInPoint(at: playerController.currentTime, snapEnabled: appState.snapToSceneCuts)
            appState.exportMovingClipsEnabled = true
            flashKey("I")

        case .outPoint:
            markingState.setOutPoint(at: playerController.currentTime, snapEnabled: appState.snapToSceneCuts, isManual: true)
            appState.exportMovingClipsEnabled = true
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
                removeClipAndStopLoop(id)
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
            let frameDuration = 1.0 / 25.0
            let clip = MarkedClip(inPoint: spec.start + frameDuration, outPoint: spec.start + spec.duration - frameDuration, isManual: false)
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
        // Ensure both types are enabled when auto-generating
        appState.exportStillsEnabled = true
        appState.exportMovingClipsEnabled = true
        regenerateStills()
        regenerateClips()
    }

    /// Fill gaps between existing clips with new segments, preserving all current clips.
    /// Uses scene boundaries and the scenes-per-clip setting as a target, with ±1 scene variation.
    private func fillTimelineGaps() {
        let previousStills = markingState.markedStills
        let previousClips = markingState.markedClips

        let scenes = effectiveScenes
        guard !scenes.isEmpty else { return }

        let frameDuration = 1.0 / 25.0
        let cutMargin = 0.042 // ~1 frame at 24fps
        let targetWindowSize = min(appState.scenesPerClip, scenes.count)

        // Collect existing clip intervals (both manual and auto)
        let existingClips = markingState.markedClips.sorted { $0.inPoint < $1.inPoint }

        // Build list of gap intervals (uncovered time ranges)
        var gaps: [(start: Double, end: Double)] = []
        var cursor = scenes.first!.start
        for clip in existingClips {
            if clip.inPoint > cursor + frameDuration * 2 {
                gaps.append((start: cursor, end: clip.inPoint))
            }
            cursor = max(cursor, clip.outPoint)
        }
        let timelineEnd = scenes.last!.end
        if cursor < timelineEnd - frameDuration * 2 {
            gaps.append((start: cursor, end: timelineEnd))
        }

        guard !gaps.isEmpty else { return }

        markingState.suppressUndoCallback = true

        // For each gap, find scenes that fall within it and group them into segments
        for gap in gaps {
            // Find scenes that overlap this gap
            let gapScenes = scenes.enumerated().filter { _, scene in
                scene.start < gap.end - frameDuration && scene.end > gap.start + frameDuration
            }
            guard !gapScenes.isEmpty else { continue }

            var i = 0
            while i < gapScenes.count {
                // Vary window size: target ± 1 for variety, clamped to available scenes
                let variation = gapScenes.count - i >= targetWindowSize + 1
                    ? Int.random(in: -1...1)
                    : 0
                let windowSize = max(1, min(targetWindowSize + variation, gapScenes.count - i))

                let segStartScene = gapScenes[i].element
                let segEndScene = gapScenes[min(i + windowSize - 1, gapScenes.count - 1)].element

                // Clamp to gap boundaries
                let segStart = max(segStartScene.start + cutMargin, gap.start)
                let segEnd = min(segEndScene.end - cutMargin, gap.end)

                // Safety: ensure at least 2 frames of content, skip last frame to avoid flash
                let inPoint = segStart + frameDuration
                let outPoint = segEnd - frameDuration

                if outPoint > inPoint + frameDuration {
                    let clip = MarkedClip(
                        inPoint: inPoint,
                        outPoint: outPoint,
                        isManual: false
                    )
                    markingState.markedClips.append(clip)
                }

                i += windowSize
            }
        }

        markingState.markedClips.sort { $0.inPoint < $1.inPoint }
        markingState.suppressUndoCallback = false

        appState.appUndoStack.append(.settingsRegeneration(
            previousStills: previousStills, previousClips: previousClips,
            description: "Fill timeline gaps"))
    }

    private func maybeShowAutoDetectPrompt() {
        // Don't prompt if user opted out, or cuts already detected, or already detecting
        guard !UserDefaults.standard.bool(forKey: "autoDetectPromptDontShow") else { return }
        guard !appState.scenesDetected else { return }
        guard !isDetectingScenes else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showAutoDetectPrompt = true
        }
    }

    private func detectScenes() {
        // Cancel any in-progress detection
        appState.cancelSceneDetection()
        let detectionId = UUID()
        currentDetectionId = detectionId
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
                            // Only update if this is still the active detection
                            guard detectionId == currentDetectionId else { return }
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

    // MARK: - Helpers

    /// Remove a clip and stop looping if the removed clip was actively looping.
    private func removeClipAndStopLoop(_ id: UUID) {
        if loopingClipId == id {
            playerController.clearLoopRange()
            loopingClipId = nil
        }
        markingState.removeClip(id: id)
    }

}

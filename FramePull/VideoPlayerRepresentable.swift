import SwiftUI
import AVKit
import AppKit
import CoreImage

/// NSViewRepresentable wrapper for AVPlayerView with looping, keyboard, and click support
struct VideoPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let onKeyPress: (KeyPress) -> Void
    let onClick: () -> Void

    enum KeyPress {
        case still          // S key
        case inPoint        // I key
        case outPoint       // O key
        case playPause      // Space
        case cancelIn       // Escape
        case undo           // Cmd+Z
        case delete         // Delete / Backspace
        case jumpToPreviousMarker  // ↑ arrow
        case jumpToNextMarker      // ↓ arrow
        case skipFramesBack        // Shift+← arrow (−10 frames)
        case skipFramesForward     // Shift+→ arrow (+10 frames)
    }

    func makeNSView(context: Context) -> KeyCapturePlayerView {
        let playerView = KeyCapturePlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.keyPressHandler = onKeyPress
        playerView.clickHandler = onClick

        // Make sure view can become first responder
        DispatchQueue.main.async {
            playerView.window?.makeFirstResponder(playerView)
        }

        return playerView
    }

    func updateNSView(_ nsView: KeyCapturePlayerView, context: Context) {
        nsView.player = player
        nsView.keyPressHandler = onKeyPress
        nsView.clickHandler = onClick
        // First responder is handled by makeNSView, viewDidMoveToWindow, and mouseDown
        // Do NOT call makeFirstResponder here — updateNSView fires 20x/sec during playback
    }
}

/// Custom AVPlayerView that captures keyboard and mouse events
class KeyCapturePlayerView: AVPlayerView {
    var keyPressHandler: ((VideoPlayerRepresentable.KeyPress) -> Void)?
    var clickHandler: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder when added to window
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    // Arrow keys are intercepted by AVPlayerView's performKeyEquivalent before keyDown
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Shift+Left/Right → skip ±10 frames (must check before fallthrough to super)
        if event.keyCode == 123 && event.modifierFlags.contains(.shift) {
            keyPressHandler?(.skipFramesBack)
            return true
        } else if event.keyCode == 124 && event.modifierFlags.contains(.shift) {
            keyPressHandler?(.skipFramesForward)
            return true
        } else if event.keyCode == 126 { // Up arrow → previous marker
            keyPressHandler?(.jumpToPreviousMarker)
            return true
        } else if event.keyCode == 125 { // Down arrow → next marker
            keyPressHandler?(.jumpToNextMarker)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        switch characters {
        case "s":
            keyPressHandler?(.still)
        case "i":
            keyPressHandler?(.inPoint)
        case "o":
            keyPressHandler?(.outPoint)
        case " ":
            keyPressHandler?(.playPause)
        case "z" where event.modifierFlags.contains(.command):
            keyPressHandler?(.undo)
        default:
            if event.keyCode == 53 { // Escape
                keyPressHandler?(.cancelIn)
            } else if event.keyCode == 51 || event.keyCode == 117 { // Backspace / Forward Delete
                keyPressHandler?(.delete)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Make sure we're first responder on click
        window?.makeFirstResponder(self)
        // Trigger play/pause on click
        clickHandler?()
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }
}

/// Looping video player controller
class LoopingPlayerController: ObservableObject {
    let player: AVPlayer
    private var loopObserver: Any?
    private var timeObserver: Any?

    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    private var desiredRate: Float = 1.0
    @Published var volume: Float = 1.0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var videoSize: CGSize = CGSize(width: 16, height: 9) // Default aspect ratio

    init(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)

        setupLooping()
        setupTimeObserver()
        loadDuration()
        loadVideoSize()
    }

    deinit {
        player.pause()
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        if let observer = boundaryObserver {
            player.removeTimeObserver(observer)
        }
    }

    private func setupLooping() {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.player.seek(to: .zero)
            self.player.rate = self.desiredRate
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = CMTimeGetSeconds(time)
        }
    }

    private func loadDuration() {
        Task {
            if let item = player.currentItem {
                let duration = try? await item.asset.load(.duration)
                if let duration = duration {
                    await MainActor.run {
                        self.duration = CMTimeGetSeconds(duration)
                    }
                }
            }
        }
    }

    private func loadVideoSize() {
        Task {
            if let item = player.currentItem {
                let tracks = try? await item.asset.loadTracks(withMediaType: .video)
                if let videoTrack = tracks?.first {
                    let size = try? await videoTrack.load(.naturalSize)
                    let transform = try? await videoTrack.load(.preferredTransform)

                    if let naturalSize = size {
                        // Apply transform to get correct orientation
                        let correctedSize: CGSize
                        if let t = transform, t.a == 0 && t.d == 0 {
                            // Video is rotated 90 or 270 degrees
                            correctedSize = CGSize(width: naturalSize.height, height: naturalSize.width)
                        } else {
                            correctedSize = naturalSize
                        }
                        await MainActor.run {
                            self.videoSize = correctedSize
                        }
                    }
                }
            }
        }
    }

    var aspectRatio: CGFloat {
        guard videoSize.height > 0 else { return 16/9 }
        return videoSize.width / videoSize.height
    }

    func play() {
        player.rate = desiredRate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        player.volume = volume
        if volume == 0 {
            isMuted = true
            player.isMuted = true
        } else if isMuted {
            isMuted = false
            player.isMuted = false
        }
    }

    var volumeIconName: String {
        if isMuted || volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    // MARK: - Loop Range Playback
    // Plays a clip segment in a loop using a boundary time observer that seeks back to start when reaching end.
    // Used by timeline play buttons and the clips list loop button.

    @Published var loopRange: (start: Double, end: Double)? = nil
    private var boundaryObserver: Any?

    func setLoopRange(start: Double, end: Double) {
        clearLoopRange()
        loopRange = (start: start, end: end)
        seek(to: start)
        play()
        // Add boundary observer to loop back when reaching end
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self] in
            guard let self, let lr = self.loopRange else { return }
            self.seek(to: lr.start)
        }
    }

    func clearLoopRange() {
        if let obs = boundaryObserver {
            player.removeTimeObserver(obs)
            boundaryObserver = nil
        }
        loopRange = nil
    }

    // MARK: - LUT Video Composition (real-time preview)

    /// Apply a LUT to the video player preview using AVVideoComposition with CIFilter.
    func updateVideoComposition(cubeDimension: Int, cubeData: Data) {
        guard let asset = player.currentItem?.asset else { return }

        Task {
            let videoComposition = try? await AVMutableVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: { request in
                    let source = request.sourceImage.clampedToExtent()
                    guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
                        request.finish(with: source, context: nil)
                        return
                    }
                    filter.setValue(cubeDimension, forKey: "inputCubeDimension")
                    filter.setValue(cubeData, forKey: "inputCubeData")
                    filter.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
                    filter.setValue(source, forKey: kCIInputImageKey)
                    let output = filter.outputImage?.cropped(to: request.sourceImage.extent) ?? source
                    request.finish(with: output, context: nil)
                }
            )
            guard let videoComposition else { return }
            await MainActor.run {
                self.player.currentItem?.videoComposition = videoComposition
            }
        }
    }

    /// Remove LUT from video player preview
    func clearVideoComposition() {
        player.currentItem?.videoComposition = nil
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        player.rate = rate
        if rate > 0 {
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepFrames(_ count: Int) {
        let frameDuration = 1.0 / 25.0
        let newTime = max(0, min(duration, currentTime + Double(count) * frameDuration))
        seek(to: newTime)
    }

    // MARK: - Scrubbing (approximate, throttled — for timeline/marker drags)

    private var pendingSeek: Double? = nil
    private var isSeeking = false
    private var isScrubbing = false

    func scrub(to time: Double) {
        // Instant playhead feedback — timeline tracks the drag immediately
        currentTime = time
        isScrubbing = true

        guard !isSeeking else {
            pendingSeek = time
            return
        }
        isSeeking = true
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)

        // Short videos (< 5s) typically have few keyframes — keyframe-tolerant scrubbing snaps
        // every drag to the same frame, then the "exact final seek" jumps to the precise frame,
        // producing a visible flicker. For short clips, decode is cheap; do exact seeks throughout.
        let useExact = duration > 0 && duration < 5.0
        let tolerance: CMTime = useExact ? .zero : .positiveInfinity

        // Optimizes networking/buffering during rapid seeks
        player.currentItem?.preferredForwardBufferDuration = 1.0

        player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self else { return }
            
            if let pending = self.pendingSeek {
                self.pendingSeek = nil
                self.isSeeking = false
                self.scrub(to: pending)
            } else {
                // When pending is exhausted (cursor stopped), do one final exact seek
                let exactTime = CMTime(seconds: self.currentTime, preferredTimescale: 600)
                self.player.seek(to: exactTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    // Restore default forward buffering
                    self.player.currentItem?.preferredForwardBufferDuration = 0 // 0 means default
                    self.isSeeking = false
                    self.isScrubbing = false
                }
            }
        }
    }

    var currentFrame: Int {
        Int(currentTime * 25) + 1
    }

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

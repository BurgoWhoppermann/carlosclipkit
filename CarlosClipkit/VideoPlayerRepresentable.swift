import SwiftUI
import AVKit
import AppKit

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
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }

    private func setupLooping() {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
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
        player.play()
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

    func setRate(_ rate: Float) {
        player.rate = rate
        if rate > 0 {
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
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

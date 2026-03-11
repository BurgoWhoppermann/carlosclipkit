import SwiftUI
import AVKit

struct BetaSplashView: View {
    let version: String
    let build: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.trailing, 10)
            }

            // Header
            VStack(spacing: 8) {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 72, height: 72)
                }

                Text("FramePull")
                    .font(.title.weight(.bold))

                Text("BETA")
                    .font(.caption.weight(.heavy))
                    .tracking(3)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.framePullBlue)
                    .cornerRadius(4)
            }
            .padding(.top, 0)
            .padding(.bottom, 24)

            // Watch tutorial button
            Button(action: {
                TutorialWindowController.shared.showTutorial()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                    Text("Watch Quick Start Video")
                        .font(.body.weight(.medium))
                }
                .foregroundColor(.framePullBlue)
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .background(Color.framePullBlue.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)

            // YouTube link
            Button(action: {
                if let url = URL(string: "https://youtube.com/shorts/0gg_b9Xx1Xs") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.callout)
                    Text("Watch on YouTube")
                        .font(.callout)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)

            // What's New
            VStack(alignment: .leading, spacing: 6) {
                Text("What's New")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.framePullBlue)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "magnet").font(.caption2).foregroundColor(.secondary).frame(width: 14)
                    Text("Snap toggle on timeline — snap in/out points and drag edges to playhead or scene cuts")
                        .font(.caption2).foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "eye").font(.caption2).foregroundColor(.secondary).frame(width: 14)
                    Text("Preview in export — animated clip previews and still thumbnails before exporting")
                        .font(.caption2).foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "cube").font(.caption2).foregroundColor(.secondary).frame(width: 14)
                    Text("Added LUT Support")
                        .font(.caption2).foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "square.3.layers.3d").font(.caption2).foregroundColor(.secondary).frame(width: 14)
                    Text("Multi-lane timeline for overlapping clips, loop buttons on clip bars")
                        .font(.caption2).foregroundColor(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.caption2).foregroundColor(.secondary).frame(width: 14)
                    Text("Volume control, keyboard shortcuts work everywhere, auto-resize preview")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Build info + bug report
            VStack(spacing: 4) {
                Text("Build \(build)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: {
                    if let url = URL(string: "mailto:mail@carlooppermann.com?subject=FramePull%20Bug%20Report") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Found a bug? Please report to mail@carlooppermann.com")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 24)

            // Dismiss button
            Button(action: onDismiss) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.framePullBlue)
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 380, height: 500)
        .background(KeyDismissHandler(onDismiss: onDismiss))
    }

    /// Invisible NSView that captures key events to dismiss the splash
    private struct KeyDismissHandler: NSViewRepresentable {
        let onDismiss: () -> Void
        func makeNSView(context: Context) -> KeyCaptureView {
            let view = KeyCaptureView()
            view.onKeyDown = onDismiss
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            return view
        }
        func updateNSView(_ nsView: KeyCaptureView, context: Context) {}

        class KeyCaptureView: NSView {
            var onKeyDown: (() -> Void)?
            override var acceptsFirstResponder: Bool { true }
            override func keyDown(with event: NSEvent) {
                if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 53 {
                    onKeyDown?()
                } else {
                    super.keyDown(with: event)
                }
            }
        }
    }
}

// MARK: - Native Tutorial Window

class TutorialWindowController: NSObject, NSWindowDelegate {
    static let shared = TutorialWindowController()

    private var window: NSWindow?
    private var playerView: AVPlayerView?

    func showTutorial() {
        // If already open, just bring to front
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let videoURL = Bundle.main.url(forResource: "VideoTutorial1", withExtension: "mp4") else { return }

        let player = AVPlayer(url: videoURL)

        let avPlayerView = AVPlayerView()
        avPlayerView.player = player
        avPlayerView.controlsStyle = .floating
        avPlayerView.showsFullScreenToggleButton = true
        self.playerView = avPlayerView

        // Video is 1080x1660 (portrait) — open at a reasonable size
        let windowWidth: CGFloat = 440
        let windowHeight: CGFloat = 676

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FramePull — Quick Start"
        window.contentView = avPlayerView
        window.minSize = NSSize(width: 280, height: 430)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        playerView?.player?.pause()
        playerView?.player = nil
        playerView = nil
        window = nil
    }
}

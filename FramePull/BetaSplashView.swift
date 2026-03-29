import SwiftUI
import AVKit

struct SplashView: View {
    let version: String
    let build: String
    let onDismiss: () -> Void

    @State private var dontShowAgain = UserDefaults.standard.bool(forKey: "splashDontShowAgain")

    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [.framePullNavy, Color(red: 0.06, green: 0.18, blue: 0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                }

                // Header
                VStack(spacing: 6) {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }

                    Text("FramePull")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)

                    Text("v\(version)")
                        .font(.caption)
                        .foregroundColor(.framePullSilver.opacity(0.7))
                }
                .padding(.bottom, 20)

                // Workflow cards 2×2
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        WorkflowCard(
                            step: 1,
                            title: "Mark Manually",
                            subtitle: "Set stills & clip points on the timeline",
                            imageName: "tutorial_manual",
                            color: .framePullAmber
                        )
                        WorkflowCard(
                            step: 2,
                            title: "Detect Cuts",
                            subtitle: "Find scene boundaries automatically",
                            imageName: "tutorial_cuts",
                            color: .framePullBlue
                        )
                    }
                    HStack(spacing: 12) {
                        WorkflowCard(
                            step: 3,
                            title: "Auto-Generate",
                            subtitle: "Place stills & clips from detected scenes",
                            imageName: "tutorial_autogen",
                            color: .framePullAmber
                        )
                        WorkflowCard(
                            step: 4,
                            title: "Export",
                            subtitle: "Save stills, GIFs & video clips",
                            imageName: "tutorial_export",
                            color: .framePullBlue
                        )
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // Bottom section
                VStack(spacing: 10) {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 0.5)
                        .padding(.horizontal, 24)

                    // Feedback hint
                    HStack(spacing: 4) {
                        Text("Feature requests & feedback:")
                            .font(.caption)
                            .foregroundColor(.framePullSilver.opacity(0.6))
                        Button(action: {
                            if let url = URL(string: "mailto:mail@carlooppermann.com?subject=FramePull%20Feedback") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("mail@carlooppermann.com")
                                .font(.caption)
                                .foregroundColor(.framePullBlue)
                        }
                        .buttonStyle(.plain)
                    }

                    // Watch tutorial
                    Button(action: {
                        TutorialWindowController.shared.showTutorial()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                                .font(.callout)
                            Text("Watch Quick Start Video")
                                .font(.callout.weight(.medium))
                        }
                        .foregroundColor(.framePullAmber)
                    }
                    .buttonStyle(.plain)

                    // Don't show again
                    Toggle(isOn: $dontShowAgain) {
                        Text("Don't show on launch")
                            .font(.caption)
                            .foregroundColor(.framePullSilver.opacity(0.5))
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: dontShowAgain) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "splashDontShowAgain")
                    }

                    // Get Started
                    Button(action: onDismiss) {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullAmber)
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(width: 480, height: 620)
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

// MARK: - Workflow Card

private struct WorkflowCard: View {
    let step: Int
    let title: String
    let subtitle: String
    let imageName: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tutorial screenshot
            ZStack(alignment: .topLeading) {
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Step badge
                Text("\(step)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(color))
                    .offset(x: 6, y: 6)
            }

            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundColor(.white)

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.framePullSilver)
                .lineLimit(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
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

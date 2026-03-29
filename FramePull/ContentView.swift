import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    private static let appIcon = NSApplication.shared.applicationIconImage.copy() as! NSImage

    @EnvironmentObject var appState: AppState
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isDropTargeted: Bool = false

    private let supportedTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]

    var body: some View {
        VStack(spacing: 0) {
            if let videoURL = appState.videoURL {
                ManualMarkingView(videoURL: videoURL)
            } else {
                dropZoneView
                // Version footer (only on drop zone)
                versionFooter
            }
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
    }

    // MARK: - Drop Zone View
    private var dropZoneView: some View {
        VStack(spacing: 16) {
            // Recent videos (top)
            if !appState.recentVideos.isEmpty {
                recentVideosSection
            }

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .foregroundColor(isDropTargeted ? .framePullBlue : .secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isDropTargeted ? Color.framePullLightBlue : Color.clear)
                    )

                VStack(spacing: 12) {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .frame(width: 64, height: 64)

                    Text("Drop video here")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(isDropTargeted ? .framePullBlue : .primary)

                    Text("or")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button("Import...") {
                        importVideo()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullBlue)
                    .help("Browse for a video file to import")

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

    @State private var hoveredRecentURL: URL? = nil

    // MARK: - Recent Videos
    private var recentVideosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 4)

            HStack(spacing: 8) {
                ForEach(appState.recentVideos, id: \.url) { entry in
                    Button(action: {
                        _ = entry.url.startAccessingSecurityScopedResource()
                        appState.videoURL = entry.url
                        appState.clearSceneCache()
                        appState.addRecentVideo(entry.url)
                    }) {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.framePullBlue.opacity(hoveredRecentURL == entry.url ? 0.15 : 0.07))
                                Image(systemName: "film.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.framePullBlue.opacity(0.6))
                            }
                            .frame(height: 44)

                            Text(entry.name)
                                .font(.system(size: 10))
                                .foregroundColor(hoveredRecentURL == entry.url ? .framePullBlue : .secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.center)
                                .frame(height: 26)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(hoveredRecentURL == entry.url ? Color.secondary.opacity(0.08) : Color.clear)
                        )
                        .scaleEffect(hoveredRecentURL == entry.url ? 1.04 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: hoveredRecentURL)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredRecentURL = hovering ? entry.url : nil
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Version Footer
    private var versionFooter: some View {
        HStack {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.6))

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: - Actions

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
            appState.addRecentVideo(url)
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
                    appState.addRecentVideo(url)
                }
            }
        }

        return true
    }
}

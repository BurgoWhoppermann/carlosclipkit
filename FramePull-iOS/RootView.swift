//
//  RootView.swift
//  FramePull (iOS)
//
//  Import screen until a video is loaded, then the marking UI — the same shape
//  as the Mac target, where ContentView gives way to ManualMarkingView.
//

import SwiftUI
import PhotosUI
import AVFoundation

struct RootView: View {
    @StateObject private var markingState = MarkingState()
    @StateObject private var player = PlayerController()
    @StateObject private var detection = DetectionController()
    @StateObject private var recents = RecentVideoStore()

    @State private var videoURL: URL?
    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("detectionSensitivity") private var sensitivity: DetectionSensitivity = .medium

    var body: some View {
        NavigationStack {
            Group {
                if videoURL == nil {
                    importScreen
                } else {
                    MarkingView(
                        markingState: markingState,
                        player: player,
                        detection: detection,
                        videoURL: videoURL,
                        onChangeVideo: reset,
                        onDetectCuts: startDetection,
                        onClearCuts: { detection.clear(markingState: markingState) }
                    )
                }
            }
            .navigationTitle(videoURL == nil ? "FramePull" : "")
            .navigationBarTitleDisplayMode(videoURL == nil ? .large : .inline)
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            await loadFromPhotos(photoItem)
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        try await load(url: importSecurityScopedVideo(at: url))
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Import screen

    private var importScreen: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "film.stack")
                .font(.system(size: 58))
                .foregroundStyle(Color.framePullBlue)

            VStack(spacing: 6) {
                Text("Pull stills and clips from any video")
                    .font(.headline)
                Text("FramePull finds every scene cut, then you mark what you want.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.framePullBlue)

                Button {
                    isImportingFile = true
                } label: {
                    Label("Browse Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 28)

            if !recents.items.isEmpty && !isLoading {
                recentsSection
            }

            if isLoading {
                ProgressView("Loading video…")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)

            HStack(spacing: 10) {
                ForEach(recents.items) { item in
                    Button {
                        Task { try? await load(url: item.url) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                if let image = recents.thumbnails[item.path] {
                                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(Color.secondary.opacity(0.15))
                                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                                }
                            }
                            .frame(height: 62)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text(item.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(item.formattedDuration)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from recents", role: .destructive) { recents.remove(item) }
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Loading

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw VideoImportError.couldNotLoad
            }
            try await load(url: movie.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(url: URL) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        markingState.clearAll()
        try await player.load(url: url)

        markingState.videoDuration = player.duration
        markingState.sourceFrameRate = player.frameRate
        videoURL = url
        recents.add(url: url, duration: player.duration)

        startDetection()
    }

    private func startDetection() {
        guard let asset = player.asset else { return }
        detection.start(asset: asset, markingState: markingState, sensitivity: sensitivity)
    }

    private func reset() {
        detection.reset()
        player.pause()
        markingState.clearAll()
        markingState.detectedCuts = []
        videoURL = nil
        photoItem = nil
        errorMessage = nil
    }
}

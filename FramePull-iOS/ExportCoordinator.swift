//
//  ExportCoordinator.swift
//  FramePull (iOS)
//
//  Drives the SAME VideoProcessor / VideoSnippetProcessor the Mac app uses, so
//  output is byte-identical across platforms — including the stills/ gifs/ videos/
//  folder structure and the 4x5 / 9x16 subfolders.
//
//  The one genuine platform difference is delivery. macOS writes straight into a
//  user-chosen folder; iOS has no such thing, so everything is rendered into a
//  temporary working directory first and then either handed to the Photos library
//  or copied into a folder the user picks in the Files app.
//

import SwiftUI
import Photos
import AVFoundation

enum ExportDestination: String, CaseIterable, Identifiable {
    case photos, files
    var id: String { rawValue }

    var label: String {
        switch self {
        case .photos: return "Photos Library"
        case .files:  return "Files…"
        }
    }

    var detail: String {
        switch self {
        case .photos: return "Saved straight to your camera roll. Folders are flattened — Photos has no folders."
        case .files:  return "Pick a folder. Keeps the stills / gifs / videos structure."
        }
    }
}

struct MobileExportOptions {
    var exportStills = true
    var stillFormat: StillFormat = .jpeg
    var stillSize: StillSize = .full

    var exportClips = true
    var clipQuality: ClipQuality = .fullHD
    var muteAudio = false

    var exportGIF = false
    var gifResolution: GIFResolution = .hd720
    var gifFrameRate = 15
    var gifQuality = 0.7

    var export4x5 = false
    var export9x16 = false
}

@MainActor
final class ExportCoordinator: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published var errorMessage: String?
    @Published var completionMessage: String?

    /// Set once rendering finishes and the user still has to choose a folder.
    @Published var pendingFilesDelivery: URL?

    /// Source video name, so a Files delivery can name its folder after it.
    private var sourceName = "Export"

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isExporting = false
        status = "Cancelled."
    }

    func export(
        markingState: MarkingState,
        videoURL: URL,
        options: MobileExportOptions,
        destination: ExportDestination
    ) {
        guard !isExporting else { return }
        sourceName = videoURL.deletingPathExtension().lastPathComponent
        isExporting = true
        progress = 0
        errorMessage = nil
        completionMessage = nil
        status = "Preparing…"

        task = Task {
            do {
                let workDir = try makeWorkDirectory()
                try await render(
                    markingState: markingState,
                    videoURL: videoURL,
                    options: options,
                    into: workDir
                )
                try Task.checkCancellation()

                switch destination {
                case .photos:
                    status = "Saving to Photos…"
                    let count = try await saveToPhotos(from: workDir)
                    completionMessage = "Saved \(count) item\(count == 1 ? "" : "s") to Photos."
                    try? FileManager.default.removeItem(at: workDir)
                case .files:
                    status = "Choose a destination folder."
                    pendingFilesDelivery = workDir
                }

                progress = 1
            } catch is CancellationError {
                status = "Cancelled."
            } catch {
                errorMessage = error.localizedDescription
                status = "Export failed."
            }
            isExporting = false
        }
    }

    // MARK: - Rendering

    private func makeWorkDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func render(
        markingState: MarkingState,
        videoURL: URL,
        options: MobileExportOptions,
        into workDir: URL
    ) async throws {
        let stills = markingState.approvedStills
        let clips = markingState.approvedClips

        let stillUnits = options.exportStills ? stills.count : 0
        let clipUnits  = (options.exportClips || options.exportGIF) ? clips.count : 0
        let totalUnits = max(1, stillUnits + clipUnits)
        var done = 0

        if options.exportStills, !stills.isEmpty {
            status = "Exporting \(stills.count) still\(stills.count == 1 ? "" : "s")…"
            let processor = VideoProcessor()
            try await processor.extractStillsAtTimestamps(
                from: videoURL,
                timestamps: stills.map(\.timestamp),
                to: workDir,
                scale: options.stillSize.scale,
                format: options.stillFormat,
                export4x5: options.export4x5,
                export9x16: options.export9x16,
                reframeOffsets: stills.map(\.reframeOffset)
            ) { [weak self] fraction, message in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = (Double(done) + fraction * Double(stillUnits)) / Double(totalUnits)
                    if !message.isEmpty { self.status = message }
                }
            }
            done += stillUnits
            try Task.checkCancellation()
        }

        if options.exportClips || options.exportGIF, !clips.isEmpty {
            let processor = VideoSnippetProcessor()
            for (index, clip) in clips.enumerated() {
                try Task.checkCancellation()
                status = "Exporting clip \(index + 1) of \(clips.count)…"

                try await processor.exportClipAndGIF(
                    from: videoURL,
                    startTime: clip.inPoint,
                    duration: max(0.05, clip.outPoint - clip.inPoint),
                    resolution: options.gifResolution,
                    gifFrameRate: options.gifFrameRate,
                    gifQuality: options.gifQuality,
                    exportGIF: options.exportGIF,
                    exportMP4: options.exportClips,
                    format: .mp4,
                    to: workDir,
                    export4x5: options.export4x5,
                    export9x16: options.export9x16,
                    presetName: options.clipQuality.exportPreset,
                    muteAudio: options.muteAudio,
                    reframeOffset: clip.reframeOffset
                )

                done += 1
                progress = Double(done) / Double(totalUnits)
            }
        }
    }

    // MARK: - Delivery

    private func saveToPhotos(from workDir: URL) async throws -> Int {
        let authorized = await requestPhotoAddPermission()
        guard authorized else { throw ExportDeliveryError.photosDenied }

        let files = filesRecursively(in: workDir)
        var saved = 0

        for url in files {
            let ext = url.pathExtension.lowercased()
            let isVideo = (ext == "mp4" || ext == "mov")
            let isImage = (ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "tiff" || ext == "gif")
            guard isVideo || isImage else { continue }

            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: nil)
            }
            saved += 1
        }
        return saved
    }

    private func requestPhotoAddPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return true }
        let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return granted == .authorized || granted == .limited
    }

    /// Copies the rendered tree into a folder the user picked in Files, keeping
    /// the stills/ gifs/ videos/ layout intact.
    func deliverToFiles(destination: URL) {
        guard let workDir = pendingFilesDelivery else { return }
        defer {
            try? FileManager.default.removeItem(at: workDir)
            pendingFilesDelivery = nil
        }

        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        do {
            // Same layout as macOS: one folder per source video, reused on repeat
            // exports, rather than a new dated folder every time.
            let root = ProcessingUtilities.ensureExportRoot(
                in: destination,
                videoName: sourceName
            )

            var copied = 0
            for source in filesRecursively(in: workDir) {
                let relative = source.path.replacingOccurrences(of: workDir.path + "/", with: "")
                let target = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
                copied += 1
            }
            completionMessage = "Exported \(copied) file\(copied == 1 ? "" : "s") to \(root.lastPathComponent)."
            status = "Done."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func filesRecursively(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
    }
}

enum ExportDeliveryError: LocalizedError {
    case photosDenied

    var errorDescription: String? {
        switch self {
        case .photosDenied:
            return "FramePull needs permission to add items to your Photos library. Enable it in Settings, or export to Files instead."
        }
    }
}

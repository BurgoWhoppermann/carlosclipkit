//
//  VideoImport.swift
//  FramePull (iOS)
//
//  Two ways in: the Photos library (where phone footage actually lives) and the
//  Files app (for footage synced from a Mac or an external drive).
//
//  PhotosPicker hands back a Transferable, not a URL, so the movie is copied
//  into the app's own tmp directory first — AVAsset needs a stable file URL and
//  the picker's is short-lived.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            PickedMovie(url: try stageImport(of: received.file))
        }
    }
}

enum VideoImportError: LocalizedError {
    case couldNotLoad
    case couldNotAccess

    var errorDescription: String? {
        switch self {
        case .couldNotLoad:   return "That video couldn't be loaded."
        case .couldNotAccess: return "FramePull couldn't get access to that file."
        }
    }
}

/// Copies a security-scoped file (from the Files app) into our own tmp directory
/// so later reads don't depend on holding the scope open.
func importSecurityScopedVideo(at url: URL) throws -> URL {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    do {
        return try stageImport(of: url)
    } catch {
        throw VideoImportError.couldNotAccess
    }
}

/// Copies an incoming file into tmp, KEEPING ITS NAME.
///
/// Uniqueness comes from a per-import subdirectory rather than from renaming the file.
/// The name matters downstream: every exported still, clip and grid is prefixed with
/// `videoURL.deletingPathExtension().lastPathComponent`, as is the export folder and the
/// Photos album. Copying to "import-<UUID>.mov" meant all of it came out named after a
/// UUID instead of the user's video.
func stageImport(of source: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var name = source.lastPathComponent
    if name.isEmpty || source.pathExtension.isEmpty {
        // Some providers hand over an extensionless temp file.
        let base = name.isEmpty ? "Video" : source.deletingPathExtension().lastPathComponent
        name = "\(base).mov"
    }

    let destination = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
}

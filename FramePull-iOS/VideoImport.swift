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
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
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

    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("import-\(UUID().uuidString)")
        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)

    do {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    } catch {
        throw VideoImportError.couldNotAccess
    }
    return destination
}

//
//  GridThumbnailStore.swift
//  FramePull (iOS)
//
//  Frame thumbnails for the grid composer, cached by marker id.
//
//  The composer shows the same frame in the source strip and inside every cell, and cells
//  redraw constantly while panning and pinching. Generating on each redraw would stall the
//  gesture, so each frame is decoded once and kept.
//

import SwiftUI
import AVFoundation

@MainActor
final class GridThumbnailStore: ObservableObject {
    @Published private(set) var images: [UUID: UIImage] = [:]

    private var inFlight: Set<UUID> = []
    private var generator: AVAssetImageGenerator?
    private var sourceURL: URL?

    func prepare(url: URL) {
        guard sourceURL != url else { return }
        sourceURL = url
        images.removeAll()
        inFlight.removeAll()

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        // Cell previews are small; decoding full frames here would be wasteful.
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        generator = gen
    }

    func image(for id: UUID) -> UIImage? { images[id] }

    func load(id: UUID, at time: Double) {
        guard images[id] == nil, !inFlight.contains(id), let generator else { return }
        inFlight.insert(id)

        Task { [weak self] in
            let cg = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(id)
                if let cg { self.images[id] = UIImage(cgImage: cg) }
            }
        }
    }
}

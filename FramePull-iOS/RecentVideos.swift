//
//  RecentVideos.swift
//  FramePull (iOS)
//
//  The three most recently opened videos, shown on the import screen.
//
//  Imports are copied into the app's tmp directory, which the system may purge, so a
//  recent entry can outlive the file it points at. Each entry therefore keeps a thumbnail
//  and its own bookmark-free path, and the list is filtered on load: anything whose file
//  has gone is dropped rather than offered and then failing to open.
//

import SwiftUI
import AVFoundation

struct RecentVideo: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let duration: Double
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var formattedDuration: String {
        guard duration.isFinite, duration > 0 else { return "" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@MainActor
final class RecentVideoStore: ObservableObject {
    @Published private(set) var items: [RecentVideo] = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]

    private let key = "recentVideos"
    private let limit = 3

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentVideo].self, from: data) else {
            items = []
            return
        }
        // Drop entries whose file the system has purged.
        items = decoded.filter(\.exists)
        if items.count != decoded.count { persist() }
        items.forEach { loadThumbnail(for: $0) }
    }

    func add(url: URL, duration: Double) {
        let entry = RecentVideo(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            duration: duration,
            addedAt: Date()
        )
        items.removeAll { $0.path == entry.path }
        items.insert(entry, at: 0)
        items = Array(items.prefix(limit))
        persist()
        loadThumbnail(for: entry)
    }

    func remove(_ item: RecentVideo) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.path] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadThumbnail(for item: RecentVideo) {
        guard thumbnails[item.path] == nil, item.exists else { return }
        Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            // A frame a little way in — the very first frame is often black or a slate.
            let time = CMTime(seconds: min(1, max(0, item.duration * 0.1)), preferredTimescale: 600)
            guard let cg = try? await generator.image(at: time).image else { return }
            await MainActor.run { self?.thumbnails[item.path] = UIImage(cgImage: cg) }
        }
    }
}

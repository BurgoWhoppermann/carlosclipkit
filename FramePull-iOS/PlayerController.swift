//
//  PlayerController.swift
//  FramePull (iOS)
//
//  iOS counterpart to the Mac target's LoopingPlayerController. Same
//  responsibilities: own the AVPlayer, publish current time at a steady tick,
//  expose frame-accurate seeking and frame stepping, and surface the source
//  frame rate that every snap/offset calculation in MarkingState derives from.
//

import SwiftUI
import AVFoundation
import Combine

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var isReady = false

    let player = AVPlayer()

    /// Shared with scene detection so both read through one asset rather than two
    /// independent ones over the same file.
    private(set) var asset: AVURLAsset?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    var frameDuration: Double { 1.0 / max(1.0, frameRate) }

    init() {
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL) async throws {
        isReady = false
        let asset = AVURLAsset(url: url)
        self.asset = asset

        let loadedDuration = try await asset.load(.duration)
        duration = CMTimeGetSeconds(loadedDuration)

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let fps = try await track.load(.nominalFrameRate)
            if fps > 0 { frameRate = Double(fps) }

            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = size.applying(transform)
            videoSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        installTimeObserver()
        installEndObserver(for: item)

        currentTime = 0
        isReady = true
    }

    private func installTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        // 20 Hz, matching the Mac target. Higher rates flood SwiftUI with republishes
        // for no visible gain.
        let interval = CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = CMTimeGetSeconds(time)
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.isPlaying = false }
        }
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if currentTime >= duration - frameDuration { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Frame-accurate seek — zero tolerance, matching the Mac target so a marker
    /// set on iOS lands on exactly the same frame it would on desktop.
    func seek(to time: Double) {
        let clamped = min(max(0, time), max(0, duration))
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepFrames(_ count: Int) {
        pause()
        seek(to: currentTime + Double(count) * frameDuration)
    }
}

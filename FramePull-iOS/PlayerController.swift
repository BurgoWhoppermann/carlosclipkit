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

    // Scrub coalescing: at most one seek in flight, only the newest target kept.
    private var pendingSeek: Double?
    private var isSeeking = false
    private var isScrubbing = false

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
                self.isPlaying = self.player.rate != 0
                // While dragging, the playhead follows the finger. Letting the observer
                // write here too makes it flick back to wherever the player actually is.
                guard !self.isScrubbing else { return }
                self.currentTime = CMTimeGetSeconds(time)
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

    /// Scrub target for a drag in progress.
    ///
    /// Issuing a fresh exact seek on every gesture callback floods AVPlayer: each request
    /// on long-GOP H.264 has to decode from the preceding keyframe, they queue up, and the
    /// picture lurches between stale positions. ProRes hid this because it is all-intra and
    /// every seek is cheap.
    ///
    /// So: one seek in flight at a time, keeping only the newest target, with tolerance
    /// bounded to a single frame. When the finger stops, settle on the exact frame.
    func scrub(to time: Double) {
        let clamped = min(max(0, time), max(0, duration))
        currentTime = clamped
        isScrubbing = true

        guard !isSeeking else {
            pendingSeek = clamped
            return
        }
        isSeeking = true

        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = CMTime(seconds: frameDuration, preferredTimescale: 600)

        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let pending = self.pendingSeek {
                    self.pendingSeek = nil
                    self.isSeeking = false
                    self.scrub(to: pending)
                } else {
                    let exact = CMTime(seconds: self.currentTime, preferredTimescale: 600)
                    self.player.seek(to: exact, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        MainActor.assumeIsolated {
                            self.isSeeking = false
                            self.isScrubbing = false
                        }
                    }
                }
            }
        }
    }

    /// Call when a drag ends, so the playhead settles on an exact frame even if the last
    /// scrub was still in flight.
    func endScrub() {
        guard !isSeeking else { return }
        isScrubbing = false
        seek(to: currentTime)
    }

    func stepFrames(_ count: Int) {
        pause()
        isScrubbing = false
        seek(to: currentTime + Double(count) * frameDuration)
    }
}

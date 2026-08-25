//
//  DetectionController.swift
//  FramePull (iOS)
//
//  Owns scene-cut detection as an explicit, interruptible job rather than a fire-and-
//  forget await buried in the import path. Detection can be started manually, cancelled
//  mid-run, re-run against the same video, and its results cleared.
//
//  Two things here exist specifically to stop playback and detection fighting:
//
//   • Progress is throttled to whole percent. It used to publish on every reported
//     fraction, and each publish re-rendered the whole marking screen.
//   • The AVURLAsset is passed in and shared with the player rather than constructed
//     fresh, so the two don't set up duplicate decode paths over the same file.
//

import SwiftUI
import AVFoundation

/// Detection sensitivity, measured against the Bhattacharyya distance threshold.
///
/// Lower threshold = more cuts. Retuned for the spatial-grid distance metric; these
/// numbers are NOT comparable to the older global-histogram thresholds.
///
/// Measured on 30s of real 25fps footage: 0.40 -> 13 cuts, 0.28 -> 16, 0.20 -> 20.
/// Balanced sits inside a 0.25–0.30 plateau where the cut list does not change at all,
/// which is the sign that cuts and ordinary motion are cleanly separated.
enum DetectionSensitivity: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }

    var threshold: Double {
        switch self {
        case .low:    return 0.40
        case .medium: return 0.28
        case .high:   return 0.20
        }
    }

    var label: String {
        switch self {
        case .low:    return "Fewer cuts"
        case .medium: return "Balanced"
        case .high:   return "More cuts"
        }
    }
}

@MainActor
final class DetectionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(Double)
        case finished(Int)
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var lastPublishedPercent = -1

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var hasRun: Bool {
        switch phase {
        case .finished, .cancelled, .failed: return true
        case .idle, .running: return false
        }
    }

    var statusText: String {
        switch phase {
        case .idle:               return "Scene cuts not detected yet."
        case .running(let value): return "Detecting scene cuts… \(Int(value * 100))%"
        case .finished(let count): return "\(count) cut\(count == 1 ? "" : "s") detected."
        case .cancelled:          return "Detection cancelled."
        case .failed(let message): return message
        }
    }

    func start(asset: AVURLAsset, markingState: MarkingState, sensitivity: DetectionSensitivity) {
        cancel()

        phase = .running(0)
        lastPublishedPercent = -1

        task = Task { [weak self] in
            let detector = SceneDetector()
            do {
                let cuts = try await detector.detectSceneCuts(
                    from: asset,
                    threshold: sensitivity.threshold
                ) { fraction in
                    Task { @MainActor in self?.publish(fraction) }
                }
                try Task.checkCancellation()
                guard let self else { return }
                markingState.detectedCuts = cuts
                self.phase = .finished(cuts.count)
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed("Detection failed: \(error.localizedDescription)")
            }
        }
    }

    /// Only republish on a whole-percent change — the detector reports every 10 frames,
    /// and each published value re-renders the marking screen.
    private func publish(_ fraction: Double) {
        guard isRunning else { return }
        let percent = Int(fraction * 100)
        guard percent != lastPublishedPercent else { return }
        lastPublishedPercent = percent
        phase = .running(fraction)
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        phase = .cancelled
    }

    func clear(markingState: MarkingState) {
        cancel()
        markingState.detectedCuts = []
        phase = .idle
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}

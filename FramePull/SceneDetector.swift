import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics

class SceneDetector: @unchecked Sendable {

    // Pre-allocated context for 96x96 downsampling (to avoid allocating per frame)
    private let histogramContextLock = NSLock()
    private let reusedHistogramContext: CGContext? = {
        let size = 96
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        return context
    }()

    enum SceneDetectorError: LocalizedError {
        case cannotLoadVideo
        case cannotGetDuration
        case cannotGenerateFrame(time: CMTime)
        case noScenesDetected
        case detectionStalled(framesCompleted: Int, totalFrames: Int)

        var errorDescription: String? {
            switch self {
            case .cannotLoadVideo:
                return "Cannot load the video file for scene detection."
            case .cannotGetDuration:
                return "Cannot determine video duration."
            case .cannotGenerateFrame(let time):
                return "Failed to extract frame at time \(CMTimeGetSeconds(time)) seconds for scene analysis."
            case .noScenesDetected:
                return "No scenes could be detected in the video."
            case .detectionStalled(let done, let total):
                return "Scene detection stalled after \(done) of \(total) frames. Try again, or pause playback while it runs."
            }
        }
    }

    /// Detect scene cuts by analyzing frame differences using color histogram comparison.
    /// Samples at the source's native frame rate with zero seek tolerance — every recorded
    /// cut lands exactly on a source frame boundary. Uses batch frame generation for
    /// sequential decode (no per-frame seek).
    /// - Parameters:
    ///   - asset: The video asset to analyze
    ///   - threshold: Mean per-block Bhattacharyya distance (0.0–1.0), higher = fewer cuts.
    ///     Measured on 30s of real 25fps footage, cut count is flat at 16 across
    ///     0.25–0.30 — that plateau means cuts and motion separate cleanly there, so the
    ///     0.28 default sits in the middle of it. NOTE: this scale is not comparable to
    ///     the pre-2026-08 global-histogram thresholds.
    ///   - minimumSceneDuration: Minimum duration for a scene in seconds (suppresses
    ///     multiple cuts inside the same transition fade)
    ///   - progress: Optional callback reporting fraction complete (0.0–1.0)
    /// - Returns: Array of timestamps where scene cuts were detected
    func detectSceneCuts(
        from asset: AVURLAsset,
        threshold: Double = 0.28,
        minimumSceneDuration: Double = 0.15,
        progress: ((Double) -> Void)? = nil
    ) async throws -> [Double] {
        let isReadable = try await asset.load(.isReadable)
        guard isReadable else { throw SceneDetectorError.cannotLoadVideo }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { throw SceneDetectorError.cannotGetDuration }

        let tracks = try await asset.loadTracks(withMediaType: .video)
        let nominalFps: Float = (try? await tracks.first?.load(.nominalFrameRate)) ?? 30
        let fps = Double(nominalFps > 0 ? nominalFps : 30)
        let frameInterval = 1.0 / fps

        var allTimes: [Double] = []
        var t = 0.0
        while t < durationSeconds {
            allTimes.append(t)
            t += frameInterval
        }
        guard allTimes.count >= 2 else { return [] }

        // Short clips decode fast enough that the two-pass overhead isn't worth it.
        guard allTimes.count > Self.twoPassMinimumFrames else {
            let pairs = try await compare(
                times: allTimes, in: asset, threshold: threshold, progress: progress
            )
            return applyMinimumDuration(pairs.map(\.curr), minimum: minimumSceneDuration)
        }

        // PASS 1 — coarse scan.
        //
        // Sampling every frame of a 30s 25fps clip means 750 zero-tolerance decodes, which
        // is ~10s on a Mac and half a minute on a phone. A cut is a large change, so it is
        // still unmistakable when frames are compared several apart; only its exact
        // position is unknown. So scan coarsely to find WHERE a cut is, then decode every
        // frame just around each candidate to find WHICH frame it is. Frame accuracy is
        // preserved — only the wasted decoding between cuts goes away.
        // One generator for both passes. Building a fresh one per refinement window cost
        // more than the decoding it saved.
        let generator = Self.makeGenerator(for: asset)

        let stride = Self.coarseStride
        let coarseTimes = Swift.stride(from: 0, to: allTimes.count, by: stride).map { allTimes[$0] }

        // A deliberately permissive threshold: frames further apart differ more, and a
        // missed candidate here can never be recovered later.
        let candidates = try await compare(
            times: coarseTimes,
            in: asset,
            threshold: threshold * Self.coarseThresholdFactor,
            generator: generator,
            progress: { progress?($0 * Self.coarseProgressShare) }
        )

        guard !candidates.isEmpty else { return [] }

        // Consecutive candidates overlap; refining each separately would decode the same
        // frames twice and can split one transition across two windows.
        // Padded by two frames on each side. Candidate bounds are the decoder's ACTUAL
        // frame times, but the window is sampled with REQUESTED times, and a zero-tolerance
        // request lands on the frame at or before it. Without the pad the window came up
        // one frame short and missed cuts sitting on its trailing edge — a real cut at
        // 10.16 with distance 0.58 was silently dropped.
        let pad = frameInterval * 2

        var windows: [(lo: Double, hi: Double)] = []
        for candidate in candidates {
            let lo = candidate.prev - pad
            let hi = candidate.curr + pad
            if var last = windows.last, lo <= last.hi {
                last.hi = max(last.hi, hi)
                windows[windows.count - 1] = last
            } else {
                windows.append((lo, hi))
            }
        }

        // PASS 2 — refine each window to exact frames.
        var refined: [Double] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()

            let frames = allTimes.filter { $0 >= window.lo && $0 <= window.hi }
            guard frames.count >= 2 else { continue }

            // EVERY transition above the real threshold, not just the strongest: two cuts
            // 0.16s apart fall inside one coarse window, and keeping only the maximum threw
            // the second away. minimumSceneDuration collapses genuine duplicates later.
            let exact = try await compare(
                times: frames, in: asset, threshold: threshold, generator: generator
            )
            refined.append(contentsOf: exact.map(\.curr))

            progress?(Self.coarseProgressShare
                      + (1 - Self.coarseProgressShare) * Double(index + 1) / Double(windows.count))
        }

        progress?(1)
        return applyMinimumDuration(refined.sorted(), minimum: minimumSceneDuration)
    }

    // Two-pass tuning, measured on 30s of real 25fps footage (750 frames). Single pass
    // was 9.79s; these settings give 4.45s for an identical 16-cut result, and the
    // synthetic 4-scene clip still yields exactly 3 cuts.
    //
    // Stride 4 beats larger strides: wider coarse gaps mean wider refinement windows, and
    // the extra decoding there outweighs the samples saved. Factor 0.85 keeps a margin
    // below the real threshold — comparing frames 4 apart across a cut yields a LARGER
    // distance than adjacent frames do, so the coarse pass cannot miss what the fine pass
    // would find, but the margin covers fast cutting where a shot briefly returns.
    // Giving the coarse pass loose seek tolerance was tried and made no difference (4.51s):
    // batch generation already decodes ordered times efficiently.
    private static let twoPassMinimumFrames = 240
    private static let coarseStride = 4
    private static let coarseThresholdFactor = 0.85
    private static let coarseProgressShare = 0.7

    /// Suppresses cuts that land closer together than `minimum`, keeping the earliest.
    private func applyMinimumDuration(_ cuts: [Double], minimum: Double) -> [Double] {
        var result: [Double] = []
        var last = -Double.greatestFiniteMagnitude
        for cut in cuts where cut - last >= minimum {
            result.append(cut)
            last = cut
        }
        return result
    }


    /// One comparison of consecutive frames at the given times.
    ///
    /// Shared by both passes: the coarse scan calls it with strided times, the refinement
    /// with every frame around a candidate. Returns the transitions whose distance exceeds
    /// `threshold`, each carrying the frame before, the frame after, and the distance.
    struct FramePair {
        let prev: Double
        let curr: Double
        let distance: Double
    }

    private func compare(
        times: [Double],
        in asset: AVURLAsset,
        threshold: Double,
        generator: AVAssetImageGenerator? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws -> [FramePair] {
        guard times.count >= 2 else { return [] }

        let imageGenerator = generator ?? Self.makeGenerator(for: asset)
        let sampleTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let timesAsValues = sampleTimes.map { NSValue(time: $0) }

        // The accumulator owns every piece of mutable state behind a lock and guarantees
        // the continuation resumes exactly once. Bare local vars mutated straight from the
        // generator callback could hang forever: resuming only on an exact
        // `framesProcessed == totalSamples` match meant a single lost increment — a racy
        // callback, a frame the decoder failed to deliver under memory pressure, or the
        // cancellation path returning before the counter bumped — left it never resuming.
        let accumulator = DetectionAccumulator(totalSamples: times.count, threshold: threshold, detector: self)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Watchdog: if the generator stops delivering callbacks entirely, surface
                // the stall rather than waiting forever.
                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                watchdog.schedule(deadline: .now() + 30, repeating: 30)
                watchdog.setEventHandler {
                    guard accumulator.hasStalled() else { return }
                    watchdog.cancel()
                    imageGenerator.cancelAllCGImageGeneration()
                    // Deliberately not partial results: a truncated run looks identical to
                    // a completed one and silently hides missing scene cuts.
                    if let progressed = accumulator.finishStalled() {
                        continuation.resume(throwing: SceneDetectorError.detectionStalled(
                            framesCompleted: progressed.completed,
                            totalFrames: progressed.total
                        ))
                    }
                }
                watchdog.resume()

                imageGenerator.generateCGImagesAsynchronously(forTimes: timesAsValues) {
                    requestedTime, cgImage, actualTime, _, _ in

                    if Task.isCancelled {
                        imageGenerator.cancelAllCGImageGeneration()
                        if accumulator.finishOnce() {
                            watchdog.cancel()
                            continuation.resume(throwing: CancellationError())
                        }
                        return
                    }

                    // Index from requestedTime, not arrival order — see DetectionAccumulator.
                    let requested = CMTimeGetSeconds(requestedTime)
                    let index = times.enumerated()
                        .min(by: { abs($0.element - requested) < abs($1.element - requested) })?
                        .offset ?? 0

                    let step = accumulator.consume(index: index, image: cgImage, actualTime: actualTime)

                    if let fraction = step.progressFraction { progress?(fraction) }
                    if let result = step.finishedPairs {
                        watchdog.cancel()
                        continuation.resume(returning: result)
                    }
                }
            }
        } onCancel: {
            imageGenerator.cancelAllCGImageGeneration()
        }
    }

    /// Zero seek tolerance so the extracted frame is the actual frame at the requested
    /// time, not a nearby keyframe. Small output keeps histogram work cheap.
    private static func makeGenerator(for asset: AVURLAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 128, height: 128)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    // Spatial histogram layout. A single global colour histogram cannot tell a cut
    // between two shots of the same location apart from ordinary motion — both leave the
    // overall colour mix intact. Splitting the frame into a grid and comparing blocks
    // catches the reframing that a cut always brings.
    //
    // 96x96 downsample / 3 = 32x32 px blocks, 4 bins per channel = 64 bins per block,
    // 9 blocks = 576 doubles, comparable in size to the old 512-bin global histogram.
    static let gridDivisions = 3
    static let binsPerChannel = 4
    static let binsPerBlock = binsPerChannel * binsPerChannel * binsPerChannel
    static let blockCount = gridDivisions * gridDivisions

    /// Compute per-block RGB histograms from a CGImage, concatenated into one array.
    /// - Returns: `blockCount * binsPerBlock` values; each block's slice sums to 1.0.
    func computeHistogram(for image: CGImage) -> [Double] {
        let downsampleSize = 96

        histogramContextLock.lock()
        defer { histogramContextLock.unlock() }

        guard let context = reusedHistogramContext,
              let data = context.data else {
            return [Double](repeating: 0.0, count: Self.blockCount * Self.binsPerBlock)
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: downsampleSize, height: downsampleSize))
        return computeBlockHistograms(data: data, size: downsampleSize)
    }

    /// Build one normalized histogram per grid block.
    private func computeBlockHistograms(data: UnsafeMutableRawPointer, size: Int) -> [Double] {
        let divisions = Self.gridDivisions
        let bins = Self.binsPerChannel
        let binsPerBlock = Self.binsPerBlock
        let blockSize = size / divisions

        var histograms = [Double](repeating: 0.0, count: Self.blockCount * binsPerBlock)
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        for y in 0..<size {
            let blockRow = min(y / blockSize, divisions - 1)
            for x in 0..<size {
                let blockCol = min(x / blockSize, divisions - 1)
                let block = blockRow * divisions + blockCol

                let offset = (y * size + x) * 4
                let rBin = Int(bytes[offset]) * bins / 256
                let gBin = Int(bytes[offset + 1]) * bins / 256
                let bBin = Int(bytes[offset + 2]) * bins / 256

                let binIndex = rBin * bins * bins + gBin * bins + bBin
                histograms[block * binsPerBlock + binIndex] += 1.0
            }
        }

        // Normalize each block independently so blocks are comparable to each other.
        let pixelsPerBlock = Double(blockSize * blockSize)
        for i in 0..<histograms.count {
            histograms[i] /= pixelsPerBlock
        }
        return histograms
    }

    /// Distance between two frames, as the mean Bhattacharyya distance across grid blocks.
    ///
    /// The mean is what separates a cut from motion. A cut reframes everything, so nearly
    /// every block changes and the mean stays high. A person crossing the frame disturbs
    /// one or two blocks, which the mean dilutes. Taking the max instead would fire on any
    /// local movement; a global histogram would miss cuts inside one location.
    fileprivate func frameDistance(_ h1: [Double], _ h2: [Double]) -> Double {
        let binsPerBlock = Self.binsPerBlock
        let blocks = min(h1.count, h2.count) / binsPerBlock
        guard blocks > 0 else { return 0 }

        var total = 0.0
        for block in 0..<blocks {
            let start = block * binsPerBlock
            var bcCoefficient = 0.0
            for i in start..<(start + binsPerBlock) {
                bcCoefficient += sqrt(h1[i] * h2[i])
            }
            total += sqrt(max(0.0, 1.0 - min(1.0, bcCoefficient)))
        }
        return total / Double(blocks)
    }

    func getSceneRanges(cuts: [Double], videoDuration: Double) -> [(start: Double, end: Double)] {
        var ranges: [(start: Double, end: Double)] = []
        var previousCut = 0.0

        for cut in cuts {
            if cut > previousCut {
                ranges.append((start: previousCut, end: cut))
            }
            previousCut = cut
        }

        // Add final scene from last cut to end
        if previousCut < videoDuration {
            ranges.append((start: previousCut, end: videoDuration))
        }

        // If no cuts were detected, treat entire video as one scene
        if ranges.isEmpty {
            ranges.append((start: 0.0, end: videoDuration))
        }

        return ranges
    }

    /// Select timestamps ensuring distribution across different scenes
    /// - Parameters:
    ///   - sceneRanges: Array of scene ranges
    ///   - count: Number of timestamps to select
    /// - Returns: Array of selected timestamps
    func selectTimestampsAcrossScenes(
        sceneRanges: [(start: Double, end: Double)],
        count: Int
    ) -> [Double] {
        guard !sceneRanges.isEmpty else { return [] }
        guard count > 0 else { return [] }

        var timestamps: [Double] = []

        if count <= sceneRanges.count {
            // Select one timestamp from count different scenes
            // Distribute selections across scenes evenly
            let step = Double(sceneRanges.count) / Double(count)
            for i in 0..<count {
                let sceneIndex = min(Int(Double(i) * step), sceneRanges.count - 1)
                let scene = sceneRanges[sceneIndex]
                let timestamp = selectRandomTimestampInRange(scene)
                timestamps.append(timestamp)
            }
        } else {
            // More timestamps requested than scenes, distribute evenly
            let timestampsPerScene = count / sceneRanges.count
            let extraTimestamps = count % sceneRanges.count

            for (index, scene) in sceneRanges.enumerated() {
                let countForScene = timestampsPerScene + (index < extraTimestamps ? 1 : 0)
                let sceneTimestamps = selectMultipleTimestampsInRange(scene, count: countForScene)
                timestamps.append(contentsOf: sceneTimestamps)
            }
        }

        return timestamps.sorted()
    }

    /// Place exactly `countPerScene` stills in every scene — never skip any scene
    func selectTimestampsPerScene(
        sceneRanges: [(start: Double, end: Double)],
        countPerScene: Int
    ) -> [Double] {
        guard !sceneRanges.isEmpty, countPerScene > 0 else { return [] }

        var timestamps: [Double] = []
        for scene in sceneRanges {
            let sceneTimestamps = selectMultipleTimestampsInRange(scene, count: countPerScene)
            timestamps.append(contentsOf: sceneTimestamps)
        }
        return timestamps.sorted()
    }

    /// Select up to 3 start times per scene for clips/GIFs
    /// Adapts clip duration to fit shorter scenes rather than skipping them entirely
    /// - Parameters:
    ///   - sceneRanges: Available scene ranges
    ///   - duration: Desired clip/GIF duration (will be shortened for short scenes)
    /// - Returns: Array of (startTime, duration) tuples, up to 3 per scene
    func selectThreeStartTimesPerScene(
        sceneRanges: [(start: Double, end: Double)],
        duration: Double,
        adaptToScene: Bool = true
    ) -> [(start: Double, duration: Double)] {
        var results: [(start: Double, duration: Double)] = []

        // Minimum usable scene length (at least 1 second of content)
        let absoluteMinimumScene = 1.5
        // Minimum clip duration we'll accept (50% of requested, at least 1 second)
        let minimumClipDuration = max(1.0, duration * 0.5)

        for scene in sceneRanges {
            let sceneDuration = scene.end - scene.start

            // Skip extremely short scenes that can't produce any usable content
            guard sceneDuration >= absoluteMinimumScene else { continue }

            // Calculate how much of the scene we can use (leave small buffers at edges)
            // Use larger end buffer to ensure clips don't cross into the next scene
            let startBuffer = min(0.3, sceneDuration * 0.1)
            let endBuffer = max(0.5, min(0.5, sceneDuration * 0.15))
            let usableDuration = sceneDuration - startBuffer - endBuffer

            // Determine actual clip duration for this scene
            let actualClipDuration: Double
            let clipCount: Int

            if usableDuration >= duration {
                // Scene is long enough for full-length clips
                actualClipDuration = duration

                // How many clips can we fit?
                let availableForClips = usableDuration - actualClipDuration
                if availableForClips >= duration * 2 {
                    clipCount = 3  // Plenty of room for 3 clips
                } else if availableForClips >= duration {
                    clipCount = 2  // Room for 2 clips
                } else {
                    clipCount = 1  // Just 1 clip
                }
            } else if adaptToScene && usableDuration >= minimumClipDuration {
                // Scene is shorter but we can still extract a shorter clip
                actualClipDuration = usableDuration
                clipCount = 1  // Only 1 clip from short scenes
            } else {
                // Scene too short for even a minimum clip
                continue
            }

            let safeStart = scene.start + startBuffer
            let safeEnd = scene.end - endBuffer - actualClipDuration

            // Maximum allowed end time - clips must end 0.5s before scene boundary
            let maxEndTime = scene.end - 0.5

            if clipCount == 1 {
                // Single clip — place at midpoint of usable range
                let rangeStart = safeStart
                let rangeEnd = max(safeStart, safeEnd)
                var startTime = (rangeStart + rangeEnd) / 2

                // Validate clip won't cross into next scene
                let actualEndTime = startTime + actualClipDuration
                if actualEndTime > maxEndTime {
                    startTime = max(safeStart, maxEndTime - actualClipDuration)
                }

                results.append((start: startTime, duration: actualClipDuration))
            } else {
                // Multiple clips — deterministic even distribution
                // 2 clips → 1/3 and 2/3 points; 3 clips → 1/4, 1/2, 3/4 points
                let availableRange = max(0.001, safeEnd - safeStart)

                for i in 0..<clipCount {
                    let fraction = Double(i + 1) / Double(clipCount + 1)
                    var startTime = safeStart + (fraction * availableRange)

                    // Validate clip won't cross into next scene
                    let actualEndTime = startTime + actualClipDuration
                    if actualEndTime > maxEndTime {
                        startTime = max(safeStart, maxEndTime - actualClipDuration)
                    }

                    results.append((start: startTime, duration: actualClipDuration))
                }
            }
        }

        // Fallback for fast-paced content: if no clips could be extracted, use interval-based approach
        if results.isEmpty && !sceneRanges.isEmpty {
            let totalStart = sceneRanges.first!.start
            let totalEnd = sceneRanges.last!.end
            let totalDuration = totalEnd - totalStart

            // Extract clips at regular intervals (aim for 3-6 clips depending on video length)
            let numClips = min(6, max(3, Int(totalDuration / duration)))
            let interval = totalDuration / Double(numClips + 1)

            // Use shorter clip duration if needed
            let actualDuration = min(duration, totalDuration / Double(numClips) - 0.6)

            if actualDuration >= 1.0 {
                for i in 1...numClips {
                    let centerTime = totalStart + (interval * Double(i))
                    var startTime = centerTime - (actualDuration / 2)

                    // Find which scene this clip is in and ensure it doesn't cross boundaries
                    if let containingScene = sceneRanges.first(where: { startTime >= $0.start && startTime < $0.end }) {
                        let maxEndTime = containingScene.end - 0.5
                        let actualEndTime = startTime + actualDuration
                        if actualEndTime > maxEndTime {
                            startTime = max(containingScene.start + 0.3, maxEndTime - actualDuration)
                        }
                    }

                    let clampedStart = max(0.3, min(startTime, totalEnd - actualDuration - 0.5))
                    results.append((start: clampedStart, duration: actualDuration))
                }
            } else {
                // Video is very short - extract at least 1 clip from the longest continuous segment
                let longestScene = sceneRanges.max { ($0.end - $0.start) < ($1.end - $1.start) }!
                let sceneDuration = longestScene.end - longestScene.start
                let clipDuration = max(1.0, min(duration, sceneDuration - 1.0))
                var startTime = longestScene.start + (sceneDuration - clipDuration) / 2

                // Ensure clip ends 0.5s before scene boundary
                let maxEndTime = longestScene.end - 0.5
                if startTime + clipDuration > maxEndTime {
                    startTime = max(longestScene.start + 0.3, maxEndTime - clipDuration)
                }

                results.append((start: max(0.3, startTime), duration: clipDuration))
            }
        }

        return results.sorted { $0.start < $1.start }
    }

    /// Select clips that each span a given number of consecutive scenes, spread across the video
    func selectRandomClips(
        videoDuration: Double,
        scenesPerClip: Int,
        count: Int,
        allowOverlapping: Bool = false,
        sceneRanges: [(start: Double, end: Double)] = []
    ) -> [(start: Double, duration: Double)] {
        guard count > 0, videoDuration > 0 else { return [] }

        let scenes = sceneRanges.isEmpty
            ? [(start: 0.0, end: videoDuration)]
            : sceneRanges.sorted { $0.start < $1.start }
        let windowSize = min(scenesPerClip, scenes.count)

        // Build all valid candidates by sliding a window of windowSize consecutive scenes
        // Apply a 1-frame safety margin at scene boundaries to avoid transition flicker
        let cutMargin = 0.042  // ~1 frame at 24fps
        var candidates: [(start: Double, end: Double)] = []
        for i in 0...(scenes.count - windowSize) {
            let start = scenes[i].start + cutMargin
            let end = scenes[i + windowSize - 1].end - cutMargin
            if end > start {
                candidates.append((start: start, end: end))
            }
        }

        guard !candidates.isEmpty else { return [] }

        // Maximum non-overlapping windows of size windowSize across scenes.count scenes
        // is floor(scenes.count / windowSize). Using candidates.count here is wrong because
        // candidates includes all overlapping windows, making targetCount too high and
        // causing the overlap-rejection loop to silently produce fewer clips than requested.
        let maxNonOverlapping = scenes.count / max(1, windowSize)
        let targetCount = allowOverlapping
            ? count
            : min(count, maxNonOverlapping)

        // Select clips spread evenly with random jitter for variety
        var selected: [(start: Double, duration: Double)] = []
        let spacing = Double(candidates.count) / Double(targetCount)

        var usedIndices = Set<Int>()
        for i in 0..<targetCount {
            // Compute the range of candidates in this "bucket"
            let bucketStart = Int(Double(i) * spacing)
            let bucketEnd = min(Int(Double(i + 1) * spacing), candidates.count)
            let bucketSize = bucketEnd - bucketStart

            // Pick a random index within this bucket for variety on re-generate
            let jitter = bucketSize > 1 ? Int.random(in: 0..<bucketSize) : 0
            let centerIndex = bucketStart + jitter

            // Search outward from the picked index for a valid, non-overlapping candidate
            var bestIndex: Int? = nil
            for offset in 0..<candidates.count {
                for dir in [0, 1, -1] {
                    let idx = dir == 0 ? centerIndex : centerIndex + offset * dir
                    guard idx >= 0, idx < candidates.count else { continue }
                    if !allowOverlapping && usedIndices.contains(idx) { continue }
                    let candidate = candidates[idx]
                    if !allowOverlapping {
                        let overlaps = selected.contains { existing in
                            candidate.start < existing.start + existing.duration && candidate.end > existing.start
                        }
                        if overlaps { continue }
                    }
                    bestIndex = idx
                    break
                }
                if bestIndex != nil { break }
            }
            if let idx = bestIndex {
                let c = candidates[idx]
                selected.append((start: c.start, duration: c.end - c.start))
                usedIndices.insert(idx)
            }
        }

        return selected.sorted { $0.start < $1.start }
    }

    // MARK: - Private Methods

    /// Select a random timestamp within a scene range
    private func selectRandomTimestampInRange(_ range: (start: Double, end: Double)) -> Double {
        let safeMargin = min(0.5, (range.end - range.start) * 0.1)
        let safeStart = range.start + safeMargin
        let safeEnd = range.end - safeMargin

        guard safeEnd > safeStart else {
            return (range.start + range.end) / 2
        }

        return Double.random(in: safeStart...safeEnd)
    }

    /// Select multiple random timestamps within a scene range, spread evenly
    private func selectMultipleTimestampsInRange(
        _ range: (start: Double, end: Double),
        count: Int
    ) -> [Double] {
        guard count > 0 else { return [] }

        let duration = range.end - range.start
        let safeMargin = min(0.5, duration * 0.05)
        let safeStart = range.start + safeMargin
        let safeEnd = range.end - safeMargin

        guard safeEnd > safeStart else {
            return Array(repeating: (range.start + range.end) / 2, count: count)
        }

        if count == 1 {
            return [Double.random(in: safeStart...safeEnd)]
        }

        // Divide the range into segments and pick one from each
        let segmentDuration = (safeEnd - safeStart) / Double(count)
        var timestamps: [Double] = []

        for i in 0..<count {
            let segmentStart = safeStart + (Double(i) * segmentDuration)
            let segmentEnd = segmentStart + segmentDuration
            let timestamp = Double.random(in: segmentStart...segmentEnd)
            timestamps.append(timestamp)
        }

        return timestamps
    }
}


// MARK: - Detection accumulator

/// Serialises every piece of per-frame state touched by the image generator's callback
/// and guarantees the continuation is resumed exactly once.
private final class DetectionAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let totalSamples: Int
    private let threshold: Double
    private unowned let detector: SceneDetector

    private struct Frame {
        let histogram: [Double]?
        let time: Double
    }

    private var pairs: [SceneDetector.FramePair] = []
    private var previousHistogram: [Double]?
    private var previousTime: Double = 0
    private var pending: [Int: Frame] = [:]
    private var nextIndex = 0
    private var framesProcessed = 0
    private var framesAtLastCheck = -1
    private var finished = false

    struct Step {
        var progressFraction: Double?
        var finishedPairs: [SceneDetector.FramePair]?
    }

    init(totalSamples: Int, threshold: Double, detector: SceneDetector) {
        self.totalSamples = totalSamples
        self.threshold = threshold
        self.detector = detector
    }

    /// Frames are compared strictly in timeline order.
    ///
    /// generateCGImagesAsynchronously does not guarantee the handler fires in the order the
    /// times were requested, and histogram comparison is inherently sequential — a frame is
    /// only meaningful against the one before it. Comparing in arrival order silently
    /// corrupts the result (it dropped a 3-cut clip to 1 cut). So each frame is filed under
    /// its own index and the queue drained in order.
    func consume(index: Int, image: CGImage?, actualTime: CMTime) -> Step {
        // Histogram work stays outside the lock — it's the expensive part and needs
        // nothing shared.
        let histogram = image.map { detector.computeHistogram(for: $0) }
        let sampleTime = CMTimeGetSeconds(actualTime)

        lock.lock()
        defer { lock.unlock() }

        framesProcessed += 1
        pending[index] = Frame(histogram: histogram, time: sampleTime)

        while let frame = pending.removeValue(forKey: nextIndex) {
            nextIndex += 1
            guard let histogram = frame.histogram else { continue }

            if let previous = previousHistogram {
                let distance = detector.frameDistance(previous, histogram)
                if distance > threshold {
                    pairs.append(SceneDetector.FramePair(
                        prev: previousTime, curr: frame.time, distance: distance
                    ))
                }
            }
            previousHistogram = histogram
            previousTime = frame.time
        }

        var step = Step()
        if framesProcessed % 10 == 0 || framesProcessed >= totalSamples {
            step.progressFraction = min(1, Double(framesProcessed) / Double(totalSamples))
        }
        // `>=` rather than `==`: an exact match is too fragile to hang a whole import on.
        if framesProcessed >= totalSamples, !finished {
            finished = true
            step.finishedPairs = pairs.sorted { $0.curr < $1.curr }
        }
        return step
    }

    /// True when no callback has arrived since the previous watchdog tick.
    func hasStalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        let stalled = framesProcessed == framesAtLastCheck
        framesAtLastCheck = framesProcessed
        return stalled
    }

    /// Report how far the run got before the generator went quiet.
    func finishStalled() -> (completed: Int, total: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return (framesProcessed, totalSamples)
    }

    func finishOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

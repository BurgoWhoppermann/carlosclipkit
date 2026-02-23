import Foundation
import AVFoundation
import CoreImage
import AppKit

class SceneDetector {

    enum SceneDetectorError: LocalizedError {
        case cannotLoadVideo
        case cannotGetDuration
        case cannotGenerateFrame(time: CMTime)
        case noScenesDetected

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
            }
        }
    }

    /// Detect scene cuts by analyzing frame differences using color histogram comparison.
    /// Uses streaming: only 1 frame + 1 histogram in memory at a time (no bulk loading).
    /// - Parameters:
    ///   - asset: The video asset to analyze
    ///   - threshold: Bhattacharyya distance threshold (0.0-1.0), higher = fewer cuts detected. Real cuts typically score 0.4-0.7, motion/lighting 0.05-0.25
    ///   - samplingInterval: Time between sampled frames in seconds
    ///   - minimumSceneDuration: Minimum duration for a scene in seconds (to avoid micro-scenes)
    ///   - progress: Optional callback reporting fraction complete (0.0-1.0)
    /// - Returns: Array of timestamps where scene cuts were detected
    func detectSceneCuts(
        from asset: AVURLAsset,
        threshold: Double = 0.35,
        samplingInterval: Double = 0.1,
        minimumSceneDuration: Double = 0.15,
        progress: ((Double) -> Void)? = nil
    ) async throws -> [Double] {
        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw SceneDetectorError.cannotLoadVideo
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else {
            throw SceneDetectorError.cannotGetDuration
        }

        // Set up image generator with small output size for speed
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 128, height: 128)  // Small size for fast extraction
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        defer { imageGenerator.cancelAllCGImageGeneration() }

        // Generate timestamps to sample
        var sampleTimes: [Double] = []
        var currentTime = 0.0
        while currentTime < durationSeconds {
            sampleTimes.append(currentTime)
            currentTime += samplingInterval
        }

        let totalSamples = sampleTimes.count
        guard totalSamples >= 2 else {
            // Video too short for scene detection, return empty cuts
            return []
        }

        // Streaming comparison: extract one frame at a time, compare with previous histogram
        // Only 1 CGImage + 1 histogram in memory at any time
        var cuts: [Double] = []
        var lastCutTime: Double = 0.0
        var previousHistogram: [Double]? = nil
        var framesProcessed = 0

        for (index, sampleTime) in sampleTimes.enumerated() {
            // Support cooperative cancellation
            try Task.checkCancellation()

            let time = CMTime(seconds: sampleTime, preferredTimescale: 600)

            let cgImage: CGImage
            do {
                let (image, _) = try await imageGenerator.image(at: time)
                cgImage = image
            } catch {
                // Skip frames that can't be extracted
                continue
            }

            // Compute histogram for current frame
            let currentHistogram = computeHistogram(for: cgImage)
            // cgImage goes out of scope after this point — no accumulation

            if let prevHist = previousHistogram {
                let distance = bhattacharyyaDistance(prevHist, currentHistogram)

                if distance > threshold {
                    // Only add cut if it's far enough from the last cut (minimum scene duration)
                    if sampleTime - lastCutTime >= minimumSceneDuration {
                        cuts.append(sampleTime)
                        lastCutTime = sampleTime
                    }
                }
            }

            previousHistogram = currentHistogram
            framesProcessed += 1

            // Report progress every 10 frames to avoid callback overhead
            if index % 10 == 0 || index == totalSamples - 1 {
                progress?(Double(index + 1) / Double(totalSamples))
            }
        }

        return cuts.sorted()
    }

    /// Compute a normalized 512-bin color histogram from a CGImage
    /// Uses 8x8x8 RGB bins via a 96x96 downsampled context for speed
    /// - Parameter image: Source CGImage
    /// - Returns: Normalized histogram array (512 bins, sums to 1.0)
    func computeHistogram(for image: CGImage) -> [Double] {
        let downsampleSize = 96

        guard let context = createDownsampledContext(image, size: downsampleSize),
              let data = context.data else {
            return [Double](repeating: 0.0, count: 512)
        }

        let pixelCount = downsampleSize * downsampleSize
        return computeColorHistogram(data: data, pixelCount: pixelCount)
    }

    /// Compute an 8x8x8 RGB color histogram (512 bins) from pixel data
    private func computeColorHistogram(data: UnsafeMutableRawPointer, pixelCount: Int) -> [Double] {
        let binsPerChannel = 8
        let totalBins = binsPerChannel * binsPerChannel * binsPerChannel  // 512
        var histogram = [Double](repeating: 0.0, count: totalBins)
        let bytes = data.bindMemory(to: UInt8.self, capacity: pixelCount * 4)

        for i in 0..<pixelCount {
            let offset = i * 4
            let rBin = Int(bytes[offset]) * binsPerChannel / 256
            let gBin = Int(bytes[offset + 1]) * binsPerChannel / 256
            let bBin = Int(bytes[offset + 2]) * binsPerChannel / 256
            let binIndex = rBin * binsPerChannel * binsPerChannel + gBin * binsPerChannel + bBin
            histogram[binIndex] += 1.0
        }

        // Normalize to sum to 1.0
        let total = Double(pixelCount)
        for i in 0..<totalBins {
            histogram[i] /= total
        }

        return histogram
    }

    /// Compute Bhattacharyya distance between two normalized histograms
    /// Returns 0.0 (identical) to 1.0 (no overlap)
    private func bhattacharyyaDistance(_ h1: [Double], _ h2: [Double]) -> Double {
        var bcCoefficient = 0.0
        for i in 0..<h1.count {
            bcCoefficient += sqrt(h1[i] * h2[i])
        }
        // Clamp to [0,1] to handle floating point imprecision
        let distance = sqrt(max(0.0, 1.0 - bcCoefficient))
        return min(1.0, distance)
    }

    /// Create a downsampled RGB context from an image for fast comparison
    /// - Parameters:
    ///   - image: Source image
    ///   - size: Target size (both width and height)
    /// - Returns: CGContext with the downsampled image drawn, or nil on failure
    private func createDownsampledContext(_ image: CGImage, size: Int) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        return context
    }

    /// Divide video into scene ranges based on detected cuts
    /// - Parameters:
    ///   - cuts: Array of cut timestamps
    ///   - videoDuration: Total video duration in seconds
    /// - Returns: Array of scene ranges as (start, end) tuples
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

    /// Select random non-overlapping clip start times across the full video duration
    func selectRandomClips(
        videoDuration: Double,
        clipDuration: Double,
        count: Int,
        avoidCrossingScenes: Bool = false,
        allowOverlapping: Bool = false,
        sceneRanges: [(start: Double, end: Double)] = []
    ) -> [(start: Double, duration: Double)] {
        guard videoDuration > clipDuration, count > 0 else { return [] }

        // Build valid placement zones (clips align exactly with scene boundaries)
        var validZones: [(start: Double, end: Double)] = []

        if avoidCrossingScenes && !sceneRanges.isEmpty {
            for scene in sceneRanges {
                let zoneEnd = scene.end - clipDuration
                if zoneEnd > scene.start {
                    validZones.append((start: scene.start, end: zoneEnd))
                }
            }
        } else {
            let zoneEnd = videoDuration - clipDuration
            if zoneEnd > 0 {
                validZones.append((start: 0, end: zoneEnd))
            }
        }

        guard !validZones.isEmpty else { return [] }

        let totalZoneLength = validZones.reduce(0.0) { $0 + ($1.end - $1.start) }
        let targetCount: Int
        if allowOverlapping {
            targetCount = count
        } else {
            let maxClips = Int(totalZoneLength / clipDuration)
            targetCount = min(count, max(1, maxClips))
        }

        // Generate random non-overlapping start times via rejection sampling
        var placements: [Double] = []
        var attempts = 0
        let maxAttempts = targetCount * 100

        while placements.count < targetCount && attempts < maxAttempts {
            attempts += 1

            // Pick a random point weighted by zone length
            let randomPoint = Double.random(in: 0..<totalZoneLength)
            var accumulated = 0.0
            var chosenStart: Double? = nil

            for zone in validZones {
                let zoneLength = zone.end - zone.start
                if randomPoint < accumulated + zoneLength {
                    chosenStart = zone.start + (randomPoint - accumulated)
                    break
                }
                accumulated += zoneLength
            }

            guard let startTime = chosenStart else { continue }

            // Check for overlap with existing placements (skip if overlapping allowed)
            if allowOverlapping {
                placements.append(startTime)
            } else {
                let overlaps = placements.contains { existing in
                    let existingEnd = existing + clipDuration
                    let newEnd = startTime + clipDuration
                    return startTime < existingEnd && newEnd > existing
                }
                if !overlaps {
                    placements.append(startTime)
                }
            }
        }

        return placements.sorted().map { (start: $0, duration: clipDuration) }
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

import Foundation
import AVFoundation
import AppKit
import Vision

class VideoProcessor {

    // Number of candidate frames to sample when blur rejection is enabled
    private let blurCandidateCount = 10

    // Shared utilities are in ProcessingUtilities.swift

    enum ProcessingError: LocalizedError {
        case cannotLoadVideo
        case cannotGetDuration
        case cannotGenerateImage(time: CMTime)
        case cannotCreateImage
        case cannotWriteFile(path: String)

        var errorDescription: String? {
            switch self {
            case .cannotLoadVideo:
                return "Cannot load the video file. Please ensure it's a valid video format."
            case .cannotGetDuration:
                return "Cannot determine video duration."
            case .cannotGenerateImage(let time):
                return "Failed to extract frame at time \(CMTimeGetSeconds(time)) seconds."
            case .cannotCreateImage:
                return "Failed to create image."
            case .cannotWriteFile(let path):
                return "Failed to write file: \(path)"
            }
        }
    }

    func extractStills(
        from videoURL: URL,
        count: Int,
        to outputDirectory: URL,
        sceneRanges: [(start: Double, end: Double)]? = nil,
        specificTimestamps: [Double]? = nil,
        scale: Double = 1.0,
        format: StillFormat = .jpeg,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        // Load the video asset
        let asset = AVURLAsset(url: videoURL)

        // Check if the video is readable
        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw ProcessingError.cannotLoadVideo
        }

        // Get duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else {
            throw ProcessingError.cannotGetDuration
        }

        // Use specific timestamps if provided (from draggable markers), otherwise calculate
        let timestamps: [Double]
        if let specific = specificTimestamps, !specific.isEmpty {
            timestamps = specific.sorted()
        } else if let scenes = sceneRanges, !scenes.isEmpty {
            let sceneDetector = SceneDetector()
            timestamps = sceneDetector.selectTimestampsAcrossScenes(
                sceneRanges: scenes,
                count: count
            )
        } else {
            timestamps = generateRandomTimestamps(count: count, duration: durationSeconds)
        }

        // Set up image generator
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        defer { imageGenerator.cancelAllCGImageGeneration() }

        // Get video filename without extension for naming stills
        let videoName = videoURL.deletingPathExtension().lastPathComponent

        // Find next available index (to append rather than overwrite)
        let stillsDir = ProcessingUtilities.ensureSubdirectory(outputDirectory, path: "stills")
        let startingIndex = ProcessingUtilities.findNextAvailableIndex(in: stillsDir, prefix: "\(videoName)_still", suffix: ".\(format.fileExtension)")

        // Extract frames at the pre-refined timestamps
        let times = timestamps.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var index = 0

        for await result in imageGenerator.images(for: times) {
            progress(Double(index) / Double(count), "Extracting frame \(index + 1) of \(count)...")

            switch result {
            case .success(_, let image, _):
                var finalImage = image
                if scale < 1.0 {
                    finalImage = scaleImage(finalImage, scale: scale)
                }
                try saveFrame(finalImage, index: startingIndex + index - 1, videoName: videoName, outputDirectory: outputDirectory, format: format)
            case .failure(let time, _):
                throw ProcessingError.cannotGenerateImage(time: time)
            }

            index += 1
        }

        progress(1.0, "Complete!")
    }

    /// Save a CGImage in the specified format
    private func saveFrame(
        _ cgImage: CGImage,
        index: Int,
        videoName: String,
        outputDirectory: URL,
        format: StillFormat = .jpeg,
        subdirectory: String = "stills"
    ) throws {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)

        let imageData: Data?
        switch format {
        case .jpeg:
            imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .png:
            imageData = bitmapRep.representation(using: .png, properties: [:])
        case .tiff:
            imageData = bitmapRep.tiffRepresentation
        }

        guard let data = imageData else {
            throw ProcessingError.cannotCreateImage
        }

        // Save to the specified subdirectory (stills/, stills/4x5/, stills/9x16/)
        let stillsDir = ProcessingUtilities.ensureSubdirectory(outputDirectory, path: subdirectory)
        let filename = String(format: "%@_still_%03d.\(format.fileExtension)", videoName, index + 1)
        let fileURL = stillsDir.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL)
        } catch {
            throw ProcessingError.cannotWriteFile(path: fileURL.path)
        }
    }

    /// Check if an image contains a face using Vision rectangle detection
    /// More reliable than landmark detection for presence checks (works with profiles, low light, etc.)
    private func hasFace(in image: CGImage) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return false
        }

        guard let results = request.results else { return false }
        return results.contains { $0.confidence > 0.3 }
    }

    /// Compute sharpness using Laplacian variance on a downsampled grayscale image
    /// Downsamples to 512px wide for consistent, fast analysis (~1-2ms)
    private func computeSharpness(of image: CGImage) -> Double {
        let targetWidth = 512
        let aspectRatio = Double(image.height) / Double(image.width)
        let targetHeight = max(1, Int(Double(targetWidth) * aspectRatio))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let data = context.data else {
            return 0
        }

        let pixelData = data.bindMemory(to: UInt8.self, capacity: targetWidth * targetHeight)

        // Full Laplacian scan over all pixels (3x3 kernel: 0 1 0 / 1 -4 1 / 0 1 0)
        var sum: Double = 0
        var sumSquared: Double = 0
        var count: Double = 0

        for y in 1..<(targetHeight - 1) {
            for x in 1..<(targetWidth - 1) {
                let center = Int(pixelData[y * targetWidth + x])
                let top = Int(pixelData[(y - 1) * targetWidth + x])
                let bottom = Int(pixelData[(y + 1) * targetWidth + x])
                let left = Int(pixelData[y * targetWidth + (x - 1)])
                let right = Int(pixelData[y * targetWidth + (x + 1)])

                let laplacian = Double(top + bottom + left + right - 4 * center)

                sum += laplacian
                sumSquared += laplacian * laplacian
                count += 1
            }
        }

        guard count > 0 else { return 0 }

        let mean = sum / count
        let variance = (sumSquared / count) - (mean * mean)

        return variance
    }

    /// Scale a CGImage by the given factor (e.g. 0.5 for half size)
    private func scaleImage(_ image: CGImage, scale: Double) -> CGImage {
        let newWidth = Int(Double(image.width) * scale)
        let newHeight = Int(Double(image.height) * scale)

        guard newWidth > 0, newHeight > 0,
              let colorSpace = image.colorSpace,
              let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    private func generateRandomTimestamps(count: Int, duration: Double) -> [Double] {
        // Generate random timestamps across the full video duration
        // Avoid the very first and last 0.5 seconds to ensure valid frames
        let safeStart = min(0.5, duration * 0.01)
        let safeEnd = max(duration - 0.5, duration * 0.99)
        let safeDuration = safeEnd - safeStart

        var timestamps: [Double] = []
        for _ in 0..<count {
            let randomTime = safeStart + Double.random(in: 0...1) * safeDuration
            timestamps.append(randomTime)
        }

        // Sort timestamps for sequential extraction (better performance)
        return timestamps.sorted()
    }

    // MARK: - Timestamp Refinement ("Prefer Faces in Focus")

    /// Result of timestamp refinement — how many stills were shifted to better frames.
    struct RefinementResult {
        let timestamps: [Double]
        let shiftedCount: Int    // frames that moved to find a face/sharper frame
        let originalCount: Int   // how many we started with
    }

    /// For each scene, sample frames and pick the sharpest one with a detected face.
    /// Scenes with no face detected are skipped entirely.
    func findBestFacePerScene(
        from videoURL: URL,
        scenes: [(start: Double, end: Double)],
        countPerScene: Int = 1,
        progress: @escaping (Double, String) -> Void
    ) async -> [Double] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Relax tolerance — exact frames unnecessary for face detection
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        // Limit frame size — 1280px wide is plenty for face detection
        generator.maximumSize = CGSize(width: 1280, height: 0)
        defer { generator.cancelAllCGImageGeneration() }

        var results: [Double] = []

        for (index, scene) in scenes.enumerated() {
            if Task.isCancelled { break }
            progress(Double(index) / Double(scenes.count),
                     "Searching scene for faces \(index + 1) of \(scenes.count)...")

            let duration = scene.end - scene.start
            // Sample every ~0.3s, minimum 3 samples, cap at 30 per scene
            let sampleCount = max(3, min(30, Int(duration / 0.3)))
            let step = duration / Double(sampleCount + 1)

            var faceCandidates: [(time: Double, sharpness: Double)] = []
            var framesExtracted = 0
            var facesFound = 0

            let frameTimes = (1...sampleCount).map { i in
                CMTime(seconds: scene.start + step * Double(i), preferredTimescale: 600)
            }

            for await result in generator.images(for: frameTimes) {
                if Task.isCancelled { break }
                switch result {
                case .success(let cmTime, let cgImage, _):
                    framesExtracted += 1
                    let t = CMTimeGetSeconds(cmTime)
                    guard hasFace(in: cgImage) else { continue }
                    facesFound += 1
                    let sharpness = computeSharpness(of: cgImage)
                    faceCandidates.append((time: t, sharpness: sharpness))
                case .failure(let cmTime, let error):
                    #if DEBUG
                    print("[Prefer Faces] Frame extraction failed at \(CMTimeGetSeconds(cmTime))s: \(error.localizedDescription)")
                    #endif
                }
            }

            #if DEBUG
            print("[Prefer Faces] Scene \(index + 1): \(framesExtracted)/\(sampleCount) frames extracted, \(facesFound) faces found")
            #endif

            // Take top N by sharpness, spaced at least 0.5s apart
            let sorted = faceCandidates.sorted { $0.sharpness > $1.sharpness }
            var picked: [Double] = []
            for candidate in sorted {
                if picked.count >= countPerScene { break }
                let tooClose = picked.contains { abs($0 - candidate.time) < 0.5 }
                if !tooClose { picked.append(candidate.time) }
            }
            results.append(contentsOf: picked)
        }

        #if DEBUG
        print("[Prefer Faces] Total: \(results.count) stills from \(scenes.count) scenes")
        #endif
        progress(1.0, "Face search complete")
        return results.sorted()
    }

    /// Refine candidate timestamps by finding the sharpest face-containing frame nearby.
    /// If no face is found, falls back to the sharpest frame overall (never drops stills).
    /// Each still is constrained to search within its "zone" (midpoints to neighbors) to prevent clustering.
    func refineTimestamps(
        from videoURL: URL,
        timestamps: [Double],
        videoDuration: Double,
        progress: @escaping (Double, String) -> Void
    ) async -> RefinementResult {
        let asset = AVURLAsset(url: videoURL)

        // Share a single generator across all timestamps to avoid
        // spawning separate VTDecoderXPCService connections per still
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        defer { generator.cancelAllCGImageGeneration() }

        // Sort timestamps so we can compute zone boundaries
        let sorted = timestamps.sorted()

        var refined: [Double] = []
        var shiftedCount = 0

        for (index, timestamp) in sorted.enumerated() {
            progress(Double(index) / Double(sorted.count), "Refining frame \(index + 1) of \(sorted.count)...")

            // Compute zone boundaries: each still stays within midpoints to its neighbors
            let minBound = index == 0
                ? 0.0
                : (sorted[index - 1] + timestamp) / 2.0
            let maxBound = index == sorted.count - 1
                ? videoDuration
                : (timestamp + sorted[index + 1]) / 2.0

            let bestTime = await findBestFrameTimestamp(
                generator: generator,
                targetTime: timestamp,
                videoDuration: videoDuration,
                minBound: minBound,
                maxBound: maxBound
            )
            refined.append(bestTime)

            if abs(bestTime - timestamp) > 0.1 {
                shiftedCount += 1
            }
        }

        progress(1.0, "Refinement complete")
        return RefinementResult(timestamps: refined, shiftedCount: shiftedCount, originalCount: timestamps.count)
    }

    /// Find the best frame near a target time: prefers sharp face frames, falls back to sharpest frame.
    /// Searches ±3s outward from target, constrained to [minBound, maxBound] zone.
    /// Never returns nil — always finds the best available frame.
    private func findBestFrameTimestamp(
        generator: AVAssetImageGenerator,
        targetTime: Double,
        videoDuration: Double,
        minBound: Double = 0,
        maxBound: Double = .greatestFiniteMagnitude
    ) async -> Double {
        let effectiveMin = max(0.1, minBound)
        let effectiveMax = min(videoDuration - 0.1, maxBound)

        let offsets: [Double] = [0, 0.3, 0.6, 1.0, 1.5, 2.0, 2.5, 3.0]
        var candidateTimes: [Double] = []

        for offset in offsets {
            if offset == 0 {
                candidateTimes.append(targetTime)
            } else {
                let earlier = targetTime - offset
                let later = targetTime + offset
                if earlier >= effectiveMin { candidateTimes.append(earlier) }
                if later <= effectiveMax { candidateTimes.append(later) }
            }
        }

        var bestFace: (time: Double, sharpness: Double)?   // best frame WITH a face
        var bestOverall: (time: Double, sharpness: Double)? // best frame regardless

        let frameTimes = candidateTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }

        for await result in generator.images(for: frameTimes) {
            switch result {
            case .success(let cmTime, let cgImage, _):
                let candidateTime = CMTimeGetSeconds(cmTime)
                let sharpness = computeSharpness(of: cgImage)

                // Track best overall (fallback)
                if bestOverall == nil || sharpness > bestOverall!.sharpness {
                    bestOverall = (time: candidateTime, sharpness: sharpness)
                }

                // Track best with face (preferred)
                if hasFace(in: cgImage) {
                    if bestFace == nil || sharpness > bestFace!.sharpness {
                        bestFace = (time: candidateTime, sharpness: sharpness)
                    }
                }
            case .failure:
                continue
            }
        }

        // Prefer face frame, fall back to sharpest overall, fall back to original
        return bestFace?.time ?? bestOverall?.time ?? targetTime
    }

    // MARK: - Manual Marking Mode

    /// Extract stills at specific user-marked timestamps
    /// - Parameters:
    ///   - videoURL: Source video URL
    ///   - timestamps: Array of exact timestamps to extract
    ///   - outputDirectory: Where to save the stills
    ///   - progress: Progress callback
    // cropImageToAspectRatio is in ProcessingUtilities.swift

    func extractStillsAtTimestamps(
        from videoURL: URL,
        timestamps: [Double],
        to outputDirectory: URL,
        scale: Double = 1.0,
        format: StillFormat = .jpeg,
        export4x5: Bool = false,
        export9x16: Bool = false,
        lutCubeDimension: Int? = nil,
        lutCubeData: Data? = nil,
        reframeOffsets: [CGFloat]? = nil,
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws {
        guard !timestamps.isEmpty else { return }

        let asset = AVURLAsset(url: videoURL)

        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw ProcessingError.cannotLoadVideo
        }

        // Set up image generator
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        defer { imageGenerator.cancelAllCGImageGeneration() }

        let videoName = videoURL.deletingPathExtension().lastPathComponent

        // Pair timestamps with their reframe offsets, then sort by timestamp
        let offsets = reframeOffsets ?? Array(repeating: CGFloat(0.5), count: timestamps.count)
        let paired = zip(timestamps, offsets).sorted { $0.0 < $1.0 }

        // Find next available index so re-exports never overwrite existing files
        let stillsDir = ProcessingUtilities.ensureSubdirectory(outputDirectory, path: "stills")
        let startingIndex = ProcessingUtilities.findNextAvailableIndex(in: stillsDir, prefix: "\(videoName)_still", suffix: ".\(format.fileExtension)")
        let times = paired.map { CMTime(seconds: $0.0, preferredTimescale: 600) }
        var index = 0

        for await result in imageGenerator.images(for: times) {
            let (_, reframeOffset) = paired[index]
            let fileIndex = startingIndex + index - 1  // saveFrame uses index+1 for filename
            progress(Double(index) / Double(timestamps.count), "Extracting still \(index + 1) of \(timestamps.count)...")

            switch result {
            case .success(_, let image, _):
                var cgImage = image
                if scale < 1.0 {
                    cgImage = scaleImage(cgImage, scale: scale)
                }

                // Apply LUT color correction if active
                if let dim = lutCubeDimension, let data = lutCubeData {
                    cgImage = LUTProcessor.applyLUT(to: cgImage, cubeDimension: dim, cubeData: data) ?? cgImage
                }

                // Save original
                try saveFrame(cgImage, index: fileIndex, videoName: videoName, outputDirectory: outputDirectory, format: format)

                // Save 4:5 crop variant — uses reframe offset only when 9:16 is not also enabled
                if export4x5 {
                    let use4x5Offset = !export9x16
                    let cropped = ProcessingUtilities.cropImageToAspectRatio(cgImage, targetRatio: 4.0 / 5.0, horizontalOffset: use4x5Offset ? reframeOffset : 0.5)
                    try saveFrame(cropped, index: fileIndex, videoName: videoName, outputDirectory: outputDirectory, format: format, subdirectory: "stills/4x5")
                }

                // Save 9:16 crop variant with per-still reframe offset
                if export9x16 {
                    let cropped = ProcessingUtilities.cropImageToAspectRatio(cgImage, targetRatio: 9.0 / 16.0, horizontalOffset: reframeOffset)
                    try saveFrame(cropped, index: fileIndex, videoName: videoName, outputDirectory: outputDirectory, format: format, subdirectory: "stills/9x16")
                }
            case .failure(let time, _):
                print("Failed to extract frame at \(CMTimeGetSeconds(time))")
            }

            index += 1
        }

        progress(1.0, "Complete!")
    }

}

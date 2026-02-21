import Foundation
import AVFoundation
import AppKit
import Vision

class VideoProcessor {

    // Number of candidate frames to sample when blur rejection is enabled
    private let blurCandidateCount = 10

    /// Ensure a subdirectory exists and return its URL
    private func ensureSubdirectory(_ base: URL, path: String) -> URL {
        let subdir = base.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir
    }

    /// Find the next available file index in a directory
    /// Scans for files matching pattern like "videoname_still_001.jpg" and returns the next number
    private func findNextAvailableIndex(in directory: URL, prefix: String, suffix: String) -> Int {
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 1
        }

        var maxIndex = 0
        let pattern = "\(prefix)_"
        let suffixLower = suffix.lowercased()

        for file in files {
            let filename = file.lastPathComponent
            guard filename.hasPrefix(pattern) && filename.lowercased().hasSuffix(suffixLower) else {
                continue
            }

            // Extract the number from filename like "videoname_still_001.jpg"
            let withoutPrefix = String(filename.dropFirst(pattern.count))
            let withoutSuffix = String(withoutPrefix.dropLast(suffix.count))

            if let number = Int(withoutSuffix) {
                maxIndex = max(maxIndex, number)
            }
        }

        return maxIndex + 1
    }

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
        let stillsDir = ensureSubdirectory(outputDirectory, path: "stills")
        let startingIndex = findNextAvailableIndex(in: stillsDir, prefix: "\(videoName)_still", suffix: ".\(format.fileExtension)")

        // Extract frames at the pre-refined timestamps
        var savedCount = 0

        for (index, timestamp) in timestamps.enumerated() {
            progress(Double(index) / Double(count), "Extracting frame \(index + 1) of \(count)...")

            let time = CMTime(seconds: timestamp, preferredTimescale: 600)
            let cgImage: CGImage
            do {
                let (image, _) = try await imageGenerator.image(at: time)
                cgImage = image
            } catch {
                throw ProcessingError.cannotGenerateImage(time: time)
            }

            var finalImage = cgImage

            // Apply scale if needed
            if scale < 1.0 {
                finalImage = scaleImage(finalImage, scale: scale)
            }

            // Save with specified format, index continuing from previous extractions
            try saveFrame(finalImage, index: startingIndex + savedCount - 1, videoName: videoName, outputDirectory: outputDirectory, format: format)
            savedCount += 1
        }

        progress(1.0, "Complete!")
    }

    /// Save a CGImage in the specified format
    private func saveFrame(
        _ cgImage: CGImage,
        index: Int,
        videoName: String,
        outputDirectory: URL,
        format: StillFormat = .jpeg
    ) throws {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        let imageData: Data?
        switch format {
        case .jpeg:
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData) else {
                throw ProcessingError.cannotCreateImage
            }
            imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .png:
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData) else {
                throw ProcessingError.cannotCreateImage
            }
            imageData = bitmapRep.representation(using: .png, properties: [:])
        case .tiff:
            imageData = nsImage.tiffRepresentation
        }

        guard let data = imageData else {
            throw ProcessingError.cannotCreateImage
        }

        // Save to stills/ subdirectory
        let stillsDir = ensureSubdirectory(outputDirectory, path: "stills")
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
        return results.contains { $0.confidence > 0.5 }
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

    /// Refine candidate timestamps by finding the sharpest face-containing frame nearby.
    /// If no face is found, falls back to the sharpest frame overall (never drops stills).
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

        var refined: [Double] = []
        var shiftedCount = 0

        for (index, timestamp) in timestamps.enumerated() {
            progress(Double(index) / Double(timestamps.count), "Refining frame \(index + 1) of \(timestamps.count)...")

            let bestTime = await findBestFrameTimestamp(generator: generator, targetTime: timestamp, videoDuration: videoDuration)
            refined.append(bestTime)

            if abs(bestTime - timestamp) > 0.1 {
                shiftedCount += 1
            }
        }

        progress(1.0, "Refinement complete")
        return RefinementResult(timestamps: refined, shiftedCount: shiftedCount, originalCount: timestamps.count)
    }

    /// Find the best frame near a target time: prefers sharp face frames, falls back to sharpest frame.
    /// Searches ±3s outward from target. Never returns nil — always finds the best available frame.
    private func findBestFrameTimestamp(
        generator: AVAssetImageGenerator,
        targetTime: Double,
        videoDuration: Double
    ) async -> Double {
        let offsets: [Double] = [0, 0.3, 0.6, 1.0, 1.5, 2.0, 2.5, 3.0]
        var candidateTimes: [Double] = []

        for offset in offsets {
            if offset == 0 {
                candidateTimes.append(targetTime)
            } else {
                let earlier = targetTime - offset
                let later = targetTime + offset
                if earlier >= 0.1 { candidateTimes.append(earlier) }
                if later <= videoDuration - 0.1 { candidateTimes.append(later) }
            }
        }

        var bestFace: (time: Double, sharpness: Double)?   // best frame WITH a face
        var bestOverall: (time: Double, sharpness: Double)? // best frame regardless

        for candidateTime in candidateTimes {
            let time = CMTime(seconds: candidateTime, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await generator.image(at: time)
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
            } catch {
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
    func extractStillsAtTimestamps(
        from videoURL: URL,
        timestamps: [Double],
        to outputDirectory: URL,
        scale: Double = 1.0,
        format: StillFormat = .jpeg,
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
        let sortedTimestamps = timestamps.sorted()

        for (index, timestamp) in sortedTimestamps.enumerated() {
            progress(Double(index) / Double(timestamps.count), "Extracting still \(index + 1) of \(timestamps.count)...")

            let time = CMTime(seconds: timestamp, preferredTimescale: 600)

            do {
                var (cgImage, _) = try await imageGenerator.image(at: time)
                if scale < 1.0 {
                    cgImage = scaleImage(cgImage, scale: scale)
                }
                try saveFrame(cgImage, index: index, videoName: videoName, outputDirectory: outputDirectory, format: format)
            } catch {
                throw ProcessingError.cannotGenerateImage(time: time)
            }
        }

        progress(1.0, "Complete!")
    }

}

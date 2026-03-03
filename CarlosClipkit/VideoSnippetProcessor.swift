import Foundation
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

class VideoSnippetProcessor {

    /// Ensure a subdirectory exists and return its URL
    private func ensureSubdirectory(_ base: URL, path: String) -> URL {
        let subdir = base.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir
    }

    /// Find the next available file index in a directory
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

            let withoutPrefix = String(filename.dropFirst(pattern.count))
            let withoutSuffix = String(withoutPrefix.dropLast(suffix.count))

            if let number = Int(withoutSuffix) {
                maxIndex = max(maxIndex, number)
            }
        }

        return maxIndex + 1
    }

    enum SnippetError: LocalizedError {
        case cannotLoadVideo
        case cannotGetDuration
        case cannotCreateExportSession
        case exportFailed(String)
        case durationTooLong(available: Double)

        var errorDescription: String? {
            switch self {
            case .cannotLoadVideo:
                return "Cannot load the video file. Please ensure it's a valid video format."
            case .cannotGetDuration:
                return "Cannot determine video duration."
            case .cannotCreateExportSession:
                return "Cannot create video export session."
            case .exportFailed(let reason):
                return "Video export failed: \(reason)"
            case .durationTooLong(let available):
                return "Clip duration exceeds available video length (\(String(format: "%.1f", available)) seconds)."
            }
        }
    }

    func extractClips(
        from videoURL: URL,
        clipSpecs: [(start: Double, duration: Double)],
        format: OutputFormat,
        to outputDirectory: URL,
        export4x5: Bool = false,
        export9x16: Bool = false,
        presetName: String = AVAssetExportPresetHighestQuality,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let asset = AVURLAsset(url: videoURL)

        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw SnippetError.cannotLoadVideo
        }

        let videoName = videoURL.deletingPathExtension().lastPathComponent
        let totalCount = clipSpecs.count

        // Create videos subdirectory
        let videosDir = ensureSubdirectory(outputDirectory, path: "videos")

        // Find next available index (to append rather than overwrite)
        let startingIndex = findNextAvailableIndex(in: videosDir, prefix: "\(videoName)_clip", suffix: ".\(format.fileType)")

        for (clipIndex, spec) in clipSpecs.enumerated() {
            let clipProgress = Double(clipIndex) / Double(totalCount)
            progress(clipProgress, "Exporting clip \(clipIndex + 1) of \(totalCount)...")

            let fileNumber = startingIndex + clipIndex
            let filename = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
            let fileURL = videosDir.appendingPathComponent(filename)

            try await exportClip(
                from: asset,
                startTime: spec.start,
                duration: spec.duration,
                format: format,
                outputURL: fileURL,
                presetName: presetName
            )

            // Export 4:5 cropped version if requested
            if export4x5 {
                let videos4x5Dir = ensureSubdirectory(videosDir, path: "4x5")
                let filename4x5 = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let fileURL4x5 = videos4x5Dir.appendingPathComponent(filename4x5)

                try await exportCroppedClip(
                    from: asset,
                    startTime: spec.start,
                    duration: spec.duration,
                    format: format,
                    aspectRatio: .ratio4x5,
                    outputURL: fileURL4x5,
                    presetName: presetName
                )
            }

            // Export 9:16 cropped version if requested
            if export9x16 {
                let videos9x16Dir = ensureSubdirectory(videosDir, path: "9x16")
                let filename9x16 = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let fileURL9x16 = videos9x16Dir.appendingPathComponent(filename9x16)

                try await exportCroppedClip(
                    from: asset,
                    startTime: spec.start,
                    duration: spec.duration,
                    format: format,
                    aspectRatio: .ratio9x16,
                    outputURL: fileURL9x16,
                    presetName: presetName
                )
            }

            progress(Double(clipIndex + 1) / Double(totalCount), "Exported clip \(clipIndex + 1) of \(totalCount)")
        }

        progress(1.0, totalCount == 0 ? "No scenes long enough for clips" : "Complete!")
    }

    private func exportClip(
        from asset: AVURLAsset,
        startTime: Double,
        duration: Double,
        format: OutputFormat,
        outputURL: URL,
        presetName: String = AVAssetExportPresetHighestQuality
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: presetName
        ) else {
            throw SnippetError.cannotCreateExportSession
        }

        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let clipDuration = CMTime(seconds: duration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, duration: clipDuration)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = timeRange

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return
        case .failed:
            throw SnippetError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        case .cancelled:
            throw SnippetError.exportFailed("Export was cancelled")
        default:
            throw SnippetError.exportFailed("Unexpected export status")
        }
    }

    // MARK: - Manual Marking Mode

    /// Aspect ratio options for cropping
    enum AspectRatioCrop {
        case ratio4x5   // 0.8 (portrait, Instagram feed)
        case ratio9x16  // 0.5625 (vertical, Stories/Reels/TikTok)

        var ratio: CGFloat {
            switch self {
            case .ratio4x5: return 4.0 / 5.0
            case .ratio9x16: return 9.0 / 16.0
            }
        }

        var suffix: String {
            switch self {
            case .ratio4x5: return "_4x5"
            case .ratio9x16: return "_9x16"
            }
        }
    }

    /// Export both a video clip AND a GIF from the same in/out points
    /// Uses findNextAvailableIndex to never overwrite existing files
    func exportClipAndGIF(
        from videoURL: URL,
        startTime: Double,
        duration: Double,
        resolution: GIFResolution,
        gifQuality: Double = 0.7,
        exportGIF: Bool = true,
        exportMP4: Bool = true,
        format: OutputFormat,
        to outputDirectory: URL,
        export4x5: Bool = false,
        export9x16: Bool = false,
        presetName: String = AVAssetExportPresetHighestQuality
    ) async throws {
        let asset = AVURLAsset(url: videoURL)

        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw SnippetError.cannotLoadVideo
        }

        let videoName = videoURL.deletingPathExtension().lastPathComponent

        // Create subdirectories only when needed
        let videosDir = exportMP4 ? ensureSubdirectory(outputDirectory, path: "videos") : outputDirectory
        let gifsDir = exportGIF ? ensureSubdirectory(outputDirectory, path: "gifs") : outputDirectory

        // Find next available index for consistent numbering
        let clipIndex = exportMP4 ? findNextAvailableIndex(in: videosDir, prefix: "\(videoName)_clip", suffix: ".\(format.fileType)") : 1
        let gifIndex = exportGIF ? findNextAvailableIndex(in: gifsDir, prefix: "\(videoName)_clip", suffix: ".gif") : 1
        let fileNumber = max(clipIndex, gifIndex)

        // Export original video clip
        if exportMP4 {
            let clipFilename = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
            let clipURL = videosDir.appendingPathComponent(clipFilename)

            try await exportClip(
                from: asset,
                startTime: startTime,
                duration: duration,
                format: format,
                outputURL: clipURL,
                presetName: presetName
            )
        }

        // Export original GIF
        if exportGIF {
            let gifFilename = String(format: "%@_clip_%03d.gif", videoName, fileNumber)
            let gifURL = gifsDir.appendingPathComponent(gifFilename)

            try await createGIF(
                from: asset,
                startTime: startTime,
                duration: duration,
                frameRate: 15,
                maxWidth: resolution.maxWidth,
                quality: gifQuality,
                outputURL: gifURL
            )
        }

        // Export cropped versions if requested
        if export4x5 {
            if exportMP4 {
                let videos4x5Dir = ensureSubdirectory(videosDir, path: "4x5")
                let crop4x5ClipFilename = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let crop4x5ClipURL = videos4x5Dir.appendingPathComponent(crop4x5ClipFilename)

                try await exportCroppedClip(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    format: format,
                    aspectRatio: .ratio4x5,
                    outputURL: crop4x5ClipURL,
                    presetName: presetName
                )
            }

            if exportGIF {
                let gifs4x5Dir = ensureSubdirectory(gifsDir, path: "4x5")
                let crop4x5GifFilename = String(format: "%@_clip_%03d.gif", videoName, fileNumber)
                let crop4x5GifURL = gifs4x5Dir.appendingPathComponent(crop4x5GifFilename)

                try await createCroppedGIF(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    frameRate: 15,
                    maxWidth: resolution.maxWidth,
                    quality: gifQuality,
                    aspectRatio: .ratio4x5,
                    outputURL: crop4x5GifURL
                )
            }
        }

        if export9x16 {
            if exportMP4 {
                let videos9x16Dir = ensureSubdirectory(videosDir, path: "9x16")
                let crop9x16ClipFilename = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let crop9x16ClipURL = videos9x16Dir.appendingPathComponent(crop9x16ClipFilename)

                try await exportCroppedClip(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    format: format,
                    aspectRatio: .ratio9x16,
                    outputURL: crop9x16ClipURL,
                    presetName: presetName
                )
            }

            if exportGIF {
                let gifs9x16Dir = ensureSubdirectory(gifsDir, path: "9x16")
                let crop9x16GifFilename = String(format: "%@_clip_%03d.gif", videoName, fileNumber)
                let crop9x16GifURL = gifs9x16Dir.appendingPathComponent(crop9x16GifFilename)

                try await createCroppedGIF(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    frameRate: 15,
                    maxWidth: resolution.maxWidth,
                    quality: gifQuality,
                    aspectRatio: .ratio9x16,
                    outputURL: crop9x16GifURL
                )
            }
        }
    }

    /// Export a cropped video clip with specified aspect ratio (center crop)
    private func exportCroppedClip(
        from asset: AVURLAsset,
        startTime: Double,
        duration: Double,
        format: OutputFormat,
        aspectRatio: AspectRatioCrop,
        outputURL: URL,
        presetName: String = AVAssetExportPresetHighestQuality
    ) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SnippetError.cannotLoadVideo
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        // Apply transform to get actual video dimensions
        let transformedSize = naturalSize.applying(transform)
        let videoWidth = abs(transformedSize.width)
        let videoHeight = abs(transformedSize.height)

        // Calculate crop rectangle (center crop to target aspect ratio)
        let targetRatio = aspectRatio.ratio
        let currentRatio = videoWidth / videoHeight

        let cropRect: CGRect
        if currentRatio > targetRatio {
            // Video is wider than target - crop sides
            let newWidth = videoHeight * targetRatio
            let xOffset = (videoWidth - newWidth) / 2
            cropRect = CGRect(x: xOffset, y: 0, width: newWidth, height: videoHeight)
        } else {
            // Video is taller than target - crop top/bottom
            let newHeight = videoWidth / targetRatio
            let yOffset = (videoHeight - newHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: videoWidth, height: newHeight)
        }

        // Create composition
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SnippetError.cannotCreateExportSession
        }

        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let clipDuration = CMTime(seconds: duration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, duration: clipDuration)

        try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        // Add audio if available
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        // Set up video composition for cropping
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: clipDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)

        // Create transform that crops to center
        var cropTransform = CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)

        // Apply original video transform
        cropTransform = transform.concatenating(cropTransform)

        layerInstruction.setTransform(cropTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        videoComposition.instructions = [instruction]
        videoComposition.renderSize = CGSize(width: cropRect.width, height: cropRect.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: presetName
        ) else {
            throw SnippetError.cannotCreateExportSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return
        case .failed:
            throw SnippetError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        case .cancelled:
            throw SnippetError.exportFailed("Export was cancelled")
        default:
            throw SnippetError.exportFailed("Unexpected export status")
        }
    }

    /// Create a cropped GIF with specified aspect ratio (center crop)
    private func createCroppedGIF(
        from asset: AVURLAsset,
        startTime: Double,
        duration: Double,
        frameRate: Int,
        maxWidth: Int,
        quality: Double = 0.7,
        aspectRatio: AspectRatioCrop,
        outputURL: URL
    ) async throws {
        let frameCount = Int(duration * Double(frameRate))
        let frameInterval = duration / Double(frameCount)
        let delayTime = 1.0 / Double(frameRate)

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        defer { imageGenerator.cancelAllCGImageGeneration() }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw SnippetError.exportFailed("Cannot create GIF destination")
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delayTime
            ],
            kCGImageDestinationLossyCompressionQuality as String: quality
        ]

        for frameIndex in 0..<frameCount {
            let frameTime = startTime + (Double(frameIndex) * frameInterval)
            let time = CMTime(seconds: frameTime, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await imageGenerator.image(at: time)
                let croppedImage = cropImageToAspectRatio(cgImage, aspectRatio: aspectRatio)
                let outputImage = resizeImage(croppedImage, maxWidth: maxWidth)
                CGImageDestinationAddImage(destination, outputImage, frameProperties as CFDictionary)
            } catch {
                throw SnippetError.exportFailed("Cannot extract frame at \(frameTime)s")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw SnippetError.exportFailed("Cannot finalize GIF")
        }
    }

    /// Center-crop an image to the specified aspect ratio
    private func cropImageToAspectRatio(_ image: CGImage, aspectRatio: AspectRatioCrop) -> CGImage {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let targetRatio = aspectRatio.ratio
        let currentRatio = imageWidth / imageHeight

        let cropRect: CGRect
        if currentRatio > targetRatio {
            // Image is wider than target - crop sides
            let newWidth = imageHeight * targetRatio
            let xOffset = (imageWidth - newWidth) / 2
            cropRect = CGRect(x: xOffset, y: 0, width: newWidth, height: imageHeight)
        } else {
            // Image is taller than target - crop top/bottom
            let newHeight = imageWidth / targetRatio
            let yOffset = (imageHeight - newHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: imageWidth, height: newHeight)
        }

        return image.cropping(to: cropRect) ?? image
    }

    /// Create a GIF from video
    private func createGIF(
        from asset: AVURLAsset,
        startTime: Double,
        duration: Double,
        frameRate: Int,
        maxWidth: Int,
        quality: Double = 0.7,
        outputURL: URL
    ) async throws {
        let frameCount = Int(duration * Double(frameRate))
        let frameInterval = duration / Double(frameCount)
        let delayTime = 1.0 / Double(frameRate)

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        defer { imageGenerator.cancelAllCGImageGeneration() }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw SnippetError.exportFailed("Cannot create GIF destination")
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delayTime
            ],
            kCGImageDestinationLossyCompressionQuality as String: quality
        ]

        for frameIndex in 0..<frameCount {
            let frameTime = startTime + (Double(frameIndex) * frameInterval)
            let time = CMTime(seconds: frameTime, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await imageGenerator.image(at: time)
                let outputImage = resizeImage(cgImage, maxWidth: maxWidth)
                CGImageDestinationAddImage(destination, outputImage, frameProperties as CFDictionary)
            } catch {
                throw SnippetError.exportFailed("Cannot extract frame at \(frameTime)s")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw SnippetError.exportFailed("Cannot finalize GIF")
        }
    }

    /// Resize an image to fit within maxWidth
    private func resizeImage(_ image: CGImage, maxWidth: Int) -> CGImage {
        let originalWidth = image.width
        let originalHeight = image.height

        guard originalWidth > maxWidth else {
            return image
        }

        let scale = Double(maxWidth) / Double(originalWidth)
        let newWidth = maxWidth
        let newHeight = Int(Double(originalHeight) * scale)

        guard let colorSpace = image.colorSpace,
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
}

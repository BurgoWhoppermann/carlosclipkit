import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CoreImage

class VideoSnippetProcessor {

    // Shared utilities (ensureSubdirectory, findNextAvailableIndex, resizeImage, cropImageToAspectRatio) are in ProcessingUtilities.swift

    enum SnippetError: LocalizedError {
        case cannotLoadVideo
        case cannotGetDuration
        case cannotCreateExportSession
        case exportFailed(String)
        case durationTooLong(available: Double)
        case clipTooShort

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
            case .clipTooShort:
                return "Clip is too short to create a GIF (needs at least 1 frame)."
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
        muteAudio: Bool = false,
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
        let videosDir = ProcessingUtilities.ensureSubdirectory(outputDirectory, path: "videos")

        // Find next available index (to append rather than overwrite)
        let startingIndex = ProcessingUtilities.findNextAvailableIndex(in: videosDir, prefix: "\(videoName)_clip", suffix: ".\(format.fileType)")

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
                presetName: presetName,
                muteAudio: muteAudio
            )

            // Export 4:5 cropped version if requested
            if export4x5 {
                let videos4x5Dir = ProcessingUtilities.ensureSubdirectory(videosDir, path: "4x5")
                let filename4x5 = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let fileURL4x5 = videos4x5Dir.appendingPathComponent(filename4x5)

                try await exportCroppedClip(
                    from: asset,
                    startTime: spec.start,
                    duration: spec.duration,
                    format: format,
                    aspectRatio: .ratio4x5,
                    outputURL: fileURL4x5,
                    presetName: presetName,
                    muteAudio: muteAudio
                )
            }

            // Export 9:16 cropped version if requested
            if export9x16 {
                let videos9x16Dir = ProcessingUtilities.ensureSubdirectory(videosDir, path: "9x16")
                let filename9x16 = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let fileURL9x16 = videos9x16Dir.appendingPathComponent(filename9x16)

                try await exportCroppedClip(
                    from: asset,
                    startTime: spec.start,
                    duration: spec.duration,
                    format: format,
                    aspectRatio: .ratio9x16,
                    outputURL: fileURL9x16,
                    presetName: presetName,
                    muteAudio: muteAudio
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
        presetName: String = AVAssetExportPresetHighestQuality,
        lutCubeDimension: Int? = nil,
        lutCubeData: Data? = nil,
        muteAudio: Bool = false
    ) async throws {
        let start = CMTime(seconds: startTime, preferredTimescale: 600)
        let clipDuration = CMTime(seconds: duration, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: start, duration: clipDuration)

        // When muting audio, use a composition with only the video track
        let exportAsset: AVAsset
        if muteAudio {
            let composition = AVMutableComposition()
            if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
               let videoTrack = videoTracks.first,
               let compositionVideoTrack = composition.addMutableTrack(
                   withMediaType: .video,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            }
            exportAsset = composition
        } else {
            exportAsset = asset
        }

        guard let exportSession = AVAssetExportSession(
            asset: exportAsset,
            presetName: presetName
        ) else {
            throw SnippetError.cannotCreateExportSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        if muteAudio {
            // Composition already has the correct time range baked in
            exportSession.timeRange = CMTimeRange(start: .zero, duration: clipDuration)
        } else {
            exportSession.timeRange = timeRange
        }

        // Apply LUT via AVVideoComposition if active
        if let dim = lutCubeDimension, let data = lutCubeData {
            let videoComposition = try? await AVMutableVideoComposition.videoComposition(
                with: exportAsset,
                applyingCIFiltersWithHandler: { request in
                    let source = request.sourceImage.clampedToExtent()
                    guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
                        request.finish(with: source, context: nil)
                        return
                    }
                    filter.setValue(dim, forKey: "inputCubeDimension")
                    filter.setValue(data, forKey: "inputCubeData")
                    filter.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
                    filter.setValue(source, forKey: kCIInputImageKey)
                    let output = filter.outputImage?.cropped(to: request.sourceImage.extent) ?? source
                    request.finish(with: output, context: nil)
                }
            )
            exportSession.videoComposition = videoComposition
        }

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
        presetName: String = AVAssetExportPresetHighestQuality,
        lutCubeDimension: Int? = nil,
        lutCubeData: Data? = nil,
        muteAudio: Bool = false,
        reframeOffset: CGFloat = 0.5
    ) async throws {
        let asset = AVURLAsset(url: videoURL)

        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            throw SnippetError.cannotLoadVideo
        }

        let videoName = videoURL.deletingPathExtension().lastPathComponent

        // Create subdirectories only when needed
        let videosDir = exportMP4 ? ProcessingUtilities.ensureSubdirectory(outputDirectory, path: "videos") : outputDirectory
        let gifsDir = exportGIF ? ProcessingUtilities.ensureSubdirectory(outputDirectory, path: "gifs") : outputDirectory

        // Find next available index for consistent numbering
        let clipIndex = exportMP4 ? ProcessingUtilities.findNextAvailableIndex(in: videosDir, prefix: "\(videoName)_clip", suffix: ".\(format.fileType)") : 1
        let gifIndex = exportGIF ? ProcessingUtilities.findNextAvailableIndex(in: gifsDir, prefix: "\(videoName)_clip", suffix: ".gif") : 1
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
                presetName: presetName,
                lutCubeDimension: lutCubeDimension,
                lutCubeData: lutCubeData,
                muteAudio: muteAudio
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
                outputURL: gifURL,
                lutCubeDimension: lutCubeDimension,
                lutCubeData: lutCubeData
            )
        }

        // Export cropped versions if requested
        // When both 4:5 and 9:16 are enabled, 9:16 uses the reframe offset; 4:5 stays center-cropped.
        // When only 4:5 is enabled, 4:5 uses the reframe offset.
        let use4x5Offset = export4x5 && !export9x16
        if export4x5 {
            if exportMP4 {
                let videos4x5Dir = ProcessingUtilities.ensureSubdirectory(videosDir, path: "4x5")
                let crop4x5ClipFilename = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let crop4x5ClipURL = videos4x5Dir.appendingPathComponent(crop4x5ClipFilename)

                try await exportCroppedClip(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    format: format,
                    aspectRatio: .ratio4x5,
                    outputURL: crop4x5ClipURL,
                    presetName: presetName,
                    muteAudio: muteAudio,
                    horizontalOffset: use4x5Offset ? reframeOffset : 0.5
                )
            }

            if exportGIF {
                let gifs4x5Dir = ProcessingUtilities.ensureSubdirectory(gifsDir, path: "4x5")
                let crop4x5GifFilename = String(format: "%@_clip_%03d.gif", videoName, fileNumber)
                let crop4x5GifURL = gifs4x5Dir.appendingPathComponent(crop4x5GifFilename)

                try await createGIF(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    frameRate: 15,
                    maxWidth: resolution.maxWidth,
                    quality: gifQuality,
                    aspectRatio: .ratio4x5,
                    outputURL: crop4x5GifURL,
                    lutCubeDimension: lutCubeDimension,
                    lutCubeData: lutCubeData,
                    horizontalOffset: use4x5Offset ? reframeOffset : 0.5
                )
            }
        }

        if export9x16 {
            if exportMP4 {
                let videos9x16Dir = ProcessingUtilities.ensureSubdirectory(videosDir, path: "9x16")
                let crop9x16ClipFilename = String(format: "%@_clip_%03d.%@", videoName, fileNumber, format.fileType)
                let crop9x16ClipURL = videos9x16Dir.appendingPathComponent(crop9x16ClipFilename)

                try await exportCroppedClip(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    format: format,
                    aspectRatio: .ratio9x16,
                    outputURL: crop9x16ClipURL,
                    presetName: presetName,
                    muteAudio: muteAudio,
                    horizontalOffset: reframeOffset
                )
            }

            if exportGIF {
                let gifs9x16Dir = ProcessingUtilities.ensureSubdirectory(gifsDir, path: "9x16")
                let crop9x16GifFilename = String(format: "%@_clip_%03d.gif", videoName, fileNumber)
                let crop9x16GifURL = gifs9x16Dir.appendingPathComponent(crop9x16GifFilename)

                try await createGIF(
                    from: asset,
                    startTime: startTime,
                    duration: duration,
                    frameRate: 15,
                    maxWidth: resolution.maxWidth,
                    quality: gifQuality,
                    aspectRatio: .ratio9x16,
                    outputURL: crop9x16GifURL,
                    lutCubeDimension: lutCubeDimension,
                    lutCubeData: lutCubeData,
                    horizontalOffset: reframeOffset
                )
            }
        }
    }

    /// Export a cropped video clip with specified aspect ratio
    private func exportCroppedClip(
        from asset: AVURLAsset,
        startTime: Double,
        duration: Double,
        format: OutputFormat,
        aspectRatio: AspectRatioCrop,
        outputURL: URL,
        presetName: String = AVAssetExportPresetHighestQuality,
        muteAudio: Bool = false,
        horizontalOffset: CGFloat = 0.5
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

        // Calculate crop rectangle with adjustable horizontal position
        let targetRatio = aspectRatio.ratio
        let currentRatio = videoWidth / videoHeight

        let cropRect: CGRect
        if currentRatio > targetRatio {
            // Video is wider than target - crop sides
            let newWidth = videoHeight * targetRatio
            let xOffset = (videoWidth - newWidth) * horizontalOffset
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

        // Add audio if available (skip when muting)
        if !muteAudio,
           let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
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

    /// Create a GIF from video, with optional aspect ratio cropping
    private func createGIF(
        from asset: AVURLAsset,
        startTime: Double,
        duration: Double,
        frameRate: Int,
        maxWidth: Int,
        quality: Double = 0.7,
        aspectRatio: AspectRatioCrop? = nil,
        outputURL: URL,
        lutCubeDimension: Int? = nil,
        lutCubeData: Data? = nil,
        horizontalOffset: CGFloat = 0.5
    ) async throws {
        let frameCount = Int(duration * Double(frameRate))
        guard frameCount >= 1 else {
            throw SnippetError.clipTooShort
        }
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
                let cropped = aspectRatio.map { ProcessingUtilities.cropImageToAspectRatio(cgImage, targetRatio: $0.ratio, horizontalOffset: horizontalOffset) } ?? cgImage
                var outputImage = ProcessingUtilities.resizeImage(cropped, maxWidth: maxWidth)
                // Apply LUT color correction if active
                if let dim = lutCubeDimension, let data = lutCubeData {
                    outputImage = LUTProcessor.applyLUT(to: outputImage, cubeDimension: dim, cubeData: data) ?? outputImage
                }
                CGImageDestinationAddImage(destination, outputImage, frameProperties as CFDictionary)
            } catch {
                throw SnippetError.exportFailed("Cannot extract frame at \(frameTime)s")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw SnippetError.exportFailed("Cannot finalize GIF")
        }
    }
}

import Foundation
import AVFoundation
import AppKit
import CoreImage
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Renders a `GridConfig` into a JPEG (all-still grids) or an MP4 (any-clip grids).
/// Crop math is shared with the SwiftUI preview via `CellTransform.drawRect`, guaranteeing WYSIWYG.
final class GridExporter {

    enum GridExportError: LocalizedError {
        case emptyGrid
        case incompleteGrid
        case frameExtractionFailed(time: Double)
        case canvasRenderFailed
        case writeFailed(URL)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyGrid: return "Grid has no cells assigned."
            case .incompleteGrid: return "Grid is missing cells — fill every slot before exporting."
            case .frameExtractionFailed(let t): return "Could not extract frame at \(t)s from source video."
            case .canvasRenderFailed: return "Failed to compose grid canvas."
            case .writeFailed(let url): return "Failed to write grid file at \(url.path)."
            case .writerFailed(let msg): return "Video writer failed: \(msg)"
            }
        }
    }

    // MARK: - Image grid (all stills)

    /// Export an image grid (all cells must be stills). Writes a JPEG to `outputURL`.
    func exportImageGrid(
        config: GridConfig,
        sourceVideoURL: URL,
        markedStills: [MarkedStill],
        markedClips: [MarkedClip],
        outputURL: URL,
        lutCubeDimension: Int? = nil,
        lutCubeData: Data? = nil,
        jpegQuality: CGFloat = 0.92
    ) async throws {
        guard config.filledCount > 0 else { throw GridExportError.emptyGrid }
        guard config.isComplete else { throw GridExportError.incompleteGrid }

        let canvasSize = config.ratio.outputSize()
        let asset = AVURLAsset(url: sourceVideoURL)

        let cellImages = try await extractStaticCellImages(
            cells: config.filledCells,
            asset: asset,
            canvasSize: canvasSize,
            markedStills: markedStills,
            markedClips: markedClips,
            lutCubeDimension: lutCubeDimension,
            lutCubeData: lutCubeData
        )

        guard let composite = composeIntoCGImage(config: config, canvasSize: canvasSize, cellImages: cellImages) else {
            throw GridExportError.canvasRenderFailed
        }
        try writeJPEG(composite, to: outputURL, quality: jpegQuality)
    }

    // MARK: - Video grid (any clip)

    /// Export a video grid. Output duration matches the longest clip in the grid; shorter clips loop;
    /// stills render as static frames. Resolution comes from `config.ratio.outputSize()`.
    func exportVideoGrid(
        config: GridConfig,
        sourceVideoURL: URL,
        markedStills: [MarkedStill],
        markedClips: [MarkedClip],
        outputURL: URL,
        frameRate: Int32 = 30,
        lutCubeDimension: Int? = nil,
        lutCubeData: Data? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard config.filledCount > 0 else { throw GridExportError.emptyGrid }
        guard config.isComplete else { throw GridExportError.incompleteGrid }

        let stillByID = Dictionary(uniqueKeysWithValues: markedStills.map { ($0.id, $0) })
        let clipByID = Dictionary(uniqueKeysWithValues: markedClips.map { ($0.id, $0) })

        // Resolve clip cells (sources we'll extract per-frame)
        var clipsInGrid: [(source: GridCellSource, clip: MarkedClip)] = []
        for cell in config.filledCells {
            if case .clip(let id) = cell, let clip = clipByID[id] {
                clipsInGrid.append((cell, clip))
            }
        }
        // Output duration = max(clip.duration × clip's loop count). Other clips loop naturally
        // via the modulo extraction below to fill the longest contribution.
        let weightedDurations = clipsInGrid.map { (s, c) in c.duration * Double(config.loopCount(for: s)) }
        guard let maxDuration = weightedDurations.max(), maxDuration > 0 else {
            // No clips — caller should have used the image path
            throw GridExportError.emptyGrid
        }

        let canvasSize = config.ratio.outputSize()
        let asset = AVURLAsset(url: sourceVideoURL)

        // Pre-extract still frames once. They're reused for every output frame.
        var stillImages = try await extractStaticCellImages(
            cells: config.filledCells.filter { if case .still = $0 { return true } else { return false } },
            asset: asset,
            canvasSize: canvasSize,
            markedStills: markedStills,
            markedClips: markedClips,
            lutCubeDimension: lutCubeDimension,
            lutCubeData: lutCubeData
        )

        // One generator per clip — keyframe-tolerant so seeking inside the looped range is fast.
        var clipGenerators: [GridCellSource: AVAssetImageGenerator] = [:]
        for (source, _) in clipsInGrid {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            // Half-frame tolerance keeps seeks near-instant on H.264 at 30fps.
            let tol = CMTime(value: 1, timescale: frameRate * 2)
            g.requestedTimeToleranceBefore = tol
            g.requestedTimeToleranceAfter = tol
            // Don't ask for more than the canvas — saves decode/scale work.
            let maxDim = max(canvasSize.width, canvasSize.height)
            g.maximumSize = CGSize(width: maxDim, height: maxDim)
            clipGenerators[source] = g
        }

        // Set up writer
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw GridExportError.writerFailed(error.localizedDescription)
        }

        // Bitrate scales with pixel count. ~25 Mbps for 4K vertical, ~12 Mbps for 1080p.
        let pixelArea = canvasSize.width * canvasSize.height
        let bitrate = max(8_000_000, min(40_000_000, Int(pixelArea * 3.0)))

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvasSize.width.rounded()),
            AVVideoHeightKey: Int(canvasSize.height.rounded()),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width.rounded()),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height.rounded()),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        guard writer.canAdd(writerInput) else { throw GridExportError.writerFailed("cannot add input") }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw GridExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Defer covers every error path (cancellation, frame extraction failure, append failure)
        // so we never leak a half-written file or an in-flight writer session.
        var didFinishCleanly = false
        defer {
            if !didFinishCleanly && writer.status == .writing {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let lutFilter = makeLUTFilter(dimension: lutCubeDimension, data: lutCubeData)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        let totalFrames = max(1, Int((maxDuration * Double(frameRate)).rounded()))

        for frame in 0..<totalFrames {
            // Honor cancellation between frames so the user can abort a long render.
            try Task.checkCancellation()

            let outputTime = Double(frame) / Double(frameRate)
            var frameImages = stillImages

            for (source, clip) in clipsInGrid {
                // Loop the clip to fill the longest cell's duration
                let tInClip = clip.inPoint + outputTime.truncatingRemainder(dividingBy: clip.duration)
                let cmt = CMTime(seconds: tInClip, preferredTimescale: 600)
                let cg = try await clipGenerators[source]!.image(at: cmt).image
                if let lutFilter {
                    frameImages[source] = bake(lut: lutFilter, ciContext: ciContext, cg: cg) ?? cg
                } else {
                    frameImages[source] = cg
                }
            }

            // Pull a buffer from the adaptor's pool, draw the composite into it
            guard let pool = adaptor.pixelBufferPool else {
                throw GridExportError.writerFailed("pixel buffer pool unavailable")
            }
            var pb: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard status == kCVReturnSuccess, let buffer = pb else {
                throw GridExportError.canvasRenderFailed
            }

            drawComposite(into: buffer, config: config, canvasSize: canvasSize, cellImages: frameImages)

            // Wait for the writer to be ready — propagate cancellation by NOT swallowing the throw.
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let pres = CMTime(value: Int64(frame), timescale: frameRate)
            if !adaptor.append(buffer, withPresentationTime: pres) {
                throw GridExportError.writerFailed(writer.error?.localizedDescription ?? "append failed")
            }

            progressHandler?(Double(frame + 1) / Double(totalFrames))
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw GridExportError.writerFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        didFinishCleanly = true
    }

    // MARK: - Composition (shared)

    /// Compose `cellImages` into a fresh CGImage at `canvasSize`. Used by the image-grid path.
    private func composeIntoCGImage(config: GridConfig, canvasSize: CGSize, cellImages: [GridCellSource: CGImage]) -> CGImage? {
        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        drawComposite(into: ctx, config: config, canvasSize: canvasSize, cellImages: cellImages)
        return ctx.makeImage()
    }

    /// Compose into the CGContext backing a CVPixelBuffer. Used by the video-grid path.
    private func drawComposite(into pixelBuffer: CVPixelBuffer, config: GridConfig, canvasSize: CGSize, cellImages: [GridCellSource: CGImage]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: baseAddr,
            width: Int(canvasSize.width.rounded()),
            height: Int(canvasSize.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return }
        drawComposite(into: ctx, config: config, canvasSize: canvasSize, cellImages: cellImages)
    }

    /// Inner draw routine — same for image & video paths. Operates on a top-left-oriented context.
    private func drawComposite(into ctx: CGContext, config: GridConfig, canvasSize: CGSize, cellImages: [GridCellSource: CGImage]) {
        // Black background
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvasSize))

        // CG context origin is bottom-left; cell math uses top-left for intuitive layout.
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)

        for (index, source) in config.indexedFilledCells {
            guard let image = cellImages[source] else { continue }
            let cellRect = config.cellRect(index: index, in: canvasSize)
            let srcSize = CGSize(width: image.width, height: image.height)
            let transform = config.transform(for: source)
            let drawRect = transform.drawRect(srcSize: srcSize, cellRect: cellRect)

            ctx.saveGState()
            ctx.clip(to: cellRect)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: drawRect.origin.y * 2 + drawRect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: drawRect)
            ctx.restoreGState()
            ctx.restoreGState()
        }
    }

    // MARK: - Extraction

    /// Pre-extract all still frames (and clip midpoints when called from the image path) at full quality.
    private func extractStaticCellImages(
        cells: [GridCellSource],
        asset: AVURLAsset,
        canvasSize: CGSize,
        markedStills: [MarkedStill],
        markedClips: [MarkedClip],
        lutCubeDimension: Int?,
        lutCubeData: Data?
    ) async throws -> [GridCellSource: CGImage] {
        let stillByID = Dictionary(uniqueKeysWithValues: markedStills.map { ($0.id, $0) })
        let clipByID = Dictionary(uniqueKeysWithValues: markedClips.map { ($0.id, $0) })

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: max(canvasSize.width, canvasSize.height) * 2,
                                       height: max(canvasSize.width, canvasSize.height) * 2)

        var times: [(source: GridCellSource, time: Double)] = []
        for cell in cells {
            switch cell {
            case .still(let id):
                guard let still = stillByID[id] else { continue }
                times.append((cell, still.timestamp))
            case .clip(let id):
                guard let clip = clipByID[id] else { continue }
                times.append((cell, clip.inPoint + clip.duration / 2))
            }
        }

        let lutFilter = makeLUTFilter(dimension: lutCubeDimension, data: lutCubeData)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        var result: [GridCellSource: CGImage] = [:]
        for (source, time) in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            do {
                let cg = try await generator.image(at: cmTime).image
                if let lut = lutFilter {
                    result[source] = bake(lut: lut, ciContext: ciContext, cg: cg) ?? cg
                } else {
                    result[source] = cg
                }
            } catch {
                throw GridExportError.frameExtractionFailed(time: time)
            }
        }
        return result
    }

    // MARK: - LUT helpers

    private func makeLUTFilter(dimension: Int?, data: Data?) -> CIFilter? {
        guard let dimension, let data, !data.isEmpty else { return nil }
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")
        filter?.setValue(dimension, forKey: "inputCubeDimension")
        filter?.setValue(data, forKey: "inputCubeData")
        filter?.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return filter
    }

    private func bake(lut: CIFilter, ciContext: CIContext, cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        lut.setValue(ci, forKey: kCIInputImageKey)
        guard let output = lut.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    // MARK: - File output

    private func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GridExportError.writeFailed(url)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw GridExportError.writeFailed(url)
        }
    }
}

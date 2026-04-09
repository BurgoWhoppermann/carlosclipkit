import Foundation
import CoreGraphics

/// Shared utilities used by VideoProcessor and VideoSnippetProcessor
enum ProcessingUtilities {

    /// Ensure a subdirectory exists and return its URL
    static func ensureSubdirectory(_ base: URL, path: String) -> URL {
        let subdir = base.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir
    }

    /// Find the next available file index in a directory.
    /// Scans for files matching pattern like "videoname_still_001.jpg" and returns the next number.
    static func findNextAvailableIndex(in directory: URL, prefix: String, suffix: String) -> Int {
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

    /// Resize a CGImage to fit within maxWidth, preserving aspect ratio
    static func resizeImage(_ image: CGImage, maxWidth: Int) -> CGImage {
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

    /// Crop an image to the specified aspect ratio with adjustable horizontal position
    /// - Parameters:
    ///   - image: Source image
    ///   - targetRatio: Target width/height ratio (e.g. 9/16 = 0.5625)
    ///   - horizontalOffset: Horizontal crop position (0.0 = far left, 0.5 = center, 1.0 = far right)
    static func cropImageToAspectRatio(_ image: CGImage, targetRatio: CGFloat, horizontalOffset: CGFloat = 0.5) -> CGImage {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let currentRatio = imageWidth / imageHeight

        let cropRect: CGRect
        if currentRatio > targetRatio {
            // Image is wider than target — crop sides
            let newWidth = imageHeight * targetRatio
            let xOffset = (imageWidth - newWidth) * horizontalOffset
            cropRect = CGRect(x: xOffset, y: 0, width: newWidth, height: imageHeight)
        } else {
            // Image is taller than target — crop top/bottom
            let newHeight = imageWidth / targetRatio
            let yOffset = (imageHeight - newHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: imageWidth, height: newHeight)
        }

        return image.cropping(to: cropRect) ?? image
    }
}

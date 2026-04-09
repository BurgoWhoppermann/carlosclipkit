import Foundation
import CoreImage
import AppKit

/// Parses .cube LUT files and applies color transformations via CIColorCubeWithColorSpace.
/// Supports both 1D and 3D LUTs in the standard Adobe/Resolve .cube format.
struct LUTProcessor {

    enum LUTError: LocalizedError {
        case cannotReadFile
        case invalidFormat(String)
        case noSizeSpecified

        var errorDescription: String? {
            switch self {
            case .cannotReadFile: return "Cannot read LUT file"
            case .invalidFormat(let detail): return "Invalid LUT format: \(detail)"
            case .noSizeSpecified: return "LUT file missing LUT_3D_SIZE"
            }
        }
    }

    // MARK: - .cube File Parser

    /// Parse a .cube LUT file into cube dimension and float data for CIColorCubeWithColorSpace.
    /// Returns (cubeDimension, cubeData) where cubeData is raw Float32 RGBA values.
    static func parseCubeFile(at url: URL) throws -> (Int, Data) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw LUTError.cannotReadFile
        }

        var size: Int?
        var domainMin: (Float, Float, Float) = (0, 0, 0)
        var domainMax: (Float, Float, Float) = (1, 1, 1)
        var rgbValues: [(Float, Float, Float)] = []

        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Parse keywords
            if trimmed.hasPrefix("TITLE") { continue }
            if trimmed.hasPrefix("LUT_3D_SIZE") || trimmed.hasPrefix("LUT_1D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let s = Int(parts.last!) {
                    size = s
                }
                continue
            }
            if trimmed.hasPrefix("DOMAIN_MIN") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 4,
                   let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    domainMin = (r, g, b)
                }
                continue
            }
            if trimmed.hasPrefix("DOMAIN_MAX") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 4,
                   let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) {
                    domainMax = (r, g, b)
                }
                continue
            }

            // Skip other keywords
            if trimmed.first?.isLetter == true { continue }

            // Parse RGB triplet
            let parts = trimmed.split(separator: " ")
            if parts.count >= 3,
               let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                // Normalize to 0-1 range if domain is non-standard
                let nr = (r - domainMin.0) / (domainMax.0 - domainMin.0)
                let ng = (g - domainMin.1) / (domainMax.1 - domainMin.1)
                let nb = (b - domainMin.2) / (domainMax.2 - domainMin.2)
                rgbValues.append((nr, ng, nb))
            }
        }

        guard let cubeSize = size else {
            throw LUTError.noSizeSpecified
        }

        let expectedCount = cubeSize * cubeSize * cubeSize
        guard rgbValues.count == expectedCount else {
            throw LUTError.invalidFormat("Expected \(expectedCount) entries for size \(cubeSize), got \(rgbValues.count)")
        }

        // Convert to RGBA Float32 data for CIColorCubeWithColorSpace
        var floatData = [Float]()
        floatData.reserveCapacity(expectedCount * 4)

        for (r, g, b) in rgbValues {
            floatData.append(r)
            floatData.append(g)
            floatData.append(b)
            floatData.append(1.0) // Alpha
        }

        let data = Data(bytes: floatData, count: floatData.count * MemoryLayout<Float>.size)
        return (cubeSize, data)
    }

    // MARK: - Apply LUT to CGImage

    /// Shared CIContext — reused across calls to avoid the cost of acquiring
    /// a Metal device handle on every invocation.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Apply a parsed LUT to a CGImage using CIColorCubeWithColorSpace.
    /// Returns the color-corrected CGImage, or nil if the filter fails.
    static func applyLUT(to cgImage: CGImage, cubeDimension: Int, cubeData: Data) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(cubeDimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(colorSpace, forKey: "inputColorSpace")
        filter.setValue(ciImage, forKey: kCIInputImageKey)

        guard let outputImage = filter.outputImage else { return nil }

        return ciContext.createCGImage(outputImage, from: ciImage.extent)
    }

    // MARK: - Directory Scanner

    /// Scan a directory for .cube files and return their display names and URLs, sorted alphabetically.
    static func scanForLUTs(in directory: URL) -> [(name: String, url: URL)] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map { (name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

//
//  ExportSettings.swift
//  FramePull
//
//  Platform-neutral export configuration shared by the macOS and iOS targets.
//  These are pure value types with no AppKit/UIKit dependency — they previously
//  lived in FramePullApp.swift alongside Mac-only window management, which kept
//  them out of reach of the iOS target.
//

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

extension Notification.Name {
    static let triggerExport = Notification.Name("FramePull.triggerExport")
}

enum OutputFormat: String, CaseIterable {
    case mp4 = "MP4"

    var fileType: String {
        switch self {
        case .mp4: return "mp4"
        }
    }
}

enum GIFResolution: String, CaseIterable {
    case small = "480w"
    case hd720 = "720p"
    case hd1080 = "1080p"

    var maxWidth: Int {
        switch self {
        case .small: return 480
        case .hd720: return 1280
        case .hd1080: return 1920
        }
    }

    var displayName: String {
        switch self {
        case .small: return "480w (Small)"
        case .hd720: return "720p (HD)"
        case .hd1080: return "1080p (Full HD)"
        }
    }

    /// Estimate GIF file size in bytes for a given frame rate, clip duration, and quality.
    /// GIF uses LZW on indexed color (256 max); for video-sourced content the
    /// per-pixel cost after compression is ~0.6 bytes at full quality.
    /// Lower quality posterizes colors → fewer unique values → better LZW compression.
    func estimatedSize(frameRate: Int, clipDuration: Double, quality: Double = 0.7) -> Int {
        let w = Double(maxWidth)
        let h = w * 9.0 / 16.0  // Assume 16:9 source
        let frameCount = Double(frameRate) * clipDuration
        // Quality 1.0 → factor 1.0 (full size), quality 0.3 → factor ~0.35
        let compressionFactor = 0.2 + 0.8 * quality
        return Int(w * h * 0.6 * frameCount * compressionFactor)
    }
}

enum StillFormat: String, CaseIterable {
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        }
    }
}

enum StillPlacement: String, CaseIterable {
    case spreadEvenly = "Spread evenly"
    case perScene = "Per scene"
    case preferFaces = "Prefer faces"

    var description: String {
        switch self {
        case .spreadEvenly:
            return "Distributes stills at equal intervals with some randomness."
        case .perScene:
            return "Places a fixed number of stills in every scene."
        case .preferFaces:
            return "One still per scene, picking the sharpest frame with a face. Skips scenes without faces."
        }
    }
}

enum StillSize: String, CaseIterable {
    case full = "Full"
    case half = "Half"

    var scale: Double {
        switch self {
        case .full: return 1.0
        case .half: return 0.5
        }
    }
}

enum ClipQuality: String, CaseIterable {
    case sd480 = "480p"
    case hd720 = "720p"
    case fullHD = "1080p"
    case uhd = "4K (UHD)"
    case source = "Source"

    var exportPreset: String {
        switch self {
        case .sd480: return AVAssetExportPreset640x480
        case .hd720: return AVAssetExportPreset1280x720
        case .fullHD: return AVAssetExportPreset1920x1080
        case .uhd: return AVAssetExportPreset3840x2160
        case .source: return AVAssetExportPresetHighestQuality
        }
    }

    var displayName: String { rawValue }
}

// MARK: - Brand Colors
extension Color {
    static let framePullNavy   = Color(red: 0.039, green: 0.122, blue: 0.247) // #0A1F3F Deep Navy
    static let framePullAmber  = Color(red: 0.949, green: 0.620, blue: 0.173) // #F29E2C Warm Amber
    static let framePullSilver = Color(red: 0.875, green: 0.902, blue: 0.929) // #DFE6ED Light Silver
    // Primary UI accent — bright blue for readability on dark backgrounds
    static let framePullBlue      = Color(red: 0.29, green: 0.56, blue: 0.85)   // #4A90D9
    static let framePullLightBlue = Color(red: 0.29, green: 0.56, blue: 0.85).opacity(0.1)
}

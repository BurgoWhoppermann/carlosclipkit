//
//  AutoGenerate.swift
//  FramePull (iOS)
//
//  One-tap marker generation from the detected cuts. Uses SceneDetector.getSceneRanges
//  so scenes are derived exactly as they are on macOS, and follows the same frame rules
//  documented in CLAUDE.md:
//
//    • Stills land at the MIDPOINT of each scene — past any dissolve on the way in and
//      before the next cut, so the frame is representative rather than transitional.
//    • Clips run IN at the scene start, OUT at scene end minus one source frame, so the
//      next cut's frame never leaks into the exported clip.
//
//  Auto markers are added with isManual: false, which keeps them clearable via
//  MarkingState.clearAutoStills() / clearAutoClips() without touching hand-placed ones.
//

import Foundation

/// How many consecutive scenes each generated clip spans.
///
/// One-scene clips give you every shot separately; grouping several scenes yields short
/// sequences that keep a cut or two inside them, which is usually what you want for a
/// social edit.
enum ScenesPerClip: Int, CaseIterable, Identifiable {
    case one = 1, two = 2, three = 3, four = 4
    var id: Int { rawValue }

    var label: String { "\(rawValue)" }

    var description: String {
        switch self {
        case .one:  return "One clip per scene — every shot on its own."
        case .two:  return "Each clip spans 2 scenes, so it contains 1 cut."
        case .three: return "Each clip spans 3 scenes, so it contains 2 cuts."
        case .four: return "Each clip spans 4 scenes, so it contains 3 cuts."
        }
    }
}

struct AutoGenerator {
    let markingState: MarkingState
    let duration: Double

    private var sceneRanges: [(start: Double, end: Double)] {
        SceneDetector().getSceneRanges(
            cuts: markingState.detectedCuts,
            videoDuration: duration
        )
    }

    /// Number of markers a run would produce, so the UI can say so before committing.
    var sceneCount: Int { sceneRanges.count }

    /// Clips produced for a given grouping — ceil(scenes / scenesPerClip).
    func clipCount(scenesPerClip: ScenesPerClip) -> Int {
        let scenes = sceneCount
        guard scenes > 0 else { return 0 }
        return (scenes + scenesPerClip.rawValue - 1) / scenesPerClip.rawValue
    }

    func run(stills: Bool, clips: Bool, scenesPerClip: ScenesPerClip) {
        if stills { generateStills() }
        if clips { generateClips(scenesPerClip: scenesPerClip.rawValue) }
    }

    private func generateStills() {
        markingState.clearAutoStills()
        for range in sceneRanges {
            let midpoint = range.start + (range.end - range.start) / 2
            markingState.addStill(at: midpoint, isManual: false)
        }
        markingState.markedStills.sort { $0.timestamp < $1.timestamp }
    }

    /// Groups consecutive scenes into clips. IN is the first scene's start, OUT the last
    /// scene's end minus one source frame — so the cuts *inside* the group are kept and
    /// only the cut that ends the group is excluded.
    private func generateClips(scenesPerClip: Int) {
        markingState.clearAutoClips()
        let frameDuration = markingState.frameDuration
        let ranges = sceneRanges
        let groupSize = max(1, scenesPerClip)

        var index = 0
        while index < ranges.count {
            let groupEnd = min(index + groupSize, ranges.count)
            let start = ranges[index].start
            // OUT steps back one source frame — same rule as snapToNearestCut.
            let outPoint = max(start, ranges[groupEnd - 1].end - frameDuration)

            if outPoint > start {
                markingState.markedClips.append(
                    MarkedClip(inPoint: start, outPoint: outPoint, isManual: false)
                )
            }
            index = groupEnd
        }
        markingState.markedClips.sort { $0.inPoint < $1.inPoint }
    }
}

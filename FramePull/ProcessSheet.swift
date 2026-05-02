import SwiftUI

/// Host sheet that visualises the post-marking workflow as a 3-phase timeline:
/// Review & Select → Create Grids → Export. Users enter at any phase and flow forward.
struct ProcessSheet: View {
    let videoURL: URL
    var onExportComplete: () -> Void
    var onExportError: (String) -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// `nil` until the user picks an entry phase. Free navigation after that — pills are bidirectional.
    @State private var activePhase: ProcessPhase? = nil
    @State private var visitedPhases: Set<ProcessPhase> = []

    private var markingState: MarkingState { appState.markingState }

    private var reframeRatio: VideoSnippetProcessor.AspectRatioCrop? {
        appState.export9x16 ? .ratio9x16 : (appState.export4x5 ? .ratio4x5 : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — timeline + close
            HStack(spacing: 12) {
                ProcessTimelineHeader(
                    activePhase: activePhase,
                    visitedPhases: visitedPhases,
                    onTap: { phase in goto(phase: phase) }
                )
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Content
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer (per-phase actions)
            if activePhase != nil && activePhase != .export {
                Divider()
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        // Adaptive sizing — adapts to small windows (e.g. MacBook Air) without clipping the
        // composer. Defaults to a generous size when there's room.
        .frame(minWidth: 720, idealWidth: 760, maxWidth: 1100,
               minHeight: 540, idealHeight: 680, maxHeight: 900)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch activePhase {
        case .none:
            entryView
        case .review:
            MarkerPreviewView(
                videoURL: videoURL,
                markingState: markingState,
                reframeRatio: reframeRatio,
                showStills: appState.exportStillsEnabled,
                showClips: appState.exportMovingClipsEnabled,
                selectMode: true,
                useApprovalState: true
            )
        case .grid:
            GridBuilderView(videoURL: videoURL, markingState: markingState)
        case .export:
            ExportSettingsView(
                videoURL: videoURL,
                stillCount: markingState.approvedStills.count,
                clipCount: markingState.approvedClips.count,
                onExportComplete: onExportComplete,
                onExportError: onExportError,
                embedded: true
            )
            .environmentObject(appState)
        }
    }

    // MARK: - Entry view (unstarted)

    private var entryView: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.framePullBlue)

            Text("Process your marks")
                .font(.title2.weight(.semibold))

            Text("Click a step above to begin. You can review your selection, build grids for social, or jump straight to export.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 24) {
                summaryStat(count: markingState.markedStills.count, label: "stills", color: .orange)
                summaryStat(count: markingState.markedClips.count, label: "clips", color: .green)
            }
            .padding(.top, 4)

            HStack(spacing: 10) {
                Button("Review & Select") { goto(phase: .review) }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullBlue)
                    .help("Open the picker, untick anything you want to drop, then continue")

                Button("Skip to Export") { goto(phase: .export) }
                    .buttonStyle(.bordered)
                    .help("Bypass review and grid creation — export everything currently marked")
            }
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func summaryStat(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.callout)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)

            Spacer()

            switch activePhase {
            case .review:
                Button("Skip to Export") { goto(phase: .export) }
                    .buttonStyle(.bordered)
                    .help("Use the current selection and bypass grid creation")

                Button("Next: Create Grids →") { goto(phase: .grid) }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullBlue)

            case .grid:
                Button("Next: Export →") { goto(phase: .export) }
                    .buttonStyle(.borderedProminent)
                    .tint(.framePullBlue)

            case .none, .export:
                EmptyView()
            }
        }
    }

    // MARK: - Navigation

    /// Free navigation: jump to any phase from anywhere. The current phase (if any) is recorded
    /// as visited so the timeline visual reflects what the user has been on.
    private func goto(phase: ProcessPhase) {
        if let current = activePhase, current != phase {
            visitedPhases.insert(current)
        }
        activePhase = phase
    }
}

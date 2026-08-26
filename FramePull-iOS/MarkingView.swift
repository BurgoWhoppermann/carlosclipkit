//
//  MarkingView.swift
//  FramePull (iOS)
//
//  Touch equivalent of the Mac target's ManualMarkingView. The Mac app marks with
//  the S / I / O keys; with no keyboard those become thumb buttons.
//
//  Three layouts off the size classes:
//
//    .portrait          iPhone upright — everything stacked, list underneath
//    .landscapeCompact  iPhone on its side — video takes the screen, controls
//                       move to a right-hand rail, timeline spans the bottom
//    .wide              iPad — video + timeline on the left, controls and the
//                       marked list in a permanent sidebar
//
//  All marking routes through the same MarkingState the Mac app uses, so snapping,
//  the 1-frame OUT offset, bidirectional I/O and undo behave identically.
//

import SwiftUI

struct MarkingView: View {
    @ObservedObject var markingState: MarkingState
    @ObservedObject var player: PlayerController

    @ObservedObject var detection: DetectionController
    let videoURL: URL?
    let onChangeVideo: () -> Void
    let onDetectCuts: () -> Void
    let onClearCuts: () -> Void

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    @State private var snapEnabled = true
    @State private var zoomLevel: Double = 1
    @State private var showingList = false
    @State private var showingExport = false
    @State private var showingGrids = false
    @State private var showingReview = false
    @State private var showingAutoDialog = false
    @AppStorage("detectionSensitivity") private var sensitivity: DetectionSensitivity = .medium

    private enum Layout { case portrait, landscapeCompact, wide }

    private var layout: Layout {
        if vSize == .compact { return .landscapeCompact }
        if hSize == .regular { return .wide }
        return .portrait
    }

    var body: some View {
        Group {
            switch layout {
            case .portrait:         portraitLayout
            case .landscapeCompact: landscapeLayout
            case .wide:             wideLayout
            }
        }
        .background(Color.black.opacity(0.92))
        .toolbar { toolbarContent }
        .toolbar(layout == .landscapeCompact ? .hidden : .visible, for: .navigationBar)
        .sheet(isPresented: $showingList) {
            NavigationStack {
                markedList
                    .navigationTitle("Marked")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingList = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingAutoDialog) {
            AutoGenerateSheet(markingState: markingState, duration: player.duration)
        }
        .fullScreenCover(isPresented: $showingReview) {
            if let videoURL {
                ReviewSwipeView(
                    markingState: markingState,
                    videoURL: videoURL,
                    onExport: { showingExport = true }
                )
            }
        }
        .sheet(isPresented: $showingGrids) {
            if let videoURL {
                GridComposerView(
                    markingState: markingState,
                    videoURL: videoURL,
                    onExport: { showingExport = true }
                )
            }
        }
        .sheet(isPresented: $showingExport) {
            if let videoURL {
                ExportSheet(markingState: markingState, videoURL: videoURL)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Change Video", action: onChangeVideo)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                markingState.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(markingState.undoStack.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            cutsMenu
        }
    }

    /// Scene-cut controls: run it, run it again, throw the results away, and pick how
    /// sensitive it should be. Detection used to fire once on import with no way to
    /// influence or repeat it.
    private var cutsMenu: some View {
        Menu {
            Button {
                onDetectCuts()
            } label: {
                Label(
                    markingState.detectedCuts.isEmpty ? "Detect scene cuts" : "Detect again",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(detection.isRunning)

            Button(role: .destructive) {
                onClearCuts()
            } label: {
                Label("Clear detected cuts", systemImage: "trash")
            }
            .disabled(markingState.detectedCuts.isEmpty)

            Divider()

            Picker("Sensitivity", selection: $sensitivity) {
                ForEach(DetectionSensitivity.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
        } label: {
            if detection.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Label("Cuts", systemImage: "scissors")
            }
        }
    }

    private var reviewButton: some View {
        Button {
            showingReview = true
        } label: {
            Label("Review", systemImage: "rectangle.stack")
        }
        .disabled(totalMarked == 0)
    }

    private var totalMarked: Int {
        markingState.markedStills.count + markingState.markedClips.count
    }

    /// Review and Export live in a bar that is always on screen: pinned to the bottom in
    /// portrait and on iPad, folded into the side rail in landscape.
    private var actionBar: some View {
        HStack(spacing: 10) {
            actionBarButton(
                title: "Review",
                subtitle: totalMarked > 0 ? "\(totalMarked) marked" : "nothing yet",
                systemImage: "rectangle.stack",
                tint: Color.framePullAmber,
                prominent: false,
                enabled: totalMarked > 0
            ) { showingReview = true }

            actionBarButton(
                title: "Grids",
                subtitle: gridSubtitle,
                systemImage: "square.grid.2x2",
                tint: Color.framePullBlue,
                prominent: false,
                enabled: markedCount > 0
            ) { showingGrids = true }

            actionBarButton(
                title: "Export",
                subtitle: markedCount > 0 ? "\(markedCount) kept" : "nothing kept",
                systemImage: "square.and.arrow.up",
                tint: Color.framePullBlue,
                prominent: true,
                enabled: markedCount > 0
            ) { showingExport = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func actionBarButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        prominent: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(enabled ? (prominent ? Color.white : tint) : Color.white.opacity(0.3))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(enabled
                          ? (prominent ? tint : tint.opacity(0.16))
                          : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var exportButton: some View {
        Button {
            showingExport = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(markedCount == 0)
    }

    private var gridSubtitle: String {
        let done = markingState.completedGrids.count
        let total = markingState.grids.count
        if total == 0 { return "none yet" }
        return "\(done)/\(total) ready"
    }

    private var markedCount: Int {
        markingState.approvedStills.count + markingState.approvedClips.count
    }

    // MARK: - Layouts

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            videoPane
                .frame(maxWidth: .infinity)
            detectionBar
            timelineSection(height: 78)
            transportRow
            markingButtonsRow
            markedList
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                videoPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                sideRail
                    .frame(width: 112)
                    .padding(.horizontal, 6)
            }
            detectionBar
            // Full width, so it uses the corner that used to sit empty beside the rail.
            timelineSection(height: 52)
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                videoPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                detectionBar
                timelineSection(height: 92)
                transportRow
            }
            .padding(12)

            Divider()

            VStack(spacing: 0) {
                markingButtonsRow
                    .padding(.top, 12)
                markedList
                actionBar
            }
            .frame(width: 330)
        }
    }

    // MARK: - Pieces

    private var videoPane: some View {
        PlayerLayerView(player: player.player)
            .aspectRatio(aspect, contentMode: .fit)
            .background(Color.black)
            .onTapGesture { player.togglePlay() }
    }

    private var aspect: CGFloat {
        guard player.videoSize.height > 0 else { return 16.0 / 9.0 }
        return player.videoSize.width / player.videoSize.height
    }

    @ViewBuilder
    private var detectionBar: some View {
        switch detection.phase {
        case .running(let value):
            HStack(spacing: 10) {
                ProgressView(value: value) {
                    Text(detection.statusText).font(.caption)
                }
                .tint(Color.framePullAmber)

                Button("Stop") { detection.cancel() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.framePullAmber)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                Spacer()
                Button("Retry") { onDetectCuts() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

        case .cancelled:
            HStack(spacing: 8) {
                Text("Detection stopped.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Resume detection") { onDetectCuts() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

        case .idle, .finished:
            EmptyView()
        }
    }

    private func timelineSection(height: CGFloat) -> some View {
        VStack(spacing: 4) {
            MobileTimelineView(
                markingState: markingState,
                player: player,
                zoomLevel: $zoomLevel,
                trackHeight: height
            )

            if layout != .landscapeCompact {
                HStack {
                    Text(detection.isRunning ? detection.statusText : "\(markingState.detectedCuts.count) cuts")
                    Spacer()
                    if zoomLevel > 1.01 {
                        Button("Reset zoom") { withAnimation { zoomLevel = 1 } }
                    } else {
                        Text("Pinch to zoom")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, layout == .landscapeCompact ? 4 : 12)
        .padding(.top, 6)
    }

    private var transportRow: some View {
        HStack(spacing: 20) {
            Text(timecode(player.currentTime))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()
            Button { player.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
            }
            Button { player.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }
            Spacer()

            snapToggle
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var snapToggle: some View {
        Toggle(isOn: $snapEnabled) { Text("Snap").font(.caption) }
            .toggleStyle(.button)
            .tint(Color.framePullAmber)
    }

    /// Landscape rail. Everything here is a real touch target — an earlier version had
    /// Snap and the list button at caption size, too small to hit.
    ///
    /// Scrollable on purpose: landscape height ranges from ~320pt (iPhone SE) to ~430pt,
    /// and the full control set does not fit at the small end. Scrolling clips nothing;
    /// a plain VStack would silently cut off Export on the shortest devices.
    private var sideRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                Text(timecode(player.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    Button { player.stepFrames(-1) } label: {
                        Image(systemName: "backward.frame.fill").frame(width: 30, height: 30)
                    }
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    Button { player.stepFrames(1) } label: {
                        Image(systemName: "forward.frame.fill").frame(width: 30, height: 30)
                    }
                }
                .font(.system(size: 15))

                markButton(title: "IN", systemImage: "arrow.right.to.line", tint: inTint, compact: true) {
                    markingState.setInPoint(at: player.currentTime, snapEnabled: snapEnabled, isManual: true)
                }
                markButton(title: "STILL", systemImage: "camera.fill", tint: .white, compact: true) {
                    markingState.addStill(at: player.currentTime, isManual: true)
                }
                markButton(title: "OUT", systemImage: "arrow.left.to.line", tint: outTint, compact: true) {
                    markingState.setOutPoint(at: player.currentTime, snapEnabled: snapEnabled, isManual: true)
                }

                if let hint = pendingHint {
                    Text(hint)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.framePullAmber)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                railButton(
                    title: "Snap",
                    systemImage: snapEnabled ? "magnet.fill" : "magnet",
                    tint: snapEnabled ? Color.framePullAmber : .white.opacity(0.5)
                ) {
                    snapEnabled.toggle()
                }

                HStack(spacing: 4) {
                    railButton(title: "\(totalMarked)", systemImage: "list.bullet", tint: .white) {
                        showingList = true
                    }

                    Menu {
                        Button(markingState.detectedCuts.isEmpty ? "Detect scene cuts" : "Detect again") {
                            onDetectCuts()
                        }
                        .disabled(detection.isRunning)
                        Button("Clear detected cuts", role: .destructive) { onClearCuts() }
                            .disabled(markingState.detectedCuts.isEmpty)
                        Picker("Sensitivity", selection: $sensitivity) {
                            ForEach(DetectionSensitivity.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                    } label: {
                        Image(systemName: "scissors")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.framePullAmber)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Labelled rows, not icon-only: these are the end-of-workflow actions and
                // deserve the same weight here that the pinned bar gives them in portrait.
                railButton(
                    title: "Auto",
                    systemImage: "wand.and.stars",
                    tint: markingState.detectedCuts.isEmpty ? .white.opacity(0.3) : Color.framePullAmber
                ) {
                    guard !markingState.detectedCuts.isEmpty else { return }
                    showingAutoDialog = true
                }

                railButton(
                    title: "Review",
                    systemImage: "rectangle.stack",
                    tint: totalMarked > 0 ? Color.framePullAmber : .white.opacity(0.3)
                ) {
                    guard totalMarked > 0 else { return }
                    showingReview = true
                }

                railButton(
                    title: "Export",
                    systemImage: "square.and.arrow.up",
                    tint: markedCount > 0 ? Color.framePullBlue : .white.opacity(0.3)
                ) {
                    guard markedCount > 0 else { return }
                    showingExport = true
                }

                Button("Change", action: onChangeVideo)
                    .font(.caption2)
                    .frame(height: 26)
            }
            .padding(.vertical, 6)
        }
    }

    /// Full-width rail row — 34pt tall so it's actually tappable.
    private func railButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func railIcon(
        systemImage: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? tint : .white.opacity(0.25))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(.white.opacity(enabled ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var inTint: Color {
        markingState.pendingInPoint != nil ? Color.framePullAmber : Color.framePullBlue
    }

    private var outTint: Color {
        markingState.pendingOutPoint != nil ? Color.framePullAmber : Color.framePullBlue
    }

    /// Marking buttons plus the auto-generate row beneath them.
    private var markingButtonsRow: some View {
        VStack(spacing: 8) {
            markButtonsOnly
            autoGenerateButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var autoGenerateButton: some View {
        Button {
            showingAutoDialog = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text("Auto-generate from \(markingState.detectedCuts.count) cuts")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundStyle(autoTint)
            .background(autoTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(autoTint.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(markingState.detectedCuts.isEmpty)
    }

    private var autoTint: Color {
        markingState.detectedCuts.isEmpty ? .white.opacity(0.3) : Color.framePullAmber
    }

    private var markButtonsOnly: some View {
        HStack(spacing: 10) {
            markButton(title: "IN", systemImage: "arrow.right.to.line", tint: inTint) {
                markingState.setInPoint(at: player.currentTime, snapEnabled: snapEnabled, isManual: true)
            }
            markButton(title: "STILL", systemImage: "camera.fill", tint: .white) {
                markingState.addStill(at: player.currentTime, isManual: true)
            }
            markButton(title: "OUT", systemImage: "arrow.left.to.line", tint: outTint) {
                markingState.setOutPoint(at: player.currentTime, snapEnabled: snapEnabled, isManual: true)
            }
        }
        .overlay(alignment: .top) {
            if let hint = pendingHint {
                Text(hint)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.framePullAmber)
                    .offset(y: -14)
            }
        }
    }

    private var pendingHint: String? {
        if let pendingIn = markingState.pendingInPoint {
            return "IN \(timecode(pendingIn)) → set OUT"
        }
        if let pendingOut = markingState.pendingOutPoint {
            return "set IN ← OUT \(timecode(pendingOut))"
        }
        return nil
    }

    private func markButton(
        title: String,
        systemImage: String,
        tint: Color,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 15 : 18, weight: .semibold))
                Text(title)
                    .font(compact ? .system(size: 10, weight: .bold) : .caption.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 40 : 58)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.7), lineWidth: 1)
            )
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Marked items

    private var markedList: some View {
        List {
            if !markingState.markedClips.isEmpty {
                Section {
                    ForEach(markingState.markedClips) { clip in
                        Button {
                            player.seek(to: clip.inPoint)
                        } label: {
                            HStack {
                                Image(systemName: "film").foregroundStyle(Color.framePullBlue)
                                Text("\(timecode(clip.inPoint)) → \(timecode(clip.outPoint))")
                                    .monospacedDigit()
                                Spacer()
                                Text(String(format: "%.1fs", clip.outPoint - clip.inPoint))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { markingState.removeClip(id: clip.id) }
                        }
                    }
                } header: {
                    sectionHeader("Clips (\(markingState.markedClips.count))") {
                        markingState.clearClips()
                    }
                }
            }

            if !markingState.markedStills.isEmpty {
                Section {
                    ForEach(markingState.markedStills) { still in
                        Button {
                            player.seek(to: still.timestamp)
                        } label: {
                            HStack {
                                Image(systemName: "camera")
                                Text(timecode(still.timestamp)).monospacedDigit()
                                Spacer()
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { markingState.removeStill(id: still.id) }
                        }
                    }
                } header: {
                    sectionHeader("Stills (\(markingState.markedStills.count))") {
                        markingState.clearStills()
                    }
                }
            }

            if markingState.markedClips.isEmpty && markingState.markedStills.isEmpty {
                Text("Scrub to a frame, then tap STILL, or IN and OUT to mark a clip. Either order works.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Section header with a Clear action, so wiping a whole marker type doesn't mean
    /// swiping every row away one at a time.
    private func sectionHeader(_ title: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Clear", action: clear)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .textCase(nil)
        }
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds - floor(seconds)) * player.frameRate)
        return String(format: "%d:%02d.%02d", minutes, secs, frames)
    }
}

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Thumbnail size class

/// Thumbnail size class for the Review & Select grid. User-selectable via a S/M/L picker
/// in the header; preference persists in UserDefaults. Aspect is fixed at 16:9 — height
/// is always derived from the column width, so the layout reflows cleanly.
enum PreviewThumbSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var minWidth: CGFloat { switch self { case .small: 140; case .medium: 200; case .large: 280 } }
    var maxWidth: CGFloat { switch self { case .small: 170; case .medium: 240; case .large: 340 } }
    var spacing: CGFloat { switch self { case .small: 8;  case .medium: 10;  case .large: 12 } }
    var label: String   { switch self { case .small: "S"; case .medium: "M"; case .large: "L" } }
    var aspect: CGFloat { 16.0 / 9.0 }
}

// MARK: - Marker Preview View
/// Shows a thumbnail grid of all marked stills and clips before export.
/// Stills show static thumbnails; clips render as looping animated GIFs (temp files, cleaned up on dismiss).

struct MarkerPreviewView: View {
    let videoURL: URL
    @ObservedObject var markingState: MarkingState
    /// Which aspect ratio to show the reframe slider for (nil = no reframe, 9:16 takes priority over 4:5)
    let reframeRatio: VideoSnippetProcessor.AspectRatioCrop?
    var showStills: Bool = true
    var showClips: Bool = true
    /// When true, shows checkboxes for item selection and a confirm button
    var selectMode: Bool = false
    /// Called when user confirms selection in selectMode — passes (selectedStillIDs, selectedClipIDs)
    var onSelectionConfirm: ((Set<UUID>, Set<UUID>) -> Void)? = nil
    /// When true, checkbox toggles read/write directly to `markingState.isApproved`
    /// instead of a local set, and the Confirm Selection footer is hidden (host owns advance).
    var useApprovalState: Bool = false

    private var markedStills: [MarkedStill] { showStills ? markingState.markedStills : [] }
    private var markedClips: [MarkedClip] { showClips ? markingState.markedClips : [] }

    @Environment(\.dismiss) private var dismiss

    // Pre-generated at 640 px — good for both the grid and lightbox, avoids per-navigation reloads
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var clipGIFURLs: [String: URL] = [:]

    // Loading gate — grid only appears after ALL previews are ready
    @State private var isLoadingPreviews = true
    @State private var loadingProgress: Double = 0
    @State private var isGeneratingGIFs = false

    // Lightbox
    @State private var lightboxIndex: Int? = nil
    @State private var lightboxKeyMonitor: Any? = nil
    @State private var gridKeyMonitor: Any? = nil
    @State private var hoveredItemIndex: Int? = nil

    // Reframe
    @State private var localReframeOffset: CGFloat = 0.5
    @State private var dragStartOffset: CGFloat = 0.5
    @State private var isDraggingReframe = false

    // Selection (for selectMode)
    @State private var selectedStillIDs: Set<UUID> = []
    @State private var selectedClipIDs: Set<UUID> = []

    /// User-selectable thumbnail size class — persists via @AppStorage so the choice survives launches.
    @AppStorage("reviewThumbSize") private var thumbSize: PreviewThumbSize = .medium

    /// Adaptive grid columns derived from `thumbSize`.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbSize.minWidth, maximum: thumbSize.maxWidth),
                  spacing: thumbSize.spacing)]
    }

    /// Cell height: fixed-aspect 16:9 derived from the *minimum* column width so cells don't
    /// jitter as columns reflow at the boundary. Cells render at this height; the SwiftUI
    /// LazyVGrid handles horizontal expansion to fill the column.
    private var thumbHeight: CGFloat { thumbSize.minWidth / thumbSize.aspect }

    /// Flat ordered list: stills first, then clips. Indices used by the lightbox.
    private var allItems: [(key: String, caption: String)] {
        markedStills.map { ("still_\($0.id)", $0.formattedTime) } +
        markedClips.map { ("clip_\($0.id)", "\($0.formattedInPoint) – \($0.formattedOutPoint)") }
    }

    private var selectedStillCount: Int {
        useApprovalState ? markedStills.filter(\.isApproved).count : selectedStillIDs.count
    }
    private var selectedClipCount: Int {
        useApprovalState ? markedClips.filter(\.isApproved).count : selectedClipIDs.count
    }
    private var totalSelectedCount: Int { selectedStillCount + selectedClipCount }
    private var allSelected: Bool {
        if useApprovalState {
            return markedStills.allSatisfy(\.isApproved) && markedClips.allSatisfy(\.isApproved)
        }
        return selectedStillIDs.count == markedStills.count && selectedClipIDs.count == markedClips.count
    }

    private func isStillSelected(_ id: UUID) -> Bool {
        if useApprovalState {
            return markedStills.first(where: { $0.id == id })?.isApproved ?? false
        }
        return selectedStillIDs.contains(id)
    }

    private func isClipSelected(_ id: UUID) -> Bool {
        if useApprovalState {
            return markedClips.first(where: { $0.id == id })?.isApproved ?? false
        }
        return selectedClipIDs.contains(id)
    }

    private func toggleStill(_ id: UUID) {
        if useApprovalState {
            let current = markedStills.first(where: { $0.id == id })?.isApproved ?? true
            markingState.setApproval(forStill: id, approved: !current)
        } else {
            if selectedStillIDs.contains(id) { selectedStillIDs.remove(id) }
            else { selectedStillIDs.insert(id) }
        }
    }

    private func toggleClip(_ id: UUID) {
        if useApprovalState {
            let current = markedClips.first(where: { $0.id == id })?.isApproved ?? true
            markingState.setApproval(forClip: id, approved: !current)
        } else {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) }
            else { selectedClipIDs.insert(id) }
        }
    }

    private func setAllSelected(_ selected: Bool) {
        if useApprovalState {
            for still in markedStills { markingState.setApproval(forStill: still.id, approved: selected) }
            for clip in markedClips { markingState.setApproval(forClip: clip.id, approved: selected) }
        } else if selected {
            selectedStillIDs = Set(markedStills.map(\.id))
            selectedClipIDs = Set(markedClips.map(\.id))
        } else {
            selectedStillIDs.removeAll()
            selectedClipIDs.removeAll()
        }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                // Header — always visible
                HStack(spacing: 12) {
                    Text(selectMode ? "Select & Export" : "Preview & Reframe").font(.headline)
                    Spacer()
                    if !isLoadingPreviews && (markedStills.count + markedClips.count) > 0 {
                        // S/M/L picker — choice persists via @AppStorage("reviewThumbSize").
                        Picker("Size", selection: $thumbSize) {
                            ForEach(PreviewThumbSize.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 96)
                        .help("Thumbnail size")
                    }
                    if selectMode {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            setAllSelected(!allSelected)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.framePullBlue)
                        .font(.callout)
                    }
                    if !useApprovalState {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                    }
                }

                if isLoadingPreviews {
                    // ── Loading screen ──────────────────────────────────────
                    Spacer()
                    VStack(spacing: 14) {
                        ProgressView(value: loadingProgress)
                            .progressViewStyle(.linear)
                            .tint(.framePullBlue)
                            .frame(maxWidth: 320)
                        Text("Generating previews… \(Int(loadingProgress * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    // ── Thumbnail grid ──────────────────────────────────────
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !markedStills.isEmpty {
                                Text("STILLS (\(selectMode ? "\(selectedStillCount)/" : "")\(markedStills.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(Array(markedStills.enumerated()), id: \.element.id) { i, still in
                                        let isSelected = isStillSelected(still.id)
                                        let isHovered = hoveredItemIndex == i
                                        ZStack(alignment: .topLeading) {
                                            VStack(spacing: 4) {
                                                if let img = thumbnails["still_\(still.id)"] {
                                                    Image(nsImage: img)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fit)
                                                        .frame(maxWidth: .infinity).frame(height: thumbHeight)
                                                        .cornerRadius(6)
                                                } else {
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(Color.gray.opacity(0.15))
                                                        .frame(maxWidth: .infinity).frame(height: thumbHeight)
                                                }
                                                Text(still.formattedTime)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                            .opacity(selectMode && !isSelected ? 0.4 : 1.0)

                                            if selectMode {
                                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                                    .foregroundColor(isSelected ? .framePullAmber : .secondary)
                                                    .background(Circle().fill(Color.black.opacity(0.3)).padding(-2))
                                                    .padding(4)
                                            }
                                        }
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.framePullAmber, lineWidth: isHovered ? 2 : 0)
                                                .shadow(color: isHovered ? Color.framePullAmber.opacity(0.5) : .clear, radius: isHovered ? 6 : 0)
                                                .animation(.easeInOut(duration: 0.15), value: isHovered)
                                        )
                                        .scaleEffect(isHovered ? 1.03 : 1.0)
                                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                                        .contentShape(Rectangle())
                                        .onHover { hovering in hoveredItemIndex = hovering ? i : (hoveredItemIndex == i ? nil : hoveredItemIndex) }
                                        .onTapGesture {
                                            if selectMode {
                                                toggleStill(still.id)
                                            } else {
                                                lightboxIndex = i
                                            }
                                        }
                                        .help(selectMode ? "Click to select/deselect · Space to preview" : "Click to enlarge · Space to preview")
                                    }
                                }
                            }

                            if !markedClips.isEmpty {
                                Text("CLIPS (\(selectMode ? "\(selectedClipCount)/" : "")\(markedClips.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.green)
                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(Array(markedClips.enumerated()), id: \.element.id) { j, clip in
                                        let clipKey = "clip_\(clip.id)"
                                        let isSelected = isClipSelected(clip.id)
                                        let clipItemIndex = markedStills.count + j
                                        let isHovered = hoveredItemIndex == clipItemIndex
                                        ZStack(alignment: .topLeading) {
                                            VStack(spacing: 4) {
                                                ZStack(alignment: .center) {
                                                    if let gifURL = clipGIFURLs[clipKey] {
                                                        AnimatedGIFView(url: gifURL)
                                                            .frame(maxWidth: .infinity).frame(height: thumbHeight)
                                                            .clipped()
                                                            .cornerRadius(6)
                                                    } else if let img = thumbnails[clipKey] {
                                                        Image(nsImage: img)
                                                            .resizable()
                                                            .aspectRatio(contentMode: .fit)
                                                            .frame(maxWidth: .infinity).frame(height: thumbHeight)
                                                            .cornerRadius(6)
                                                    }
                                                    // GIF generation spinner
                                                    if isGeneratingGIFs && clipGIFURLs[clipKey] == nil {
                                                        VStack {
                                                            HStack {
                                                                ProgressView()
                                                                    .scaleEffect(0.6)
                                                                    .padding(4)
                                                                    .background(Circle().fill(Color.black.opacity(0.6)))
                                                                Spacer()
                                                            }
                                                            Spacer()
                                                        }
                                                        .frame(maxWidth: .infinity).frame(height: thumbHeight)
                                                    }
                                                    // Duration badge
                                                    VStack {
                                                        Spacer()
                                                        HStack {
                                                            Spacer()
                                                            Text(clip.formattedDuration)
                                                                .font(.system(size: 9, design: .monospaced))
                                                                .foregroundColor(.white)
                                                                .padding(.horizontal, 4)
                                                                .padding(.vertical, 2)
                                                                .background(.black.opacity(0.7))
                                                                .cornerRadius(3)
                                                                .padding(4)
                                                        }
                                                    }
                                                    .frame(maxWidth: .infinity).frame(height: thumbHeight)
                                                }
                                                Text("\(clip.formattedInPoint) – \(clip.formattedOutPoint)")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                            .opacity(selectMode && !isSelected ? 0.4 : 1.0)

                                            if selectMode {
                                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                                    .foregroundColor(isSelected ? .framePullAmber : .secondary)
                                                    .background(Circle().fill(Color.black.opacity(0.3)).padding(-2))
                                                    .padding(4)
                                            }
                                        }
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.framePullAmber, lineWidth: isHovered ? 2 : 0)
                                                .shadow(color: isHovered ? Color.framePullAmber.opacity(0.5) : .clear, radius: isHovered ? 6 : 0)
                                                .animation(.easeInOut(duration: 0.15), value: isHovered)
                                        )
                                        .scaleEffect(isHovered ? 1.03 : 1.0)
                                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                                        .contentShape(Rectangle())
                                        .onHover { hovering in hoveredItemIndex = hovering ? clipItemIndex : (hoveredItemIndex == clipItemIndex ? nil : hoveredItemIndex) }
                                        .onTapGesture {
                                            if selectMode {
                                                toggleClip(clip.id)
                                            } else {
                                                lightboxIndex = clipItemIndex
                                            }
                                        }
                                        .help(selectMode ? "Click to select/deselect · Space to preview" : "Click to enlarge · Space to preview")
                                    }
                                }
                            }
                        }
                        .padding(.bottom)
                    }

                    // ── Select mode footer ─────────────────────────────────
                    if selectMode && !useApprovalState {
                        Divider()
                        HStack {
                            Text("\(totalSelectedCount) item\(totalSelectedCount == 1 ? "" : "s") selected")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                onSelectionConfirm?(selectedStillIDs, selectedClipIDs)
                            } label: {
                                Label("Confirm Selection", systemImage: "checkmark.circle")
                                    .font(.callout.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.framePullAmber)
                            .disabled(totalSelectedCount == 0)
                        }
                        .padding(.top, 4)
                    } else if selectMode && useApprovalState {
                        Divider()
                        HStack {
                            Text("\(totalSelectedCount) of \(markedStills.count + markedClips.count) item\(totalSelectedCount == 1 ? "" : "s") kept")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding()
            .modifier(MarkerPreviewSizing(useApprovalState: useApprovalState, selectMode: selectMode))
            .task { await generateAllPreviews() }
            .onAppear {
                if selectMode && !useApprovalState {
                    // Initialize all items as selected
                    selectedStillIDs = Set(markedStills.map(\.id))
                    selectedClipIDs = Set(markedClips.map(\.id))
                }
                // Grid-level spacebar monitor — opens lightbox on hovered item
                gridKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 49, self.lightboxIndex == nil else { return event }
                    // Space pressed while no lightbox — open on hovered item or first item
                    let idx = self.hoveredItemIndex ?? 0
                    if idx < self.allItems.count {
                        self.lightboxIndex = idx
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                cleanupTempGIFs()
                if let m = lightboxKeyMonitor { NSEvent.removeMonitor(m); lightboxKeyMonitor = nil }
                if let m = gridKeyMonitor { NSEvent.removeMonitor(m); gridKeyMonitor = nil }
            }
            .onChange(of: lightboxIndex) { newIdx in
                if let idx = newIdx {
                    // Sync reframe slider with current item's offset
                    let key = allItems[idx].key
                    if key.hasPrefix("still_"), let id = UUID(uuidString: String(key.dropFirst(6))) {
                        localReframeOffset = markedStills.first { $0.id == id }?.reframeOffset ?? 0.5
                    } else if key.hasPrefix("clip_"), let id = UUID(uuidString: String(key.dropFirst(5))) {
                        localReframeOffset = markedClips.first { $0.id == id }?.reframeOffset ?? 0.5
                    }

                    if lightboxKeyMonitor == nil {
                        lightboxKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                            switch event.keyCode {
                            case 123: if let i = self.lightboxIndex, i > 0 { self.lightboxIndex = i - 1 }; return nil
                            case 124: if let i = self.lightboxIndex, i < self.allItems.count - 1 { self.lightboxIndex = i + 1 }; return nil
                            case 49, 53: self.lightboxIndex = nil; return nil  // Space or Esc closes lightbox
                            default: return event
                            }
                        }
                    }
                } else if let m = lightboxKeyMonitor {
                    NSEvent.removeMonitor(m)
                    lightboxKeyMonitor = nil
                }
            }

            if lightboxIndex != nil { lightboxOverlay }

        } // ZStack
        .onExitCommand {
            if lightboxIndex != nil { lightboxIndex = nil } else { dismiss() }
        }
    }

    // MARK: - Lightbox overlay

    @ViewBuilder
    private var lightboxOverlay: some View {
        if let idx = lightboxIndex {
            let items = allItems
            ZStack {
                Color.black.opacity(0.88).onTapGesture {
                    if !selectMode { lightboxIndex = nil }
                }
                VStack(spacing: 0) {
                    HStack {
                        Text("\(idx + 1) of \(items.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Button { lightboxIndex = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3).foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Close lightbox (Esc)")
                    }
                    .padding(.horizontal, 16).padding(.top, 16)

                    HStack(spacing: 0) {
                        Button { if idx > 0 { lightboxIndex = idx - 1 } } label: {
                            Image(systemName: "chevron.left")
                                .font(.title2.weight(.semibold))
                                .foregroundColor(idx > 0 ? .white : .white.opacity(0.15))
                                .frame(width: 44)
                        }
                        .buttonStyle(.plain).disabled(idx == 0)
                        .help("Previous (←)")

                        // Image is always pre-loaded — no async work here
                        Group {
                            let isClip = idx >= markedStills.count
                            let key = items[idx].key
                            if isClip, let gifURL = clipGIFURLs[key] {
                                ZStack {
                                    AnimatedGIFView(url: gifURL, allowScaleUp: true)
                                        .id(key) // Force recreation when switching clips
                                        .aspectRatio(16.0/9.0, contentMode: .fit).cornerRadius(8)
                                    Text("Preview quality")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.35))
                                    if reframeRatio != nil { reframeCropOverlay }
                                }
                            } else if let img = thumbnails[key] {
                                ZStack {
                                    Image(nsImage: img).resizable()
                                        .aspectRatio(contentMode: .fit).cornerRadius(8)
                                    if reframeRatio != nil { reframeCropOverlay }
                                }
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topLeading) {
                            if selectMode {
                                let isClipItem = idx >= markedStills.count
                                let itemID = isClipItem ? markedClips[idx - markedStills.count].id : markedStills[idx].id
                                let isSelected = isClipItem ? isClipSelected(itemID) : isStillSelected(itemID)
                                Button {
                                    if isClipItem { toggleClip(itemID) } else { toggleStill(itemID) }
                                } label: {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundColor(isSelected ? .framePullAmber : .white.opacity(0.6))
                                        .shadow(radius: 4)
                                }
                                .buttonStyle(.plain)
                                .padding(16)
                                .help(isSelected ? "Deselect" : "Select")
                            }
                        }
                        .gesture(reframeRatio != nil ? reframeDragGesture(for: items[idx].key) : nil)
                        .onTapGesture {
                            if selectMode {
                                let isClipItem = idx >= markedStills.count
                                let itemID = isClipItem ? markedClips[idx - markedStills.count].id : markedStills[idx].id
                                if isClipItem { toggleClip(itemID) } else { toggleStill(itemID) }
                            }
                        }
                        .onHover { hovering in
                            if reframeRatio != nil {
                                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                        }

                        Button { if idx < items.count - 1 { lightboxIndex = idx + 1 } } label: {
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .foregroundColor(idx < items.count - 1 ? .white : .white.opacity(0.15))
                                .frame(width: 44)
                        }
                        .buttonStyle(.plain).disabled(idx == items.count - 1)
                        .help("Next (→)")
                    }
                    .frame(maxHeight: .infinity)

                    Text(items[idx].caption)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))

                    // Reframe slider
                    if let ratio = reframeRatio {
                        let label = ratio == .ratio9x16 ? "9:16 Reframe" : "4:5 Reframe"
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.left.and.right")
                                    .foregroundColor(.white.opacity(0.5))
                                    .font(.caption2)
                                Text(label)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                Spacer()
                                if localReframeOffset != 0.5 {
                                    Button("Reset") {
                                        localReframeOffset = 0.5
                                        commitReframeOffset(for: items[idx].key)
                                    }
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.4))
                                    .buttonStyle(.plain)
                                    .help("Reset crop position to center")
                                }
                            }
                            Slider(value: $localReframeOffset, in: 0...1)
                                .tint(.orange)
                                .help("Slide to adjust crop position — or drag the image directly")
                                .onChange(of: localReframeOffset) { _ in
                                    commitReframeOffset(for: items[idx].key)
                                }
                        }
                        .padding(.horizontal, 60)
                    }

                    Spacer().frame(height: 12)
                }
            }
        }
    }

    // MARK: - Reframe helpers

    /// Drag gesture for reframing — dragging left/right moves the crop window
    private func reframeDragGesture(for key: String) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDraggingReframe {
                    isDraggingReframe = true
                    dragStartOffset = localReframeOffset
                }
                // Drag right = move crop frame right = increase offset
                let delta = value.translation.width / 300.0
                localReframeOffset = max(0, min(1, dragStartOffset + delta))
                commitReframeOffset(for: key)
            }
            .onEnded { _ in
                isDraggingReframe = false
                dragStartOffset = localReframeOffset
            }
    }

    /// Commit the current slider value back to the MarkingState model
    private func commitReframeOffset(for key: String) {
        if key.hasPrefix("still_"), let id = UUID(uuidString: String(key.dropFirst(6))) {
            markingState.updateReframeOffset(forStill: id, offset: localReframeOffset)
        } else if key.hasPrefix("clip_"), let id = UUID(uuidString: String(key.dropFirst(5))) {
            markingState.updateReframeOffset(forClip: id, offset: localReframeOffset)
        }
    }

    /// Overlay that dims the areas outside the crop window for the active reframe ratio
    private var reframeCropOverlay: some View {
        GeometryReader { geo in
            let viewW = geo.size.width
            let viewH = geo.size.height
            // Use the actual reframe ratio; assume 16:9 source (most common)
            let sourceRatio: CGFloat = 16.0 / 9.0
            let targetRatio: CGFloat = reframeRatio?.ratio ?? (9.0 / 16.0)

            let cropWidthFraction = targetRatio / sourceRatio
            let maxSlide = 1.0 - cropWidthFraction
            let leftEdge = maxSlide * localReframeOffset
            let rightEdge = leftEdge + cropWidthFraction

            // Left dim region
            Path { p in
                p.addRect(CGRect(x: 0, y: 0, width: viewW * leftEdge, height: viewH))
            }
            .fill(Color.black.opacity(0.55))

            // Right dim region
            Path { p in
                p.addRect(CGRect(x: viewW * rightEdge, y: 0, width: viewW * (1 - rightEdge), height: viewH))
            }
            .fill(Color.black.opacity(0.55))

            // Crop border
            Rectangle()
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
                .frame(width: viewW * cropWidthFraction, height: viewH)
                .position(x: viewW * (leftEdge + cropWidthFraction / 2), y: viewH / 2)
        }
        .allowsHitTesting(false)
        .cornerRadius(8)
    }

    // MARK: - Preview generation

    /// Phase 1: generates 640-px thumbnails (fast, behind the loading screen).
    /// Phase 2: generates lightweight animated GIFs (10 fps, max 5 s) lazily
    ///          *after* the grid is already visible — they pop in as they finish.
    private func generateAllPreviews() async {
        let stills    = Array(markedStills.prefix(30))
        let clipThumb = Array(markedClips.prefix(30))
        let total     = max(1, Double(stills.count + clipThumb.count))
        var done      = 0.0

        let allItems = stills.map { (key: "still_\($0.id)", time: $0.timestamp) } +
                       clipThumb.map { (key: "clip_\($0.id)", time: $0.inPoint) }

        // ── Phase 1: thumbnails only (fast) ───────────────────────────────
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let times = allItems.map { CMTime(seconds: $0.time, preferredTimescale: 600) }
        var index = 0

        for await result in generator.images(for: times) {
            if case let .success(_, cg, _) = result {
                let img = NSImage(cgImage: cg, size: .zero)
                let key = allItems[index].key
                await MainActor.run { thumbnails[key] = img }
            }
            done += 1
            await MainActor.run { loadingProgress = done / total }
            index += 1
        }

        // Show the grid immediately — GIFs will appear as they finish
        await MainActor.run { loadingProgress = 1; isLoadingPreviews = false; isGeneratingGIFs = true }

        // ── Phase 2: lightweight GIFs (10 fps, full clip duration) ──────────
        // Each clip's encoding hops to a detached task so synchronous CGImageDestination
        // calls don't hitch the main thread.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let url = videoURL
        for clip in markedClips.prefix(20) {
            if Task.isCancelled { break }
            let clipKey = "clip_\(clip.id)"
            let result = await Task.detached(priority: .utility) { [clip, tempDir, url] in
                await encodeLoopingGIF(
                    sourceVideoURL: url,
                    clipID: clip.id,
                    inPoint: clip.inPoint,
                    duration: clip.duration,
                    maxDuration: .greatestFiniteMagnitude,  // no cap — preview shows full clip
                    fps: 10,
                    maxSize: 320,
                    tempDir: tempDir
                )
            }.value
            if let result {
                await MainActor.run { clipGIFURLs[clipKey] = result }
            }
        }

        await MainActor.run { isGeneratingGIFs = false }
    }

    private func cleanupTempGIFs() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePullPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - Sizing modifier

private struct MarkerPreviewSizing: ViewModifier {
    let useApprovalState: Bool
    let selectMode: Bool
    func body(content: Content) -> some View {
        if useApprovalState {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(width: 680, height: selectMode ? 620 : 560)
        }
    }
}

// MARK: - Animated GIF View
/// NSViewRepresentable that wraps NSImageView with `animates = true` to play GIF files as looping animations.

struct AnimatedGIFView: NSViewRepresentable {
    let url: URL
    var allowScaleUp: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = PassthroughImageView()
        imageView.animates = true
        imageView.imageScaling = allowScaleUp ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.canDrawSubviewsIntoLayer = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let image = NSImage(contentsOf: url) {
            imageView.image = image
        }
        context.coordinator.currentURL = url
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Reload when the URL changes (e.g. navigating between clips in the lightbox)
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            nsView.image = NSImage(contentsOf: url)
        } else if nsView.image == nil {
            nsView.image = NSImage(contentsOf: url)
        }
        nsView.imageScaling = allowScaleUp ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        nsView.animates = true
    }

    class Coordinator { var currentURL: URL? }
}

/// NSImageView that's invisible to AppKit hit-testing AND mouse events. Required so SwiftUI
/// parents (Button click, .onTapGesture, .onDrag, .gesture) actually receive events when
/// this view is layered inside them — by default NSImageView (and its layer-backed image
/// rendering) intercepts events at the AppKit level, even with .allowsHitTesting(false)
/// applied to the SwiftUI wrapper.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    // Belt-and-suspenders: explicitly forward any mouse events that somehow reach us.
    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
}

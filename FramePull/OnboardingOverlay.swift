import SwiftUI

// MARK: - Highlight Identifiers

enum OnboardingHighlightID: Int, CaseIterable, Comparable {
    case detectCuts = 0
    case manualControls
    case autoGenerate
    case exportSettings
    case exportDialogue

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .detectCuts:      return "Detect Cuts"
        case .manualControls:  return "Manual Markers"
        case .autoGenerate:    return "Auto-Generate"
        case .exportSettings:  return "Export"
        case .exportDialogue:  return "Export Settings"
        }
    }

    var description: String {
        switch self {
        case .detectCuts:
            return "Analyze your video to find scene boundaries automatically. It helps with orientation in manual mode and is necessary for auto-generate."
        case .manualControls:
            return "Play the video and press S for stills, or I/O to mark clip in/out points."
        case .autoGenerate:
            return "Generate stills and clips from detected scenes. More detailed adjustments are available below the video."
        case .exportSettings:
            return "Configure formats, quality, and export everything. Use Preview & Select inside to pick individual items and adjust crop positions."
        case .exportDialogue:
            return "Choose your format, size, and output folder here. You can export stills, GIFs, and video clips — or all three at once."
        }
    }

    var stepNumber: String {
        "\(rawValue + 1)"
    }
}

// MARK: - Preference Key

struct OnboardingHighlightEntry: Equatable {
    let id: OnboardingHighlightID
    let rect: CGRect
}

struct OnboardingHighlightKey: PreferenceKey {
    static var defaultValue: [OnboardingHighlightEntry] = []
    static func reduce(value: inout [OnboardingHighlightEntry], nextValue: () -> [OnboardingHighlightEntry]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - View Extension

extension View {
    func onboardingHighlight(_ id: OnboardingHighlightID) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: OnboardingHighlightKey.self,
                                value: [OnboardingHighlightEntry(id: id, rect: geo.frame(in: .named("onboarding")))])
            }
        )
    }
}

// MARK: - Spotlight Cutout Shape

struct SpotlightShape: Shape {
    var cutout: CGRect
    var cornerRadius: CGFloat = 8
    var padding: CGFloat = 8

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(cutout.origin.x, AnimatablePair(cutout.origin.y, AnimatablePair(cutout.size.width, cutout.size.height)))
        }
        set {
            cutout.origin.x = newValue.first
            cutout.origin.y = newValue.second.first
            cutout.size.width = newValue.second.second.first
            cutout.size.height = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let padded = cutout.insetBy(dx: -padding, dy: -padding)
        path.addRoundedRect(in: padded, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}

// MARK: - Opt-in Toast

struct OnboardingToast: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var dontAskAgain = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.wave.fill")
                    .font(.title2)
                    .foregroundColor(.framePullAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text("First time here?")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Quick tour — takes 10 seconds")
                        .font(.callout)
                        .foregroundColor(.framePullSilver)
                }
            }

            HStack(spacing: 12) {
                Button(action: {
                    if dontAskAgain {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    }
                    onDecline()
                }) {
                    Text("I'll explore myself")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                Button(action: onAccept) {
                    Text("Show me around")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullAmber)
            }

            Toggle(isOn: $dontAskAgain) {
                Text("Don't ask again")
                    .font(.caption)
                    .foregroundColor(.framePullSilver.opacity(0.5))
            }
            .toggleStyle(.checkbox)
        }
        .padding(20)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.framePullNavy.opacity(0.95))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.framePullAmber.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Hint Dots (passive discovery)

struct OnboardingHintDots: View {
    let highlights: [OnboardingHighlightID: CGRect]
    @Binding var isPresented: Bool
    @State private var visibleDots: Set<OnboardingHighlightID> = Set(OnboardingHighlightID.allCases)
    @State private var expandedDot: OnboardingHighlightID? = nil
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(OnboardingHighlightID.allCases, id: \.rawValue) { id in
                if let rect = highlights[id], visibleDots.contains(id) {
                    hintDot(for: id, at: rect)
                }
            }

            // Single expanded tooltip
            if let id = expandedDot, let rect = highlights[id] {
                expandedTooltip(for: id, at: rect)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
            // Auto-fade dots after 8 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if expandedDot == nil {
                    withAnimation(.easeOut(duration: 0.5)) {
                        visibleDots.removeAll()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func hintDot(for id: OnboardingHighlightID, at rect: CGRect) -> some View {
        ZStack {
            // Pulse ring
            Circle()
                .stroke(Color.framePullAmber.opacity(0.4), lineWidth: 1.5)
                .frame(width: 28, height: 28)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .opacity(pulse ? 0.0 : 0.6)

            // Dot
            Circle()
                .fill(Color.framePullAmber)
                .frame(width: 22, height: 22)
                .overlay(
                    Text(id.stepNumber)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.framePullNavy)
                )
                .shadow(color: .framePullAmber.opacity(0.4), radius: 4)
        }
        .position(x: rect.maxX + 4, y: rect.minY - 4)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedDot == id {
                    expandedDot = nil
                } else {
                    expandedDot = id
                }
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func expandedTooltip(for id: OnboardingHighlightID, at rect: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(id.title)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        expandedDot = nil
                        visibleDots.remove(id)
                        if visibleDots.isEmpty { isPresented = false }
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            Text(id.description)
                .font(.caption)
                .foregroundColor(.framePullSilver)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.framePullNavy.opacity(0.95))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .position(x: rect.midX, y: rect.minY - 50)
        .transition(.opacity)
    }
}

// MARK: - Spotlight Tooltip Card (for guided tour)

private struct OnboardingTooltipCard: View {
    let step: OnboardingHighlightID
    let currentIndex: Int
    let totalSteps: Int
    let cutoutRect: CGRect
    let containerSize: CGSize
    @Binding var dontShowAgain: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    private var showAbove: Bool {
        cutoutRect.midY > containerSize.height * 0.4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(step.description)
                .font(.callout)
                .foregroundColor(.framePullSilver)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $dontShowAgain) {
                Text("Don't show next time")
                    .font(.caption)
                    .foregroundColor(.framePullSilver.opacity(0.6))
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == currentIndex ? Color.framePullAmber : Color.white.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    if currentIndex > 0 {
                        Button("Back", action: onBack)
                            .buttonStyle(.plain)
                            .foregroundColor(.framePullSilver.opacity(0.7))
                            .font(.callout)
                    }

                    Button(action: onNext) {
                        Text(currentIndex == totalSteps - 1 ? "Done" : "Next")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.framePullAmber)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.framePullNavy.opacity(0.95))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .position(tooltipPosition)
    }

    private var tooltipPosition: CGPoint {
        let cardWidth: CGFloat = 300
        let cardHeight: CGFloat = 130
        let arrowGap: CGFloat = 16

        let x = min(max(cutoutRect.midX, cardWidth / 2 + 12),
                     containerSize.width - cardWidth / 2 - 12)

        let y: CGFloat
        if showAbove {
            y = cutoutRect.minY - 8 - arrowGap - cardHeight / 2
        } else {
            y = cutoutRect.maxY + 8 + arrowGap + cardHeight / 2
        }

        return CGPoint(x: x, y: max(cardHeight / 2 + 8, min(y, containerSize.height - cardHeight / 2 - 8)))
    }
}

// MARK: - Export Dialogue Mockup (non-interactive visual for tour step 5)

private struct ExportDialogueMockup: View {
    private static let appIcon: NSImage = {
        let icon = NSApplication.shared.applicationIconImage.copy() as! NSImage
        return icon
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — centered
            HStack {
                Spacer()
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Export Settings")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }

            // Summary
            HStack(spacing: 16) {
                Label("12 stills", systemImage: "photo")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Label("5 clips", systemImage: "film")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }

            mockDivider

            // Stills settings
            mockCheckbox("Export stills", checked: true)
            Group {
                mockRow("Format:") {
                    mockSegmented(["JPEG", "PNG", "TIFF"], selected: 0)
                }
                mockRow("Still size:") {
                    HStack(spacing: 6) {
                        mockSegmented(["1x", "0.5x"], selected: 0)
                        Text("1920 x 1080")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.leading, 20)

            mockDivider

            // GIF settings
            mockCheckbox("Export GIFs", checked: true)
            Group {
                mockRow("Resolution:") {
                    mockPicker("480p")
                }
                mockRow("Frame rate:") {
                    mockPicker("15 fps")
                }
            }
            .padding(.leading, 20)

            mockDivider

            // MP4 settings
            mockCheckbox("Export video clips", checked: true)
            mockRow("Quality:") {
                mockPicker("Original")
            }
            .padding(.leading, 20)

            mockDivider

            // Crop options
            HStack {
                Text("Additional crops:")
                Spacer()
                mockCheckbox("4:5", checked: false)
                mockCheckbox("9:16", checked: true)
            }

            mockDivider

            // Save location
            HStack {
                Text("Save to:")
                Spacer()
                Text("~/Desktop/MyProject")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("Choose...")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }

            // Action buttons
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                        .font(.caption)
                    Text("Preview & Select")
                        .font(.callout.weight(.medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.framePullAmber))

                Text("Export")
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.framePullBlue))
            }

            // Footer note
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .font(.caption)
                Text("Files are always added — never overwritten")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.framePullAmber.opacity(0.5), lineWidth: 1.5)
        )
        .allowsHitTesting(false)
    }

    // MARK: - Mock UI helpers

    private var mockDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
    }

    private func mockCheckbox(_ label: String, checked: Bool, disabled: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.body)
                .foregroundColor(disabled ? .secondary : (checked ? .accentColor : .secondary))
            Text(label)
                .foregroundColor(disabled ? .secondary : .primary)
        }
    }

    private func mockRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            content()
        }
    }

    private func mockSegmented(_ options: [String], selected: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Text(option)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == selected ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .foregroundColor(index == selected ? .accentColor : .secondary)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func mockPicker(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.callout)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

// MARK: - Onboarding Overlay View

enum OnboardingMode {
    case toast       // Asking user if they want a tour
    case guided      // Spotlight tour
    case hints       // Passive hint dots
}

struct OnboardingOverlayView: View {
    let highlights: [OnboardingHighlightID: CGRect]
    @Binding var isPresented: Bool
    var forceGuided: Bool = false

    @State private var mode: OnboardingMode = .toast
    @State private var currentStep = 0
    @State private var dontShowAgain = false

    private var steps: [OnboardingHighlightID] { OnboardingHighlightID.allCases }
    private var currentID: OnboardingHighlightID { steps[currentStep] }
    private var currentRect: CGRect? { highlights[currentID] }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch mode {
                case .toast:
                    Color.black.opacity(0.3)
                        .onTapGesture { dismissGuide() }

                    OnboardingToast(
                        onAccept: {
                            withAnimation(.easeInOut(duration: 0.3)) { mode = .guided }
                        },
                        onDecline: { dismissGuide() }
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))

                case .guided:
                    guidedContent(geo: geo)

                case .hints:
                    EmptyView()
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if forceGuided { mode = .guided }
        }
    }

    @ViewBuilder
    private func guidedContent(geo: GeometryProxy) -> some View {
        if currentID == .exportDialogue {
            // Step 5: full dim + mock export dialogue (top-center like a real sheet) + tooltip beside it
            Color.black.opacity(0.55)
                .onTapGesture { dismissGuide() }

            // HStack: mockup + tooltip side by side, anchored to the top
            HStack(alignment: .top, spacing: 20) {
                ExportDialogueMockup()
                exportDialogueTooltip(containerSize: geo.size, isOverlay: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
        } else if let rect = currentRect {
            // Steps 1-4: spotlight cutout
            SpotlightShape(cutout: rect)
                .fill(style: FillStyle(eoFill: true))
                .foregroundColor(Color.black.opacity(0.55))
                .animation(.easeInOut(duration: 0.35), value: currentStep)
                .onTapGesture { dismissGuide() }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.framePullAmber.opacity(0.5), lineWidth: 1.5)
                .frame(width: rect.width + 16, height: rect.height + 16)
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeInOut(duration: 0.35), value: currentStep)

            OnboardingTooltipCard(
                step: currentID,
                currentIndex: currentStep,
                totalSteps: steps.count,
                cutoutRect: rect,
                containerSize: geo.size,
                dontShowAgain: $dontShowAgain,
                onBack: { withAnimation(.easeInOut(duration: 0.3)) { currentStep -= 1 } },
                onNext: {
                    if currentStep < steps.count - 1 {
                        withAnimation(.easeInOut(duration: 0.3)) { currentStep += 1 }
                    } else {
                        dismissGuide()
                    }
                },
                onSkip: { dismissGuide() }
            )
            .animation(.easeInOut(duration: 0.35), value: currentStep)
        }
    }

    /// Tooltip card for the export dialogue step — positioned inline (not via .position())
    private func exportDialogueTooltip(containerSize: CGSize, isOverlay: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OnboardingHighlightID.exportDialogue.title)
                .font(.headline)
                .foregroundColor(.white)

            Text(OnboardingHighlightID.exportDialogue.description)
                .font(.callout)
                .foregroundColor(.framePullSilver)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $dontShowAgain) {
                Text("Don't show next time")
                    .font(.caption)
                    .foregroundColor(.framePullSilver.opacity(0.6))
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<steps.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentStep ? Color.framePullAmber : Color.white.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.3)) { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.framePullSilver.opacity(0.7))
                    .font(.callout)

                    Button(action: { dismissGuide() }) {
                        Text("Done")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.framePullAmber)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.framePullNavy.opacity(0.95))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func dismissGuide() {
        if dontShowAgain {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        }
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
    }
}

// MARK: - Auto-Detect Cuts Prompt

struct AutoDetectPromptView: View {
    let onDetect: () -> Void
    let onSkip: () -> Void

    @State private var dontAskAgain = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "scissors")
                    .font(.title2)
                    .foregroundColor(.framePullAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Detect scene cuts?")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Analyzes your video to find scene boundaries automatically.")
                        .font(.callout)
                        .foregroundColor(.framePullSilver)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Button(action: {
                    if dontAskAgain {
                        UserDefaults.standard.set(true, forKey: "autoDetectPromptDontShow")
                    }
                    onSkip()
                }) {
                    Text("Skip")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                Button(action: {
                    if dontAskAgain {
                        UserDefaults.standard.set(true, forKey: "autoDetectPromptDontShow")
                    }
                    onDetect()
                }) {
                    Text("Detect Cuts")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.framePullAmber)
            }

            Toggle(isOn: $dontAskAgain) {
                Text("Don't ask again")
                    .font(.caption)
                    .foregroundColor(.framePullSilver.opacity(0.5))
            }
            .toggleStyle(.checkbox)
        }
        .padding(20)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.framePullNavy.opacity(0.95))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.framePullAmber.opacity(0.3), lineWidth: 0.5)
        )
    }
}

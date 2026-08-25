//
//  ReviewSwipeView.swift
//  FramePull (iOS)
//
//  Tinder-style review deck, ported from the earlier FramePull Mobile prototype
//  (FramePullMobile/Sources/App/ReviewSelectionView.swift). The interaction was
//  already tuned there, so the mechanics are kept deliberately faithful:
//
//   • Only two cards are ever rendered — the top card and one peeking behind it.
//   • Clip cards only build an AVPlayer when they're on top; buried cards show a
//     spinner, otherwise the deck spins up a player per clip.
//   • animateOut() flings the card away, then AFTER the animation resets offset
//     and advances the index inside a Transaction with animations disabled. Skip
//     that and the next card visibly flies in from off-screen.
//   • An isAnimating guard blocks gestures and buttons during that window so a
//     fast double-swipe can't skip an item.
//
//  What differs from the prototype: decisions are written straight into the shared
//  MarkingState via setApproval(), so each swipe lands on the app-wide undo stack
//  and the export path — which already filters on isApproved — picks them up with
//  no extra plumbing.
//

import SwiftUI
import AVFoundation

struct ReviewItem: Identifiable {
    let id: UUID
    let kind: Kind

    enum Kind {
        case still(MarkedStill)
        case clip(MarkedClip)
    }
}

struct ReviewSwipeView: View {
    @ObservedObject var markingState: MarkingState
    let videoURL: URL
    var onExport: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var items: [ReviewItem] = []
    @State private var currentIndex = 0
    @State private var keptCount = 0
    @State private var deletedCount = 0
    @State private var cardOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var isAnimating = false

    private let swipeThreshold: CGFloat = 120
    private let flingDuration = 0.25

    private var currentItem: ReviewItem? {
        guard currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if currentItem != nil {
                    deck
                    skipButton
                    decisionButtons
                } else {
                    summary
                }
            }
        }
        .onAppear(perform: buildQueue)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.12)))
            }

            Spacer()

            if !items.isEmpty {
                Text("\(min(currentIndex + 1, items.count)) of \(items.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text("\(keptCount)").font(.subheadline.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(.green.opacity(0.85)))
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    // MARK: - Deck

    private var deck: some View {
        ZStack {
            ForEach(visibleSlice, id: \.element.id) { index, item in
                let isTop = index == currentIndex
                card(for: item, isTop: isTop)
                    .id(item.id)
                    .zIndex(isTop ? 1 : 0)
                    .offset(
                        x: isTop ? cardOffset.width : 0,
                        y: isTop ? cardOffset.height * 0.3 : 20
                    )
                    .scaleEffect(isTop ? 1 : 0.95)
                    .rotationEffect(.degrees(isTop ? cardRotation : 0))
                    .animation(
                        isTop ? .interactiveSpring(response: 0.3, dampingFraction: 0.7) : .spring(),
                        value: cardOffset
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(swipeGesture)
    }

    /// Only the top card plus one behind it — rendering the whole queue would spin
    /// up an AVPlayer for every clip at once.
    private var visibleSlice: [(offset: Int, element: ReviewItem)] {
        guard currentIndex < items.count else { return [] }
        let upper = min(items.count, currentIndex + 2)
        return Array(items.enumerated())[currentIndex..<upper].map { ($0.offset, $0.element) }
    }

    @ViewBuilder
    private func card(for item: ReviewItem, isTop: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(Color.black)

            switch item.kind {
            case .still(let still):
                StillReviewCard(timestamp: still.timestamp, videoURL: videoURL)
            case .clip(let clip):
                if isTop {
                    ClipReviewCard(clip: clip, videoURL: videoURL)
                } else {
                    ProgressView().tint(.white)
                }
            }

            if isTop {
                stamps
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: isTop ? 10 : 2)
    }

    @ViewBuilder
    private var stamps: some View {
        if cardOffset.width > 30 {
            stamp(text: "KEEP", color: .green, angle: -15, alignment: .topLeading)
        }
        if cardOffset.width < -30 {
            stamp(text: "DELETE", color: .red, angle: 15, alignment: .topTrailing)
        }
    }

    private func stamp(text: String, color: Color, angle: Double, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 36, weight: .heavy))
            .foregroundStyle(color)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 4))
            .rotationEffect(.degrees(angle))
            .opacity(min(1, Double(abs(cardOffset.width) / 100)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(24)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isAnimating else { return }
                withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.9)) {
                    cardOffset = value.translation
                    cardRotation = Double(value.translation.width / 20)
                }
            }
            .onEnded { value in
                guard !isAnimating else { return }
                if value.translation.width > swipeThreshold {
                    keep()
                } else if value.translation.width < -swipeThreshold {
                    reject()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        cardOffset = .zero
                        cardRotation = 0
                    }
                }
            }
    }

    // MARK: - Buttons

    private var decisionButtons: some View {
        HStack(spacing: 60) {
            circleButton(icon: "xmark", tint: .red) { reject() }
            circleButton(icon: "checkmark", tint: .green) { keep() }
        }
        .padding(.bottom, 40)
    }

    private func circleButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            guard !isAnimating else { return }
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.15))
                .clipShape(Circle())
        }
    }

    private var skipButton: some View {
        Button(action: keepAllRemaining) {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill").font(.system(size: 11))
                Text("Skip review · Keep all (\(items.count - currentIndex))")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.vertical, 8)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle().fill(.green.opacity(0.15)).frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 6) {
                Text("\(keptCount) item\(keptCount == 1 ? "" : "s") kept")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if deletedCount > 0 {
                    Text("\(deletedCount) deleted from the timeline. Undo on the timeline brings them back.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            VStack(spacing: 12) {
                Button {
                    dismiss()
                    onExport()
                } label: {
                    Label("Export \(keptCount) item\(keptCount == 1 ? "" : "s")", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.framePullBlue)
                .disabled(keptCount == 0)

                Button("Back to timeline") { dismiss() }
                    .foregroundStyle(.white.opacity(0.7))

                Button("Review again") { buildQueue() }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Queue + decisions

    private func buildQueue() {
        var queue = markingState.markedStills.map { ReviewItem(id: $0.id, kind: .still($0)) }
        queue.append(contentsOf: markingState.markedClips.map { ReviewItem(id: $0.id, kind: .clip($0)) })
        items = queue
        currentIndex = 0
        keptCount = 0
        deletedCount = 0
        cardOffset = .zero
        cardRotation = 0
    }

    private func keep() {
        guard let item = currentItem else { return }
        setApproval(for: item, approved: true)
        keptCount += 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        animateOut(direction: 1)
    }

    /// Left swipe deletes outright rather than just unticking. Both removals record
    /// undo in MarkingState, so a mis-swipe is recoverable from the timeline's undo.
    private func reject() {
        guard let item = currentItem else { return }
        switch item.kind {
        case .still(let still): markingState.removeStill(id: still.id)
        case .clip(let clip):   markingState.removeClip(id: clip.id)
        }
        deletedCount += 1
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        animateOut(direction: -1)
    }

    private func keepAllRemaining() {
        guard !isAnimating else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        for item in items[currentIndex...] {
            setApproval(for: item, approved: true)
            keptCount += 1
        }
        currentIndex = items.count
    }

    private func setApproval(for item: ReviewItem, approved: Bool) {
        switch item.kind {
        case .still(let still): markingState.setApproval(forStill: still.id, approved: approved)
        case .clip(let clip):   markingState.setApproval(forClip: clip.id, approved: approved)
        }
    }

    /// Fling the card away, then reset position and advance WITHOUT animation —
    /// otherwise the incoming card animates in from wherever the old one landed.
    private func animateOut(direction: CGFloat) {
        isAnimating = true
        withAnimation(.easeOut(duration: flingDuration)) {
            cardOffset = CGSize(width: direction * 500, height: direction * 100)
            cardRotation = Double(direction * 25)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + flingDuration) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cardOffset = .zero
                cardRotation = 0
                currentIndex += 1
                isAnimating = false
            }
        }
    }
}

// MARK: - Cards

/// Frame-accurate still preview — zero seek tolerance so the card shows exactly
/// the frame that will be exported.
struct StillReviewCard: View {
    let timestamp: Double
    let videoURL: URL

    @State private var image: UIImage?
    @State private var frameNumber: Int?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white).task { await loadFrame() }
            }

            cardLabel(icon: "camera.fill", text: frameNumber.map { "Frame \($0)" }
                      ?? String(format: "%.1fs", timestamp))
        }
    }

    private func loadFrame() async {
        let asset = AVURLAsset(url: videoURL)

        var frameRate: Float = 30
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            frameRate = fps
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        guard let (cgImage, _) = try? await generator.image(
            at: CMTime(seconds: timestamp, preferredTimescale: 600)
        ) else { return }

        image = UIImage(cgImage: cgImage)
        frameNumber = Int(timestamp * Double(frameRate))
    }
}

/// Looping clip preview. AVPlayerLooper needs an AVQueuePlayer and both must be
/// retained, hence the two pieces of state.
struct ClipReviewCard: View {
    let clip: MarkedClip
    let videoURL: URL

    @State private var looper: AVPlayerLooper?
    @State private var queuePlayer: AVQueuePlayer?

    var body: some View {
        ZStack {
            if let queuePlayer {
                PlayerLayerView(player: queuePlayer)
                    .onAppear { queuePlayer.play() }
                    .onDisappear { queuePlayer.pause() }
            } else {
                ProgressView().tint(.white).onAppear(perform: setupLooper)
            }

            cardLabel(icon: "video.fill", text: String(format: "Clip %.1fs", clip.duration))
        }
    }

    private func setupLooper() {
        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        let range = CMTimeRange(
            start: CMTime(seconds: clip.inPoint, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.05, clip.duration), preferredTimescale: 600)
        )

        let player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        queuePlayer = player
    }
}

@ViewBuilder
private func cardLabel(icon: String, text: String) -> some View {
    VStack {
        Spacer()
        HStack {
            Image(systemName: icon)
            Text(text)
        }
        .font(.subheadline.bold())
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .padding(12)
    }
}

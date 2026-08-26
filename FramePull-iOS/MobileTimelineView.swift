//
//  MobileTimelineView.swift
//  FramePull (iOS)
//
//  Touch timeline using the same visible-time-window model as the Mac target's
//  ManualTimelineView: the strip always renders at viewport width, and zoom
//  shrinks the visible time range rather than the rendered content.
//
//    visibleDuration = duration / zoomLevel
//    x(t)            = (t - scrollTime) / visibleDuration * width
//
//  Gestures: drag scrubs, pinch zooms anchored on the playhead, and the window
//  page-scrolls to follow the playhead when it leaves the visible range.
//

import SwiftUI

struct MobileTimelineView: View {
    @ObservedObject var markingState: MarkingState
    @ObservedObject var player: PlayerController

    @Binding var zoomLevel: Double
    var trackHeight: CGFloat = 78
    @State private var scrollTime: Double = 0
    @State private var zoomAnchor: Double? = nil
    @State private var isScrubbing = false

    private var duration: Double { max(player.duration, 0.0001) }
    private var visibleDuration: Double { duration / max(1, zoomLevel) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.28))

                clipBars(width: width)
                cutTicks(width: width)
                stillTicks(width: width)
                pendingMarkers(width: width)
                playhead(width: width)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
            .gesture(zoomGesture)
            .onChange(of: player.currentTime) { _ in followPlayhead() }
            .onChange(of: zoomLevel) { _ in clampScroll() }
        }
        .frame(height: trackHeight)
    }

    // MARK: - Layers

    private func cutTicks(width: CGFloat) -> some View {
        ForEach(visible(markingState.detectedCuts), id: \.self) { cut in
            Rectangle()
                .fill(Color.framePullAmber.opacity(0.85))
                .frame(width: 1.5, height: trackHeight * 0.55)
                .position(x: x(cut, width), y: trackHeight * 0.3)
        }
    }

    private func clipBars(width: CGFloat) -> some View {
        ForEach(markingState.markedClips.filter { overlapsWindow($0.inPoint, $0.outPoint) }) { clip in
            let startX = x(clip.inPoint, width)
            let endX = x(clip.outPoint, width)
            let barWidth = max(2, endX - startX)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.framePullBlue.opacity(clip.isApproved ? 0.55 : 0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.framePullBlue, lineWidth: 1)
                )
                .frame(width: barWidth, height: trackHeight * 0.34)
                .position(x: startX + barWidth / 2, y: trackHeight * 0.72)
        }
    }

    private func stillTicks(width: CGFloat) -> some View {
        ForEach(markingState.markedStills.filter { inWindow($0.timestamp) }) { still in
            Circle()
                .fill(still.isApproved ? Color.white : Color.white.opacity(0.35))
                .frame(width: 7, height: 7)
                .position(x: x(still.timestamp, width), y: trackHeight * 0.72)
        }
    }

    @ViewBuilder
    private func pendingMarkers(width: CGFloat) -> some View {
        if let pendingIn = markingState.pendingInPoint, inWindow(pendingIn) {
            pendingLine(at: x(pendingIn, width), label: "IN")
        }
        if let pendingOut = markingState.pendingOutPoint, inWindow(pendingOut) {
            pendingLine(at: x(pendingOut, width), label: "OUT")
        }
    }

    private func pendingLine(at xPos: CGFloat, label: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.framePullAmber)
            Rectangle()
                .fill(Color.framePullAmber)
                .frame(width: 2)
        }
        .frame(height: trackHeight * 0.8)
        .position(x: xPos, y: trackHeight * 0.42)
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: isScrubbing ? 3 : 2, height: trackHeight)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .position(x: x(player.currentTime, width), y: trackHeight / 2)
    }

    // MARK: - Gestures

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isScrubbing = true
                player.pause()
                player.scrub(to: time(forX: value.location.x, width: width))
            }
            .onEnded { _ in
                isScrubbing = false
                player.endScrub()
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = zoomAnchor ?? zoomLevel
                if zoomAnchor == nil { zoomAnchor = zoomLevel }
                zoomLevel = min(40, max(1, base * value))
                centerOnPlayhead()
            }
            .onEnded { _ in zoomAnchor = nil }
    }

    // MARK: - Window math

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((time - scrollTime) / visibleDuration) * width
    }

    private func time(forX xPos: CGFloat, width: CGFloat) -> Double {
        scrollTime + Double(xPos / max(width, 1)) * visibleDuration
    }

    private func inWindow(_ time: Double) -> Bool {
        time >= scrollTime - visibleDuration * 0.1 &&
        time <= scrollTime + visibleDuration * 1.1
    }

    private func overlapsWindow(_ start: Double, _ end: Double) -> Bool {
        end >= scrollTime && start <= scrollTime + visibleDuration
    }

    private func visible(_ times: [Double]) -> [Double] {
        times.filter { inWindow($0) }
    }

    /// Page-style follow, matching the Mac behaviour: only move the window when
    /// the playhead actually leaves it, so the strip doesn't crawl continuously.
    private func followPlayhead() {
        guard !isScrubbing else { return }
        let t = player.currentTime
        if t < scrollTime || t > scrollTime + visibleDuration {
            scrollTime = t - visibleDuration * 0.15
            clampScroll()
        }
    }

    private func centerOnPlayhead() {
        scrollTime = player.currentTime - visibleDuration / 2
        clampScroll()
    }

    private func clampScroll() {
        scrollTime = min(max(0, scrollTime), max(0, duration - visibleDuration))
    }
}

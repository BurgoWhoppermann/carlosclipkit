//
//  PlayerLayerView.swift
//  FramePull (iOS)
//
//  Thin AVPlayerLayer host. Deliberately not AVKit's VideoPlayer: that brings
//  its own transport chrome and gesture handling, which fights the marking UI.
//

import SwiftUI
import AVFoundation

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        // Identity check mirrors the Mac target: reassigning the player rebuilds
        // the presentation layer and makes the video flicker on every tick.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

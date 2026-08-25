//
//  FramePullMobileApp.swift
//  FramePull (iOS)
//
//  iOS/iPadOS entry point. Ships under the SAME bundle identifier as the macOS
//  app (de.carlooppermann.clipkit) so the two platforms sit in one App Store
//  record and qualify for universal purchase.
//
//  The UI is the touch counterpart of the Mac marking flow: import, detect cuts,
//  then mark stills and clips against the shared MarkingState.
//

import SwiftUI

@main
struct FramePullMobileApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

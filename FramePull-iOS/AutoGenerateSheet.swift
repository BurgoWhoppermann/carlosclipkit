//
//  AutoGenerateSheet.swift
//  FramePull (iOS)
//
//  Auto-generation used to be a confirmation dialog buried in the scene-cut menu. It's a
//  primary action — one tap to fill the timeline from the detected cuts — so it gets its
//  own sheet, opened from a full-width button under the marking controls.
//

import SwiftUI

struct AutoGenerateSheet: View {
    @ObservedObject var markingState: MarkingState
    let duration: Double

    @Environment(\.dismiss) private var dismiss

    @AppStorage("autoGenerateStills") private var makeStills = true
    @AppStorage("autoGenerateClips") private var makeClips = true
    @AppStorage("autoScenesPerClip") private var scenesPerClip: ScenesPerClip = .three

    private var generator: AutoGenerator {
        AutoGenerator(markingState: markingState, duration: duration)
    }

    private var sceneCount: Int { generator.sceneCount }
    private var clipCount: Int { generator.clipCount(scenesPerClip: scenesPerClip) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Detected cuts", value: "\(markingState.detectedCuts.count)")
                    LabeledContent("Scenes", value: "\(sceneCount)")
                } footer: {
                    Text("Scenes are the stretches between detected cuts, plus the head and tail of the video.")
                }

                Section("Stills") {
                    Toggle("One still per scene", isOn: $makeStills)
                    if makeStills {
                        LabeledContent("Will create", value: "\(sceneCount) still\(sceneCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Text("Placed in the middle of each scene, clear of any transition at either end.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Clips") {
                    Toggle("Generate clips", isOn: $makeClips)

                    if makeClips {
                        Picker("Scenes per clip", selection: $scenesPerClip) {
                            ForEach(ScenesPerClip.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(scenesPerClip.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Will create", value: "\(clipCount) clip\(clipCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        markingState.clearStills()
                    } label: {
                        Label("Clear all stills (\(markingState.markedStills.count))", systemImage: "camera.badge.ellipsis")
                    }
                    .disabled(markingState.markedStills.isEmpty)

                    Button(role: .destructive) {
                        markingState.clearClips()
                    } label: {
                        Label("Clear all clips (\(markingState.markedClips.count))", systemImage: "film.stack")
                    }
                    .disabled(markingState.markedClips.isEmpty)
                } header: {
                    Text("Clear")
                } footer: {
                    Text("Removes hand-placed markers too. Undo on the timeline brings them back.")
                }
            }
            .navigationTitle("Auto-generate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        generator.run(stills: makeStills, clips: makeClips, scenesPerClip: scenesPerClip)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    } label: {
                        Label("Generate", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.framePullAmber)
                    .disabled(!makeStills && !makeClips)

                    Text("Replaces previously auto-generated markers. Hand-placed ones are kept.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
    }
}

//
//  ExportSheet.swift
//  FramePull (iOS)
//
//  Touch counterpart of ExportSettingsView: a scrollable form with a pinned
//  action bar that turns into progress + Cancel while an export runs.
//

import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    @ObservedObject var markingState: MarkingState
    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = ExportCoordinator()

    @State private var options = MobileExportOptions()
    @State private var destination: ExportDestination = .photos
    @State private var isPickingFolder = false

    private var stillCount: Int { markingState.approvedStills.count }
    private var clipCount: Int { markingState.approvedClips.count }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                destinationSection
                if stillCount > 0 { stillsSection }
                if clipCount > 0 { clipsSection }
                if gridCount > 0 { gridSection }
                if stillCount > 0 || clipCount > 0 { cropSection }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(coordinator.isExporting)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let folder): coordinator.deliverToFiles(destination: folder)
                case .failure(let error):  coordinator.errorMessage = error.localizedDescription
                }
            }
            .onChange(of: coordinator.pendingFilesDelivery) { pending in
                if pending != nil { isPickingFolder = true }
            }
        }
        .interactiveDismissDisabled(coordinator.isExporting)
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            HStack(spacing: 18) {
                Label("\(stillCount)", systemImage: "camera")
                Label("\(clipCount)", systemImage: "film")
                if gridCount > 0 { Label("\(gridCount)", systemImage: "square.grid.2x2") }
                Spacer()
            }
            .font(.title3)
            .foregroundStyle(Color.framePullBlue)
        } footer: {
            Text("Only items you've kept are exported. Swipe to delete anything you don't want.")
        }
    }

    private var destinationSection: some View {
        Section("Destination") {
            Picker("Save to", selection: $destination) {
                ForEach(ExportDestination.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(destination.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stillsSection: some View {
        Section("Stills") {
            Toggle("Export stills", isOn: $options.exportStills)

            if options.exportStills {
                Picker("Format", selection: $options.stillFormat) {
                    ForEach(StillFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                Picker("Size", selection: $options.stillSize) {
                    ForEach(StillSize.allCases, id: \.self) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
            }
        }
    }

    private var clipsSection: some View {
        Section("Clips") {
            Toggle("Export MP4", isOn: $options.exportClips)

            if options.exportClips {
                Picker("Quality", selection: $options.clipQuality) {
                    ForEach(ClipQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Toggle("Mute audio", isOn: $options.muteAudio)
            }

            Toggle("Also export GIF", isOn: $options.exportGIF)

            if options.exportGIF {
                Picker("GIF size", selection: $options.gifResolution) {
                    ForEach(GIFResolution.allCases, id: \.self) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                Stepper("GIF frame rate: \(options.gifFrameRate)", value: $options.gifFrameRate, in: 5...30)
            }
        }
    }

    private var gridCount: Int { markingState.completedGrids.count }

    private var gridSection: some View {
        Section {
            Toggle("Export grids", isOn: $options.exportGrids)
            if options.exportGrids {
                LabeledContent("Ready to render", value: "\(gridCount)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Grids")
        } footer: {
            Text("Only grids with every cell filled are exported. All-still grids render as JPEG; anything containing a clip renders as MP4.")
        }
    }

    private var cropSection: some View {
        Section {
            Toggle("Also export 4:5", isOn: $options.export4x5)
            Toggle("Also export 9:16", isOn: $options.export9x16)
        } header: {
            Text("Social crops")
        } footer: {
            Text("Extra copies cropped for feed and story. When both are on, 9:16 uses each item's reframe position and 4:5 stays centred.")
        }
    }

    private func resultBanner(_ message: String, isError: Bool) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(isError ? .red : .green)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 8) {
            // Result sits directly above the button. In the Form it rendered
            // below the fold, so a finished export looked like nothing happened.
            if let message = coordinator.errorMessage {
                resultBanner(message, isError: true)
            } else if let message = coordinator.completionMessage {
                resultBanner(message, isError: false)
            }

            if coordinator.isExporting {
                ProgressView(value: coordinator.progress) {
                    Text(coordinator.status).font(.caption)
                }
                .tint(Color.framePullAmber)

                Button("Cancel", role: .destructive) { coordinator.cancel() }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
            } else {
                Button {
                    coordinator.export(
                        markingState: markingState,
                        videoURL: videoURL,
                        options: options,
                        destination: destination
                    )
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.framePullBlue)
                .disabled(!hasSomethingToExport)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var hasSomethingToExport: Bool {
        let stills = options.exportStills && stillCount > 0
        let clips = (options.exportClips || options.exportGIF) && clipCount > 0
        let grids = options.exportGrids && gridCount > 0
        return stills || clips || grids
    }
}

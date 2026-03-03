import SwiftUI

/// Dialog for configuring stills & clips settings before auto-generating markers.
struct AnalysisSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .foregroundColor(.clipkitBlue)
                Text("Generate Markers")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content — each section: toggle header → settings
            VStack(spacing: 16) {
                // ── Stills ──
                stillsSection

                // ── Clips ──
                clipsSection
            }
            .padding()

            Divider()

            // Generate button
            VStack(spacing: 6) {
                Button(action: {
                    onGenerate()
                    dismiss()
                }) {
                    Label("Generate", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.clipkitBlue)
                .controlSize(.large)
                .disabled(!appState.scenesDetected || (!appState.exportStillsEnabled && !appState.exportMovingClipsEnabled))

                if !appState.scenesDetected {
                    Text("Detect cuts first")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !appState.exportStillsEnabled && !appState.exportMovingClipsEnabled {
                    Text("Enable at least one export type")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(width: 420)
    }

    // MARK: - Stills Section

    private var stillsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle header
            sectionToggle(title: "Stills", icon: "photo.on.rectangle", isOn: $appState.exportStillsEnabled)

            // Settings (always visible, greyed out when disabled)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Count")
                        .font(.subheadline)
                        .frame(width: 65, alignment: .leading)
                    TextField("", value: $appState.stillCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.center)
                    Stepper("", value: $appState.stillCount, in: 1...100)
                        .labelsHidden()
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Placement")
                        .font(.subheadline)
                        .frame(width: 65, alignment: .leading)
                    Picker("", selection: $appState.stillPlacement) {
                        ForEach(StillPlacement.allCases, id: \.self) { placement in
                            Text(placement.rawValue).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 4)
            .disabled(!appState.exportStillsEnabled)
            .opacity(appState.exportStillsEnabled ? 1 : 0.35)
        }
    }

    // MARK: - Clips Section

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle header
            sectionToggle(title: "Clips", icon: "film", isOn: $appState.exportMovingClipsEnabled)

            // Settings (always visible, greyed out when disabled)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Count")
                        .font(.subheadline)
                        .frame(width: 65, alignment: .leading)
                    TextField("", value: $appState.clipCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.center)
                    Stepper("", value: $appState.clipCount, in: 1...50)
                        .labelsHidden()
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Length")
                        .font(.subheadline)
                        .frame(width: 65, alignment: .leading)
                    Slider(value: $appState.clipDuration, in: 1.0...30.0, step: 1.0)
                        .tint(.clipkitBlue)
                    Text("\(appState.clipDuration, specifier: "%.0f")s")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }

                Toggle("Avoid crossing cuts", isOn: $appState.avoidCrossingScenes)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                Toggle("Allow overlapping", isOn: $appState.allowOverlapping)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
            }
            .padding(.top, 10)
            .padding(.horizontal, 4)
            .disabled(!appState.exportMovingClipsEnabled)
            .opacity(appState.exportMovingClipsEnabled ? 1 : 0.35)
        }
    }

    // MARK: - Section Toggle

    private func sectionToggle(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isOn.wrappedValue ? .clipkitBlue : .secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
                Spacer()
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isOn.wrappedValue ? .clipkitBlue : .secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn.wrappedValue ? Color.clipkitLightBlue : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn.wrappedValue ? Color.clipkitBlue : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

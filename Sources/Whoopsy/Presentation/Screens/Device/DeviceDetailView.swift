import SwiftUI

/// The strap's own page — reached from the badge in Home's top bar.
///
/// **This is the page template.** It exists to answer one question the rest of the app depends on and
/// nothing else can supply: *which model is this strap?* The envelope, the packet-type numbering and
/// the header checksum are all selected by that answer, and until now it was guessed from an
/// advertised name — a test that cannot tell a 5.0 from a 5.0 MG and calls an unnamed strap a 4.0.
///
/// It is deliberately a `Form` and deliberately thin. The strap's history, the drain and the clock are
/// not here because none of them is implemented; a screen that showed a "Sync now" button for a
/// generation this build cannot frame would be promising something the code refuses to do.
public struct DeviceDetailView: View {
    @State private var viewModel: DeviceDetailViewModel

    public init(viewModel: DeviceDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            strapSection
            modelSection
            protocolSection
            if !viewModel.status.isEmpty {
                Section { Text(viewModel.status).font(.footnote).foregroundStyle(Theme.textSecondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .navigationTitle("Strap")
        .inlineNavigationTitle()
        .task { await viewModel.load() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var strapSection: some View {
        Section("Strap") {
            if viewModel.hasDevice {
                LabeledContent("Connection", value: viewModel.device?.connectionState.rawValue ?? "—")
                // A dash, never a number, unless the strap is connected — `batteryPercentage` is a
                // literal `100` written at discovery, so a figure here would be this app's own
                // constant rather than a reading. Same rule as Home's badge.
                LabeledContent("Battery", value: viewModel.batteryPercentage.map { "\($0)%" } ?? "—")
                LabeledContent("Firmware", value: deviceValue(viewModel.device?.firmwareVersion))
                LabeledContent("Signal", value: viewModel.device?.signalStrengthRssi.map { "\($0) dBm" } ?? "—")
            } else {
                Text("No strap connected.")
                    .foregroundStyle(Theme.textSecondary)
                Text("Open Settings → Device to scan for one.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var modelSection: some View {
        Section {
            // The app's first `Picker`. Styled by the platform on purpose: a `Form` row that pushes a
            // list is the idiom on iOS, a pop-up button is the idiom on macOS, and Home is built for
            // both. Three options do not need a segmented control to disambiguate them.
            Picker("Model", selection: Binding(
                get: { viewModel.model },
                set: { viewModel.choose($0) }
            )) {
                ForEach(WhoopHardwareGeneration.selectableModels) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .disabled(!viewModel.hasDevice)
        } footer: {
            if viewModel.isModelSaved {
                Text("Saved for this strap. The choice is remembered per device and decides which protocol this app speaks to it.")
            } else {
                Text("Not chosen yet — this is inferred from the name the strap advertises, which cannot tell a 5.0 from a 5.0 MG. Confirm it above.")
            }
        }
    }

    private var protocolSection: some View {
        Section("Sync") {
            if viewModel.supportsSync {
                Label("Protocol implemented", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.recoveryGreen)
                // **The envelope named here is the selected model's own**, because there are now two
                // of them and the sentence used to name the 4.0 unconditionally. A 5.0 framed with the
                // 4.0's envelope is not a message that strap rejects — it is a different one — so a
                // caption that named the wrong envelope would be describing the exact mistake the two
                // builders exist to make unreachable.
                Text("Commands are framed with the WHOOP \(viewModel.protocolEnvelopeName) envelope recorded in docs/BLE_PROTOCOL.md.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                // Said plainly rather than left to the docs: the two envelopes match independent
                // reverse-engineering references and their checksums are pinned by published vectors,
                // but no frame this app builds has ever been seen by a strap. The 5.0's sentence is a
                // different one — see `DeviceDetailViewModel.protocolCaveat`.
                Text(viewModel.protocolCaveat)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            } else {
                // Unreachable from the picker, which offers exactly three models and all three are
                // now implemented on both sides. It renders for a generation with **no envelope at
                // all** — the standard `0x2A37` strap and the simulator — which is a different fact
                // from the one this branch used to carry: it used to mean "readable but not writable",
                // and that state no longer exists for any model the user can select.
                Label("No proprietary protocol", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.recoveryYellow)
                Text("This model has no WHOOP packet envelope, so nothing is framed for it and only the standard heart-rate service is read.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func deviceValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }
}

// MARK: - Platform

extension View {
    /// Puts the navigation title inline, on the platforms that have the concept.
    ///
    /// `navigationBarTitleDisplayMode` is unavailable on macOS, and this page is built for both — the
    /// host `swift build` is this repo's edit/compile loop and the test runner links against its
    /// objects. This is the third member of the family `HomeDashboardView.hidingTabBar(_:)` documents;
    /// the iOS build stays green either way, which is what makes the guard necessary rather than
    /// tidy.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

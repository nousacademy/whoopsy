import SwiftUI

/// `More → Settings`, which is the Anonymous diagnostics toggle and nothing else.
///
/// **It drew four sections and now draws one, and the three that left are on the profile page's `LOGS`
/// tab** — Apple Health, the WHOOP and Zero fasting imports, and the JSON + CSV export. That was the
/// user's decision, and the structural half of it is `LocalDataViewModel`: the four actions moved with
/// their captions and their arguments rather than being duplicated, so there is exactly one button per
/// import in this app. See that type for why it is a second view model rather than a fifth section of
/// this page's.
///
/// **The toggle stayed because it is a statement about the app rather than about data.** The `LOGS` tab
/// answers *where does my history come from and where does it go*; this answers *does this app phone
/// home*, and that question belongs on the page that is about the app. Its caption is load-bearing
/// rather than decorative — a local-first app that never says so looks exactly like one that uploads
/// quietly — and it is the reason this caption is the one piece of copy that did not move with the rest.
///
/// **What is left is one `Section` and one conditional one.** The status line stays because it is this
/// page's own: the toggle writes through `save()`, and a save that failed has nowhere else to say so.
public struct SettingsDashboardView: View {
    @State private var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) { _viewModel = State(initialValue: viewModel) }

    public var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Anonymous diagnostics", isOn: Binding(
                    get: { viewModel.preferences.analyticsEnabled },
                    set: { viewModel.preferences.analyticsEnabled = $0; Task { await viewModel.save() } }))
                Text("Whoopsy is local-first; this preference never enables cloud biometric uploads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.status.isEmpty { Section { Text(viewModel.status).font(.footnote) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .task { await viewModel.load() }
        .preferredColorScheme(.dark)
    }
}

import SwiftUI

/// The fourth row behind More: the three facts this app reads off the user.
///
/// **It is a `Form`, like `SettingsDashboardView` beside it, and not one of the app's dark card
/// screens.** That is a decision about what kind of page this is: a card screen in this app draws
/// readings, and this page has none — every field here is an input, and the app's own `Form` styling
/// is what makes a field look editable rather than like a figure the app measured. The alternative
/// was a hand-built card whose `TextField`s would have had to be styled back into looking like
/// controls.
///
/// **It exists because calorie figures had no honest input.** `StrainAccumulatorMath.estimateCalories`
/// multiplies by body weight and refuses to substitute one, so every calorie figure in this app is a
/// dash until somebody supplies one. The profile page is that somebody. See `ProfileViewModel` for why
/// these three fields and not the entity's ten.
public struct ProfileDashboardView: View {
    @State private var viewModel: ProfileViewModel

    public init(viewModel: ProfileViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Form {
            Section {
                field(
                    title: "Weight",
                    text: $viewModel.weightText,
                    unit: "kg",
                    detail: "Used for calories only. Leave it blank and calorie figures stay blank rather than being scaled by a weight this app guessed.")
            } header: {
                Text("Body")
            }

            Section {
                field(
                    title: "Max heart rate",
                    text: $viewModel.maxHeartRateText,
                    unit: "bpm",
                    detail: "The ceiling of every heart-rate zone, and the numerator of the VO₂ max estimate — which is why that figure is labelled an estimate.")
                field(
                    title: "Resting heart rate",
                    text: $viewModel.restingHeartRateText,
                    unit: "bpm",
                    detail: "The floor of every zone: the bands are percentages of the reserve between these two numbers.")
            } header: {
                Text("Heart rate")
            } footer: {
                Text("Zones are built from this pair, so they change when it changes. Days already recorded keep the figures they were scored with.")
            }

            Section {
                Button("Save") { Task { await viewModel.save() } }
                    .disabled(!viewModel.hasLoaded)

                if !viewModel.status.isEmpty {
                    Text(viewModel.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .navigationTitle("Profile")
        .inlineNavigationTitle()
        .task { await viewModel.load() }
        .preferredColorScheme(.dark)
    }

    /// One labelled numeric field: the name and unit on the left, the entry on the right.
    ///
    /// **The keyboard is `.decimalPad` for weight and `.numberPad` for the two rates**, and that is not
    /// cosmetic — `ProfileDraft` refuses anything outside a plausible band, and the surest way not to
    /// refuse is not to offer it. Neither keyboard has a return key, so the Save button is the only way
    /// out of a field, which is why it is a visible button rather than a toolbar item.
    private func field(
        title: String,
        text: Binding<String>,
        unit: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)

                Spacer(minLength: 8)

                TextField("—", text: text)
                    .multilineTextAlignment(.trailing)
                    .numericKeyboard(decimal: unit == "kg")
                    .monospacedDigit()
                    .frame(maxWidth: 90)

                Text(unit)
                    .foregroundStyle(.secondary)
            }

            // Its own `Text`, and not a `**bold**` run inside a string built with `+`: a concatenated
            // `String` takes `Text`'s `StringProtocol` overload, which does not parse Markdown, and
            // this app has already shipped asterisks to a screen that way.
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Platform

extension View {
    /// Offers a numeric keyboard, on the platforms that have one.
    ///
    /// `keyboardType` is unavailable on macOS and this page is compiled for both — the host
    /// `swift build` is this repo's edit/compile loop and the test runner links its objects, so an
    /// unguarded modifier breaks the fast path while the simulator build stays green. This is the
    /// fourth member of the family `HomeDashboardView.hidingTabBar(_:)` documents.
    ///
    /// `.decimalPad` for a weight and `.numberPad` for the two heart rates: the difference is whether a
    /// decimal separator is a legitimate keystroke, and offering one where it is not is the surest way
    /// to make a user type something `ProfileDraft` then has to refuse.
    @ViewBuilder
    func numericKeyboard(decimal: Bool) -> some View {
        #if os(iOS)
        keyboardType(decimal ? .decimalPad : .numberPad)
        #else
        self
        #endif
    }
}

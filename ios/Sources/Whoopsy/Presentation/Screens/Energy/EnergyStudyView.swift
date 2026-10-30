import SwiftUI

/// The Energy tab: **a study surface, and it reads nothing.**
///
/// **It holds the map and nothing else, deliberately.** The tab began as today's strain under a new
/// name and the user corrected that on 2026-10-30: *"its not going to move my stats energy tab is
/// different study im conducting and should be ignored from app."* So this screen takes no repository,
/// reads no row and writes none — there is no `StrainViewModel` behind it and no day on it.
///
/// **That is the isolation rather than an unfinished page.** A study surface that displayed the app's
/// own strain beside the diagram would invite the reader to treat the two as one claim; a surface that
/// wrote anything would put a diagram's assumptions into a person's history. The tab is therefore
/// inert with respect to every number the rest of the app computes, which is what "ignored from app"
/// has to mean in a codebase whose whole discipline is one writer per stored fact.
public struct EnergyStudyView: View {

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    EnergyFlowMapView()
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
            .background(Theme.backgroundDark)
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .principal) { titleLabel } }
        }
        .preferredColorScheme(.dark)
    }

    private var titleLabel: some View {
        Text("ENERGY")
            .font(.system(size: 14, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.textPrimary)
    }
}

import SwiftUI

/// The Recovery **tab** — a `NavigationStack` around the day's statistics, and nothing else.
///
/// The figures themselves are `RecoveryDetailView`, because Home's green recovery ring pushes the
/// same screen and two copies of it would be two definitions of the tier colour and the dash gates.
/// What is left here is the one thing the tab owns that the pushed copy does not: the stack.
///
/// The tab opens on **today and only today**. The detail view no longer pages, so this is the whole
/// of the tab's day handling — a day the reader cannot move off. On an install whose history is all
/// imported that is a dash, because the export ends before today; the route to a past day is Home's
/// recovery ring, which pushes the same screen seeded with the day on screen. See
/// `RecoveryDetailView` for why the stepper was removed rather than left inert.
public struct RecoveryDashboardView: View {
    @State private var viewModel: RecoveryViewModel
    public init(viewModel: RecoveryViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View {
        NavigationStack {
            RecoveryDetailView(viewModel: viewModel, date: Date())
        }
    }
}

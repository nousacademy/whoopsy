import SwiftUI

/// Main application entry point for Whoopsy.
public struct WhoopsyAppView: View {
    @State private var environment: AppEnvironment

    public init(environment: AppEnvironment = AppEnvironment()) {
        self._environment = State(initialValue: environment)
    }

    public var body: some View {
        MainContainerView(container: environment.container)
            .preferredColorScheme(.dark)
    }
}

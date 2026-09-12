import SwiftUI
import Whoopsy

/// The executable entry point for the Whoopsy iOS Application on iPhone 12+.
@main
struct WhoopsyApp: App {
    @State private var environment: AppEnvironment

    init() {
        let isXcodeCanvas = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        _environment = State(initialValue: AppEnvironment(
            container: isXcodeCanvas ? .preview : DIContainer(useMockBLE: false)
        ))
    }

    var body: some Scene {
        WindowGroup {
            WhoopsyAppView(environment: environment)
        }
    }
}

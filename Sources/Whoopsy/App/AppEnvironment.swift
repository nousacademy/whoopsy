import Foundation
import SwiftUI

/// App-wide environment orchestrator injected into SwiftUI Environment.
@MainActor
@Observable
public final class AppEnvironment {
    public let container: DIContainer

    public init(container: DIContainer = .preview) {
        self.container = container
    }
}

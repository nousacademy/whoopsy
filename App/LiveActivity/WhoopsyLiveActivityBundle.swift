import SwiftUI
import WidgetKit

/// The extension's entry point. **This file is compiled only by Xcode** — `Package.swift` excludes
/// `App/LiveActivity` from the `WhoopsyApp` target, because `path: "app"` is `App/` and SwiftPM
/// compiles every `.swift` file under a target's path recursively, which would drag a `WidgetKit`
/// `@main` bundle into the host executable where WidgetKit does not exist.
@main
struct WhoopsyLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        WhoopsySessionLiveActivity()
    }
}

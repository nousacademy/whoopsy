import SwiftUI

extension View {
    /// Puts the navigation title inline, on the platforms that have the concept.
    ///
    /// `navigationBarTitleDisplayMode` is unavailable on macOS, and every page that calls this is built
    /// for both — the host `swift build` is this repo's edit/compile loop and the test runner links
    /// against its objects. This is a member of the family `HomeDashboardView.hidingTabBar(_:)`
    /// documents; the iOS build stays green either way, which is what makes the guard necessary rather
    /// than tidy.
    ///
    /// **It lives here rather than on a screen because four screens use it** — `LiveSessionView`,
    /// `ActivityEditSheet`, `ActivityPickerView` and `ProfileDashboardView` — and it used to be declared
    /// on `DeviceDetailView`, which the merged device page replaced. A helper with four callers does not
    /// belong to whichever of them happened to be written first, and deleting that screen without
    /// relocating this would have broken the host build while `xcodebuild` stayed green.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

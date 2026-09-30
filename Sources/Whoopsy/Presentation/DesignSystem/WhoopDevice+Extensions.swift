import Foundation

/// The battery figure this app is entitled to show, or `nil` when it is not entitled to show one.
///
/// `WhoopDevice.batteryPercentage` is **not optional and defaults to `100`**, and `WhoopBLEManager`
/// writes that same literal at discovery — so a percentage read off a strap the app has no link to is
/// a constant this app wrote down rather than a measurement it took. The gate is
/// `connectionState == .connected`, and `.connected` alone. `.scanning`, `.connecting`,
/// `.disconnected` and `.error` each describe a link that is not up. **`.syncing` is the one worth
/// saying out loud**, because it is the other state that means a live strap and the dot beside this
/// figure draws it green: it is admitted to neither, on the grounds that `WhoopBLEManager` never
/// constructs it in this build, so nothing here has ever seen a battery percentage read during a
/// drain and can say whether it is the strap's own or the discovery literal a second time. Admitting
/// a state on the strength of what it probably means is how a constant becomes a reading.
///
/// **`nil` rather than `ActivityFigure.dash`, and the difference is the whole reason this is not the
/// device page's `batteryText(for:)`.** Both ask one question — *may this figure be shown* — and each
/// draws the absent case its own way because of what surrounds it. `DeviceSettingsView` drew a labelled
/// `BATTERY` row inside a `Form`, where a row with no value looks unfinished and the dash is the app's
/// word for *nothing was measured*. Home's badge draws a compact glyph with a figure beside it, and
/// there the dash — 9.7 × 1.3 pt of white at that type size, measured off the screen — was read by the
/// user as a battery **bar**: a reading rather than the app's word for no reading. So the gate is
/// defined once, here, and each screen picks its own drawing of "no figure":
/// `DeviceSettingsView.batteryText(for:)` is `device?.batteryReading ?? ActivityFigure.dash`, and
/// Home's badge draws nothing at all in the slot.
///
/// **The `Form` row is gone and the badge is now the only reader**, so Home's drawing is the only one
/// on screen. `batteryText(for:)` is kept unrendered rather than deleted, on the `ActivityDurationBar`
/// precedent: the suite has no test discovery, so removing it would drop its §14 assertions and a
/// falling `assertions=` count would be the only trace. This paragraph still states the gate's two
/// drawings because the second one is what the app now does — but do not read the first as a screen
/// that still exists.
///
/// It cannot live on the entity: `WhoopDevice` is in `Domain`, which imports only `Foundation` and so
/// cannot name the design system's vocabulary either. `RecoveryState+Extensions.swift` is the shape,
/// and `WhoopConnectionState+Extensions.swift` beside it is the sibling — that file's `linkColor` is
/// the dot's rule, and it answers a deliberately different question from this one.
extension WhoopDevice {
    /// The strap's battery as this app is allowed to print it, or `nil` when no figure may be drawn.
    public var batteryReading: String? {
        guard connectionState == .connected else { return nil }
        return "\(batteryPercentage)%"
    }
}

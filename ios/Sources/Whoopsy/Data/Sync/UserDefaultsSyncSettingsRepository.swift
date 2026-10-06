import Foundation

/// The storage pane's settings, in `UserDefaults` beside the app.
///
/// **It is a plain value store and it does not throw, on `AppPreferencesRepository`'s own reasoning
/// rather than by oversight.** A fresh install is `SyncSettings()` — device storage, no span drawn,
/// biometrics staying on the phone — which is the app as it was before this feature existed. There is no
/// failure a reader could act on, so there is no error to report: the worst a lost preference can do is
/// leave the user where they already were, with everything on the phone.
///
/// **Nothing here may move into `AppPreferences`.** That struct is *exported* — `ExportLocalDataUseCase`
/// writes its fields into the JSON's `settings` block and §6 asserts that shape — so a destination added
/// to it would silently become part of a file format. The two are separate on purpose: one is a record of
/// what the app is doing, the other is a boundary between two stores, and only one of them is somebody's
/// export.
///
/// **There is one namespace and no `namespace:` argument, which is the whole of what this class lost.**
/// It used to be constructed three times — `org.whoopsy.sync`, `.workouts`, `.strains` — because each use
/// case kept its own pair of cutoffs over its own resource's history, and two resources advancing one
/// shared pair would have taken turns silently skipping each other's rows. The cutoffs are gone with the
/// delete that justified them: what a destination and a span describe is *this install*, not one
/// resource's position in its own history, so three copies of the same two answers would be three things
/// to keep in step for no reader. A resource that needs its own settings later needs its own argument
/// back, and the class's own history is where that argument is written down.
///
/// **Both ends of the span are stored as a `Double` behind a presence test, and the test is the point.**
/// The keys are absent until a user draws a span, and `defaults.double(forKey:)` answers `0` for a key
/// nobody has written — which is 1970-01-01, a span starting before the whole history and therefore not
/// the same instruction as *no span at all*. So absence is asked for separately, with
/// `object(forKey:)`, and the same idiom `UserDefaultsActiveFastRepository` uses.
///
/// **The other two need no such test, and the asymmetry is deliberate.** A destination is an enum and a
/// flag is a `Bool`, and both have a documented meaning for absence — `.device` and `false` are the
/// state a fresh install is in and the state that sends nothing anywhere — so a missing key and an
/// unreadable `rawValue` both fall back there. A date has no safe fallback: any instant this class could
/// invent would be a span end the user never drew, which is why it is the one value asked for by
/// presence.
public final class UserDefaultsSyncSettingsRepository: SyncSettingsRepository, @unchecked Sendable {

    /// The one namespace every key is built on. Kept out of `org.whoopsy.presentation.*` and
    /// `org.whoopsy.strapModels`: these are the sync's own values, and a reader looking for them should
    /// not have to know which page they are drawn on.
    private static let namespace = "org.whoopsy.sync"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async -> SyncSettings {
        SyncSettings(
            destination: destination(),
            range: range(),
            uploadsBiometricSamples: defaults.bool(forKey: Self.namespace + ".uploadsBiometricSamples")
        )
    }

    public func save(_ settings: SyncSettings) async {
        defaults.set(settings.destination.rawValue, forKey: Self.namespace + ".destination")
        write(settings.range?.from, forKey: Self.namespace + ".rangeFrom")
        write(settings.range?.to, forKey: Self.namespace + ".rangeTo")
        defaults.set(settings.uploadsBiometricSamples, forKey: Self.namespace + ".uploadsBiometricSamples")
    }

    // MARK: - The three values

    /// The stored destination, or `.device` when nothing readable is stored.
    ///
    /// Two cases land on the fallback and both are ordinary. A key nobody has written is the default
    /// state of a fresh install. A `rawValue` this build does not know is what a downgrade leaves
    /// behind — and `.device` is the right answer there rather than an error, because it is the branch
    /// that sends nothing to a server. The opposite guess would start uploading a user's history on the
    /// strength of a string nobody here can read.
    private func destination() -> SyncSettings.Destination {
        guard let raw = defaults.string(forKey: Self.namespace + ".destination") else { return .device }
        return SyncSettings.Destination(rawValue: raw) ?? .device
    }

    /// The stored span, or `nil` unless **both** ends are there.
    ///
    /// Both or neither, mirroring `SyncEngine.setRange(from:to:)`, which is the only writer: a half-drawn
    /// span is not a span, and returning one with an invented end would put the button in a state its own
    /// gate could not describe. A file left with one key by an interrupted write therefore reads as *no
    /// span*, which is the state that runs nothing.
    ///
    /// The two `Date`s are returned exactly as they were written — always a `startOfDay`, because
    /// `SyncRange` snaps in its own `init` and is the only way one is built. Snapping here as well would
    /// be a second definition of the boundary that could drift from the one the run actually walks.
    private func range() -> SyncSettings.SyncRange? {
        guard
            let from = date(forKey: Self.namespace + ".rangeFrom"),
            let to = date(forKey: Self.namespace + ".rangeTo")
        else { return nil }
        return SyncSettings.SyncRange(from: from, to: to)
    }

    /// A stored instant, or `nil` when nobody has written one.
    private func date(forKey key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    /// Write an instant, or clear the key when there is none.
    ///
    /// **A `nil` end removes the key rather than writing a sentinel**, which is the whole reason the
    /// presence test above exists. Writing `0` would make *no span* and *a span ending at the epoch* the
    /// same stored value, and they are opposite instructions: the second one covers no days at all.
    private func write(_ date: Date?, forKey key: String) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

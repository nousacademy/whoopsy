import Foundation
import SwiftUI

/// `More → Settings`: the one preference that is not about a person's body or their files.
///
/// ## This type had five dependencies and has one
///
/// It carried `healthKit`, `whoopExport`, `fasting` and `exportUseCase` beside its preferences
/// repository, and every one of the four moved to `LocalDataViewModel` for the profile page's `LOGS`
/// tab on the user's instruction. **The four methods and their doc comments went with them verbatim** —
/// the HealthKit result being the only honest signal of a permission that is never disclosed, the export
/// import needing a deliberate tap rather than firing from `load()`, the fasting import being the one
/// that writes a session with no measurement behind it — because those arguments are about those
/// *actions* and not about the page they happened to be drawn on. Re-deriving them here would be the way
/// they got lost.
///
/// **The page is one switch and the row survives.** That is the possibly-surprising consequence of the
/// user's own choice, stated here rather than left to be discovered: `More` still lists `Settings`, and
/// what is behind it is the Anonymous diagnostics toggle. What did *not* move is the toggle, because it
/// is a statement about the app rather than about data — and it is the only preference in the app whose
/// caption has to explain that a local-first app is not secretly uploading anything.
///
/// **One dependency, not the two the plan's table predicted.** The second name it listed,
/// `preferences`, is the `AppPreferences` *value* this type holds and reloads, not a second repository —
/// so the shrink is five to one, and both the load and the save go through `repository`.
@MainActor @Observable public final class SettingsViewModel {

    public var preferences = AppPreferences()
    public var status = ""

    private let repository: any AppPreferencesRepository

    public init(repository: any AppPreferencesRepository) {
        self.repository = repository
    }

    public func load() async { preferences = await repository.load() }

    public func save() async { await repository.save(preferences) }
}

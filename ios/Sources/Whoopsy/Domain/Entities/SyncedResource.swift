import Foundation

/// The resources this app syncs, in the order the Worker's own contract lists them.
///
/// **`allCases` *is* the drawn order, and the drawn order is `shared/openapi.json`'s.** The pane's
/// `SYNCED RESOURCES` list is a `ForEach` over this enum, so a resource added here appears on the
/// screen with no view edit — and the order is not a preference: the contract is generated from the
/// Worker's route definitions and sorted by path, so reading the order off the document is what keeps
/// the pane from claiming a list the server does not have. §22 asserts one against the other rather
/// than either against a literal typed twice.
///
/// **Seven of the Worker's eight resources, and the missing one is deliberate.** `biometricSamples` is
/// the eighth and the only resource whose read window is measured in *seconds* rather than days — a
/// single day of it is up to 86,400 rows — so it carries its own control and defaults to staying on
/// the phone. It is absent from this list rather than present-and-dimmed: this list answers *what would
/// move if I switched*, and naming a resource that will not move would make that answer wrong. Its
/// mount sorts **first** among the `/v1/*` paths (`b` before `p`), so its absence is visible rather
/// than hidden at the end.
///
/// **The raw values are the drawn titles and not the wire's names.** `STEP COUNTS` is what the pane
/// prints; `/v1/step-counts` is what the Worker mounts; `stepCounts` is what the Worker calls the
/// resource and what its D1 table is named after. All three are spelled differently and all three are
/// correct, which is the same three-way split `CLAUDE.md` records for this resource — so the two
/// derived properties below are the mapping, written once, rather than a literal at each call site.
public enum SyncedResource: String, Equatable, Sendable, CaseIterable {
    case profile = "PROFILE"
    case receptiveInactivities = "RECEPTIVE INACTIVITIES"
    case recoveries = "RECOVERIES"
    case sleeps = "SLEEPS"
    case stepCounts = "STEP COUNTS"
    case strains = "STRAINS"
    case workouts = "WORKOUTS"

    /// The Worker's own name for the resource — the identifier its routes, service and table are
    /// named after. Not the path and not the title; see the type's own note on the three spellings.
    public var resourceName: String {
        switch self {
        case .profile: return "userProfiles"
        case .receptiveInactivities: return "receptiveInactivities"
        case .recoveries: return "recoveries"
        case .sleeps: return "sleeps"
        case .stepCounts: return "stepCounts"
        case .strains: return "strains"
        case .workouts: return "workouts"
        }
    }

    /// The mounted path, which is what `shared/openapi.json` sorts by and therefore what `allCases`
    /// is ordered by. `userProfiles` is the one whose segment is **singular** — a profile is a
    /// singleton, so its whole surface is one path rather than a collection's three.
    public var path: String {
        switch self {
        case .profile: return "/v1/profile"
        case .receptiveInactivities: return "/v1/receptive-inactivities"
        case .recoveries: return "/v1/recoveries"
        case .sleeps: return "/v1/sleeps"
        case .stepCounts: return "/v1/step-counts"
        case .strains: return "/v1/strains"
        case .workouts: return "/v1/workouts"
        }
    }
}

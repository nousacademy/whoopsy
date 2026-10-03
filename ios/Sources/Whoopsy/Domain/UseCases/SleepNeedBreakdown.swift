import Foundation

/// One night's Sleep Need split into the parts this app can actually source.
///
/// **WHOOP publishes this model's shape, and the export carries half of it.** WHOOP's developer API
/// exposes `sleep_needed` as an additive breakdown — `baseline_milli` + `need_from_sleep_debt_milli` +
/// `need_from_recent_strain_milli` − `need_from_recent_nap_milli` — and the reference app draws that
/// split as three rows under its need figure. The bundled export carries **two** of the terms and
/// neither of the other two: `Sleep need (min)` is the total and `Sleep debt (min)` is one component,
/// while a baseline and a strain contribution exist in no column of any of the four bundled CSVs. That
/// is why this type draws a **two-part** split rather than the reference's three — the third would be a
/// number this app computed and then printed beneath WHOOP's own total, which is the fabrication its
/// whole absence discipline exists to prevent.
///
/// ## Why `need − debt` is one part and not two
///
/// The first part is the difference of the two stored columns, and it is named for both of WHOOP's
/// remaining terms because it *is* both of them: an identity of their published breakdown, not a model
/// of this app's. Nothing here estimates a baseline or a strain term, and nothing here fits anything.
///
/// **That the identity holds was measured, not assumed.** Regressing the export's own need on its own
/// inputs recovers WHOOP's published shape and fixes the coefficient the debt enters at:
///
///     need = 427.5 + 4.05 × previousDayStrain + 0.98 × debt      MAE 4.64 min over 882 nights
///
/// The debt coefficient is **0.98**, which is the finding this type rests on: the stored debt is an
/// additive component of the stored need at face value, so subtracting it leaves exactly the other two
/// terms and nothing else. Had that coefficient come back at, say, 0.4, `need − debt` would have been
/// a quantity with no published meaning and this card would not have been buildable from this data.
///
/// **It is deliberately not the app's own `SleepNeedMath`.** That model is `baseline + 6.40 × strain`,
/// and it is the right model for a *strap* night, whose need it produces. It is the wrong model here:
/// its coefficient was fitted against a need that already contains the debt term (which is why it is
/// 6.40 there and 4.05 above), and its baseline is `UserProfile.targetSleepHours` — a hard-coded
/// constant, never edited and never persisted. Running either over an imported night would print a
/// constant as that user's baseline and double-count the debt, under a total that is WHOOP's own.
///
/// **And the identity runs the other way too, which is the whole reason `hasWhoopNeed` is a
/// parameter.** `need − debt` is WHOOP's base-plus-strain only because WHOOP's need *contains* the
/// debt; `SleepNeedMath` deliberately leaves the term out (`docs/ALGORITHMS.md` §4), so on a strap night the
/// same subtraction is `baseline + strain − debt` — a base requirement short by the whole deficit,
/// under a row labelled `Healthy Minimum + Recent Strain`. Both producers store a need **and** a debt,
/// so nothing in the two numbers tells them apart; `SleepSession.hasWhoopSleepNeed` does, it is `false`
/// for a strap night, and this function withholds the split rather than drawing a false one.
///
/// ## When there is no split
///
/// `nil`, and the card draws its need bar undivided rather than a split it cannot support. Three states
/// produce it: a need this app computed rather than read (see above); a stored night with no debt at
/// all — a row written before `v10`; and a stored pair where the debt exceeds the need, which cannot be
/// a decomposition of it. The last is **unreachable on the bundled export** — measured, `need − debt`
/// runs 228…523 min across all 910 imported nights — and is a guard rather than an assumption: it is
/// the check that keeps a corrupt row from drawing a negative segment.
///
/// **A debt of `0` is a measurement and not an absence**, so it produces a `Breakdown` whose second
/// part is zero-length rather than `nil`. Seventeen of the export's nights are in perfect sleep credit,
/// and `SleepSession.sleepDebtSeconds` documents why `nil` and `0` are different answers.
public enum SleepNeedBreakdown {

    /// The parts of a need this app can name, in the order the card draws them.
    ///
    /// Two cases and not the reference's three, which is the whole argument above: a case for
    /// `healthyMinimum` or `recentStrain` would need a value no column carries, and a case for a
    /// quantity this app cannot source is an invitation to source it from the model.
    public enum Component: String, Sendable, CaseIterable, Identifiable {
        /// `need − debt`: WHOOP's `baseline_milli + need_from_recent_strain_milli`, which the export
        /// carries only as a sum.
        case minimumAndStrain
        /// `Sleep debt (min)` — the one component of the need the export stores on its own.
        case debt

        public var id: String { rawValue }

        /// The row's name, and it carries both of WHOOP's terms because the figure carries both of
        /// them. A row reading only `Healthy Minimum` would claim the strain term was not in it.
        public var displayName: String {
            switch self {
            case .minimumAndStrain: return "Healthy Minimum + Recent Strain"
            case .debt: return "Sleep Debt"
            }
        }
    }

    /// One part of the need: which term, and how many seconds of the need it accounts for.
    public struct Part: Equatable, Sendable, Identifiable {
        public let component: Component
        public let seconds: TimeInterval

        public var id: String { component.rawValue }

        public init(component: Component, seconds: TimeInterval) {
            self.component = component
            self.seconds = seconds
        }
    }

    /// A night's need, and the parts it is made of.
    ///
    /// The parts are contiguous from zero and sum to `needSeconds` **by construction** — the first is
    /// the second subtracted from the whole — which is the property the card's stacked bar and its
    /// printed column both rest on, and it is asserted rather than assumed.
    public struct Breakdown: Equatable, Sendable {
        /// The total the parts are of, carried so a drawing of them can be read against the figure the
        /// card prints above it without reaching back for the session.
        public let needSeconds: TimeInterval

        /// In `Component.allCases` order, so the bar's segments and the card's rows cannot disagree
        /// about which part comes first.
        public let parts: [Part]

        public init(needSeconds: TimeInterval, parts: [Part]) {
            self.needSeconds = needSeconds
            self.parts = parts
        }

        public func seconds(of component: Component) -> TimeInterval? {
            parts.first { $0.component == component }?.seconds
        }
    }

    /// The split of a night's need, or `nil` when the stored pair cannot form one.
    ///
    /// - Parameters:
    ///   - needSeconds: `SleepSession.targetSleepNeedSeconds` — the figure the screen prints, so the
    ///     parts are parts of the number the reader can see.
    ///   - debtSeconds: `SleepSession.sleepDebtSeconds`, or `nil` when the night has none.
    ///   - hasWhoopNeed: `SleepSession.hasWhoopSleepNeed` — whether that need is a total containing the
    ///     debt term. **Required and undefaulted**, deliberately: a caller that has not resolved whose
    ///     need it is holding has not established the thing this split is, and a default would let it
    ///     draw one anyway.
    /// - Returns: The two parts, or `nil` for the three states the type's doc comment lists.
    public static func breakdown(
        needSeconds: TimeInterval,
        debtSeconds: TimeInterval?,
        hasWhoopNeed: Bool
    ) -> Breakdown? {
        guard hasWhoopNeed,
              needSeconds > 0, let debtSeconds, debtSeconds >= 0, debtSeconds <= needSeconds
        else {
            return nil
        }
        return Breakdown(
            needSeconds: needSeconds,
            parts: [
                Part(component: .minimumAndStrain, seconds: needSeconds - debtSeconds),
                Part(component: .debt, seconds: debtSeconds),
            ])
    }
}

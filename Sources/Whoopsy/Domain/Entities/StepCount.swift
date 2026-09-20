import Foundation

/// One day's step count, as the strap's motion produced it.
///
/// ## What this replaced, and why the number is not a HealthKit read
///
/// Steps used to be the one value on Home read through HealthKit — a daily *sum*, the only quantity
/// there that is not a reading the app can file under a day key, fetched on demand by
/// `HKStatisticsQuery(.cumulativeSum)` and stored nowhere. That made steps the one metric that needed
/// a permission this app cannot verify was granted (HealthKit never discloses read status), and the
/// one metric the strap could not produce. This entity is the strap's answer: a row per day, written
/// by `TrackStepsUseCase` from decoded motion, needing no permission and no phone.
///
/// ## `measuredSeconds` is what makes `0` and *nothing* different answers
///
/// **This is the field the whole absence rule rests on, and it is not the step count.** A day with a
/// row and a count of `0` is a measurement — the user wore the strap and did not walk — and it must
/// render as a real `0`. A day with no row at all is unmeasured, and it must render as `—`. Those are
/// different claims and the count alone cannot tell them apart, exactly as `StrainScore.hasMeasurement`
/// documents for a rest day's `0.0`.
///
/// So the flag is derived, not stored: `hasMeasurement` is `measuredSeconds > 0`, and because it is a
/// computed property rather than a column there is **one** test rather than a stored flag and a
/// reader's guess about which zero it is holding. `TrackStepsUseCase` writes only when it measured
/// something, which is the same test.
///
/// **Seconds of sample time, not wall time.** A strap disconnected for six hours contributes nothing
/// to this, so a day the app watched for an hour reports an hour of coverage behind whatever count it
/// counted. Wall time would claim the day was measured across the gap — which is the fabrication this
/// field exists to prevent, and it is the same distinction `StepAccumulator.measuredSeconds` carries.
public struct StepCount: Equatable, Sendable {
    /// The day, snapped to `startOfDay`. See `LocalDatabaseManager.saveStepCount`.
    public let date: Date

    public let stepCount: Int

    /// How much motion the count was derived from, in seconds of sample time.
    public let measuredSeconds: TimeInterval

    /// Whether this row is a measurement at all.
    ///
    /// `false` means the row exists but nothing was counted into it. No writer produces one — this is
    /// reader tolerance in the same spirit as `StrainScore.hasMeasurement`, kept because a `0`-second
    /// row is constructible and a reader that forgot the rule would print it as a real day of no
    /// walking. The two states are one comparison apart, so there is no reason to guess.
    public var hasMeasurement: Bool { measuredSeconds > 0 }

    /// The count as a screen reads it: the figure, or `nil` when the row holds no measurement.
    ///
    /// **The gate every reader of this entity needs, in one place.** `hasMeasurement` says whether a
    /// row is a measurement; this says what to draw, and the two are the same decision — a measured
    /// day of no walking is a real `0` and passes through as one, while a row holding no measured span
    /// is the `—` a day the strap was not worn draws.
    ///
    /// It is a property rather than a helper on each screen because there are now two of them: Home's
    /// `STEPS` tile and the strain detail page's `STEPS` row. A second copy of `hasMeasurement ?
    /// stepCount : nil` is a second chance to write the ternary the other way round, and the two
    /// screens would then disagree about the same stored row — the drift `SleepClockAxis` was
    /// extracted to prevent.
    public var measuredStepCount: Int? { hasMeasurement ? stepCount : nil }

    /// - Parameters:
    ///   - date: The day this count belongs to. Snapped centrally on write.
    ///   - stepCount: The count. Zero is a legitimate measurement; see `measuredSeconds`.
    ///   - measuredSeconds: Seconds of motion the count came from. Zero means unmeasured.
    public init(date: Date, stepCount: Int, measuredSeconds: TimeInterval) {
        self.date = date
        self.stepCount = stepCount
        self.measuredSeconds = measuredSeconds
    }
}

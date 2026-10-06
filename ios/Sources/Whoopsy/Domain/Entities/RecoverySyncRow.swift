import Foundation

/// One `recoveries` row, carried between the layers that a sync has to cross.
///
/// **The sync moves records, not metrics, and this type is why that is not a style choice.**
/// `RecoveryMetric` is what a screen draws and it has twelve fields; `RecoveryRecord` is what the
/// database holds and it has nine. Four of the difference are read-time derivations with no column at
/// all — the three baseline deltas and the `UUID` — and one of them runs the other way, because
/// `source` is a stored column the entity does not carry. So a push written against `RecoveryMetric`
/// would drop `source` on **all 910 imported rows** and would have nothing to put in the three
/// baseline columns on the way back; a sync through the repository protocol would corrupt the
/// provenance of the entire imported history and report success while doing it.
///
/// **The names are the record's, deliberately, and that is what keeps the mapping to one step.** A
/// stored recovery reading goes by three different names on its way from SQLite to the wire —
///
/// | column | record property | wire |
/// | :--- | :--- | :--- |
/// | `skin_temperature` | `skinTemp` | `skinTemperature` |
/// | `spo2_percentage` | `spo2` | `spo2Percentage` |
/// | `date` (a UTC instant string) | `date` | `date` (`YYYY-MM-DD`) |
///
/// — and every one of those is a place a mapping can be written wrong in a way nothing catches. The
/// row therefore takes the *record's* property names verbatim, so the row ↔ record conversion is a
/// field-for-field copy with no naming decision in it at all, and the row → wire conversion is the
/// only step in the whole path where a name changes. One place to get it wrong is one place to check.
///
/// `hrvMetric` is the exception to "the record's names", and only because it already is: it is the
/// same field under the same name in all three, since `HRVMetric` is a `String`-raw enum in Domain
/// whose two literals `rmssd` and `sdnn` are what the wire validates and what the column stores.
public struct RecoverySyncRow: Equatable, Sendable {

    /// The day this row is filed under, as an instant.
    ///
    /// **It is a `Date` here and a `YYYY-MM-DD` on the wire**, and the conversion between them is the
    /// single highest-risk line in the sync — see `RecoveryWireMapper`. It stays a `Date` on this side
    /// because Domain may not know about the wire's spelling of a day, and because every span this app
    /// draws or walks is a pair of instants rather than a pair of strings.
    public let date: Date

    /// The day's recovery score, 0–100.
    public let recoveryScore: Int

    /// Resting heart rate in bpm. A rate of zero is an absence, not a measurement — but the absence
    /// has no row here, so this is not optional in the way a real optional is, it is required and
    /// positive.
    public let restingHeartRate: Int

    /// Heart-rate variability in milliseconds, in the quantity `hrvMetric` names.
    public let hrvValueMs: Double

    /// Which quantity `hrvValueMs` is. Never mixed across a baseline.
    public let hrvMetric: HRVMetric

    /// Skin temperature. `nil` is *the strap did not report one*, which is not `0`.
    public let skinTemp: Double?

    /// Blood-oxygen saturation, 0–100. `nil` when unmeasured.
    public let spo2: Double?

    /// Respiratory rate in breaths per minute. `nil` when unmeasured.
    public let respiratoryRate: Double?

    /// Provenance — which producer wrote the row (`whoop_export`, `zero_fasting`, `fast`), or `nil`
    /// for a row this app measured itself.
    ///
    /// **This is the field the whole type exists to preserve.** It is a column, it is on the wire, and
    /// it is absent from `RecoveryMetric` — so it is exactly the value a sync built on the entity would
    /// lose without a compile error, a log line or a test failure, because everything else would still
    /// round-trip perfectly.
    public let source: String?

    public init(
        date: Date,
        recoveryScore: Int,
        restingHeartRate: Int,
        hrvValueMs: Double,
        hrvMetric: HRVMetric = .rmssd,
        skinTemp: Double? = nil,
        spo2: Double? = nil,
        respiratoryRate: Double? = nil,
        source: String? = nil
    ) {
        self.date = date
        self.recoveryScore = recoveryScore
        self.restingHeartRate = restingHeartRate
        self.hrvValueMs = hrvValueMs
        self.hrvMetric = hrvMetric
        self.skinTemp = skinTemp
        self.spo2 = spo2
        self.respiratoryRate = respiratoryRate
        self.source = source
    }

    /// The entity a screen would draw, rebuilt from the stored fields.
    ///
    /// **Two things are deliberately lost and neither is a defect.** The `UUID` is fresh, because it
    /// is not a column and never was — the same is true of a metric built from a local record, which
    /// is why two reads of one unchanged row have never compared equal on this type. And the three
    /// baseline deltas come back `nil`, because they are computed on read against a window rather than
    /// stored; a caller that needs them asks the scoring path, not this row.
    ///
    /// `source` is dropped here for the same reason it is carried everywhere else: the entity has no
    /// field for it. Anything that needs to know where a row came from holds the row, not the metric —
    /// which is the rule this whole type exists to state.
    public var metric: RecoveryMetric {
        RecoveryMetric(
            date: date,
            score: recoveryScore,
            hrvValueMs: hrvValueMs,
            hrvMetric: hrvMetric,
            restingHeartRate: restingHeartRate,
            skinTemperatureCelsius: skinTemp,
            spO2Percentage: spo2,
            respiratoryRate: respiratoryRate
        )
    }

    /// The row a metric would be stored as, with its provenance supplied by the caller.
    ///
    /// The `source` is a parameter rather than read off `metric`, because the entity does not carry
    /// one — and it is not defaulted to `nil`, because `nil` is a meaningful value on this column
    /// (*this app measured it*) rather than an absence of an answer. A writer that has to say which
    /// producer it is will say it; one that forgets gets a compile error instead of an imported row
    /// relabelled as app-recorded.
    public init(_ metric: RecoveryMetric, source: String?) {
        self.init(
            date: metric.date,
            recoveryScore: metric.score,
            restingHeartRate: metric.restingHeartRate,
            hrvValueMs: metric.hrvValueMs,
            hrvMetric: metric.hrvMetric,
            skinTemp: metric.skinTemperatureCelsius,
            spo2: metric.spO2Percentage,
            respiratoryRate: metric.respiratoryRate,
            source: source
        )
    }
}

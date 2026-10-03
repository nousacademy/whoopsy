import Foundation

/// A fast the user has started and not yet ended.
///
/// **A live fast is one instant, and that is the whole of it.** The three measured fields on
/// `WorkoutSession` are optional and a fast fills none of them — no strain, no heart rate, no zones, no
/// steps — because a fasting window is time held rather than work done. So there is nothing to
/// accumulate, no stream to consume, no route to trace and no lock-screen card to push, and this type
/// is what is left once all of that is removed.
///
/// That is what lets a fast run *underneath* an activity. `LiveSessionUseCase` holds one of these
/// beside the activity's own session state, so starting a run mid-fast neither ends the fast nor
/// disturbs it, and ending the run hands the recording bar back to a fast still counting from its real
/// start.
///
/// **It is persisted, and no other live session is.** A fast's whole point can be days long, so a fast
/// that died with the process would be lost to a phone restart — the commonest thing that happens to a
/// phone in three days. A run cannot be restored this way, because its accumulator's samples are gone
/// and inventing them is the fabrication every absence rule here forbids; but a fast measures nothing,
/// so a single stored instant restores it exactly.
/// **`Hashable`, and for `WorkoutSession`'s own reason**: Home pushes the running fast's page with a
/// `navigationDestination(item:)` binding, and an `item:` binding requires its subject to be
/// `Hashable`. A fast has one field, so this is an instant's own equality and nothing is being
/// approximated to get it.
public struct ActiveFast: Hashable, Sendable {

    /// When the fast began. The only state there is.
    public let startedAt: Date

    public init(startedAt: Date) { self.startedAt = startedAt }

    /// How long the fast has been going as of `now`.
    ///
    /// Clamped at zero on `WorkoutSession.elapsedSeconds(byEndOf:)`'s reasoning: a `now` before the
    /// start is a clock disagreement rather than a negative fast. Every reader of this feeds
    /// `FastingZone.zone(forDurationSeconds:)`, which clamps anyway, so the floor here is for the
    /// readers that are not the zone.
    public func elapsedSeconds(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// The zone the fast is in as of `now`.
    ///
    /// **Over the whole elapsed span, which is deliberately the other reading from the one a stored
    /// fast's pill draws.** `ActivityFigure.fastingZone(for:on:)` answers *what had this fast reached by
    /// the end of that day*, because a Home row is about a day. The recording bar is about now, so its
    /// zone is the fast's real elapsed total. The two agree on the day a fast is running and diverge on
    /// every day it merely passes through — they answer different questions and must not be reconciled.
    public func zone(at now: Date) -> FastingZone {
        FastingZone.zone(forDurationSeconds: elapsedSeconds(at: now))
    }

    /// The row this fast will become, as it stands at `now`.
    ///
    /// **One definition for two readers.** The live fast's page is the ordinary `ActivityDetailView`
    /// fasting layout, which takes a `WorkoutSession` as a plain `let` on its view model — so a live
    /// fast has to be able to present itself as one. `LiveSessionUseCase.endFast()` writes exactly what
    /// this returns, with `now` fixed at the moment END was pressed, which is what makes the page the
    /// user was looking at and the row they end with one construction rather than two that agree today.
    ///
    /// The empty route and split lists are not placeholders: a fast has no route because nothing
    /// tracked it, and no laps because there is no lap model anywhere in this app.
    ///
    /// **`source` is a fast label and not `nil`, and that is load-bearing rather than tidy.**
    /// `WhoopExportImporter.recordedWorkoutDays()` excludes fast rows so the export's own day skip does
    /// not mistake a fast for a workout already imported. A hand-ended fast written with `nil` would
    /// make its start day read as recorded and silently drop the export's rows for that day — the same
    /// bug from the other side.
    public func projectedSession(now: Date) -> WorkoutSession {
        WorkoutSession(
            startedAt: startedAt,
            endedAt: now,
            strain: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            route: [],
            splits: [],
            source: Self.sourceLabel,
            activityName: WhoopActivityCatalog.fastingName,
            hrZonePercents: nil,
            steps: nil)
    }

    /// The `source` a fast this app recorded itself carries.
    ///
    /// Distinct from `ZeroFastingImporter.sourceLabel` rather than reusing it, because that column
    /// answers *which producer* and a hand-recorded fast is not an import. What the two share is that
    /// they are both fasts, and that is what `fastSourceValues` states — one rule for "this row is a
    /// fast", whichever button made it, so the export's day skip cannot come to know about one producer
    /// and not the other.
    public static let sourceLabel = "fast"

    /// Every `source` value that means "this row is a fast", whichever producer wrote it.
    ///
    /// **The one place that set is written down.** `WhoopExportImporter.recordedWorkoutDays()` filters
    /// against this, and a second literal there would be a second chance to miss a producer. It sits in
    /// `Domain` because both halves need it and neither may own the other: the importer is `Data` and
    /// this type is the thing being described.
    ///
    /// `ZeroFastingImporter.sourceLabel`'s value is a member, and §20 asserts that membership rather
    /// than letting the two literals drift apart silently.
    public static let fastSourceValues: Set<String> = [sourceLabel, "zero_fasting"]
}

import Foundation
import Whoopsy

/// The edit sheet's draft, for the two fields it gained and the one it used to drop.
enum ActivityEditDraftRPETests {
    static func run() async throws {
        let start = StrainTests.day.addingTimeInterval(9 * 3600)
        let region = OfflineMapCenter(latitude: 51.5074, longitude: -0.1278)
        let session = WorkoutSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            strain: 4.2,
            averageHeartRate: 121,
            maxHeartRate: 158,
            route: [],
            splits: [],
            source: WhoopExportImporter.sourceLabel,
            activityName: "Basketball",
            hrZonePercents: [40, 30, 15, 10, 5],
            steps: 1_234,
            offlineRegionID: "region-1",
            offlineRegionCenter: region)

        // ---- An untouched draft is not a change ----
        let untouched = ActivityEditDraft(session)
        assertTest(
            !untouched.hasChanges,
            "A draft nobody touched reports no change, so SAVE stays disabled")
        assertTest(
            untouched.rpe == nil,
            "An unrated session opens with no rating rather than a defaulted one")

        // ---- A rating alone is a change ----
        var rated = ActivityEditDraft(session)
        rated.setRpe(6)
        assertTest(
            rated.hasChanges && rated.rpe == 6,
            "Rating an unrated session is a change worth saving")

        // ---- …and the write carries everything the draft did not edit ----
        let written = rated.applying(to: session)
        assertTest(written.rpe == 6, "The rating reaches the session the sheet writes")
        assertTest(
            written.offlineRegionID == "region-1" && written.offlineRegionCenter == region,
            "…and the offline-map region survives an edit that did not touch it — the field this "
                + "initialiser used to drop, which wiped a downloaded region on every save")
        assertTest(
            written.strain == 4.2 && written.steps == 1_234
                && written.hrZonePercents == [40, 30, 15, 10, 5]
                && written.activityName == "Basketball",
            "…and so do the measurements and the name")

        // ---- Writing the value already held is a no-op ----
        var unchanged = ActivityEditDraft(session)
        unchanged.setRpe(nil)
        assertTest(
            !unchanged.hasChanges,
            "Writing `nil` to an unrated session adds nothing to save")

        let alreadyRated = WorkoutSession(
            id: session.id, startedAt: session.startedAt, endedAt: session.endedAt,
            strain: session.strain, averageHeartRate: session.averageHeartRate,
            maxHeartRate: session.maxHeartRate, route: [], splits: [], rpe: 6)
        var rerated = ActivityEditDraft(alreadyRated)
        rerated.setRpe(6)
        assertTest(
            !rerated.hasChanges,
            "…and writing the rating already held is likewise not a change")

        // ---- The clamp ----
        var clamped = ActivityEditDraft(session)
        clamped.setRpe(42)
        assertTest(
            clamped.rpe == 10,
            "A value above the scale is clamped on the write, got "
                + "\(clamped.rpe.map(String.init) ?? "nil")")
    }
}

import Foundation
import Whoopsy

/// The sleep page's editor: the draft's two rules, and the write that carries everything else through.
///
/// The sheet itself has no renderer, so what is asserted is exactly what can be wrong without one —
/// which night the draft describes, when `SAVE` is enabled, and whether the row that comes back out of
/// storage still knows it was WHOOP's own.
enum SleepTimeEditTests {
    static func run() async throws {
        // ── 1. The draft ────────────────────────────────────────────────────────────────────────────
        let day = Calendar.current.startOfDay(for: Date())
        let night = SleepSession(
            date: day,
            startTime: day.addingTimeInterval(23 * 3600 - 24 * 3600),   // 23:00 the evening before
            endTime: day.addingTimeInterval(7 * 3600),
            lightSleepSeconds: 14_000,
            deepSleepSeconds: 3_000,
            remSleepSeconds: 4_000,
            awakeSeconds: 1_200,
            scoredThrough: day.addingTimeInterval(7 * 3600))

        var draft = SleepTimeEditDraft(session: night)
        assertTest(
            draft.id == night.date,
            "The draft is keyed on the night's day, so a second night cannot reuse the first one's edit")
        assertTest(
            !draft.hasChanges && !draft.canSave,
            "An untouched draft has nothing to save, which is what holds the button at half opacity on "
                + "a sheet nobody moved")

        draft.start = draft.start.addingTimeInterval(-1800)
        assertTest(
            draft.hasChanges && draft.isValid && draft.canSave,
            "Moving a bound makes the draft a change, and a night that still ends after it starts is "
                + "saveable")

        var backwards = SleepTimeEditDraft(session: night)
        backwards.end = backwards.start.addingTimeInterval(-60)
        assertTest(
            !backwards.isValid && !backwards.canSave,
            "A night that ends before it starts is not a night — SAVE stays disabled rather than "
                + "writing a negative span the chart would divide by")

        var equal = SleepTimeEditDraft(session: night)
        equal.end = equal.start
        assertTest(
            !equal.isValid,
            "…and a zero-length night is refused for the same reason: `end > start` is the rule, not "
                + "`end >= start`")

        var tooLong = SleepTimeEditDraft(session: night)
        tooLong.end = tooLong.start.addingTimeInterval(SleepTimeEditDraft.maximumSpanSeconds + 60)
        assertTest(
            !tooLong.isValid,
            "…and a span over \\(Int(SleepTimeEditDraft.maximumSpanSeconds / 3600)) hours is refused: "
                + "the row is keyed by its day, and a night longer than a day would describe two")

        // ── 2. The copy carries everything but the times ───────────────────────────────────────────
        let edited = night.withEditedTimes(
            start: night.startTime.addingTimeInterval(1800),
            end: night.endTime.addingTimeInterval(1800),
            now: day.addingTimeInterval(9 * 3600))
        assertTest(
            edited.startTime == night.startTime.addingTimeInterval(1800)
                && edited.endTime == night.endTime.addingTimeInterval(1800),
            "The two bounds move by what the draft says")
        assertTest(
            edited.lightSleepSeconds == night.lightSleepSeconds
                && edited.deepSleepSeconds == night.deepSleepSeconds
                && edited.remSleepSeconds == night.remSleepSeconds
                && edited.awakeSeconds == night.awakeSeconds
                && edited.targetSleepNeedSeconds == night.targetSleepNeedSeconds
                && edited.date == night.date,
            "…and every stage total, the need and the day key are carried through: an edit is a "
                + "correction to *when*, not a claim about how the night went")
        assertTest(
            edited.scoredThrough == day.addingTimeInterval(9 * 3600),
            "…and the watermark moves to the edit instant, which is what stops the next "
                + "re-classification from redrawing the times the user just set "
                + "(got the edit instant)")

        // ── 3. The write ───────────────────────────────────────────────────────────────────────────
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let sleeps = GRDBSleepRepository(db: db)
            let profile = GRDBUserProfileRepository(db: db)
            let noSamples = OvernightBiometricStore(samples: [])
            let importedNight = SleepSession(
                date: day,
                startTime: day.addingTimeInterval(-3600),
                endTime: day.addingTimeInterval(7 * 3600),
                lightSleepSeconds: 14_000,
                deepSleepSeconds: 3_000,
                remSleepSeconds: 4_000,
                awakeSeconds: 1_200,
                hasWhoopSleepNeed: true,
                algorithm: .current,
                scoredThrough: day.addingTimeInterval(7 * 3600))
            try await sleeps.saveSleepSession(importedNight, source: WhoopExportImporter.sourceLabel)

            let page = await MainActor.run {
                SleepViewModel(
                    analyze: AnalyzeSleepUseCase(
                        biometricRepository: noSamples,
                        sleepRepository: sleeps,
                        strainRepository: GRDBStrainRepository(db: db),
                        userProfileRepository: profile,
                        motionRepository: FixtureMotionEpochRepository()),
                    repository: sleeps,
                    napRepository: GRDBNapRepository(db: db),
                    biometricRepository: noSamples,
                    analyzeSleepStress: AnalyzeSleepStressUseCase(biometricRepository: noSamples),
                    userProfileRepository: profile)
            }
            await page.load(for: day)

            let movedEnd = day.addingTimeInterval(8 * 3600)
            let saved = await page.saveTimes(
                start: day.addingTimeInterval(-1800), end: movedEnd)
            assertTest(saved, "A valid edit writes")

            let stored = try await sleeps.getSleepSession(for: day)
            assertTest(
                stored?.startTime == day.addingTimeInterval(-1800) && stored?.endTime == movedEnd,
                "…and the row read back holds the two bounds the editor set")
            assertTest(
                stored?.hasWhoopSleepNeed == true,
                "…still recognisable as WHOOP's own night — the save hands the column its own source "
                    + "back, because `hasWhoopSleepNeed` is read off exactly that string and a night "
                    + "saved without it would be re-classified as one this app typed in")
            assertTest(
                stored?.lightSleepSeconds == 14_000 && stored?.deepSleepSeconds == 3_000,
                "…with its stage totals untouched")

            let beforeInvalid = try await sleeps.getSleepSession(for: day)
            let refused = await page.saveTimes(
                start: movedEnd, end: day.addingTimeInterval(-1800))
            assertTest(
                refused == false,
                "An edit that ends before it starts is refused by the view model too, not only by the "
                    + "disabled button")
            let afterInvalid = try await sleeps.getSleepSession(for: day)
            // Field by field and not `==`: `SleepSession`'s equality cannot compare two reads of the
            // same night — each read mints a fresh `id` — which is its own recorded gotcha.
            assertTest(
                afterInvalid?.startTime == beforeInvalid?.startTime
                    && afterInvalid?.endTime == beforeInvalid?.endTime
                    && afterInvalid?.scoredThrough == beforeInvalid?.scoredThrough,
                "…and nothing was written: a refused save leaves the row exactly as it was")

            // The menu the page opens, which is `ActivityOverflowMenu`'s value and not a drawing of
            // its own — the same type the activity page's `•••` reads.
            let groups = ActivityOverflowMenu.nightGroups
            assertTest(
                groups.count == 2 && groups[0].map(\.title) == ["Edit"] && groups[1].map(\.title) == ["Cancel"],
                "The sleep page's menu is one acting row and the way out, split into two cards so "
                    + "`Cancel` sits apart exactly as it does on the activity page")
            assertTest(
                ActivityOverflowMenu.nightGroups.flatMap { $0 }.allSatisfy { !$0.isDestructive },
                "…and holds no destructive row: a night has no delete, because removing one would "
                    + "orphan the day its Recovery, ring and watermark are keyed to")

            // The page re-reads the night it wrote, which is what it hands Home.
            let reloaded = await page.session
            assertTest(
                reloaded?.endTime == movedEnd,
                "The page's own night is the saved row, not the draft — which is what `onTimesEdited` "
                    + "carries back to Home's SLEEP row")
        }
    }
}

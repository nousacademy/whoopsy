import Foundation
import Whoopsy

// MARK: - 20. The parser, over the real file, with no database behind it

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.
enum ZeroFastingParserTests {
    static func run() async throws {
        // MARK: - A. The parser, over the real file, with no database behind it

        let fastsURL = zeroFastingURL()
        let rows = (try? ZeroFastingParser.parseFasts(at: fastsURL)) ?? []
        assertTest(
            rows.count == 170,
            "The bundled `fasts.json` parses to its 170 finished fasts — a subset of the producer's own "
                + "`biodata.json`, so a re-generation that trimmed either end of the history would fail "
                + "here rather than importing a shorter one and reporting success (got \(rows.count))")

        // **This is the resource half of a two-name split, and the other half is in §18.** What ships is
        // `fasts.json` — `biodata.json`'s `fast_data` array projected down to the one key the importer reads
        // — while the name the button prints is `FastingImportAction.fileName`, `"biodata.json"`, because
        // that is the file Zero gives a user on export and so the name a reader recognises. The user's
        // correction separates them exactly: *"so my modified version was fasts.json, in UI refer to it as
        // "biodata.json" as thats what zero gives when exporting"*. So what has to stay true here is the name
        // of the **resource**: repointing the importer at `biodata.json` would bundle a real person's whole
        // record — the `ZeroFasting/` directory is gitignored for exactly that reason — and `parseFasts` would
        // refuse it anyway, throwing `.missingFastData` for anything that is not `{"fast_data": […]}`.
        // Asserted as a name and not through `bundledFastsURL()`, which would reach for `Bundle.module` and
        // trap in this runner; the file the name resolves to is the one read above.
        assertTest(
            ZeroFastingImporter.bundledResourceName == "fasts",
            "The Zero fasting import reads the bundled projection — `fasts.json` — and not the producer's "
                + "`biodata.json`. The two hold the same fasts and only one of them is this app's to ship, so "
                + "the name is the half of the decision a runner can see: the other half is that `biodata.json` "
                + "is neither declared in `Package.swift` nor readable through the bundle. **This is the "
                + "resource and not the caption** — the button prints the producer's name deliberately, and "
                + "§18 pins that separately, so the two cannot be tidied into one")

        // The id is the row's storage key and the reason this is asserted before anything is written:
        // `GRDBWorkoutRepository.makeSessions` **skips** any row whose id is not a UUID, so an id that
        // will not parse writes a row that no reader in this app can ever fetch — stored and invisible,
        // which is the worse of the two failure modes and the one a row count alone cannot see.
        assertTest(
            rows.allSatisfy { UUID(uuidString: $0.fastID) != nil },
            "Every one of the file's `FastID`s is a UUID, which is what `WorkoutSession.id` takes and "
                + "what `makeSessions` requires — a non-UUID id is a row this app stores and can never read "
                + "back")
        assertTest(
            Set(rows.map(\.fastID)).count == rows.count,
            "…and all 170 are distinct, so the primary key is one row per fast rather than a collision "
                + "that would make the import write \(rows.count - Set(rows.map(\.fastID)).count) fewer "
                + "rows than it reports")

        assertTest(
            rows.allSatisfy { $0.endedAt > $0.startedAt },
            "Every fast ends after it starts — the one structural fact a duration headline on Home's "
                + "`ACTIVITIES` card rests on, and the assertion that fails if the two instants are ever "
                + "read from the wrong keys")
        let durations = rows.map { $0.endedAt.timeIntervalSince($0.startedAt) }
        assertTest(
            durations.min() ?? 0 > 3600,
            "…and the shortest is over an hour (measured \(String(format: "%.1f", (durations.min() ?? 0) / 3600)) "
                + "h, longest \(String(format: "%.1f", (durations.max() ?? 0) / 3600)) h), which is what "
                + "keeps a stray non-fast row — a goal reminder, a Zero onboarding record — out of the "
                + "import even if the producer adds one to `fast_data`")

        // The two ends of the history, pinned as epochs rather than through a `DateFormatter`, so the
        // literals are independent of the parser's own instant grammar: a test that built its expected
        // value with the same format string the parser uses would move with it.
        assertTest(
            rows.map(\.startedAt).min() == Date(timeIntervalSince1970: 1_645_928_140),
            "The earliest start is `2022-02-27T02:15:40Z`, pinned as an epoch — a re-generated file that "
                + "lost the oldest fasts, or one whose instants were read in a different zone, fails here "
                + "rather than silently importing a history that begins later")
        assertTest(
            rows.map(\.endedAt).max() == Date(timeIntervalSince1970: 1_781_377_210),
            "…and the latest end is `2026-06-13T19:00:10Z`, pinned the same way, so the file's other end "
                + "cannot move either")

        // The parser's refusal, which is the half a row count cannot see. A `guard … else { continue }`
        // here would return a *shorter array* — or an empty one — and every assertion above would fail
        // with a row count rather than with the reason.
        func errorThrown(by text: String) -> ZeroFastingError? {
            do {
                _ = try ZeroFastingParser.parseFasts(text)
                return nil
            } catch let error as ZeroFastingError {
                return error
            } catch {
                return nil
            }
        }

        /// Whether one `StartDTM` value is refused as an unparseable instant, with everything else in the
        /// document well-formed so the refusal cannot be about another field.
        func refusesInstant(_ raw: String) -> Bool {
            let document = #"{"fast_data":[{"FastID":"8B1A4A64-1C3E-4E1F-9E2E-2B5C9A7D0E11","StartDTM":"\#(raw)","EndDTM":"2022-02-27T06:00:00Z"}]}"#
            guard let error = errorThrown(by: document) else { return false }
            if case .unparseableDate = error { return true }
            return false
        }

        assertTest(
            refusesInstant("2022-02-27 02:15:40"),
            "A space-separated instant is **refused**, not skipped: the export writes a literal `T` and a "
                + "literal `Z`, and the CSV files' `2026-08-22 00:17:13` shape — which is what "
                + "`ISO8601DateFormatter` silently returns `nil` for — must throw with the record's id on "
                + "it rather than drop the row")
        assertTest(
            refusesInstant("2022-02-27T02:15:40.000Z"),
            "…and so is a fractional-second instant, which is the other shape a JSON producer drifts to "
                + "and the one a `dateDecodingStrategy` would have accepted without anyone noticing the "
                + "grammar had widened")
        assertTest(
            refusesInstant(""),
            "…and an absent instant, which is the case that matters most: `\"\"` is what a missing key "
                + "reads as, and a parser that let it through would place a fast at the reference date")

        func isMissingFastData(_ text: String) -> Bool {
            guard let error = errorThrown(by: text) else { return false }
            if case .missingFastData = error { return true }
            return false
        }
        assertTest(
            isMissingFastData("{}"),
            "`{}` throws `.missingFastData` rather than returning zero rows — the analogue of the CSV "
                + "parser's `missingColumns`, and the check that makes pointing this importer at "
                + "`biodata.json`'s eighteen *other* keys, or at `firestore.json`, fail loudly instead of "
                + "reporting a successful import of nothing")
        assertTest(
            isMissingFastData(#"{"fast_data": {}}"#),
            "…and so does a `fast_data` that is present but not an array of records, which is the shape a "
                + "producer changing the key's type would produce")
        assertTest(
            errorThrown(by: "not json at all") != nil,
            "…while a document that is not JSON at all throws rather than answering with an empty array")
    }
}

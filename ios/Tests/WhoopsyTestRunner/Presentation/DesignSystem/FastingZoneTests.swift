import Foundation
import Whoopsy

// MARK: - 20. The fasting zone a fast's row draws instead

/// A file of §20's body, cut at the section's own `// MARK: - ` topic boundary and moved
/// verbatim. `ZeroFastingImportTests.run()` calls it, in the order the section ran it in.
enum FastingZoneTests {
    static func run() async throws {
        // MARK: - C2. The fasting zone a fast's row draws instead

        // Re-derived rather than read off the blocks above — §16's `walking` precedent. The
        // bundled file is immutable and the parser is pure, so these are the same values the
        // parser block asserted, over the same 170 rows.
        let rows = (try? ZeroFastingParser.parseFasts(at: zeroFastingURL())) ?? []
        let durations = rows.map { $0.endedAt.timeIntervalSince($0.startedAt) }
        let anchor = ZeroFastingImportTests.anchor
        let fast = ZeroFastingImportTests.session("Fast", strain: nil, durationSeconds: 16 * 3600 + 40 * 60)

        // The boundaries, both sides of every edge. **Zero publishes its zones as ranges that overlap on
        // their upper edge** — `0–4` and `4–16` both claim 4 h — so `<` against `<=` is a decision rather
        // than an implementation detail, and the convention taken is that the upper edge belongs to the
        // *next* zone. Every point below is a place a wrong comparison shows up, and the sweep accumulates
        // its mismatches so one run names all of them instead of halting at the first.
        let zoneEdges: [(seconds: TimeInterval, expected: FastingZone, label: String)] = [
            (0, .anabolic, "0s"),
            (4 * 3600 - 1, .anabolic, "3h59m59s — the last second before the first edge"),
            (4 * 3600, .catabolic, "4h exactly — the shared edge, which must open Catabolic"),
            (16 * 3600 - 1, .catabolic, "15h59m59s"),
            (16 * 3600, .fatBurning, "16h exactly — the shared edge, which must open Fat Burning"),
            (24 * 3600 - 1, .fatBurning, "23h59m59s"),
            (24 * 3600, .ketosis, "24h exactly — the shared edge, which must open Ketosis"),
            (72 * 3600 - 1, .ketosis, "71h59m59s — the longest fast that is not yet Deep"),
            (72 * 3600, .deepKetosis, "72h exactly — the floor of the open-ended zone"),
        ]
        let wrongZones = zoneEdges
            .filter { FastingZone.zone(forDurationSeconds: $0.seconds) != $0.expected }
            .map { "\($0.label) gave \(FastingZone.zone(forDurationSeconds: $0.seconds).rawValue), expected \($0.expected.rawValue)" }
        assertTest(
            wrongZones.isEmpty,
            "Every zone boundary falls where the published ranges say, with the upper edge of each range "
                + "opening the next zone — which is what puts a fast of exactly 16 h in `fatBurning` rather "
                + "than in `catabolic`, and it is a real row of the bundled file rather than a hypothetical "
                + "(mismatches: \(wrongZones.joined(separator: "; ")))")

        assertTest(
            FastingZone.allCases.count == 5,
            "There are five zones and no more, so a sixth case cannot be added without this failing and "
                + "the colour mapping, the label table and the ink rule all being revisited (got "
                + "\(FastingZone.allCases.count))")
        let expectedZoneLabels = [
            "ANABOLIC", "CATABOLIC", "FAT BURNING", "KETOSIS", "DEEP KETOSIS",
        ]
        assertTest(
            FastingZone.allCases.map(\.label) == expectedZoneLabels,
            "The five labels the pills draw are stated literals rather than the raw value uppercased, so a "
                + "case rename cannot silently change what a row reads (got "
                + "\(FastingZone.allCases.map(\.label)))")
        assertTest(
            FastingZone.allCases.map(\.hoursRange) == ["0-4H", "4-16H", "16-24H", "24-72H", "72H+"],
            "…and each carries the published range it covers, with the last one's `+` stating that 72 h is "
                + "a floor rather than an interval (got \(FastingZone.allCases.map(\.hoursRange)))")

        // The gate. These four are the whole of the rule, and the second is the one that matters: it is
        // `headlineText`'s documented "the gate is the data and never the label" holding *through* a
        // function that does consult the label, which is the reading most likely to look like a
        // regression.
        //
        // **The day handed in is the one the fast ended on, and for the two assertions that pin a zone
        // that is not a detail.** This fixture sits at anchor `1_700_000_000` — 18:13 local — with a
        // 16 h 40 m span, so it crosses midnight. Its *start* day clamps to 5 h 47 m and answers
        // `.catabolic`, and would answer `.anabolic` at UTC where the anchor is 22:13: the same literal
        // failing differently in different device zones. Handed the end day, `elapsedSeconds(byEndOf:)`
        // is `endedAt − startedAt` on **every** device, because `endedAt` is always inside its own day —
        // so the two `.fatBurning` literals survive byte-identically and these go on testing the gates
        // they were written to test rather than the arithmetic. It is also the honest reading of the
        // rule: a fast's last day *is* its own zone.
        assertTest(
            ActivityFigure.fastingZone(for: fast, on: fast.endedAt) == .fatBurning,
            "A `Fast` carrying no strain gets the pill — 16h40m is in Fat Burning, the zone the block's own "
                + "`fast` fixture sits in (got "
                + "\(String(describing: ActivityFigure.fastingZone(for: fast, on: fast.endedAt))))")
        assertTest(
            ActivityFigure.fastingZone(for: ZeroFastingImportTests.session("Fast", strain: 7.4), on: anchor.addingTimeInterval(3600)) == nil,
            "**The gate is the data and never the label, and it survives this function.** A session *named* "
                + "`Fast` that carries a strain gets **no** pill, so `headlineText` still prints `7.4` "
                + "beside it exactly as before — the pill occupies the slot the *duration* would have "
                + "occupied, never the slot the strain has (got "
                + "\(String(describing: ActivityFigure.fastingZone(for: ZeroFastingImportTests.session("Fast", strain: 7.4), on: anchor.addingTimeInterval(3600)))))")
        assertTest(
            ActivityFigure.fastingZone(for: ZeroFastingImportTests.session("Walking", strain: nil), on: anchor.addingTimeInterval(3600)) == nil,
            "…and an unmeasured session that is not a fast is untouched, printing its duration as it always "
                + "has. Its source is `zero_fasting`, the block's helper stamping every fixture — which is "
                + "the point: the gate is the *name* and not the source, so a fast the user re-labelled, and "
                + "a non-fast the importer wrote, both read correctly (got "
                + "\(String(describing: ActivityFigure.fastingZone(for: ZeroFastingImportTests.session("Walking", strain: nil), on: anchor.addingTimeInterval(3600)))))")
        // Deliberately the *same* duration `fast` carries, so the only thing differing from the assertion
        // above it is the padding and the casing — which is what makes this a test of the normalisation
        // rather than of the zone arithmetic a second time.
        let paddedFast = ZeroFastingImportTests.session("  FAST  ", strain: nil, durationSeconds: 16 * 3600 + 40 * 60)
        assertTest(
            ActivityFigure.fastingZone(for: paddedFast, on: paddedFast.endedAt) == .fatBurning,
            "…while a padded and differently-cased name still reaches it, because the comparison goes "
                + "through `ActivityName.normalised` — the same normaliser `ActivityGlyph.mark(for:)` "
                + "resolves through, so the row's chip and its pill can never disagree about which rows are "
                + "fasts (got "
                + "\(String(describing: ActivityFigure.fastingZone(for: paddedFast, on: paddedFast.endedAt))))")

        // The ink decision. Asserted as `inkDepth` rather than as a `Color`, because comparing `inkColor`
        // against the `Theme` token it returns would only prove the switch returns the arm it returns —
        // the "expected value computed by the code under test" trap. The depth is the decision the user
        // made and the one thing a screenshot of a single zone cannot see: white letters on the yellow and
        // the white fill would measure 1.5:1 and 1.0:1.
        let expectedInkDepths: [(FastingZone, FastingZone.InkDepth)] = [
            (.anabolic, .onDeep), (.catabolic, .onDeep), (.fatBurning, .onPale),
            (.ketosis, .onPale), (.deepKetosis, .onDeep),
        ]
        let wrongInks = expectedInkDepths
            .filter { $0.0.inkDepth != $0.1 }
            .map { "\($0.0.rawValue) is \($0.0.inkDepth)" }
        assertTest(
            wrongInks.isEmpty,
            "The two pale fills take the near-black ink and the other three take white, which is the whole "
                + "of the legibility rule — a white `KETOSIS` pill would be white letters on white and a "
                + "white `FAT BURNING` pill would measure 1.5:1 (wrong: \(wrongInks.joined(separator: ", ")))")

        // The property over the real file, in this section's shape for a claim about `fasts.json`: a
        // regenerated file that added a short fast would otherwise introduce a pill nobody has ever seen.
        let zoneCounts = rows.reduce(into: [FastingZone: Int]()) { counts, row in
            counts[FastingZone.zone(forDurationSeconds: row.endedAt.timeIntervalSince(row.startedAt)), default: 0] += 1
        }
        assertTest(
            zoneCounts[.anabolic] == nil,
            "**No fast in the bundled file is Anabolic *as a whole session*, and this is where that is "
                + "recorded.** The shortest of the 170 is \(String(format: "%.2f", (durations.min() ?? 0) / 3600)) h, "
                + "so no fast in it is under 4 h — the zone ships because it is Zero's own scale and a "
                + "hand-recorded 3-hour fast lands there, and this assertion is what fails loudly the day a "
                + "short fast appears rather than the pill drawing untested (got "
                + "\(String(describing: zoneCounts[.anabolic])))")
        assertTest(
            zoneCounts == [.catabolic: 89, .fatBurning: 76, .ketosis: 4, .deepKetosis: 1],
            "…and the file's 170 fasts fall 89 / 76 / 4 / 1 across the four zones it does reach, which is "
                + "the distribution every screenshot of this pill is drawn from (got "
                + "\(zoneCounts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")))")
        assertTest(
            durations.filter { $0 == 16 * 3600 }.count >= 1,
            "…and at least one fast sits **exactly** on a shared edge — measured, one fast at precisely "
                + "16 h — which is what makes the `<` versus `<=` decision above load-bearing on real data "
                + "rather than on a synthetic fixture (got "
                + "\(durations.filter { $0 == 16 * 3600 }.count))")
    }
}

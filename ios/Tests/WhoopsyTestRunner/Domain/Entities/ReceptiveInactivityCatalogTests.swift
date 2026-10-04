import Foundation
import SwiftUI
import Whoopsy

// MARK: - 17. The receptive inactivity vocabulary

/// The names a receptive inactivity may be recorded under, and the mark each one draws.
///
/// **A pure-value block with no database behind it and no CSV read**, sitting above §17's parser so it
/// still asserts if the file read below it throws — the placement §14's `+`-menu block has inside its
/// own section, and for the same reason.
///
/// **What it is evidence for, and what it is not.** It proves the vocabulary and the mapping from a
/// name to a drawing. The runner has no renderer, so nothing here is evidence that a chip draws where
/// it should — and the sweep below cannot see whether a symbol exists on the **iOS 17.0** deployment
/// target, which is a fact about the platform rather than about the string. This is a macOS binary
/// whose own symbol catalogue is the newest OS on the machine, so `figure.ice.skating` and its four
/// iOS 18 siblings all resolve non-empty here and draw nothing on a phone.
///
/// Four claims carry it, and each names a way two lists drift apart silently:
///
/// - **every name resolves a mark, and not the fallback.** `ActivityGlyph.mark(for:)` answers
///   `figure.run` for a name its table does not hold, so a name added to the catalogue without a
///   `marks` entry is not an error and not an empty chip either — it is a running figure beside
///   `Dream`. Comparing against `mark(for: nil)` is the only assertion that sees it.
/// - **the names are distinct under `ActivityName.normalised`**, which is the key both the glyph table
///   and the activity window resolve through.
/// - **the names WHOOP's own list already holds are spelled the way it spells them** — one phenomenon
///   with one spelling, which is otherwise a thing a reader of two pickers discovers for themselves.
/// - **`name(for:)` is a round trip on the catalogue's own names.** This is the block's second reader
///   and the one a producer's vocabulary arrives through, so a lookup that fell through to
///   `.capitalized` would draw every chip correctly while handing the sheet a name no row of its
///   picker matches — the only failure here that a screenshot of the card cannot see.
enum ReceptiveInactivityCatalogTests {
    static func run() async throws {

        // ---- The catalogue is a list, and every name on it draws something ----

        let names = ReceptiveInactivityCatalog.names

        assertTest(
            !names.isEmpty,
            "The receptive inactivity catalogue holds at least one name (\(names.count) held)")

        let blank = names.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        assertTest(
            blank.isEmpty,
            "…and none of them is blank, since the picker draws the string it is handed and a blank "
                + "entry is a row with nothing to read (\(blank))")

        // **The assertion that catches a name added without a mark.** The failure it looks for is not
        // an empty chip — that is the *typo* case §14 catches for the menu rows — but a wrong drawing:
        // `figure.run` under `Dream` is a running figure, which claims the opposite of what the name
        // says. The comparison is against `mark(for: nil)`, the one value the fallback is documented to
        // be, so this moves with that constant instead of restating it.
        let fallback = ActivityGlyph.mark(for: nil)
        let unmapped = names.filter { ActivityGlyph.mark(for: $0) == fallback }
        assertTest(
            unmapped.isEmpty,
            "…and every one of them resolves a mark that is **not** the `figure.run` fallback, which is "
                + "what makes a name added to the catalogue without a `marks` entry fail here rather "
                + "than draw a runner beside a dream (\(unmapped))")

        // The sweep above is satisfied by a catalogue whose every entry resolves the *same* mark, and
        // by a lookup that had been made to return a constant — neither of which draws a usable picker.
        // This is the assertion that separates a table with thirteen entries from one with one.
        let distinctMarks = names.reduce(into: [ActivityGlyph.Drawing]()) { accumulated, name in
            let mark = ActivityGlyph.mark(for: name)
            if !accumulated.contains(mark) { accumulated.append(mark) }
        }
        assertTest(
            distinctMarks.count > 1,
            "…and they do not all resolve to a single mark either, which is the assertion that catches "
                + "a lookup returning a constant — that would satisfy the fallback sweep above and draw "
                + "one glyph for the whole list (\(distinctMarks.count) distinct marks over "
                + "\(names.count) names)")

        // ---- One name, one key ----

        let keys = names.map { ActivityName.normalised($0) }
        assertTest(
            !keys.contains(nil),
            "Every name normalises to a key rather than to `nil`, which is what a blank or "
                + "whitespace-only entry would give (\(keys.map { $0 ?? "nil" }))")

        let keyList = keys.compactMap { $0 }
        assertTest(
            Set(keyList).count == keyList.count,
            "…and no two of them collide once trimmed and lowercased. `ActivityName.normalised` is the "
                + "key the glyph table and the activity window both resolve through, so two entries "
                + "differing only in case would be one row the picker drew twice and the tick on the "
                + "wrong one of them (\(keyList.count) names against \(Set(keyList).count) keys)")

        // ---- One phenomenon, one spelling ----

        // Four of these names are already in `WhoopActivityCatalog.recoveryActivities`, and the
        // catalogue carries each **verbatim** — the comma in `Non-sleep, deep rest` and the capital `G`
        // in `QiGong` included, both being WHOOP's own strings rather than this app's preferences. The
        // claim being guarded is the *name* and not the drawing: `ActivityGlyph` already resolves a
        // meditation recorded either way to one mark, so two spellings here would not produce two
        // chips — they would produce two rows in two pickers that a reader would reasonably take for
        // two different practices.
        //
        // **The intersection is asserted before the spellings are, deliberately.** Comparing the shared
        // names' spellings passes vacuously if the intersection is empty, and it would go on passing
        // after someone deleted all four from one side — so the count is what keeps the agreement
        // assertion below it from describing nothing.
        var receptiveByKey: [String: String] = [:]
        for name in names {
            if let key = ActivityName.normalised(name) { receptiveByKey[key] = name }
        }
        var whoopByKey: [String: String] = [:]
        for name in WhoopActivityCatalog.allNames {
            if let key = ActivityName.normalised(name), whoopByKey[key] == nil { whoopByKey[key] = name }
        }

        let shared = Set(receptiveByKey.keys).intersection(whoopByKey.keys).sorted()
        let expectedShared = ["breathwork", "meditation", "non-sleep, deep rest", "qigong"]
        assertTest(
            shared == expectedShared,
            "Exactly four of the catalogue's names are already in `WhoopActivityCatalog` — "
                + "`Meditation`, `Non-sleep, deep rest`, `QiGong` and `Breathwork`, all four out of its "
                + "`recoveryActivities` — so the two lists meet on this set and on nothing else, which "
                + "is what stops the spelling pair below passing over an empty intersection "
                + "(\(shared))")

        let respelled = shared.filter { receptiveByKey[$0] != whoopByKey[$0] }
        assertTest(
            respelled.isEmpty,
            "…and each of the four is spelled the way WHOOP's own list spells it, the comma and the "
                + "capital `G` included — two spellings of one phenomenon are two picker rows a reader "
                + "would take for two practices ("
                + "\(respelled.map { "\($0): \(receptiveByKey[$0] ?? "nil") vs \(whoopByKey[$0] ?? "nil")" }))")

        // The other direction, and it is the one that keeps the catalogue from becoming a second copy
        // of WHOOP's list: everything here that WHOOP does not carry is genuinely new, and the four
        // above are the whole of the overlap. A name added to this list that WHOOP already holds under
        // a *different* spelling fails the pair above; one added under the *same* spelling fails this
        // count. The two assertions are the whole of the agreement.
        let newNames = keyList.filter { whoopByKey[$0] == nil }
        assertTest(
            newNames.count == keyList.count - expectedShared.count,
            "…and the rest of the catalogue is genuinely its own vocabulary — \(newNames.count) of its "
                + "\(keyList.count) names are ones WHOOP's list does not already carry, which is what "
                + "makes this a catalogue rather than a subset (\(newNames.sorted()))")

        // ---- Every name shared with WHOOP's list resolves the same mark ----

        // The spelling assertion above is about the two *names*; this is about the one drawing behind
        // them, and it is the half a reader actually sees. `ActivityGlyph` resolves through the same
        // normalised key, so a shared name reaching two marks would mean a `marks` entry keyed on a
        // spelling the table does not use — which draws the fallback and is invisible to the sweep at
        // the top of this block, since that sweep only asks whether the mark is *a* mark.
        let respelledMarks = shared.filter {
            ActivityGlyph.mark(for: receptiveByKey[$0]) != ActivityGlyph.mark(for: whoopByKey[$0])
        }
        assertTest(
            respelledMarks.isEmpty,
            "…and a meditation recorded through either picker draws the same chip, which is what "
                + "`ActivityName.normalised` buys and what a `marks` entry keyed on the wrong spelling "
                + "would silently lose (\(respelledMarks))")

        // ---- A producer's vocabulary, resolved onto the catalogue's ----

        // **The bridge between a file's word and a name the picker offers.** A record in `dreams.json`
        // carries `"type": "dream"` and the row it becomes must be named `Dream`, because the sheet's
        // picker ticks the row its own `name` matches — an unlisted spelling would leave thirteen rows
        // drawn with none of them ticked, over a name the app invented, while the chip beside it drew
        // perfectly.
        //
        // **The round-trip sweep is the assertion that carries this block, and it is deliberately not a
        // mark sweep.** `ActivityName.normalised` folds case and surrounding space, so `"Lucid Dream"`
        // and `"Lucid dream"` reach the same glyph; a resolver that fell through to `.capitalized`
        // would draw every chip in this file correctly and still be wrong, because `Lucid Dream` is not
        // a name this catalogue holds. Nothing on the card can see the difference.
        let unresolved = names.filter { ReceptiveInactivityCatalog.name(for: $0.lowercased()) != $0 }
        assertTest(
            unresolved.isEmpty,
            "Every name in the catalogue is handed back **verbatim** when it arrives in a producer's own "
                + "lowercase form — so `\"lucid dream\"` resolves to the `Lucid dream` the picker draws "
                + "rather than to a capitalised string the catalogue does not hold "
                + "(\(unresolved.count) of \(names.count) unresolved: \(unresolved))")

        // The three spellings the resolver's own doc comment names, on the one type the file actually
        // carries. They are one type because `ActivityName.normalised` says so, and that is the same key
        // the glyph table resolves through — which is what keeps the row the import writes and the row
        // the picker writes in one chip and one row.
        let dreamSpellings = ["dream", "Dream", " DREAM "]
            .map { ReceptiveInactivityCatalog.name(for: $0) }
        assertTest(
            dreamSpellings == ["Dream", "Dream", "Dream"],
            "`\"dream\"`, `\"Dream\"` and `\" DREAM \"` are one type and all three resolve to the "
                + "catalogue's own `Dream`, so the import's `type` and the picker's row are one value "
                + "rather than three that agree today (\(dreamSpellings))")
        assertTest(
            names.contains(ReceptiveInactivityCatalog.name(for: "dream")),
            "…and what it resolves to is a name the catalogue actually offers, which is the property the "
                + "sweep above states over the whole list and the picker's tick depends on "
                + "(\(ReceptiveInactivityCatalog.name(for: "dream")) against \(names.count) names)")

        // **An unknown type is answered rather than refused, and the near-miss is what makes the answer
        // informative.** `soundbath` is one space away from a name this catalogue holds, and it comes
        // back capitalised with **no match and no fuzzy lookup** — so a producer's vocabulary gap shows
        // up as a name on the card rather than as a silent merge into `Sound bath`'s own row.
        let nearMiss = ReceptiveInactivityCatalog.name(for: "soundbath")
        assertTest(
            nearMiss == "Soundbath",
            "A type one character away from a catalogue name is capitalised and passed through rather "
                + "than matched, because `\"soundbath\"` is not `Sound bath` — a fuzzy lookup would file "
                + "one practice under another's row and nothing would say so (\(nearMiss))")
        assertTest(
            !names.contains(nearMiss),
            "…and the answer is **not** silently one of the catalogue's names, so a card drawing it is "
                + "drawing a word the picker does not offer — a state a reader can recognise, rather "
                + "than one the resolver has hidden by dressing it as a known entry")

        // ---- The two vocabularies agree about what draws, and part company about what is known ----

        // The pair, and neither half is decorative. A resolved name must draw a **real** mark while an
        // unknown type legitimately draws `figure.run` — so together they state the whole rule: known
        // goes to the table, unknown goes to the fallback, and the app invents no mark for a name it
        // does not hold. Only the first half fails if a name is added to one list and not the other;
        // only the second fails if the fallback is ever replaced by something that reads as an answer.
        assertTest(
            ActivityGlyph.mark(for: ReceptiveInactivityCatalog.name(for: "dream")) != fallback,
            "A resolved name draws a mark of its own and not `figure.run`, which is the catalogue's "
                + "vocabulary and the glyph table's asserted to agree at the one type the file carries "
                + "(\(ActivityGlyph.mark(for: ReceptiveInactivityCatalog.name(for: "dream")).primary))")
        assertTest(
            ActivityGlyph.mark(for: nearMiss) == fallback,
            "…while a type the catalogue does not hold draws the fallback, which is this app's honest "
                + "word for *no mark for this* rather than a second glyph invented for a name nothing "
                + "knows (\(ActivityGlyph.mark(for: nearMiss).primary))")
    }
}

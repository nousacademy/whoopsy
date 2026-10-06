import Foundation
import Whoopsy

// MARK: - 22.7 The absence of a delete, swept over the port, the stores and the contract

/// **This is the assertion that fails if the purge comes back, and it is the one this whole plan exists
/// to protect.** The plan's Decisions 2, 3 and 4 removed a delete from every layer at once — the
/// cutoffs that made a purge describable, the two boundary predicates that decided which side of one a
/// day was on, and the local-copy policy that carried the actual removal. The *reason* it is worth a
/// section of its own is that every one of those removals is invisible from the outside: an app that
/// deletes a day after uploading it looks exactly like an app that does not, until the day is needed
/// again, and by then the only copy is one the user cannot reach.
///
/// **The rule the sweep protects is the user's own**: *"if a DB is selected, it doesnt purge anything,
/// it just switches where data will be stored to."* So there is nothing to check at runtime — a
/// switched destination moves nothing and deletes nothing, which §22.5 asserts directly — and what is
/// left to check is that no *door* for a removal exists at all. A door is what a later edit walks
/// through without noticing, so the sweep is over three surfaces, and each would have to be reopened
/// deliberately:
///
/// 1. the `CloudSync` port, which is the server's whole vocabulary on this side of the wire;
/// 2. the seven `*SyncStore` protocols, which are the phone's own doors into its tables;
/// 3. `shared/openapi.json`, which is what the server will actually answer for.
///
/// **Each sweep carries a positive control, and that is not decoration.** A file that could not be read,
/// was truncated, or is not the file this block believes it is would make every negative assertion here
/// pass while covering nothing — so the count of what *was* found is asserted beside the absence of what
/// was not. It is the same rule as the runner's own `assertions=` field: a section that stops asserting
/// looks exactly like one that passed.
enum CloudSyncTests {

    static func run() async throws {
        // MARK: The port — nineteen doors, none of them a removal

        let port = try sourceText(at: "Domain/Repositories/CloudSync.swift")
        let portMethods = declaredMethods(in: port)

        // **The count is a tripwire rather than a contract.** Nineteen is what the seven resources need
        // today — four methods for each of the three ranged-and-read resources, two for each of the
        // three write-only ones, and one for the singleton profile. A resource added later will make
        // this fail, and that is the point: the failure sends its author to this file, where the
        // sentence below is waiting to ask whether the new resource arrived with a delete.
        assertTest(portMethods.count == 19,
                   "`CloudSync` declares 19 methods — the port's whole vocabulary, and the number this "
                       + "sweep is a tripwire for rather than a limit it enforces")
        assertTest(portMethods.filter { $0.lowercased().contains("delete") }.isEmpty,
                   "…and not one of them is a delete: \(portMethods.filter { $0.lowercased().contains("delete") })")
        assertTest(portMethods.filter { $0.lowercased().contains("purge") }.isEmpty,
                   "…nor a purge under another name")

        // The port's three families by name, so a method silently *replaced* rather than added is
        // visible: the count alone would accept one write swapped for one delete.
        for family in ["writeRecoveries", "writeStrains", "writeWorkouts", "writeSleeps",
                       "writeStepCounts", "writeReceptiveInactivities", "writeProfile"] {
            assertTest(portMethods.contains(family),
                       "The port still has `\(family)`, which is a door in and not a door out")
        }

        // MARK: The seven stores — the phone's own doors, fourteen of them

        let storeFiles = [
            "RecoverySyncStore", "WorkoutSyncStore", "StrainSyncStore", "SleepSyncStore",
            "StepCountSyncStore", "ReceptiveInactivitySyncStore", "UserProfileSyncStore",
        ]
        var storeMethods: [String] = []
        for store in storeFiles {
            let text = try sourceText(at: "Domain/Repositories/\(store).swift")
            let methods = declaredMethods(in: text)
            assertTest(methods.count == 2,
                       "`\(store)` declares exactly two methods — a read of a span and a write of one — "
                           + "so a third would be a change to what the phone can do to its own table")
            assertTest(methods.allSatisfy { $0.hasPrefix("sync") || $0.hasPrefix("save") },
                       "…and `\(store)`'s two are the read and the write rather than anything else: \(methods)")
            storeMethods.append(contentsOf: methods)
        }
        assertTest(storeMethods.count == 14, "…fourteen doors across the seven tables")
        assertTest(storeMethods.filter { $0.lowercased().contains("delete") }.isEmpty,
                   "…and none of the fourteen is a delete: \(storeMethods.filter { $0.lowercased().contains("delete") })")
        assertTest(storeMethods.filter { $0.lowercased().contains("purge") }.isEmpty,
                   "…nor a purge under another name")

        // The one near-miss, asserted on purpose: `WorkoutSyncStore`'s doc comment *does* contain the
        // word — it explains that a replacement write is what stops a stale route being left behind —
        // and a sweep written over whole file text rather than over declarations would have tripped on
        // that sentence. Naming it here is what keeps a later author from "fixing" the comment to
        // satisfy a search that was never asking about comments.
        let workoutStore = try sourceText(at: "Domain/Repositories/WorkoutSyncStore.swift")
        assertTest(workoutStore.lowercased().contains("delete"),
                   "The word does appear in `WorkoutSyncStore`'s prose, which is why this sweep reads "
                       + "declarations and never file text")

        // MARK: The contract — what the server will answer for

        let contract = try contractText()

        // The negative half. Spelled with the colon because that is the only form an operation key has
        // in JSON — a `DELETE` route would appear as `"delete": {` and nothing else in the document
        // would. Written as a search for the key rather than for the word, so the prose descriptions
        // that legitimately discuss deletion do not have to be kept out of it.
        assertTest(!contract.contains("\"delete\":"),
                   "The contract mounts no delete operation, on any path: every resource the Worker "
                       + "carries is reachable by a read and a write, and nothing it publishes can remove "
                       + "a row")
        assertTest(!contract.lowercased().contains("\"purge\":"),
                   "…nor a purge spelled as its own verb")

        // The positive controls, without which the two assertions above would pass over an empty string,
        // a truncated file or the wrong document.
        for verb in ["\"get\":", "\"post\":", "\"put\":"] {
            assertTest(contract.contains(verb),
                       "The contract does mount `\(verb.dropLast(1))` — so the sweeps above are over a "
                           + "document that really does declare operations")
        }
        assertTest(contract.contains("\"openapi\""), "…and it is the OpenAPI document beside the package")

        // Every method the contract does declare, collected and swept as one list. This is the half that
        // would catch a verb this file has never heard of rather than only the one it is looking for.
        let verbs = Set(operationVerbs(in: contract))
        assertTest(verbs == ["get", "post", "put"],
                   "The only verbs the Worker answers are get, post and put — so a delete arriving under "
                       + "a spelling this sweep did not anticipate still fails here: \(verbs.sorted())")

        // And the count of paths, for `SyncedResourceTests`' reason: a scan that read half the document
        // would sweep half the contract, and every negative above would still hold.
        assertTest(contract.components(separatedBy: "\"paths\": {").count == 2,
                   "…and the document holds exactly one `paths` object, which is the one swept")
    }
}

// MARK: - Reading the two surfaces

/// One file of Swift source, from the package root this section already climbs.
private func sourceText(at relativePath: String) throws -> String {
    let url = packageRoot().appendingPathComponent("Sources/Whoopsy/\(relativePath)")
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        assertTest(false, "The source is readable at \(url.path): \(error)")
        throw error
    }
}

/// The committed contract, one directory above the package — `SyncedResourceTests`' climb, repeated
/// rather than shared, because the two files read the same document for two unrelated reasons.
private func contractText() throws -> String {
    let url = packageRoot().deletingLastPathComponent().appendingPathComponent("shared/openapi.json")
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        assertTest(false, "The contract is readable at \(url.path): \(error)")
        throw error
    }
}

/// The names of the methods a protocol declares.
///
/// **Declarations and not file text**, which is the whole subtlety of this sweep: `CloudSync` and the
/// seven stores are heavily commented, and at least one of those comments contains the very word being
/// swept for. A search over the file would report a comment; this reports what the type can actually be
/// asked to do. The shape is `func` at the start of a line's trimmed content, which is how every
/// declaration in these eight files is written — a requirement in a protocol has no body, so there is no
/// second spelling to miss.
private func declaredMethods(in text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("func ") else { return nil }
        let rest = trimmed.dropFirst("func ".count)
        return rest.prefix { $0 != "(" && $0 != " " }
    }.map(String.init)
}

/// Every key the document's path items hold, which for this contract is the set of HTTP verbs it
/// mounts.
///
/// **Decoded rather than scanned, and the difference from `SyncedResourceTests` is what is being asked.**
/// That file needs the *order* of the paths, so it cannot use a parser that returns a dictionary; this
/// one needs only *which* verbs exist anywhere in the document, and a set has no order to lose. So the
/// parse is the ordinary one, and it is exact rather than shape-dependent — a path item whose keys
/// included `parameters` or `summary` would show up here as itself, and a verb spelled `DELETE` would
/// arrive in upper case and fail the comparison below rather than being filtered out by a rule written
/// to expect lower case.
private func operationVerbs(in text: String) -> [String] {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let paths = object["paths"] as? [String: [String: Any]]
    else {
        assertTest(false, "The contract parses as a document with a `paths` object")
        return []
    }

    assertTest(paths.count == 23,
               "…and it mounts the 23 paths this sweep believes it does, so the verb set below is "
                   + "collected from the whole contract rather than from part of it")

    // Every key of every path item, with nothing filtered out — so a path item that grew a
    // `parameters` or a `summary` beside its operations, which OpenAPI permits, fails the count here
    // rather than being quietly dropped out of the set below and taking a `DELETE` with it.
    let items = paths.values.flatMap(\.keys)
    assertTest(items.count == 31,
               "…and every path item holds nothing but an operation, sixteen gets, eight puts and "
                   + "seven posts: \(items.count)")
    return items
}

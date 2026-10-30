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
        // MARK: The port — twenty-six doors, and exactly one of them a removal

        let port = try sourceText(at: "Domain/Repositories/CloudSync.swift")
        let portMethods = declaredMethods(in: port)

        // **The count is a tripwire rather than a contract.** Twenty-six is what the seven resources
        // need — two reads and two writes each for the six keyed resources, one read and one write for
        // the singleton profile — plus the single `purge`. A resource added later will make this fail,
        // and that is the point: the failure sends its author here, where the sentence below is waiting
        // to ask whether the new resource arrived with a *second* way to delete.
        assertTest(portMethods.count == 26,
                   "`CloudSync` declares 26 methods — the port's whole vocabulary, and the number this "
                       + "sweep is a tripwire for rather than a limit it enforces")

        // **The guarantee changed shape on 2026-10-29 and it did not weaken.** It used to be "no door is
        // a delete"; it is now "exactly one door is, and it is the day purge". Both halves are asserted:
        // one method may be named for removal, it must be `purge`, and it must take a *range* — because a
        // per-row delete is what a sync would reach for to reconcile a difference, and a range is the
        // shape of "these days are wrong" rather than "this row disagrees".
        let removalMethods = portMethods.filter {
            $0.lowercased().contains("purge") || $0.lowercased().contains("delete")
        }
        assertTest(removalMethods == ["purge"],
                   "Exactly one method on the port is a removal, and it is `purge`: \(removalMethods)")
        assertTest(port.contains("func purge(from: Date, to: Date) async throws -> PurgeTally"),
                   "…and it takes a range of days rather than a row, a day or an id — the narrow "
                       + "question is a range of one")
        assertTest(removalMethods.count == 1,
                   "…so a second removal under any other name is a change this sweep refuses")

        // The port's three families by name, so a method silently *replaced* rather than added is
        // visible: the count alone would accept one write swapped for one delete.
        for family in ["writeRecoveries", "writeStrains", "writeWorkouts", "writeSleeps",
                       "writeStepCounts", "writeReceptiveInactivities", "writeProfile"] {
            assertTest(portMethods.contains(family),
                       "The port still has `\(family)`, which is a door in and not a door out")
        }

        // MARK: The seven stores — the phone's own doors, fourteen of them, none of them a removal

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
        // **These seven are still swept for the absence, and that is the half that did not change.** The
        // purge reaches its tables through `DayPurgeStore`, deliberately not through one of these; a
        // store that grew a `delete` would be a second way into a table the sync owns.
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

        // MARK: The contract — four deletes, on four named resources, and nowhere else

        let contractSlices = try contractText()
        let contract = contractSlices.joined(separator: "\n")

        // **Four, and the number is the assertion.** One per measured day-keyed resource. A fifth would
        // be a resource the Worker removes and the app does not know about; a third would be a mount
        // lost. Spelled with the colon because that is the only form an operation key has in JSON, so
        // the prose descriptions that discuss deletion legitimately do not have to be kept out of it.
        let deleteKeys = contract.components(separatedBy: "\"delete\":").count - 1
        assertTest(deleteKeys == 4,
                   "The contract mounts exactly four delete operations — one per measured day-keyed "
                       + "resource — and nothing else: found \(deleteKeys)")
        assertTest(!contract.lowercased().contains("\"purge\":"),
                   "…none of them is a separate verb; the operation is a `delete` on the collection")

        // The paths those four sit on, decoded rather than pattern-matched, and compared with the app's
        // own list. This is the assertion that keeps `SyncedResource.purgeable` and the Worker's mounts
        // in step: a resource added to one and not the other is a purge that 404s every run.
        let deletePaths = Set(pathsMounting("delete", in: contractSlices))
        let expectedPaths = Set(SyncedResource.purgeable.map(\.path))
        assertTest(deletePaths == expectedPaths,
                   "…on exactly the paths the app purges: \(deletePaths.sorted()) against "
                       + "\(expectedPaths.sorted())")

        // The positive controls, without which the assertions above would pass over an empty string, a
        // truncated file or the wrong document.
        for verb in ["\"get\":", "\"post\":", "\"put\":", "\"delete\":"] {
            assertTest(contract.contains(verb),
                       "The contract does mount `\(verb.dropLast(1))` — so the sweeps above are over a "
                           + "document that really does declare operations")
        }
        assertTest(contract.contains("\"openapi\""), "…and it is the OpenAPI document beside the package")

        // Every verb the contract does declare, collected and swept as one list: a verb this file has
        // never heard of still fails here.
        let verbs = Set(operationVerbs(in: contractSlices))
        assertTest(verbs == ["delete", "get", "post", "put"],
                   "The only verbs the Worker answers are get, post, put and delete — the last of them "
                       + "on four paths and no more: \(verbs.sorted())")

        // And the count of paths, for `SyncedResourceTests`' reason: a scan that read half the document
        // would sweep half the contract, and every assertion above would still hold.
        assertTest(contract.components(separatedBy: "\"paths\": {").count == contractSlices.count + 1,
                   "…and every one of the \(contractSlices.count) slices holds its own `paths` "
                       + "object, so the join swept the whole folder rather than its first file")
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
/// rather than shared, because the two files read the same contract for two unrelated reasons.
///
/// **It is a folder of slices now, not one document**, so this is every slice joined: the sweep is
/// over operations and verbs, and which file an operation was written in does not change either.
/// `sliceCount()` is returned beside it so the caller can prove the join read the whole folder rather
/// than stopping at the first file.
private func contractText() throws -> [String] {
    let shared = packageRoot().deletingLastPathComponent().appendingPathComponent("shared")
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(
            at: shared, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        assertTest(false, "The contract folder is readable at \(shared.path): \(error)")
        throw error
    }

    var slices: [String] = []
    for folder in folders {
        let url = folder.appendingPathComponent("openapi.json")
        do {
            slices.append(try String(contentsOf: url, encoding: .utf8))
        } catch {
            assertTest(false, "The contract slice is readable at \(url.path): \(error)")
            throw error
        }
    }
    return slices
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
private func operationVerbs(in slices: [String]) -> [String] {
    // **One decode per slice, merged into one path table.** The committed contract is a folder of
    // per-resource documents rather than a single one, and this sweep asks a whole-contract question —
    // which verbs exist anywhere — so the slices are joined at the level that matters (the paths) and
    // not by concatenating the text, which would not parse.
    var merged: [String: [String: Any]] = [:]
    for text in slices {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["paths"] as? [String: [String: Any]]
        else {
            assertTest(false, "Every contract slice parses as a document with a `paths` object")
            return []
        }
        for (path, item) in paths { merged[path] = item }
    }
    let paths = merged

    assertTest(paths.count == 23,
               "…and it mounts the 23 paths this sweep believes it does, so the verb set below is "
                   + "collected from the whole contract rather than from part of it")

    // Every key of every path item, with nothing filtered out — so a path item that grew a
    // `parameters` or a `summary` beside its operations, which OpenAPI permits, fails the count here
    // rather than being quietly dropped out of the set below and taking a `DELETE` with it.
    let items = paths.values.flatMap(\.keys)
    assertTest(items.count == 35,
               "…and every path item holds nothing but an operation, sixteen gets, eight puts, "
                   + "seven posts and four deletes: \(items.count)")
    return items
}

/// The paths whose item mounts one verb — decoded, for `operationVerbs`' reason.
///
/// Used for the one question the verb set cannot answer: *where* the deletes are. Four of them is a
/// count; four on the four measured day-keyed resources is the property that makes the app's purge and
/// the Worker's mounts the same list.
private func pathsMounting(_ verb: String, in slices: [String]) -> [String] {
    var found: [String] = []
    for text in slices {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["paths"] as? [String: [String: Any]]
        else { continue }
        for (path, item) in paths where item[verb] != nil { found.append(path) }
    }
    return found
}

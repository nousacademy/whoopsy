import Foundation
import Whoopsy

// MARK: - 22.6 The pane's list, read off the contract rather than typed beside it

/// **The claim this file exists to make is an ordering claim, and it is the one claim in §22 that a
/// screenshot cannot see.** `SyncedResource.allCases` *is* the `SYNCED RESOURCES` list — the pane is a
/// `ForEach` over the enum — and the enum's order is `shared/openapi.json`'s, which is the Worker's own
/// order because the contract is generated from its route definitions and sorted by path. So a resource
/// that the server mounted and the app forgot would be a title the pane never draws, and one the app
/// invented would be a title over nothing; **neither shows up anywhere else**, because both sides keep
/// working and each one's list is internally consistent.
///
/// **The document is read rather than a literal being typed twice.** `allCases` is asserted against the
/// paths the file actually holds, in the order the file holds them — which is why the parse below is a
/// line scan of the `paths` object rather than a `JSONSerialization` call: that would hand back a
/// dictionary, and a dictionary has no order, so the very property under test would be discarded by the
/// tool used to read it.
///
/// It needs no database, no socket and no fixture. Everything here is two files of text and one enum.
enum SyncedResourceTests {

    static func run() async throws {
        let contract = try openAPIText()

        // MARK: The mount points, in the document's own order

        let mounted = mountedPaths(in: contract)
        assertTest(mounted.count == 23,
                   "The contract mounts 23 paths — the liveness route and the seven resources' three "
                       + "each plus the profile's one — which is the control proving the scan read the "
                       + "whole `paths` object rather than stopping early and comparing against a prefix")
        assertTest(mounted.first == "/health", "…and it opens with the one route that is not a resource")

        // The collection roots: the `/v1/` paths with nothing after another slash. These are what
        // `SyncedResource.path` spells, and there are eight of them.
        let roots = mounted.filter { $0.hasPrefix("/v1/") && !$0.dropFirst("/v1/".count).contains("/") }
        assertTest(roots.count == 8,
                   "Eight of the mounts are resource roots: seven the app syncs, and one it does not")
        assertTest(roots.first == "/v1/biometric-samples",
                   "…and the one it does not is **first**, because `b` sorts before `p` — so its absence "
                       + "from the enum is visible at the head of the list rather than hidden at the end")

        // MARK: `allCases` is those roots, in that order, minus the one that stays on the phone

        let expected = roots.filter { $0 != "/v1/biometric-samples" }
        assertTest(SyncedResource.allCases.map(\.path) == expected,
                   "The enum's cases are the contract's resource roots, in the contract's order, with "
                       + "the biometric samples left out: a resource whose window is measured in seconds "
                       + "rather than days carries its own control and stays on this phone, and naming it "
                       + "here would make *what would move if I switched* answer with something that will not")
        assertTest(SyncedResource.allCases.count == 7, "…so there are seven of them")

        // The missing resource is missing by name and not merely by count, which is the distinction a
        // length check cannot make: an enum that dropped `sleeps` and gained a second `strains` would
        // satisfy every count above.
        assertTest(!SyncedResource.allCases.contains { $0.path == "/v1/biometric-samples" },
                   "No case claims the biometric samples' mount")
        assertTest(Set(SyncedResource.allCases.map(\.path)).count == 7,
                   "…and no two cases claim the same mount")

        // MARK: The three spellings, which are three different words

        // **This is the table `CLAUDE.md` records for one resource, asserted for all seven.** The drawn
        // title, the Worker's identifier and the mounted path are all different strings, and the reason
        // they are written down here rather than derived is that the mapping genuinely is not a rule:
        // `step-counts` and `stepCounts` differ by more than a case change, and the profile's identifier
        // is `userProfiles` while its path is the *singular* `/v1/profile`. A spelling that drifted
        // would keep compiling and keep drawing; only this file would notice.
        let spellings: [(SyncedResource, String, String, String)] = [
            (.profile, "PROFILE", "userProfiles", "/v1/profile"),
            (.receptiveInactivities, "RECEPTIVE INACTIVITIES", "receptiveInactivities", "/v1/receptive-inactivities"),
            (.recoveries, "RECOVERIES", "recoveries", "/v1/recoveries"),
            (.sleeps, "SLEEPS", "sleeps", "/v1/sleeps"),
            (.stepCounts, "STEP COUNTS", "stepCounts", "/v1/step-counts"),
            (.strains, "STRAINS", "strains", "/v1/strains"),
            (.workouts, "WORKOUTS", "workouts", "/v1/workouts"),
        ]
        assertTest(spellings.map { $0.0 } == SyncedResource.allCases,
                   "The table covers every case, in the enum's order — so a case added to the enum "
                       + "without a row here fails rather than going unchecked")

        for (resource, title, name, path) in spellings {
            assertTest(resource.rawValue == title, "\(title)'s raw value is the title the pane draws")
            assertTest(resource.resourceName == name, "…`\(name)` is the Worker's own name for it")
            assertTest(resource.path == path, "…and \(path) is what it is mounted at")
        }

        // Pairwise distinct across the whole table, which is the property rather than the three
        // per-resource comparisons above: a title that happened to equal a path would pass those.
        let all = spellings.flatMap { [$0.1, $0.2, $0.3] }
        assertTest(Set(all).count == 21,
                   "…and all 21 strings are distinct, so no spelling is standing in for another")

        // MARK: The document is the one this repo generates

        // A cheap guard on the read itself: the file could be a placeholder, truncated, or the wrong
        // document entirely, and every assertion above would then be comparing the enum against a scan
        // of nothing. `paths` is the last of the three top-level keys and its presence is what the scan
        // depends on, so it is asserted directly rather than assumed.
        assertTest(contract.contains("\"openapi\""), "The file read is an OpenAPI document")
        assertTest(contract.contains("\"paths\": {"), "…and it holds the `paths` object the scan walks")
    }
}

// MARK: - Reading the contract

/// The committed contract, from the repo root beside the package.
///
/// `packageRoot()` is `ios/`, so the document is one directory up — the same climb
/// `docs/BACKEND.md`'s readers make, and the reason this file needs no fixture: `shared/` is not inside
/// the SwiftPM package and a resource bundle would not carry it.
private func openAPIText() throws -> String {
    let url = packageRoot().deletingLastPathComponent().appendingPathComponent("shared/openapi.json")
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        assertTest(false, "The contract is readable at \(url.path): \(error)")
        throw error
    }
}

/// The keys of the `paths` object, in the order the document writes them.
///
/// **A line scan and not a `JSONSerialization` decode, deliberately.** `paths` is a JSON object, and
/// every parser in Foundation hands one back as a `[String: Any]` — unordered — so decoding the file
/// would throw away the exact property this section asserts. The scan is narrow enough to be safe: the
/// document is generated with one key per line, so a path entry is a line whose trimmed form begins
/// `"/` and ends `": {`, and no nested key has that shape (a nested map's keys here are status codes and
/// media types, and a description is a single escaped line so it cannot open one).
private func mountedPaths(in text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"/"), trimmed.hasSuffix("\": {") else { return nil }
        return String(trimmed.dropFirst().dropLast(4))
    }
}

import CoreBluetooth
import Foundation
// For `AnyView` and nothing else. `SpyOfflineMaps` is declared here rather than beside its siblings in
// `Support/Fixtures/` only because this is the one target file every section can see it from; the
// import is kept for the return type `OfflineMapRendering.map(route:unit:regionID:)` declares. The
// runner still renders nothing: no `body` is ever evaluated, and `ActivityRouteMapView` is constructed
// but never drawn.
import SwiftUI
import Whoopsy

// The suite's entry point, and **the only file here that may hold top-level statements.**
//
// Swift permits executable code at file scope in a file literally named `main.swift` and in no other,
// which is the constraint the whole layout is built around: everything that is a declaration —
// `SuiteTally`, `assertTest`, the twenty-two section bodies, the fixtures — lives in a sibling file
// under its own mirrored directory, and what is left here is the four statements that have to run in
// order.
//
// **The order is load-bearing.** §1–§5 run *before* the `Task` is created, which is where they ran as
// inline top-level blocks; they are synchronous, so a `Task` buys them nothing and moving them inside
// one would change when they run relative to §6. The `Task` then drives §6–§22, and the `RunLoop` keeps
// the process alive for it. `runSections` ends by calling `finishSuite`, so every completing path
// leaves through that one exit — success, a failed assertion, or a throw.
//
// **The range below is a range and not the registry's count, so a section appended to
// `SectionRegistry` does not run until it is widened here** — and a section that stops running looks
// exactly like one that passed, since the summary line's `sections=` field reads it off the *registry*
// rather than off what executed. Widening it is part of adding a section, not a follow-up.

print("==================================================")
print("⚡ RUNNING WHOOPSY TEST SUITE")
print("==================================================")

runSynchronousSections([1, 2, 3, 4, 5])

// Sections 6–22 live inside the `Task` rather than in its own body, and the reason is the exit code.
// A `Task { }`'s error is observed by nobody: an uncaught throw leaves the process to idle out the
// `RunLoop` and exit 0, which reads exactly like a suite that ran and passed. Catching one level out
// is what puts a throw on the exit code.
Task {
    do {
        try await runSections(6...22)
    } catch {
        print("❌ FAILED: the suite threw before completing: \(error)")
        tally.record(false)
        finishSuite(exitCode: 1)
    }
}

// The async sections need the process kept alive long enough to finish; 5s was too short on a
// cold database.
RunLoop.main.run(until: Date().addingTimeInterval(30.0))

// **Reaching this line is a failure, not a pass.** Every path that completes leaves through
// `finishSuite` — success, a failed assertion, or a throw — so getting here means the `Task` never
// finished and the timeout above is the only other way out of the `RunLoop`. Falling off the end
// would exit 0 and report a suite that hung as green, which is the failure mode this whole
// arrangement exists to close.
print("❌ FAILED: the suite did not finish within 30s — it hung, or a section returned without reporting")
tally.record(false)
finishSuite(exitCode: 1)

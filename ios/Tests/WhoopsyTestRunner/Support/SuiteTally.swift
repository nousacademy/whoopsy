import Foundation


/// Counts assertions and the sections that ran, so the run can end with one machine-readable line.
///
/// **The summary exists because this suite has no test discovery.** A section that stopped running
/// looks exactly like one that passed: the `✓` lines scroll past either way and nothing in the
/// output says which sections produced them. `sections=` is the field that catches a dropped section;
/// `assertions=` is the field that catches a section that ran but stopped asserting. Record both
/// before editing, and treat a drop in either as a deleted guarantee rather than as noise.
///
/// A lock rather than a bare global, because assertions arrive from the main actor and from inside
/// awaited async work and the two can interleave.
final class SuiteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = 0
    private var failed = 0
    private var sections: [Int] = []

    func record(_ ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        if ok { passed += 1 } else { failed += 1 }
    }

    func markSection(_ number: Int) {
        lock.lock(); defer { lock.unlock() }
        sections.append(number)
    }

    var state: (passed: Int, failed: Int, sections: [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (passed, failed, sections)
    }
}

let tally = SuiteTally()

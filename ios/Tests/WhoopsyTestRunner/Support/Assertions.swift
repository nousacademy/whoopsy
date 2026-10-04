import Foundation

/// Prints the run's one-line summary and exits — the single exit path for every outcome.
func finishSuite(exitCode: Int32 = 0) {
    let state = tally.state

    // A `WHOOPSY_SECTIONS` value naming a section that does not exist would otherwise run nothing and
    // exit 0, which is a typo reading as a pass. Checked only on an otherwise-clean run, so a genuinely
    // failing assertion is still the thing that gets reported.
    if exitCode == 0, !selectedSections.isEmpty {
        let missing = selectedSections.subtracting(state.sections)
        if !missing.isEmpty {
            print("\n❌ FAILED: WHOOPSY_SECTIONS named section(s) that do not exist: "
                + missing.sorted().map(String.init).joined(separator: ","))
            tally.record(false)
            finishSuite(exitCode: 1)
        }
    }

    print("\nSUITE sections=\(state.sections.sorted().map(String.init).joined(separator: ","))"
        + " assertions=\(state.passed) failed=\(state.failed) exit=\(exitCode)")
    exit(exitCode)
}

func assertTest(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    tally.record(condition)
    if condition {
        print("  ✓ \(message)")
    } else {
        // Fail fast, as before: the runner is linear, so a later section's result is not worth having
        // once an earlier one has failed. `finishSuite` prints the summary before exiting, so even a
        // failing run is machine-readable.
        print("❌ FAILED: \(message) at \(file):\(line)")
        finishSuite(exitCode: 1)
    }
}

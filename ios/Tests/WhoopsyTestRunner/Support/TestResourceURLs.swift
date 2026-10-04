import Foundation

// The bundled data files, located from the compile-time path of *this* file rather than from the
// working directory. `swift build`, `swift run` and a hand-invoked binary disagree about `cwd`, and a
// section that quietly skipped its own assertions would be worse than no section at all.
//
// **`#filePath` is whatever path is handed to `swiftc`, so it must be absolute** — a relative one
// makes `packageRoot()` depend on the caller's cwd and §11–§20 fail with *"The bundled export is
// missing at …/Sources/…"*, which reads like a broken import and is only a wrong directory.
// `scripts/test.sh` passes an absolute path and also exports `WHOOPSY_PACKAGE_ROOT`, which is the
// branch taken in practice.

/// The SwiftPM package root (`ios/`), found by walking up until a directory holds both `Package.swift`
/// and `Sources/Whoopsy`.
///
/// **This replaces a count of `deletingLastPathComponent()` calls, and the count is why it exists.**
/// The helpers below used to climb exactly three levels, which was correct only while this code sat at
/// `Tests/WhoopsyTestRunner/main.swift`. Splitting the runner across mirrored subdirectories makes the
/// depth a property of the *file* rather than of the package, so a helper in `Support/` would climb
/// three levels and land on `Tests/`. A marker walk is depth-independent and therefore survives the
/// next file being moved as well.
///
/// The `WHOOPSY_PACKAGE_ROOT` override is preferred when set, so an unrelated `Package.swift` above the
/// repo cannot fool the search and so the build's absolute-path guarantee is kept explicitly rather
/// than inferred.
func packageRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["WHOOPSY_PACKAGE_ROOT"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let fileManager = FileManager.default
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
           fileManager.fileExists(atPath: directory.appendingPathComponent("Sources/Whoopsy").path) {
            return directory
        }
        directory.deleteLastPathComponent()
    }
    // Nothing matched: hand back this file's own directory and let the caller's guard report the
    // missing file. A `fatalError` here would report a broken checkout as a crash in the runner.
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
}

/// The export this app ships with — `physiological_cycles.csv`.
func whoopExportURL() -> URL {
    packageRoot().appendingPathComponent("Sources/Whoopsy/Data/Resources/Whoop/physiological_cycles.csv")
}

/// `sleeps.csv`, which this app reads for its nap rows and nothing else — see `parseNaps`.
func whoopNapsURL() -> URL {
    packageRoot().appendingPathComponent("Sources/Whoopsy/Data/Resources/Whoop/sleeps.csv")
}

/// `fasts.json`, trimmed from the Zero tracker's own `biodata.json`.
///
/// Read here as a **repo file** and never through `Bundle.module`, which is how `ZeroFastingImporter`
/// reaches it inside a built app. `scripts/test.sh` links object files and no resource bundle, so
/// `Bundle.module` **traps** rather than returning `nil` — the same reason §11 reads the CSVs from
/// `#filePath`, and the reason §20 asserts `parseFasts(at:)` and `importFasts(at:)` and never calls
/// `bundledFastsURL()`. That accessor's whole job is to answer this same path with the resource
/// bundle's prefix, so testing it here would test the bundle lookup and not the import.
func zeroFastingURL() -> URL {
    packageRoot().appendingPathComponent("Sources/Whoopsy/Data/Resources/ZeroFasting/fasts.json")
}

/// `dreams.json`, generated from the owner's own notes log by a generator that is **not part of this
/// repository** — the owner's own tooling, untracked as the file it writes is.
///
/// Read here as a **repo file** for `zeroFastingURL()`'s reason: `scripts/test.sh` links object files
/// and no resource bundle, so `Bundle.module` **traps** rather than returning `nil`. §21 therefore
/// asserts `parseInactivities(at:)` and `importInactivities(at:)` and never calls
/// `bundledInactivitiesURL()`.
///
/// **The directory names no producer app, and the path is under `Custom/` because of it** — there is no
/// app behind these records, they are one person's own notes with their dates resolved. The file is
/// gitignored, so a fresh clone has the `{"receptive_inactivities": []}` placeholder here instead and
/// §21's assertions over the real file fail rather than silently covering nothing.
func inactivitiesURL() -> URL {
    packageRoot().appendingPathComponent("Sources/Whoopsy/Data/Resources/Custom/dreams.json")
}

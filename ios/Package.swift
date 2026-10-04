// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whoopsy",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WhoopsyCore",
            targets: ["Whoopsy"]
        ),
        // A **second product**, because the widget extension needs `WhoopsySessionAttributes` and must
        // not link `Whoopsy`. See the target's own comment.
        .library(
            name: "WhoopsyLiveActivityKit",
            targets: ["WhoopsyLiveActivityKit"]
        ),
        .executable(
            name: "WhoopsyApp",
            targets: ["WhoopsyApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .target(
            name: "WhoopsyLiveActivityKit",
            path: "Sources/WhoopsyLiveActivityKit"
        ),
        .target(
            name: "Whoopsy",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                // Referenced only from `#if os(iOS)` code (`Data/Services/LiveActivityController.swift`),
                // so this edge is inert on macOS and the target compiles to an empty module there —
                // which keeps `scripts/test.sh`'s hardcoded `Whoopsy.build/*.o` + `GRDB.build/*.o` link
                // globs sufficient. The Kit contributes no symbol the runner needs and defines none.
                "WhoopsyLiveActivityKit"
            ],
            path: "Sources/Whoopsy",
            // The three files the importer reads. `journal_entries.csv` is still not read by
            // anything and would add 283 KB to the app for no reason.
            //
            // **`sleeps.csv` is bundled for its eight nap records and nothing else**, which is why it
            // was not bundled before `v11`. It is not superseded by `physiological_cycles.csv` — the
            // two have 26 and 18 columns, and `Nap` is in `sleeps.csv` alone — and its other 910 rows
            // carry the same 910 wake onsets as the bundled file, set-for-set. Those eight need a
            // `naps` table to land in before bundling the file ships a resource with no reader; that
            // table now exists, and `WhoopExportImporter.parseNaps` filters them out of it. The pair
            // is the point: this file is read *only* for naps, and `parseNaps` requires the `Nap`
            // column so that pointing it at the cycle file fails loudly rather than finding none.
            //
            // **`workouts.csv` is bundled for its zone block**, which is in no other file: its 673
            // rows are the only producer of the strain page's `HEART RATE ZONES 1-3` / `4-5` rows, and
            // they carry a workout's own window, strain and heart rates besides. It repeats columns
            // the cycle file already has — `Cycle start time`, `Cycle timezone`, the two heart rates —
            // which is why it shares a row type and a date walk with it rather than adding a fourth.
            // `parseWorkouts` requires `Workout start time` / `Workout end time`, so pointing it at
            // either sleep file throws instead of importing nothing and reporting success.
            //
            // Declared here rather than in the Xcode project's resource phase, so the lookup goes
            // through `Bundle.module` and resolves identically under `swift build`, the test runner,
            // and the app. `Bundle.main` never found these files and never would have: the app
            // target's resource phase is empty.
            // **`fasts.json` is the Zero fasting tracker's history**, trimmed from the producer's own
            // 599 KB `biodata.json` to the one key this app reads — every byte of the bundled file is
            // read, where 92% of `biodata.json` is nineteen keys of data nothing here touches. It is
            // the fourth input's only resource, and unlike the three CSVs its absence is an error
            // rather than a shrug: `ZeroFastingImporter.importBundledFasts()` throws
            // `ZeroFastingError.notBundled` for it, because this file *is* the import. The generation
            // recipe and the `{"fast_data": []}` placeholder for a fresh clone are in `README.md`.
            //
            // The whole `Data/Resources/ZeroFasting/` directory is gitignored — it is a real person's
            // fasting history — and it is named for the app the file came out of, which is why the
            // three CSVs beside it sit in a `Whoop/` of their own under a matching ignore rule. Each
            // producer gets a directory and an ignore line; a resource placed loose under
            // `Data/Resources/` would be covered by neither, and an ignore rule that is absent
            // commits the history it was meant to keep out.
            //
            // Declared here rather than in the Xcode project's resource phase, for the same reason as
            // the CSVs above: `Bundle.module` resolves identically under `swift build`, the test
            // runner, and the app, and `Bundle.main` would find none of them.
            //
            // **The three CSVs sit in a `Whoop/` subdirectory**, named for the app they came out of,
            // with `ZeroFasting/` beside it the same arrangement for a different producer. `.process`
            // on an explicit file path **flattens it into the bundle's root**, so
            // `WhoopExportImporter`'s lookups are `url(forResource:withExtension:)` with no
            // `subdirectory:` — `ZeroFasting/fasts.json` has always resolved that way and is the
            // precedent, being the same nesting depth. Moving these files again means checking that,
            // because `Bundle.module` would return `nil` and the import would report `.notBundled`
            // rather than failing at build time.
            //
            // **`Custom/dreams.json` is the fifth and the first whose directory names no producer
            // app**, which is the same deviation `.gitignore` records on the directory and
            // `InactivityImportAction` records on the button: there is no app behind it, it is the
            // owner's own notes log with its dates resolved. It is a `.json` at the same nesting
            // depth as `ZeroFasting/fasts.json`, so it flattens the same way and
            // `InactivityImporter.bundledInactivitiesURL()` passes no `subdirectory:` either. **And
            // bundling it ships 26 KB of that prose inside the app binary**, which follows from
            // importing the notes at all — the file has to be in the bundle for any import to read
            // it — and is stated here rather than left implicit, since the directory is gitignored
            // precisely because of what it holds.
            resources: [
                .process("Data/Resources/Whoop/physiological_cycles.csv"),
                .process("Data/Resources/Whoop/sleeps.csv"),
                .process("Data/Resources/Whoop/workouts.csv"),
                .process("Data/Resources/ZeroFasting/fasts.json"),
                .process("Data/Resources/Custom/dreams.json"),
            ]
        ),
        .executableTarget(
            name: "WhoopsyApp",
            dependencies: ["Whoopsy"],
            path: "app",
            // `path: "app"` **is** `App/` on macOS's case-insensitive filesystem — `.gitignore` and
            // Finder disagree about the case, and SwiftPM follows the path it is given. SwiftPM
            // compiles every `.swift` file under a target's path recursively, so the widget sources at
            // `App/LiveActivity/` would be compiled into the *host executable*, where `WidgetKit`'s
            // `@main` bundle does not exist.
            //
            // So every Xcode-only source directory under `App/` needs a matching entry here, and this
            // is the list to extend rather than a one-off.
            exclude: ["LiveActivity", "Map"]
        )
    ]
)
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
            resources: [
                .process("Data/Resources/physiological_cycles.csv"),
                .process("Data/Resources/sleeps.csv"),
                .process("Data/Resources/workouts.csv"),
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
            exclude: ["LiveActivity"]
        )
    ]
)
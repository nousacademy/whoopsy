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
            name: "Whoopsy",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Whoopsy",
            // The two files the importer reads. `journal_entries.csv` and `workouts.csv` are still
            // not read by anything and would add 375 KB to the app for no reason.
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
            // Declared here rather than in the Xcode project's resource phase, so the lookup goes
            // through `Bundle.module` and resolves identically under `swift build`, the test runner,
            // and the app. `Bundle.main` never found these files and never would have: the app
            // target's resource phase is empty.
            resources: [
                .process("Data/Resources/physiological_cycles.csv"),
                .process("Data/Resources/sleeps.csv"),
            ]
        ),
        .executableTarget(
            name: "WhoopsyApp",
            dependencies: ["Whoopsy"],
            path: "app"
        )
    ]
)
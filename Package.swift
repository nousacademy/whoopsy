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
            // Only the file the importer reads. The other three in that directory (`sleeps.csv`,
            // `journal_entries.csv`, `workouts.csv`) are not read by anything and would add 490 KB to
            // the app for no reason. This is not because `physiological_cycles.csv` supersedes
            // `sleeps.csv` — the two have 26 and 18 columns, and `Nap` is in `sleeps.csv` alone. It is
            // because nothing reads `sleeps.csv` yet: those eight nap records need a `naps` table
            // before they can be stored at all (see `ALGORITHMS.md` §4), so bundling it would ship a
            // resource with no reader.
            //
            // Declared here rather than in the Xcode project's resource phase, so the lookup goes
            // through `Bundle.module` and resolves identically under `swift build`, the test runner,
            // and the app. `Bundle.main` never found these files and never would have: the app
            // target's resource phase is empty.
            resources: [.process("Data/Resources/physiological_cycles.csv")]
        ),
        .executableTarget(
            name: "WhoopsyApp",
            dependencies: ["Whoopsy"],
            path: "app"
        )
    ]
)
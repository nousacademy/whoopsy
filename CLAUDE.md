# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Whoopsy** — a 100% offline, subscription-free iOS companion app for WHOOP 4.0/5.0/5.0 MG straps. Reads biometrics over BLE, decodes a reverse-engineered packet protocol, stores everything locally, and computes Recovery/Strain/Sleep metrics on-device.

Written in Swift 6 with strict concurrency (`async`/`await`, `AsyncStream`, `Sendable`), structured as Clean Architecture + DDD. The SwiftPM package has one dependency: GRDB.swift (SQLite). The Xcode app target links two SDKs the package deliberately does not — MapboxMaps and Sentry — each behind a `#if canImport` in `ios/App/`, so the host build and the suite take the guarded fallback and never compile the SDK.

**The repo is a monorepo, and this file is about the app in it.** The SwiftPM package and `Whoopsy.xcodeproj` live under `ios/`; `backend/` is a Cloudflare Worker (Hono in front of D1 + R2), and `shared/openapi.json` is the contract the two halves agree on. **The Worker carries eight resources and has its own toolchain and its own gate — that is `docs/BACKEND.md`.** The iOS half syncs **seven** of the eight — `biometricSamples` deliberately stays on the phone, because its window is measured in seconds rather than days — so a sentence below saying "seven resources" is describing the client's sync and one saying "eight" is describing what the Worker carries. Paths below are written **from the repo root**, so anything naming a real file carries the `ios/` prefix; the unprefixed layer names (`Data/BLE/`, `Core/Math/`, `Presentation/DesignSystem/`, `App/DependencyInjection/`) are shorthand for paths inside `ios/Sources/Whoopsy/` and were never root-resolvable.

**Where to look.** `## Commands` and `### Tests` are how to build and run it. **`## Pages` is the inventory of every screen the app has** — each page, the view model behind it, and how it is reached — and it is the section to update when a page is added, moved or renamed. `## Architecture` is the layers and the wiring rules, `### Persistent gotchas` is what has already gone wrong here once, and `### Reference docs` is the specs.

**Three of those sections are indexes onto a longer file, and this file keeps only the rule.** The full text, the measurements and the history behind them are in `docs/`, which is **not** re-read on every turn:

| for | read |
| :--- | :--- |
| what each of the 24 suite sections asserts | `docs/TESTING.md` |
| why a screen or control is the shape it is | `docs/PAGES.md` |
| the reasoning and the evidence behind any gotcha | `docs/GOTCHAS.md` (grep the headline) |
| the Worker's resources, routes and gates | `docs/BACKEND.md` |

Grep the headline rather than reading a file whole: every gotcha below appears in `docs/GOTCHAS.md` under the same bolded words.

## Commands

```bash
make build                       # swift build — WhoopsyCore library + WhoopsyApp executable (host/macOS)
make test                        # build + run the suite; SECTIONS=13,15 to narrow it
make ios                         # the real iOS build path (iOS 17+, target WhoopsyApp)
make ipa                         # build + package tmp/whoopsy.ipa for Sideloadly (overwrites the fixed name)
make verify                      # all three — a green iOS build is not a green host build, so run both
swift build 2>&1 | grep warning  # build emits known resource warnings — see Gotchas
xed ios/Whoopsy.xcodeproj        # open the project in Xcode
```

The Worker has its own toolchain and its own gate, and **none of it is a prerequisite of `verify`** —
that target is the Swift pair and must stay runnable without a Node install:

```bash
make backend-check               # npm ci + typecheck + test + regenerate the contract, then diff it
npm --prefix backend test        # just the Worker's suite (real Worker, local D1, no deploy)
npm --prefix backend run openapi # rewrite shared/openapi.json from the route definitions
npm --prefix backend run dev     # wrangler dev on :8787 — see README § The backend
```

`make backend-check` is the four steps in one argument — install, prove the types, prove the behaviour,
and prove the committed contract is the one the code generates — and that last step is why the
generator writes unconditionally rather than skipping a no-op. **`npm ci`, not `npm install`**: the
lockfile is committed and the gate must install what CI will.

**The suite needs no secret but `npm run dev` and a deployment both do, and neither is in this
repository.** `SYNC_API_TOKEN` is one value in three homes — `backend/.dev.vars` (gitignored; copy
`.dev.vars.example`) for `wrangler dev`, `ios/App/Config/Whoopsy.local.xcconfig` (`WHOOPSY_API_TOKEN`)
for the app, and `npx wrangler secret put SYNC_API_TOKEN` for the deployment. `vitest.config.ts` binds
its own fixture token as `SYNC_API_TOKEN`, deliberately as the one binding that is *not* in
`wrangler.toml`, so `npm test` stays runnable on a fresh clone. **That file carries one setting and
nothing else — the token.** The contract's `servers[0].url` is not configured anywhere: the committed
`shared/openapi.json` carries `/`, the OpenAPI form meaning *the origin this document was fetched
from*, because that file is committed and a hostname in it would be one operator's subdomain in a
repository everyone reads, while a deployment names its own origin in the document it serves. **The Worker
answers `500`, not `401`, when it has no secret** — an unarmed deployment is the operator's problem
rather than the caller's, and
a `401` there would tell a person holding a curl that their credential was wrong. `wrangler dev`
therefore answers `500` on every `/v1` request until `.dev.vars` exists, and `GET /health` and
`GET /openapi.json` are the two paths that answer regardless.

`make build` is the fast edit/compile loop; the underlying `swift build` is fine to call directly. The `Makefile` exists so the `DEVELOPER_DIR` prefix and the `-scheme`-not-`-target` rule for iOS live in one place instead of being re-derived from this file. The iOS app is built from `ios/Whoopsy.xcodeproj`, which consumes the `WhoopsyCore` package product. There is no linter configured.

**None of those targets installs anything, and `make ios` is not the one you want for a simulator.** It compiles for a device, so it does not refresh the bundle `simctl install` reads — see **### Running on a simulator** below for the invocation that does, and for the `terminate` → `install` → `launch` sequence that makes an install actually take.

**Everything produced while testing goes in `tmp/`, never in the machine's `/tmp`.** The folder is gitignored apart from its own `README.md`, and both build paths already point into it — `scripts/test.sh`'s SwiftPM scratch path is `tmp/build/verify` and `make ios`'s derived data is `tmp/build/whoopsy-dd`. So when capturing a simulator screenshot, dumping a build log or scribbling a throwaway probe, write there. `make clean` removes `tmp/build`; the table in `tmp/README.md` says what each subfolder holds and what is safe to delete — briefly, everything except `tmp/backups/`, which holds SQLite copies of the simulator's container and is the one thing in there that is not regenerable.

### Building for iOS

```bash
make ios                         # the checked-in form — adds -derivedDataPath and CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/Whoopsy.xcodeproj -scheme WhoopsyApp \
  -destination 'generic/platform=iOS' build
```

Two things to know. **`xcode-select` points at CommandLineTools**, so bare `xcodebuild` errors out and `xcrun --sdk iphoneos` cannot find the SDK; the `DEVELOPER_DIR` prefix above sidesteps that without a `sudo xcode-select -s`. And the legacy `-target` form **cannot resolve SwiftPM dependencies** (it fails with `Unable to resolve module dependency: 'GRDB'`), so use `-scheme` — `WhoopsyApp.xcscheme` is checked in under `xcshareddata` precisely because Xcode only auto-generates schemes when the GUI opens the project.

`CODE_SIGNING_ALLOWED=NO` builds everything up to signing, which is how to check iOS compilation without a team. `ios/App/iOS/Whoopsy.entitlements` (`com.apple.developer.healthkit`) is wired up via `CODE_SIGN_ENTITLEMENTS` on both configs, and that entitlement requires the HealthKit capability enabled on the App ID server-side.

### Running on a simulator

**The command above compiles for a device, so it does not produce the bundle a simulator installs**, and nothing about it says so — `make ios` passes `-destination 'generic/platform=iOS'` and writes into `Build/Products/Debug-iphoneos`, leaving `Debug-iphonesimulator` holding whichever simulator build ran last. Installing that path after a `make ios` therefore installs a bundle **that does not contain the edit**, with `** BUILD SUCCEEDED **` printed and no warning at any point. Building for a simulator is a separate invocation, and it is the only one that refreshes the product `simctl install` reads:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/Whoopsy.xcodeproj -scheme WhoopsyApp \
  -destination 'platform=iOS Simulator,id=55511A6D-ED4D-4405-941C-FB0DFF107662' \
  -derivedDataPath "$PWD/tmp/build/whoopsy-dd" build
```

Note the **missing `CODE_SIGNING_ALLOWED=NO`** — that flag belongs to the device build above; a simulator build signs normally and does not want it. `xcrun simctl list devices booted` prints the ids, and the id above is this machine's booted iPhone 17 Pro.

Then install and launch. **`xcrun simctl` needs `DEVELOPER_DIR` too**, for the same CommandLineTools reason `xcodebuild` does — without it `xcrun` fails with `unable to find utility "simctl", not a developer tool or in PATH`, which reads as the tool being absent rather than the environment being wrong:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SIM=55511A6D-ED4D-4405-941C-FB0DFF107662
BUNDLE=org.whoopsy.app

xcrun simctl terminate $SIM $BUNDLE     # expected to FAIL when nothing is running
xcrun simctl install   $SIM "$PWD/tmp/build/whoopsy-dd/Build/Products/Debug-iphonesimulator/WhoopsyApp.app"
xcrun simctl launch    $SIM $BUNDLE
```

Four things about that sequence are load-bearing rather than ceremony.

**`terminate` before `install`, and check the launch that follows took.** `simctl launch` on an already-running app **does not relaunch it** — it foregrounds the live process — so an `install` over a running app replaces the bundle on disk while the old process keeps executing the old code, and the launch then renders the previous build. The tell is two screenshots taken either side of a visible source change coming back **pixel-identical**, which reads exactly like a modifier that did nothing. `terminate` exits non-zero with *"found nothing to terminate"* when the app is not running, which is the **expected** result on a cold simulator and not a failure.

**Never `uninstall`.** It is the other way to force a cold start and it is **wrong here**: it drops the app's data container, taking the imported export and any recorded sessions with it — and those exist nowhere else. `install` over the top preserves the container.

**The bundle id is `org.whoopsy.app`.** A `terminate` against a guessed id (e.g. `com.whoopsy.app`) fails with *"found nothing to terminate"* — the **same** message a genuinely-stopped app gives — so a wrong id is indistinguishable from a stopped app, and the `install` + `launch` that follow land under a process that is still running the old build.

**Verify the install is current before believing what you see.** Compare the installed dylib against the built one; the ~58 KB `WhoopsyApp` stub beside `WhoopsyApp.debug.dylib` is not the code:

```bash
APP=$PWD/tmp/build/whoopsy-dd/Build/Products/Debug-iphonesimulator/WhoopsyApp.app
ls -la "$APP/WhoopsyApp.debug.dylib"
ls -la "$(xcrun simctl get_app_container $SIM $BUNDLE app)/WhoopsyApp.debug.dylib"
find ios/Sources -name "*.swift" -newer "$APP/WhoopsyApp.debug.dylib"   # must print nothing
```

For the decisive check that the running binary holds a specific edit — independent of the build system and of what the screen happens to be showing — grep the **installed** dylib for a string unique to it: `strings -a "<installed>/WhoopsyApp.debug.dylib" | grep -F "<new copy>"`. A string that is missing there is a fact about the binary; a string that is present on the screen is a fact about a screenshot.

### Tests

```bash
make test                        # build + run all 24 sections
make test SECTIONS=13,15         # just those two
./scripts/test.sh 13 15          # same thing
swift test                       # FAILS: "no tests found" — Package.swift declares no test target
```

The real suite lives under `ios/Tests/WhoopsyTestRunner/` (a hand-rolled assert runner, not XCTest), and `scripts/test.sh` is the only supported way to build and run it. It builds into a **scratch path** (`tmp/build/verify`, override with `WHOOPSY_SCRATCH`) rather than `.build`: a build directory that has accumulated object files from since-deleted sources fails to link with `symbol(s) not found`. It also supplies the `-fmodule-map-file` flag that the build needs to find `CSQLite`, and reads the platform triple instead of hardcoding `arm64-apple-macosx`.

**The test tree mirrors `ios/Sources/Whoopsy/`, and that is the rule that answers "where does this test go?".** A test file is named `<SourceFile>Tests.swift` and sits at its source file's own path with `Sources/Whoopsy/` dropped — so the counterpart of `Sources/Whoopsy/Core/Math/SleepNeedMath.swift` is `Tests/WhoopsyTestRunner/Core/Math/SleepNeedMathTests.swift`, and a new domain model, route or repository is findable without searching. `Support/` deliberately does **not** mirror, because the harness (`SuiteTally`, `assertTest`, `finishSuite`), the section registry and the twelve shared fixtures have no app counterpart. **`main.swift` is the one file that may hold top-level statements** — Swift permits executable code at file scope in a file literally named that and in no other — so everything that is a declaration lives in a sibling file and `main.swift` is about 50 lines. `scripts/test.sh` links `main.swift` plus every other `.swift` under the test root, sorted, so compile order is deterministic and a failure's `#file`/`#line` is stable run to run.

**A section is a grouping and the file is the unit.** §1–§24 are *stable ids*, not positions: `Support/SectionRegistry.swift` holds one `TestSection` entry per section carrying its id, its title and the closure that runs it, so **adding a section means appending one entry and nothing is renumbered** — `WHOOPSY_SECTIONS=13` keeps its meaning for good, and every `§N` reference in this file, in `docs/` and in the section doc comments keeps its own.

**Its two steps each resolve a compiler through `PATH`, so an exported `DEVELOPER_DIR` makes them disagree — and this is a false green, not a build error you will notice.** `xcode-select` points at CommandLineTools (Swift 6.3.3) while Xcode 27 is Swift 6.4, and that variable is what moves `/usr/bin/swiftc` from one to the other; the script's `swift build` leaves a module in the scratch path and its bare `swiftc` then refuses it with *"module compiled with Swift 6.3.3 cannot be imported by the Swift 6.4 compiler"*. **Do not leave `DEVELOPER_DIR` exported in the shell you run `scripts/test.sh` from** — unset it, or export it so *both* steps see it. Recover by re-running with it unset; the module is only stale against the other toolchain, so no clean is needed. Measured 2026-09-30: a background run of the suite reported **exit 0** while its output held that compile error, no `SUITE` line and no `✅ ALL WHOOPSY TESTS PASSED SUCCESSFULLY!` banner — which is §7's rule in the flesh, and the reason the banner and the `sections=`/`assertions=` fields are the verdict and `$?` is not. Reproduced the same day by running the script's own link step twice, identical but for the variable: **without** it the link succeeds and writes its binary; **with** it the link prints that error and writes no binary at all — and that failing step reports `exit=0` too, so the exit code does not separate the two cases even at the step that fails.

**Every section is addressable, and this is the loop to use.** `WHOOPSY_SECTIONS=13` runs §13 and nothing else; §1–§5 are gated the same way. The gate is on each section's *call*, so a skipped section opens no database and imports no CSV — which is the cost being skipped.

**Read the summary line, not the scrollback:**

```
SUITE sections=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24 assertions=2820 failed=0 exit=0
```

`sections=` is the field that catches a dropped section, `assertions=` the field that catches a section that ran but stopped asserting, and the exit code is trustworthy. Sections live in `Support/SectionRegistry.swift`'s `testSections()`, which `runSections(_:)` iterates and the `Task` awaits inside a `do`/`catch`, and `finishSuite` is the single exit path for every outcome — an unobserved throw, or a hang at the 30 s timeout, would otherwise idle out the `RunLoop` and exit **0**. A `WHOOPSY_SECTIONS` value naming a section that does not exist exits 1 rather than running nothing and reporting success.

`packageRoot()` in `Support/TestResourceURLs.swift` locates the bundle's CSVs from `#filePath`, and `#filePath` is whatever path is handed to `swiftc` — so the path must be **absolute**, or the **package root** it computes depends on the caller's cwd and §11–§21 fail with *"The bundled export is missing at …/Sources/…"*, which reads like a broken import and is only a wrong working directory. `scripts/test.sh` passes an absolute path; do not reintroduce a relative one. **The climb is a marker walk** — up until a directory holds both `Package.swift` and `Sources/Whoopsy` — rather than a count of `deletingLastPathComponent()` calls, because the count was correct only while the code sat at `Tests/WhoopsyTestRunner/main.swift`: the mirrored tree makes depth a property of the *file*, so a helper in `Support/` would climb three levels and land on `Tests/`. `WHOOPSY_PACKAGE_ROOT` is preferred when set, which `scripts/test.sh` exports beside the absolute path.

The runner has 24 sections and all 24 now execute. Keep it that way. A new section is one entry appended to `testSections()` in `Support/SectionRegistry.swift` — its own `id`, its title and its body — and **nothing existing moves**: the banner's denominator is the registry's own count and its numerator is the entry's own id.

**What each section asserts is not here — it is `docs/TESTING.md`, one entry per section** (§1–§13 and §16–§18 in one long entry, then §11–§15, §19–§20 and §22–§24 after it). This file keeps the mechanics of running the suite and the rules for adding to it. Read that file's entry for a section before you edit that section, because a block described there that stops running is a deleted guarantee rather than a refactor.

There is no test discovery, so a section that stops running looks exactly like one that passed — read the `sections=` and `assertions=` fields of the summary line, record them before you edit, and treat a drop in either as a deleted guarantee.

`ios/Tests/` holds `WhoopsyTestRunner/` and nothing else. The three XCTest files that used to sit beside it in `ios/Tests/WhoopsyTests/` — `CRCUtilsTests.swift`, `MathTests.swift` and `WhoopPacketDecoderTests.swift` — are **deleted**: no test target referenced them (`Package.swift` declares none, and `Whoopsy.xcodeproj` did not list them), so they were never compiled or run, and what they asserted had since stopped compiling against the current signatures. They were also actively misleading rather than merely inert — `CRCUtilsTests` pinned its checksums with `XCTAssertGreaterThanOrEqual(crc, 0)` on a `UInt8`, which is the degenerate form this file's BLE section names as passing for a wrong polynomial, byte order and input alike. Do not reintroduce an XCTest directory here: the suite is the hand-rolled runner, and a second, unbuilt test tree beside it reads as coverage that does not exist.

## Pages

The screens this app has, and where each one is wired. **`MainContainerView` is the only place a screen's view model is built** and `DIContainer` the only place its use cases come from, so a new page is an edit to those two files and never a new global.

This section is the **map** — what exists and how you reach it. The **architecture** is `docs/ARCHITECTURE.md`, and it is where to go next: **§2.C** for the presentation layer (every screen here, the two ring components, the design system, and the reasoning behind each screen's layout), **§2.A/§2.B** for the domain and data layers, **§3** for the data-flow diagram, **§1** for the layer rules. Nothing in this section restates any of it.

**The three tabs** — the `TabView` in `ios/Sources/Whoopsy/Presentation/Screens/MainContainerView.swift`:

| Tab | View | View model | Folder |
| :--- | :--- | :--- | :--- |
| Home | `HomeDashboardView` | `HomeViewModel` | `Screens/Home/` |
| Recovery | `RecoveryDashboardView` | `RecoveryViewModel` | `Screens/Recovery/` |
| More | `MoreView` (private, same file) | — | `MainContainerView.swift` |

**There were five tabs, and the Strain and Sleep tabs are gone on the user's instruction** (*"remove strain and sleep links in bottom navigation and their associated pages, not needed"*). **Their pages went and their view models did not**: `StrainDashboardView.swift` and `SleepDashboardView.swift` are deleted, while `StrainViewModel` and `SleepViewModel` are still built — twice each — for the detail pages Home's rings push. Both deleted files were a single `public struct` whose every rule lived in a `private var`, so nothing on either was assertable and the suite's `assertions=` count is **unmoved** by their removal, which was confirmed by running it rather than assumed. **Three components lost their last reader with them** and are kept unrendered: `MetricCardView`, `HeartRateZoneBar` and `HypnogramChartView` — not the `ActivityDurationBar` precedent, since the runner asserts none of the three, but kept because the sweep went out on two **pages** and these are shared components.

**Behind More** — one `NavigationLink` in `MoreView`'s `List`, on the `NavigationStack` `MoreView` owns:

| Row | View | View model | Folder |
| :--- | :--- | :--- | :--- |
| Settings | `SettingsDashboardView` — the Anonymous diagnostics toggle and its caption, and **nothing else** | `SettingsViewModel` | `Screens/Settings/` |

**That list held four rows and the user removed three of them, one instruction at a time** — Profile, then Device, then one more whose page, view model and use case behind it are all **deleted**, so there is no verdict to carry for it below: nothing remains reachable and there is nothing left to reopen. **Each removal left the page reachable from somewhere else or deleted it, and which of the two happened is the thing to check before adding a row back.** The one-line verdicts, with the reasoning in `docs/PAGES.md`:

- **Profile** moved to Home's day-bar row, where it is now the page's only door. `MoreView`'s `ProfileViewModel` property is gone with the row.
- **Device** is Home's status badge, and only that. `MoreView`'s `DeviceViewModel` property went with it, though the view model itself is still built on `MainContainerView` for the badge. The lesson the row taught survives it: a `NavigationLink`'s destination closure is re-evaluated on every push, so a view model built inside one is a fresh instance per push — which is why both pages are handed a stored instance rather than constructed at the destination.
- **The imports and the export left this page without a row being removed**, which is the one entry here that is not a removal. `More → Settings` still lists `Settings`, and what is behind it is the Anonymous diagnostics toggle alone: the Apple Health sync, the WHOOP and Zero fasting imports and the JSON + CSV export all moved one tab deeper, onto the profile page's `LOGS` pane. **The row survives and the page is one switch** — do not read the shrunk page as the row outliving its purpose, and do not move the toggle across to "finish" the sweep: `LOGS` is about where a history comes from and goes, and this is a statement about the app.

**The prose behind each entry here — the instruction behind the page, the measurements that corrected it, and the trap a screen modelled on the wrong neighbour hits — is `docs/PAGES.md`.** Each entry there is headed by the same bolded words as the paragraph it came from here.

**Reached from Home**, which owns a `NavigationStack` of its own:

| From | Opens | View model |
| :--- | :--- | :--- |
| the profile control, at the *leading* end of the day-bar row | `ProfileDashboardView` — the page's **only** route, since More's row was removed. **Three tabbed panes**: `BIOMETRICS`, `LOGS`, `STORAGE`, the last of which is the sync's own pane — a `DEVICE STORAGE │ WHOOPSY SYNC API` switch over the seven resources that move, and the span they move over | the same `ProfileViewModel`, built in `MainContainerView`, **beside a `LocalDataViewModel`** for the `LOGS` pane **and a `SyncStorageViewModel`** for `STORAGE` |
| the status badge | `DeviceSettingsView` — the page's **only** route, since More's row was removed | the same `DeviceViewModel`, built in `MainContainerView` |
| the sleep ring | `SleepDetailView` | a second `SleepViewModel` |
| the `SLEEP` row on the ACTIVITIES card | `SleepDetailView` — the same page the ring opens, off one `sleepDetail` expression | the same second `SleepViewModel` |
| the recovery ring | `RecoveryDetailView` | a second `RecoveryViewModel` |
| the strain ring | `StrainDetailView` | a second `StrainViewModel` |
| an activity row on the ACTIVITIES card | `ActivityDetailView` | `ActivityDetailViewModel`, built in `MainContainerView` from the tapped session |
| the day bar's title | the month calendar — an overlay, not a page | read off `HomeViewModel.monthTiers` |
| Home's `+` — on **every** day | the activity menu — an overlay, not a page | read off `ActivityMenu.entries(on:now:recording:)`, which withholds `START ACTIVITY` alone — on every day but today, and while anything is already recording |
| the menu's `ADD ACTIVITY` — on **every** day, including days when a session records | `AddActivitySheet` — the app's third `.sheet`, constructed around an `AddActivityDraft` on the day being viewed | — the draft writes a `WorkoutSession` carrying `manual` and no measurement, so it needs no view model of its own; `HomeViewModel.saveActivity(_:on:)` saves it and merges it into Home's day |
| the menu's `START ACTIVITY` | `ActivityPickerView` | — it writes a `Binding<String?>`; the choice is what starts the session |
| the menu's `ADD RECEPTIVE INACTIVITY` | `ReceptiveInactivitySheet` — one of the app's three `.sheet`s, opened in **add** mode on an empty draft | — it writes a `ReceptiveInactivityDraft` onto the day being viewed, whose `NAME` row opens the picker and whose `NOTE` field is typed in place, so it needs no view model of its own |
| the sheet's `NAME` row | `ReceptiveInactivityPickerView` | — it writes a `Binding<String?>`, exactly as `ActivityPickerView` does |
| the picker's choice — `Fast` starts a fast and pushes nothing | `LiveSessionView` | `LiveSessionUseCase`, built in `DIContainer` and held for the process |
| the recording bar — drawn only while a session is running | `LiveSessionView`, or `ActivityDetailView`'s fasting layout for a fast | the same `LiveSessionUseCase` |
| a row on the `RECEPTIVE INACTIVITIES` card | `ReceptiveInactivitySheet` — the same sheet in **edit** mode, which is where its `DELETE` lives | read off `HomeViewModel.receptiveInactivities` |

Three things on this map are decisions rather than accidents, and each is a trap when a new screen is modelled on the wrong neighbour:

- **`RecoveryDetailView` is drawn twice, from two view models.** The Recovery tab wraps it with `Date()`; Home's recovery ring pushes it seeded with the day on screen. It owns no `NavigationStack` and no stepper, so the pushed copy is the only route to a past day on that screen — and one shared view model would let paging either copy move the other's day.
- **`SleepDetailView` and `StrainDetailView` used to be the *other* screens, and they are now the only ones.** Each was the pushed page beside a tab that drew a different screen — `SleepDashboardView` and `StrainDashboardView`, separate `struct`s with their own `NavigationStack`s sharing no definition with the detail page. **Both tabs are deleted, so nothing is folded in either direction and no four elements were rescued**: Home's sleep ring and the `SLEEP` row are now the only route to a night, and Home's strain ring the only route to a day's strain. The rule those tabs were the example of still holds for the screens that remain — **a tab and the detail page it pushes share no definition** — and `RecoveryDetailView` is still the one screen where the tab *is* a wrapper around the pushed page.
- **A pushed page owns no `NavigationStack` and takes its day as a plain `let`** — `RecoveryDetailView`, `SleepDetailView` and `StrainDetailView` are that shape: the pushing screen supplies the chrome and the day, and a plain `let` is what keeps a re-render of Home behind the push from moving the day being shown. Every screen that *is* a tab owns its own stack instead.

**Adding a page**: build its view model in `MainContainerView` out of `DIContainer`'s use cases, wire the navigation where it is opened, and add its row to the table above.

## Architecture

Four layers under `ios/Sources/Whoopsy/`, with a strict one-way dependency rule (verified: `Domain/` imports only `Foundation`; `Core/` adds only `os.log`; `Presentation/` imports no GRDB or CoreBluetooth):

```
Presentation  (SwiftUI + @Observable ViewModels)   →  depends on DIContainer
Domain        (Entities, UseCases, Repository protocols)  ←  implemented by Data
Data          (BLE, GRDB persistence, HealthKit adapter, exporters, HTTP client + cloud sync)
Core          (HRV/Strain/Stress math, logging, extensions)
```

- **`Domain/Repositories/*`** are protocols only. Concrete implementations live in `Data/Persistence/Repositories/` — and the cloud sync adds **eleven** more protocols to that same directory, none of them a repository over a day: `CloudSync` (the port to a server, **nineteen methods covering all seven resources**), the seven `*SyncStore`s — `RecoverySyncStore`, `WorkoutSyncStore`, `StrainSyncStore`, `SleepSyncStore`, `StepCountSyncStore`, `ReceptiveInactivitySyncStore`, `UserProfileSyncStore` (record-shaped doors into the seven tables, implemented by `LocalDatabaseManager` as bare extensions) — plus `SyncSettingsRepository`, `SyncKeyStore` and `SyncStatus`.
- **`ios/Sources/Whoopsy/App/DependencyInjection/DIContainer.swift`** is the single wiring point. `DIContainer.shared` uses real BLE; `DIContainer.preview` uses `WhoopMockBLEManager`. `ios/App/iOS/WhoopsyApp.swift` picks `preview` when `XCODE_RUNNING_FOR_PREVIEWS=1`. Use cases are constructor-injected; there are no singletons below the container except `LocalDatabaseManager.shared`.
- **Data flow**: `WhoopBLEManager` → `WhoopPacketDecoder` (0xAA framing) → `BiometricRepository` → `LocalDatabaseManager` (GRDB) → `StreamBiometricsUseCase` / `Calculate*UseCase` → `@Observable` ViewModel → SwiftUI. Two further inputs write into the same tables through the same repositories: `HealthKitStoreClient` → `HealthKitImporter`, and `WhoopExportParser` → `WhoopExportImporter` for a bundled WHOOP data export.
- **`Data/Import/*` is the only WHOOP-export seam**, and it is not a sync. It reads a CSV that shipped inside the app bundle, it runs only when the user taps the button on the profile page's `LOGS` pane (it was `More → Settings` until that surface moved), and it exists so a fresh install can show history that predates it. `WhoopExportParser` produces a plain `Sendable` row of optionals and decides nothing; `WhoopExportImporter` does the day-keying and the scoring. Unlike the other two inputs, it does not compute Strain — see the gotcha below.
- **`Data/Health/*` is the only HealthKit seam.** `HealthStoreClient` is the protocol the importer depends on; its value types are plain `Sendable` structs and it deliberately does **not** `import HealthKit`, which is what lets the import be tested with a fixture store and no device. `HealthKitStoreClient` is the real actor behind it. It has **one** read shape, `quantitySamples(_:from:to:)`, for the individual readings on a `HealthQuantityMetric` (HRV, resting heart rate). **Adding a case to `HealthQuantityMetric` also adds it to `readTypes`**, so the consent prompt grows with it, and removing one shrinks it. `FixtureHealthStore` in the runner answers **per metric in a `switch`**, deliberately: a two-way ternary sends every case that is not HRV to the resting-heart-rate array, so a new case would silently answer one quantity's query with another's readings — a fixture inventing a measurement of the wrong kind.
- **The cloud sync is the only seam that talks to a network, and it is the only *bidirectional* one.** Four things about its shape are decisions. **`CloudSync` is one port for all seven resources** and its subject is the database rather than a day or a session — a sibling `WorkoutCloudSync` would double the ports, double `UnconfiguredCloudSync`'s sentences and put a second conformance on every spy, for a separation the app does not have (one base URL, one credential, one connection). **What all seven share is one settings record** — `UserDefaultsSyncSettingsRepository`'s single namespace — because a destination and a span belong to the install rather than to a resource, and that is what makes the pane's control a switch rather than a per-resource mode. **`Data/Networking/` holds the HTTP client and the seven wire mappers** — `WhoopsyAPIClient` (the only HTTP surface: the two headers it sets, `userIDHeader` and the deployment's `Authorization: Bearer` token, and the two `Info.plist` keys behind them, `baseURLInfoKey`/`configuredBaseURL(bundle:)` and `tokenInfoKey`/`configuredToken(bundle:)`) and `RecoveryWireMapper` / `WorkoutWireMapper` / `StrainWireMapper` / `SleepWireMapper` / `StepCountWireMapper` / `ReceptiveInactivityWireMapper` / `UserProfileWireMapper`, which are the **two-names rule** made structural: a synced row takes the *record's* own property names verbatim, so row ↔ record is a field-for-field copy and a mapper is the one place in the iOS half where a wire name is written down. **`CloudRecoveryRepository` is the first of seven decorators** — `CloudSleepRepository` / `CloudStrainRepository` / `CloudWorkoutRepository` / `CloudStepRepository` / `CloudReceptiveInactivityRepository` / `CloudUserProfileRepository` beside it, one per resource — each wrapping a local repository: a save writes this phone first and, when the destination is the API, mirrors the row to the database; a read answers from this phone first and reaches the database only on a miss, and a read the database could not answer still returns the local copy while marking the day in `SyncStatus`. `DIContainer` installs it **only when a base URL and the deployment's token both exist**, while the engine is built in both arms — the decorator is a hop in the read path and a build with no database behind it should not pay an `await` for a connection that will never be made, whereas nothing runs the engine unless a user presses a button. **The pair is one decision**: the Worker refuses every `/v1` request until its own `SYNC_API_TOKEN` is set, so a hostname with no token is an install that opens a socket on every read to collect a `401`, and `UnconfiguredCloudSync` reports whichever half is missing by name. **A fresh clone is inert and the deployed build is not.** `Whoopsy.xcconfig` assigns both keys empty and the gitignored `Whoopsy.local.xcconfig` that `#include?`s over them is not in the tree, so a clone's `Info.plist` expands both to empty strings and `DIContainer` reaches `UnconfiguredCloudSync` (every method throws `.unreachable`, the one error a caller may degrade over). **The Worker has been deployed since 2026-10-07** and a build with both keys set really does read and write it — proven on the wire rather than inferred, and that is the state the owner's own build runs in. Either way a fresh install has drawn no span, so the run button is greyed until the user draws one. **There are two credentials on the wire and they are different kinds of thing.** The deployment's shared secret rides in `Authorization: Bearer` and is what the Worker checks first: one value for the whole deployment, compiled into the app and extractable from the binary, so it stops scanners, bots and drive-by requests against a discoverable `*.workers.dev` hostname and does **not** authenticate a person. `X-Whoopsy-User-Id` is checked second and is not a credential at all — it is a partition name, and what makes it unguessable is its length rather than anything the server verifies about it. `KeychainSyncKeyStore` mints those 32 random bytes on first read into the app's own Keychain entry, the Worker stores `sha256` of it and never the key, and there is no signature, expiry or revocation — anyone holding the string can read and write its rows, and anyone holding the deployment secret can read every partition in it. **Reading is a write on the first call**, so a conforming store must be single-flight across the whole read-or-mint; two concurrent first-reads that both find nothing would mint two keys and orphan a partition the app could no longer reach. **All seven read and write now.** Every decorator mirrors a save to the database when the destination is the API and falls back to the database on a local miss, so "sync API selected" both backs the data up and restores it. **The destination is kept in the Keychain** (`KeychainDestinationStore`) rather than in `UserDefaults`, so it survives an uninstall and a reinstall restores `.cloud` instead of resetting to `.device`.
- **Views get their ViewModel built in `MainContainerView`** — adding a screen means wiring its use cases through `DIContainer` and `MainContainerView`, not reaching for a global. The tab and push inventory is `## Pages` above rather than a second list here.
- **`Presentation/DesignSystem/Theme.swift`** holds all color tokens (recovery green/yellow/red, strain gradient, sleep stage colors, and the Home surfaces `homeBackground`/`homeCard`/`ringTrack`/`sleepPerformance`/`strainRing`). Don't hardcode colors in views.
- **There are two ring components and they are not interchangeable.** `GaugeRingView` (gradient, glow, label inside) is what Strain, Sleep and Recovery use. `MetricRingView` is Home's flat counterpart and takes its value as an **optional** `String?` so a dash cannot arrive with a fill attached. Changing one must not move the other. **A `GaugeRingView` label is sized as a fraction of `size` and can outgrow the chord it sits on, and nothing in this repo can see it** — a word wider than that chord crosses the stroke while every build and the whole suite stay green. `labelScale` is the defaulted parameter a caller with a long label passes; `LiveSessionView` is the one caller that passes one, and the shared `0.09` is what the other five draw and is not to be moved to suit it. Measure the width against `sqrt(innerRadius² − dy²)`, where `dy` is the label box's own lower edge below the ring's centre, rather than checking the picture. `labelFirst` is the second such parameter and it draws the label **above** the score rather than below, which five of the six call sites do not; it is free clearance rather than a risk, because the chord `sqrt(innerRadius² − dy²)` is *widest* at the ring's centre line, so moving a label up can only widen the chord it has to fit and never narrow it.
- **The Recovery ring is drawn in the day's tier colour, and there is exactly one definition of the tiers and one mapping to colour.** The boundaries (green 67–100, yellow 34–66, red 0–33; spec in `docs/ALGORITHMS.md` §"Recovery Tiers") are written down once, in `RecoveryState.init(score:)` — `RecoveryMetric.state` forwards to it, and nothing holds a second copy: a screen comparing against its own `>= 67` is precisely the defect this rule exists to prevent. `RecoveryState.color` in `Presentation/DesignSystem/RecoveryState+Extensions.swift` is the only place a tier becomes a `Color`; Home's ring and the Recovery tab's gauge, HRV card and trend chart all read through it. It cannot be a property on the enum (Domain imports only `Foundation`) and it must not be re-written per screen: two screens that each tier a score independently can draw the same 20% morning green on one and red on the other. A tier is computed from the **score**, so a `score: 0` placeholder reports `.red` — which is why the drawing gates on `hasMeasurement` and an unmeasured day renders `—` with no fill rather than as a hard 0% red ring. The rule is general and the repo now holds a second instance of it: `SleepStageType.color` in `Presentation/DesignSystem/SleepStageType+Extensions.swift` is the one stage-to-`Color` mapping, lifted out of `HypnogramChartView` when the sleep detail screen's typical-range card needed the same four answers. A fourth stage added to the enum, or a screen that wants "a slightly different deep purple", goes through that file or not at all. A third instance turns a *string* into a drawing rather than a value into a colour: `ActivityGlyph.mark(for:)` in `Presentation/DesignSystem/ActivityGlyph.swift` is the one name-to-mark mapping behind Home's `ACTIVITIES` row icons, and it returns a `Drawing` — a `primary` symbol plus an optional `secondary` — rather than a bare name, because `Fast` draws two (`fork.knife` then `timer`). **`symbol(for:)` no longer exists and must not be reintroduced**: with no accessor handing back a single string, a composite's truncation cannot be drawn by accident. Four things about it are traps. A wrong symbol name is **not** an error — it draws an empty chip, so a typo is invisible to the compiler and to any screenshot of a different row, and §17's "every symbol is non-empty" assertion is the only thing that sees it. And that assertion cannot see the second one: **every symbol must exist on the deployment target**, which is iOS 17.0, so `figure.ice.skating`, `figure.indoor.rowing`, `figure.indoor.soccer`, `figure.outdoor.rowing` and `figure.field.hockey` all return non-empty strings and all draw nothing on this build. Check a new name against `name_availability.plist` before adding it. And **a composite needs more room than a single symbol**: `drawnWidth` bounds it at `2 × size × compositeScale × assumedSymbolWidthRatio + size × compositeSpacingRatio`, which is 33.45pt at Home's 15pt chip (fits its 38pt frame), 40.14pt at the edit sheet's 18pt (fits `listGutter`'s 42) and 84.7pt at the detail header's 38pt — which is why that header's frame is a `minWidth: 48` rather than a `width`, and why the four names whose symbol is wider than 48pt now grow it too. A fourth instance is a value into a colour again, and it is the first whose mapping is **two answers rather than one**: `FastingZone.color` in `Presentation/DesignSystem/FastingZone+Extensions.swift` is the one fasting-zone-to-`Color` mapping behind the pill Home's `ACTIVITIES` card draws, and its sibling `FastingZone.inkDepth` is the one answer to *which of the two inks* the letters take on that fill. **The split is what makes the user's decision assertable**, and it is the same trap as above: a test comparing `inkColor` against `Theme.zonePillInkOnPale` proves only that the switch returns the arm it returns, while `inkDepth` states *which fills are pale* as a plain enum naming no token — so §20 pins all five, which is the one thing a screenshot of a single zone cannot see. The five fills are the user's own specification and are deliberately not the verdict scale: `recoveryRed` and `recoveryYellow` mean *worse* and *unchanged* on a recovery ring, and a zone is a category rather than a score. All seven tokens — the five fills plus `zonePillInkOnDeep`/`zonePillInkOnPale` — are `Theme`'s like every other colour, and the measured basis for the ink choice is recorded in the fill tokens' own doc comment rather than left as a preference.

### Persistent gotchas

**Every trap this repo has already hit once.** The rule is here; the evidence is not — the measurements, the derivations and the history behind each entry are `docs/GOTCHAS.md` under the same bolded words, so grep the headline rather than reading that file whole.

- **A shipped migration is frozen.**
- **A `[Double]` property on a `Codable` record is a JSON-encoded `.text` column, and `Array` is not a `DatabaseValueConvertible`.**
- **The test suite is not hermetic, but only in the migration sense — §6 opens the developer's real database, and does not write rows to it.**
- **The BLE streams are multicast.**
- **The reconnect is an outstanding `connect`, never a timer.**
- **A connected peripheral is not a producing strap, and the keep-alive's silence window must not count time the app spent suspended.**
- **A sample row's `timestamp` is an arrival instant, not a beat time.**
- **The proprietary BLE path was unvalidated until it was first run; on one 5.0 it is now validated end to end, and the 4.0 remains spec-only.**
- **The drain is implemented and its ACK loop is not optional — that ordering is the whole rule.**
- **The oxygen candidate is instrumentation, and no screen or row may read it as a measurement.**
- **A drained record's timestamp is verified as a field and unverified as a value, and the failure files history onto a wrong day rather than onto no day.**
- **Which strap is connected is a stored choice, and a guess must never override it.**
- **Column naming differs per table, and `CodingKeys` is the only thing that decides it.**
- **`naps` follows `workouts`, not `sleeps`, and a nap's day is its onset while a night's is its wake.**
- **`receptive_inactivities` has one read and no `covering:` sibling, and its day comes from the screen rather than from its own optional time.**
- **`workouts` breaks the day-key rule, and it must stay broken.**
- **There are two reads over that `date` column, they answer different questions, and they must not be merged.**
- **A half-open bound wants `Date.startOfNextDay`, never `Date.endOfDay`, and the difference is one second that is invisible and load-bearing.**
- **A destination is a switch and not a mode, and nothing anywhere removes a row — that is the user's own ruling.**
- **`workouts` is an aggregate of three tables on the wire, and three consequences of that are load-bearing.**
- **The sync's chunking terminates because of an equality, and the workouts half's method names carry the resource because Swift overloads on name + labels.**
- **The two absence codes on the wire are different words, and they are read by name.**
- **`SyncKeyStore`'s read is a write on the first call, and `SyncStatusLog` keeps its two day-sets disjoint — both are `actor`s for the same class of reason.**
- **`WorkoutSession`'s three measured fields are optional, and a fast is the reason.**
- **`Fast` is one name everywhere, and it was renamed from `Fasting` for the picker's sake.**
- **The export's day skip excludes fasts and hand-added sessions, and that exclusion is what makes the imports order-independent.**
- **`WhoopDevice.batteryPercentage` is not optional and defaults to `100`.**
- **Steps come from the strap and from nothing else, and `stepCounts` deliberately has no `source` column.**
- **§6's motion layouts are frame-absolute, and the payload origin differs per generation.**
- **The scoring window is the last 30 days that *have rows*, and a mean is not a baseline until the window held some.**
- **`MetricChange` draws a comparison on the *formatted* pair, not the raw one, and its verdict is three states rather than two.**
- **A week's baseline is a mean over measured slots, and HRV's is narrowed to one metric first.**
- **Stress Monitor is a calibration, not a recovery of WHOOP's function.**
- **The Stress Monitor chart follows three rules that are not styling choices.**
- **Home's collapsing rings header is a `PreferenceKey`, and it writes no `@State`.**
- **A failing migration crashes the app at launch.**
- **Day-keyed writes must be snapped to `date.startOfDay`.**
- **A window computed by adding hours to midnight lands on the wrong clock time, and the failure is a plausible number rather than an error.**
- **A day-keyed screen must READ.**
- **`getXHistory(days:)` windows back from `Date()` unless you pass `endingOn:`.**
- **The calendar's day colours are a map, and a day absent from it means no measurement.**
- **The month read's window is `days: <the span between the month's own bounds>, endingOn: <the month's last day>`.**
- **`.toolbar(_:for: .tabBar)` is unavailable on macOS, and Home is built for both.**
- **It hides the tab bar only from the tab's *root* view, never from a pushed destination — and the failure is silent.**
- **A saved row is not a drawn one: a pop re-fires no `.task`, so the writer's caller has to hand the row to the screen behind it.**
- **`ActivityKit` is unavailable on macOS, and the Live Activity is the family's widest member — three separate traps, none visible to `swift build`.**
- **`Package.swift` points the executable at `path: "app"`, which on a case-insensitive filesystem is `App/`, and SwiftPM compiles a target's path recursively.**
- **A Live Activity outlives the process that requested it, and nothing can adopt one.**
- **The route's GPS is the Live Activity's sibling: a capability seam whose `start()`/`stop()` must land on one instance, and whose four settings are each a way a route comes out wrong.**
- **The offline map is one object split into two halves, and the split is the layer rule rather than a design preference.**
- **The offline card keeps its drawing in `Presentation` and hands `ios/App/Map/` a single `AnyView`, and that is the whole consequence of the exclusion above.**
- **`OfflineMapServing.state(for:)` is synchronous, and nothing about Mapbox is.**
- **The Mapbox credential is two tokens with two different homes, and neither is in this tree.**
- **The remote diagnostics path is one seam and it is metadata-only; the Sentry edge lives in the app target, not the package.**
- **An activity's zone percentages divide by measured time, not by a sample count, and the five bands must not be made to sum to 100.**
- **`UserProfile` carries eleven fields and `user_profiles` stores seven of them, so every unbacked one is a number this app invented — and a body metric is the dangerous kind.**
- **`Text` prints Markdown asterisks literally unless it is handed a `LocalizedStringKey`.**
- **Home's calendar is an overlay, not a `.sheet`, and the difference is load-bearing.**
- **`SleepSession`'s `Equatable` cannot compare two reads of the same night.**
- **SDNN and RMSSD are different quantities and never share a baseline.**
- **The within-sleep stress model's baseline is drawn from prior *nights*, and reading it from days instead is the mistake that looks like success.**
- **A fixture that pins a z-score must account for `BaselineStatisticsMath`'s coefficient-of-variation floor.**
- **The export's day key is `startOfDay(Wake onset)`, and that is the app's own convention.**
- **The importer's `calendar:` parameter cannot override the database's day-key snap.**
- **24 export cycles have a `Day Strain` but no wake onset.**
- **A strap night's Sleep Need is computed; an imported night's is WHOOP's own, and the two must not be crossed.**
- **The sleep detail screen's card is titled `HOURS OF SLEEP`, and that title is a figure the card prints rather than a label on the chart beneath it.**
- **A mark positioned by `.offset` inside an `overlay` must sit in an explicit `ZStack(alignment: .leading)` with an explicit full-width frame — a bare `ForEach` there is centred in a box sized to its widest sibling.**
- **A `ScrollView` whose content holds nothing flexible lays out at its content's width, so a page whose only child is a fixed-size drawing needs `.frame(maxWidth: .infinity)` on the scroll view or its background paints a column.**
- **The sleep-consistency chart holds two minute scales, and the bridge between them is one function that must not be inlined.**
- **The consistency card's legend says `AVG`, not `OPTIMAL`.**
- **`sleeps.respiratory_rate` and `sleeps.sleep_debt` are two-producer columns, and the model that computes one of the producers is unvalidatable.**
- **Every imported `strains` row holds WHOOP's own score, not this app's.**
- **WHOOP's HRV is classified as RMSSD, and that is an inference.**
- **Importing recomputes Recovery rather than storing WHOOP's.**
- **HealthKit availability is a runtime question.**
- **HealthKit never discloses read-permission status.**
- **Five files are bundled and read through `Bundle.module` — three CSVs and two JSONs.**
- **`simctl launch` on an already-running app does not relaunch it, so a screenshot can show the previous build's code.**
- **Filenames lie.**
- **Repositories answer from local storage and nothing else.**
- **A day that was not measured gets no row, and the same test must be on both sides of the write.**
- **Absence is the same shape in all four metrics, and that is the point.**
- **Sleep has no placeholder: an unclassifiable night is an absent row.**
- **A strap night's span is *detected*, and the run is measured in wall time — never in epoch count.**
- **A channel the strap has no sensor for is `nil`, not a plausible constant.**
- **A fast's detail page draws a second layout, and everything on it is derived on read — no migration and no new column.**
- **A sentence that has to name *which* of two things is missing needs the missing thing, not a `Bool`.**
- **A D1 migration file must not end on a comment, and the failure does not name the file.**
- **The Worker's local database and its test database are two different databases, and only one of them is built for you.**

### Reference docs

Keep these in sync with the code — they are the spec for the non-obvious math and wire format. They live in `docs/`, and `CLAUDE.md` and `README.md` are the only two Markdown files left at the repo root:

- `docs/ALGORITHMS.md` — RMSSD/SDNN and the never-mix rule, ectopic-beat rejection, the Borg-scale exponential Strain model (0–21) with HRR zone weights, a weight-1 low-intensity band above resting, and two fitted curves (day `k ≈ 1.085e-5`; session `k = 0.005`, `L^0.55`), why HealthKit cannot feed Strain, the Recovery z-score formula with its guards and green/yellow/red tiers, sleep staging, and the Sleep Need model with the fitted strain coefficient and the three WHOOP inputs it deliberately omits. Implemented in `Core/Math/` and `Domain/UseCases/RecoveryScoring.swift`.
- `docs/BLE_PROTOCOL.md` — the wire format for all three straps (4.0, 5.0, 5.0 MG), which do **not** share
  one: two envelopes, two header CRCs (CRC8 / CRC16-Modbus), two record origins. The packet-type
  numbering **is** shared — the two references write the same eight roles in hex and in decimal, and
  all eight correspond exactly — so the envelope is what discriminates a generation, never the type
  byte. Carries the GATT UUIDs, the historical flash-drain protocol including the record header
  that holds a real unix timestamp, the two heart-rate producers, and a tag on every claim saying
  whether it came from an open-source reference or from this codebase. **Nothing in it is captured on
  this project's own hardware.** It is a spec rather than a changelog, so where it and `Data/BLE/`
  stand in relation to each other is carried by its two implementation-status tables — §3's for the
  handshake and the transmitted opcode set, §4's for the drain — and not by the framing sections.
  Read both before touching the sync path. Its §2.1 carries the four published checksum vectors,
  which the suite now asserts in place; both envelopes in `Data/BLE/` match §2, and the 5.0/MG pair
  is implemented for **reading** and refused for **writing** — §2's single-decoder section and §3's
  implementation status carry that split, and the two halves have different reasons.
- `docs/PATENTS.md` — what WHOOP's filings actually disclose about the mathematics behind Recovery, Strain,
  Sleep, Stress and VO₂ max, tagged `[claimed]` / `[described]` / `[not disclosed]` / `[pending]` /
  `[app]`, because **a claimed range is not an implemented constant**. Its organising finding: for most
  metrics WHOOP publishes the shape *and anchors it to an input this app cannot measure* — the user's
  anaerobic and creatine-phosphate thresholds for Strain, the end of the last slow-wave episode for
  recovery HRV, a trained classifier for staging — so the app's substitutes are forced rather than
  lazy. It is also where the Recovery tier boundaries (WHOOP's 66/33) and the undisclosed sleep-need
  sigmoid are recorded. **It is a record, not a changelog** — §8 lists what it argues should change and
  none of it has been applied. Read it before claiming any constant in `docs/ALGORITHMS.md` is WHOOP's.
- `docs/ARCHITECTURE.md` — layer philosophy, folder layout, and the data-flow diagram covering both the strap and HealthKit inputs.
- `docs/TODO.md` — one line per column of each bundled CSV: whether a named symbol consumes it, where it goes, and what the rest would take. Measured, and re-measured by `csv-field-coverage`. It is not a wish list — the uncovered lines carry the reason they are uncovered, and three of them (`Recovery score %`, `Sleep performance %`, `Sleep debt (min)`) are **decisions not to cover**, which is why the file says so in bold rather than leaving them to look like oversights.

Nine skills under `.claude/skills/` route work that is easy to get wrong:

- **`create-data-files`** — on a fresh clone that will not build, or after a bundled resource reports
  `File not found` / the import throws `.notBundled`. It runs `scripts/create-data-files.sh`, which
  writes placeholders for the five files `Package.swift` declares as resources — and only those five,
  so `journal_entries.csv` is deliberately not among them. It is built so it **cannot overwrite a file
  holding data**: the export is the only copy, and a script that could replace it is a script that
  could lose it.

- **`architecture-doc-sync`** — when you change anything under `ios/Sources/Whoopsy/`, it routes the
  change to the docs that must move with it.
- **`api-versioning`** — when the Worker's API version or its `/v1` address changes, or when a route,
  DTO, schema or bound changes in a way that might force one. It walks the coupled sites — `API_VERSION`
  and `API_PREFIX` in `backend/src/openapi.ts`, the `version` in `backend/package.json`, the eight
  mounts, the `version` on `GET /health`, the **generated** `shared/openapi.json`, the client's seven
  paths in `SyncedResource.swift`, and `docs/BACKEND.md` § Versioning. Its one hard rule is that **a
  change is a version event only when it forces a consumer to alter code** — a rewrite behind an
  unchanged shape is not one, however large it is.
- **`new-page`** — when adding a page under `ios/Sources/Whoopsy/Presentation/Screens/`: a new tab, a
  pushed detail screen, or an overlay reached from an existing one. It walks the three places a page
  must be wired — its view model in `MainContainerView`, its use cases in `DIContainer`, and its row
  in the `## Pages` table above — so that a new screen never reaches for a global.
- **`ui-regression-guard`** — when you add a screen, a UI component, or a new value to an existing
  view, or change anything shared (`GaugeRingView`, `MetricRingView`, `DayNavigationBar`, `Theme`).
  It carries the regression classes this app has actually hit — fabricated values, overwritten
  day-keyed history, unsnapped writes, frozen migrations, moved shared components — and the checks
  that catch them, including the ways a green build or a screenshot can lie.
- **`ui-data-provenance`** — before building any view that shows a number, chart, ring or tile, and
  whenever a mockup implies a figure this app should display. It establishes from the measured data
  whether that figure has a producer at all — the export carries no R-R series, no step counts, and
  ends 2026-08-22 — and lists the fabrication classes this repo has shipped, including a domain
  field that is scored but never persisted and is rendered as "At baseline" rather than a dash.
- **`evaluate-mockup`** — when a chart mockup, a reference screenshot or a feature requirement
  implies a figure this app should draw, and before any view code exists. It is `ui-data-provenance`'s
  question asked of a picture rather than of a view: whether the visualisation is renderable from
  local data at all, which of its fields cannot be populated and why, and what grounds each
  substitution — `docs/PATENTS.md` rather than a guess.
- **`csv-field-coverage`** — when an export column gains or loses a consumer: a field added to
  `WhoopExportRow`, a column on a record, a new model, a screen reading an imported value, or a CSV
  bundled or unbundled. It owns `docs/TODO.md` and carries the command that re-measures it. Its one hard
  rule is that **a parsed column is not a covered column** — `asleepMinutes` and `inBedMinutes` sit
  on every imported row and are read by nothing.
- **`whoop-investigator`** — when the question is what WHOOP actually does: how a metric is computed,
  or whether one of this app's constants, thresholds or protocol claims survives contact with the
  open-source references, the reverse-engineered specs and WHOOP's own filings. It retrieves the
  sources and separates what is reproduced from what is this app's substitution — the research half
  of a change whose other half is an `docs/ALGORITHMS.md` or `docs/BLE_PROTOCOL.md` edit.

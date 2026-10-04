# Whoopsy

A 100% offline iOS companion for WHOOP 4.0 / 5.0 / 5.0 MG straps. Your strap, your data, your
device — no subscription, no account, no analytics.

The hardware is excellent. The membership is the part you rent forever: your own physiology is
uploaded to someone else's servers and handed back to you one screen at a time, for as long as you
keep paying. Whoopsy talks to the same strap directly over Bluetooth, decodes the packets on-device,
stores everything in a local SQLite file, and works out Recovery, Strain and Sleep itself.

**There is no network code of this app's own, and no backend behind it.** Not "we don't send much" —
no `URLSession`, no HTTP client, no server. `Package.swift` declares exactly one dependency,
GRDB.swift, and it is a SQLite library.

**The repository does now contain a `backend/`, and it changes none of that.** It is the folder a
future sync will be built in: a Cloudflare Worker skeleton with declared bindings, no routes, and an
entry point whose every response is `501 Not Implemented`. Nothing under `ios/` reaches it, it has
never been deployed, and it is not a service this app talks to — read it as a stated intention rather
than as infrastructure. The sentence above is about the app that ships.

**One exception, and it is opt-in and off until you configure it.** The route card's offline map hands
its tile requests to Mapbox's SDK — a third-party binary the *Xcode target* links, because it is
iOS-only and this package also builds for macOS, so `Package.swift` could not carry it. It is off at
every layer until two tokens exist, and a build without them behaves exactly as it did before the
feature: no switch, no SDK, no request. See [§ Optional: the offline map](#optional-the-offline-map).

---

## Why

- **You own the data.** Everything lives in one SQLite file in the app's sandbox. Export it, back it
  up, delete it. There is no account to close and no server holding a copy.
- **No membership.** The app costs nothing to run because it costs nothing to operate. There is no
  backend to pay for.
- **No analytics, no telemetry, no crash reporting.** No engagement metrics, no feature flags, no
  device fingerprinting. Nothing is measured about you that you did not ask to be measured.
- **Transparent.** Every number traces to a formula in [`ALGORITHMS.md`](docs/ALGORITHMS.md), with its
  constants, its citations, and — where a constant is this project's own guess rather than a
  validated one — a plain statement that it is. Where a figure has no producer, the UI shows a dash
  rather than a plausible number.
- **Minimalist by design.** The interface follows WHOOP's own visual language: dark surfaces, one
  hero ring per screen, a small number of large numbers. Quiet where the data is quiet.

---

## Status — please read before you build

This is a working app with real engineering behind it, and it is **not yet usable on a physical
strap.** Being specific about that is more useful than a feature list:

- **The app has never run against real hardware.** The BLE protocol here is reverse-engineered from
  [`BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md). No strap has been connected, so nothing in the packet layer
  has been checked against a device.
- **Signing is not configured.** `DEVELOPMENT_TEAM` is empty and there is no certificate, so the
  Xcode project will not build to a device without you setting a team. The library and the simulator
  build fine.
- **Historical sync is implemented and has never run against a strap.** Both envelopes are built,
  inbound frames are checksum-verified, a frame split across several notifications is reassembled,
  and the drain now has its request (`0x16` on both generations), its per-batch ACK loop and a
  termination rule on `HISTORY_COMPLETE`, an idle window off the profile, or the live edge. What is
  still missing is a walk for the type-24 heart-rate record's own header — the *motion* layouts are
  walked, which is why a drained record reaches the step count and not a heart rate. See
  [`TODO.md` §5](docs/TODO.md).
- **A 5.0 can be written to, and what is unproven is whether it answers.** All three WHOOP models
  carry a transmitted opcode table now. The 5.0's command characteristic needs an authenticated SMP
  bond that nothing in this project establishes a third-party iOS app can create, so the device
  screen says that in as many words rather than calling the generation unsupported.
- **The import path is the well-exercised one.** Recovery, Strain and Sleep can all be computed from
  a WHOOP data export, and that path is covered end to end by the test suite.

What *is* solid: the domain model, the scoring maths, the persistence layer, the import pipeline, and
a 1803-assertion test runner that pins the behaviour of all of them.

---

## How it works

Four layers, one direction of dependency, in a single Swift module:

```
Presentation   SwiftUI + @Observable view models
     ↓
Domain         entities, use cases, repository protocols
     ↓
Data           BLE, GRDB persistence, HealthKit, export importer
     ↓
Core           HRV / Strain / Sleep / Stress maths
```

Three inputs write into the same local tables:

| Source | What it gives | Notes |
| :--- | :--- | :--- |
| **The strap**, over BLE | Live heart rate, R-R intervals, battery, and the day's steps off its own accelerometer | Requires a real device |
| **Apple Health** | Resting heart rate, HRV | Read-only, permission never disclosed by iOS |
| **A WHOOP export** | Full history: recovery inputs, sleep stages, strain | The path that makes a fresh install useful |

Everything downstream is computed on-device from stored rows. An imported day is **re-scored through
this app's own `RecoveryScoring`** rather than having WHOOP's percentage copied across, so one formula
covers the whole history instead of two models disagreeing on one chart.

---

## Screens

- **Home** — the day's three rings (Recovery, Strain, Sleep), a month calendar, and metric panels. Its
  activity rows push a detail page for that session: strain, steps, heart rate, and the five
  heart-rate zone rows, each compared against that activity's own recent history
- **Strain** — the day's cardiovascular load with heart-rate zone breakdown
- **Sleep** — last night's stages, efficiency, and the night's sleep need
- **Recovery** — the score, and the four figures it was computed from against their baselines
- **More** — coach insights, device management, settings and import

---

## Documentation

The docs are the spec, not a summary. They are written to be read by whoever touches this next —
including an AI assistant with no memory of the last session. They live in [`docs/`](docs/); this
file and `CLAUDE.md` are the only two left at the repo root.

| File | What it holds |
| :--- | :--- |
| [`TODO.md`](docs/TODO.md) | **The roadmap.** Outstanding work, per CSV column and per component, with the reason each item is still open. |
| [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) | **App design.** Layer rules, folder layout, component inventory, data-flow diagram. |
| [`ALGORITHMS.md`](docs/ALGORITHMS.md) | **The maths.** RMSSD/SDNN, the Strain model, the Recovery z-score, sleep staging, sleep need — with constants and citations. |
| [`BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md) | **Bluetooth.** GATT UUIDs for all three straps, both `0xAA` envelopes, CRC layout, handshake sequence. |
| [`CLAUDE.md`](CLAUDE.md) | **Working in this repo.** Build and test commands, and the hard-won gotchas that are not obvious from the code. Also the entry point for AI-assisted development. |

---

## Repository layout

Whoopsy is a monorepo with three parts, and only one of them is an app.

```
whoopsy/
├── ios/              the app — one SwiftPM package plus Whoopsy.xcodeproj
│   ├── Sources/      Whoopsy/ (the four layers) and WhoopsyLiveActivityKit/
│   ├── App/          Xcode-only sources: iOS/, Map/, LiveActivity/, Config/
│   └── Tests/        WhoopsyTestRunner/ — the hand-rolled 1803-assertion suite,
│                     mirroring Sources/Whoopsy/ file for file
├── backend/          a Cloudflare Worker (Hono · D1 · R2) — scaffolded, not implemented
├── shared/           openapi.json, the contract the two will agree on
├── docs/             the specs
└── Makefile  scripts/  tmp/  CLAUDE.md  README.md
```

**Everything the app is lives under `ios/`, and every command in this file is run from the repo
root.** `ios/` is a single SwiftPM package: `Package.swift` and `Whoopsy.xcodeproj` sit side by side
there, the project consuming the package product, and every path *inside* either of them is package-
or project-relative. That is why the app could move under `ios/` without a single source file
changing — and why the paths below carry the prefix while the ones inside the package do not.

**`backend/` holds no behaviour on purpose** — the note at the top of this file says why. It exists so
that the sync's shape is settled before its first route is written.

---

## Building

Requires Xcode 16+ and Swift 6.


### First: create the data files, or nothing will build

`ios/Sources/Whoopsy/Data/Resources/` holds **two producer directories**, one per app a file came out of,
and both are **gitignored.** What lived in `Whoop/` was one real person's physiological record —
recovery score, HRV, resting heart rate, skin temperature, blood oxygen, sleep staging, and free-text
journal notes — and it is not published. `ZeroFasting/` is ignored for the same reason and holds a
fasting tracker's history rather than a WHOOP export. **A fresh clone will not compile until you put
four files back** — every `.process(…)` entry in `Package.swift` is a build input, and a missing one
fails the build with `couldn't build … because of missing inputs`, not merely a warning.

| File | Needed? |
| :--- | :--- |
| `Whoop/physiological_cycles.csv` | **Required to build.** `Package.swift` bundles it and `WhoopExportImporter` reads it through `Bundle.module` |
| `Whoop/sleeps.csv` | **Required to build**, for the same reason — it is the second `.process(…)` entry. Read only for the **eight nap rows** it carries and nothing else |
| `Whoop/workouts.csv` | **Required to build**, for the same reason — the third `.process(…)` entry, and it is a build input like any other. §17/§19 of the suite also read it for its `HR Zone 1 %`…`5 %` block and its `Activity name` column, so the two zone rows and the activity-name path can only be exercised against a real one |
| `ZeroFasting/fasts.json` | **Required to build.** The fourth `.process(…)` entry, read by `ZeroFastingParser` through `Bundle.module` for the 170 fasts it carries. A placeholder of `{"fast_data": []}` is enough to compile and imports nothing |
| `Whoop/journal_entries.csv` | Not needed. Nothing bundles it and nothing reads it |

The three CSVs are validated as they are read, so a wrong-shaped one fails loudly instead of
importing a table of nils. The cycle file must carry `Cycle start time`, `Cycle timezone` and
`Wake onset`; the sleep file must carry those three **plus `Nap`**, and that column is the load-bearing
one — it is what tells the two files apart, so pointing the nap parser at the cycle file throws
`missingColumns(["Nap"])` rather than reading it, finding no naps, and reporting a clean import of
nothing. The workout file must carry `Cycle start time`, `Cycle timezone`, `Workout start time` and
`Workout end time`.

**If you have a WHOOP export**, drop **all three** of its CSVs — `physiological_cycles.csv`,
`sleeps.csv` and `workouts.csv` — into `ios/Sources/Whoopsy/Data/Resources/Whoop/`. Each has its own
import button under **Profile › LOGS › Whoop**, and the build needs all three whether or not you press
them.

**If you don't**, run the script. It writes a placeholder for each of the four files
`Package.swift` declares as resources — and nothing else — from that producer's own header row:

```bash
scripts/create-data-files.sh          # create what is missing, leave the rest alone
scripts/create-data-files.sh --check  # report all four, write nothing
```

The placeholders are enough to compile — **verified, not assumed**: a tree holding only the four
placeholders builds with `swift build` and no `Invalid Resource` warning, and the importer then
honestly reports zero days rather than inventing any. They do **not** make the test suite pass, and
should not: `make test` drives the real export, so §11, §13, §14, §15, §17 and §20 assert that file's
own figures (673 workouts, 910 nights, 170 fasts). Run the suite against a real export.

**It will not overwrite an export.** A file holding rows is reported and left byte-for-byte alone,
whatever flags it is given — the record is the only copy and the script is built so it cannot be the
thing that loses it. To replace one deliberately, move it aside yourself first. `journal_entries.csv`
is deliberately not created: it is the fourth CSV on disk and the only one nothing bundles or reads.
`.claude/skills/create-data-files/` carries the whole argument.

**If you use the [Zero](https://zerolongevity.com) fasting tracker**, its own export is a
`biodata.json` of 19 top-level keys, of which this app reads exactly one. Project it down rather
than bundling the whole thing — the trimmed file is 46,584 bytes and every byte of it is read, where
the source is 599 KB and 92% of it is data nothing here consumes (`rhr_data` alone is 749 rows of a
reserved-zero resting rate):

```bash
python3 -c "import json;d=json.load(open('ios/Sources/Whoopsy/Data/Resources/ZeroFasting/biodata.json'));open('ios/Sources/Whoopsy/Data/Resources/ZeroFasting/fasts.json','w').write(json.dumps({'fast_data':d['fast_data']},indent=4))"
```

The projection is faithful rather than a re-encoding: every value in `fast_data` is a string, a bool
or an int, and the key keeps its own name, so the file the app reads is a subset of the producer's
bytes. Drop it in and **Profile › LOGS › Zero Fasting › IMPORT FASTING HISTORY** turns the 170
fasts into activities on Home.

### Optional: the offline map

`USE OFFLINE MAP` — the second switch on the live session screen — downloads a Mapbox tile region
around where a session started, so the route card at the foot of the activity detail page draws
without a connection. It exists for hiking: the decision is the user's, made **before** signal is
lost, because there is nothing to check connectivity with once there is none. With it off the session
records exactly as before and the card draws `MapKit`'s live tiles.

**It is off at every layer until you supply two credentials, and neither is in this repository.**

| Token | Scope | Where it goes | Why |
| :--- | :--- | :--- | :--- |
| **Public** `pk.…` | none | `ios/App/Config/Mapbox.local.xcconfig` — **gitignored** | Expands into `MBXAccessToken` in `Info.plist` at build time. Kept out of the repository; a clone copies the example and pastes its own |
| **Secret** `sk.…` | `Downloads:Read` | `~/.netrc` | Needed for SwiftPM to *resolve* the binary package at all — a build credential, not a runtime one |

Neither is in this repository, and the public one is deliberately untracked even though Mapbox's model
treats it as embeddable. The *key* it feeds — `MBXAccessToken` — stays in `ios/App/iOS/Info.plist`, because
that is Mapbox's own documented mechanism and the one read path `MapboxSetup` has; only its value
changes.

Create the secret token in your Mapbox account, then:

```bash
cat >> ~/.netrc <<'NETRC'
machine api.mapbox.com
  login mapbox
  password sk.YOUR_SECRET_DOWNLOADS_READ_TOKEN
NETRC
chmod 0600 ~/.netrc
```

**Without it the iOS build fails at package resolution and the error reads like a network problem
rather than an authorisation one** — that is the first thing to check if `make ios` cannot resolve
`mapbox-maps-ios-binary`.

Then the public one:

```bash
cp ios/App/Config/Mapbox.local.xcconfig.example ios/App/Config/Mapbox.local.xcconfig
# edit it and set: MBX_ACCESS_TOKEN = pk.YOUR_PUBLIC_TOKEN
```

`ios/App/Config/Mapbox.local.xcconfig` is where the token goes and it is gitignored, so it is never
committed; `.example` is tracked purely so a clone knows what to create. With both credentials in
place the switch appears; with either missing the app is exactly what it was before the feature, with
no crash and no half-configured SDK.

**The token is in the second of two xcconfig files, and which one is committed is the whole trick.**
`ios/App/Config/Mapbox.xcconfig` is **tracked** and carries no token — it sets `MBX_ACCESS_TOKEN` empty and
then ends with `#include? "Mapbox.local.xcconfig"`, the *optional* include, which pulls in your file
when it exists and is silently skipped when it does not. Because an xcconfig assignment is
last-one-wins, the include coming last is what lets your token override the empty default.

That split exists because of how Xcode treats a base configuration it cannot open. `Mapbox.xcconfig`
is the app target's `baseConfigurationReference` on both Debug and Release, and a missing one is a
hard build failure, not a warning:

```
ios/Whoopsy.xcodeproj: error: Unable to open base configuration reference file '…/ios/App/Config/Mapbox.xcconfig'
```

If the file holding the token were the base configuration, every fresh clone would be unbuildable.
`#include?` makes a clone without credentials merely *unconfigured*: the built `Info.plist` gets an
empty `MBXAccessToken`, `MapboxSetup.configure()` returns `false`, the `USE OFFLINE MAP` switch is
never offered and the route card draws `MapKit`'s live tiles — the app exactly as it was before this
feature. **Do not merge the two files, and do not delete the committed one.**

`MapboxSetup.configure()` accepts only a value beginning `pk.`, and that guard catches what the empty
default cannot: a secret `sk.…` token pasted into the wrong file, or a placeholder someone typed
instead of their own token. Either way the SDK is skipped rather than half-configured, so no secret
can be shipped inside a built app by accident.

Note that `ios/App/Map/` — the three files behind this feature — is compiled **only** by the Xcode target.
It cannot be a dependency of `Package.swift`, which also declares `.macOS(.v14)` for the host binary
and the test runner, so `swift build` and `make test` never see it. That is why the card's design keeps
the drawing in `Presentation` and hands the unverifiable module a single `AnyView` to draw inside a
frame the card has already fixed; the reasoning is in [`CLAUDE.md`](CLAUDE.md)'s gotchas.

### Then build

```bash
# Fast edit/compile loop (builds the library and a macOS executable)
swift build

# The iOS app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/Whoopsy.xcodeproj -scheme WhoopsyApp \
  -destination 'generic/platform=iOS' build
```

`xcode-select` points at CommandLineTools on some machines, which is what the `DEVELOPER_DIR` prefix
works around. Add `CODE_SIGNING_ALLOWED=NO` to check compilation without a signing team.

### Running it on a simulator

The iOS command above compiles for a **device**, so it does not refresh the bundle a simulator
installs — `Debug-iphonesimulator` keeps whichever simulator build ran last, and installing that
after a device build silently installs a stale app. Building for a simulator is its own invocation:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/Whoopsy.xcodeproj -scheme WhoopsyApp \
  -destination 'platform=iOS Simulator,id=<device-id>' \
  -derivedDataPath "$PWD/tmp/build/whoopsy-dd" build
```

`xcrun simctl list devices booted` prints the ids. Then, with `DEVELOPER_DIR` still exported —
`simctl` needs it for the same reason `xcodebuild` does:

```bash
xcrun simctl terminate <device-id> org.whoopsy.app   # expected to fail if it is not running
xcrun simctl install   <device-id> "$PWD/tmp/build/whoopsy-dd/Build/Products/Debug-iphonesimulator/WhoopsyApp.app"
xcrun simctl launch    <device-id> org.whoopsy.app
```

**Terminate first, and never `uninstall`.** `simctl launch` on an app that is already running only
foregrounds it, so installing over one leaves the old process executing the old code and the screen
looks unchanged no matter what you edited. `uninstall` would force a cold start but takes the app's
data container with it — including an imported history — while `install` over the top preserves it.
If a change still seems not to have applied, check the installed binary rather than the screen:
`ls -la "$(xcrun simctl get_app_container <device-id> org.whoopsy.app app)/WhoopsyApp.debug.dylib"`
and compare its size and timestamp against the built one.

### Tests

The suite is a hand-rolled assertion runner rather than XCTest — 20 sections, 1803 assertions, and no
test discovery:

```bash
make test                 # build + run all 20 sections
make test SECTIONS=13,15  # just those two
```

`scripts/test.sh` builds into a scratch path (the default build directory keeps object files from
deleted sources and the link fails) and hands the runner an absolute `#filePath`, so the suite no
longer cares which directory you run it from. It ends with one machine-readable line:

```
SUITE sections=1,2,...,20 assertions=1803 failed=0 exit=0
```

Read that line rather than the scrollback — the suite has no test discovery, so a section that
stopped running looks exactly like one that passed. The full explanation is in
[`CLAUDE.md`](CLAUDE.md) §Tests.

Note the runner is **not hermetic in the migration sense** — one section builds the real dependency
container, so a run applies any pending migration to your own development database before the app is
ever launched. It writes no rows there: every section that stores anything builds its own in-memory
database, and a full run leaves the file byte-identical. That is documented rather than hidden.

---

## Roadmap and contributing

**[`TODO.md`](docs/TODO.md) is the roadmap**, and it is deliberately blunt: open items carry the reason
they are open, and several are marked as decisions *not* to do something, with the measurement that
justified it.

**Ideas are welcome as issues.** If you have an implementation idea — a better estimator, a new
metric, a fix for something in `docs/TODO.md` — open an issue and describe the approach. Design
discussion before code is genuinely useful here, because most of the hard problems in this project
are measurement questions rather than coding questions.

### Planned: fasting and metabolic tracking

The next significant feature is a **fasting tracker that understands what the strap is already
measuring** — the Zero-style fasting window, combined with heart rate, HRV and sleep, so the app can
describe what a fast actually did to recovery rather than only how long it lasted.

The interesting problem is not the timer. It is that a fasting window is a *different* kind of object
from everything currently in the data model: the day-keyed tables assume one row per day per metric,
and a fast spans days, moves, and has a physiological effect that lags its end. Strap data is also
sparse — a fast only has physiology behind it for the hours the app was running with the strap
connected.

If you have a view on how to model that, open an issue — that is the kind of thing worth agreeing on
before it is built.

---

## Privacy

The app stores your health data in a SQLite file inside its own sandbox. It has no account, no
server, and no code of its own that makes a network request. It does not phone home, and there is
nothing to opt out of.

**One caveat, and it is opt-in.** The offline map above hands its tile requests to Mapbox's SDK, which
is a third party — so a session that used `USE OFFLINE MAP` downloads map tiles from Mapbox, and the
route's start coordinate goes with the request. That is the whole of the trade: it buys a route map
that works in a dead zone, and it is off until the user turns the switch on and off entirely until the
build is given a token. **Mapbox Maps v11 also sends telemetry**, and the only network kill switch in
the SDK (`OfflineSwitch.isMapboxStackConnected`) has to stay on for downloads to work at all — so
whether that telemetry can be disabled through a supported path is an open question recorded in
[`CLAUDE.md`](CLAUDE.md) rather than a settled one. Nothing here reads your health data; the request
carries a map position and nothing else. Everything else in the app — BLE, HealthKit, the export
import, the fasting import — is local.

HealthKit access is read-only, and iOS never tells an app whether read permission was granted — so
Whoopsy treats a denial, an empty day and an unavailable store as the same thing and shows a dash
rather than inventing a zero. Steps are not read that way: they come off the strap's own
accelerometer and are stored like any other measured day, which keeps steps out of the HealthKit
permission request entirely.

## Licence

[Apache License 2.0](LICENSE) — use it, modify it, ship it, sell it, including on the App Store,
provided you keep the copyright notice and the [`NOTICE`](NOTICE) file with any distribution.

Two things about that choice are deliberate rather than default:

- **It carries an explicit patent grant** (§3). The protocol layer here is reverse-engineered, so
  anyone building on it gets a patent grant from contributors rather than having to assume one.
- **It is permissive, not copyleft.** Nothing here stops a closed fork; the trade is that nothing
  stops anyone from using this either, which is the point.

Whoopsy is free and stays free, with no paid tier to upsell you to. Donations are welcome if you
want to support the work.

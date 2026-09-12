# Whoopsy

A 100% offline iOS companion for WHOOP 4.0 / 5.0 straps. Your strap, your data, your device — no
subscription, no account, no analytics.

The hardware is excellent. The membership is the part you rent forever: your own physiology is
uploaded to someone else's servers and handed back to you one screen at a time, for as long as you
keep paying. Whoopsy talks to the same strap directly over Bluetooth, decodes the packets on-device,
stores everything in a local SQLite file, and works out Recovery, Strain and Sleep itself.

**There is no network code in this repository.** Not "we don't send much" — there is no `URLSession`,
no HTTP client, no third-party SDK. `Package.swift` declares exactly one dependency, GRDB.swift, and
it is a SQLite library.

---

## Why

- **You own the data.** Everything lives in one SQLite file in the app's sandbox. Export it, back it
  up, delete it. There is no account to close and no server holding a copy.
- **No membership.** The app costs nothing to run because it costs nothing to operate. There is no
  backend to pay for.
- **No analytics, no telemetry, no crash reporting.** No engagement metrics, no feature flags, no
  device fingerprinting. Nothing is measured about you that you did not ask to be measured.
- **Transparent.** Every number traces to a formula in [`ALGORITHMS.md`](ALGORITHMS.md), with its
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
  [`BLE_PROTOCOL.md`](BLE_PROTOCOL.md). No strap has been connected, so nothing in the packet layer
  has been checked against a device.
- **Signing is not configured.** `DEVELOPMENT_TEAM` is empty and there is no certificate, so the
  Xcode project will not build to a device without you setting a team. The library and the simulator
  build fine.
- **Historical sync is known-broken.** Pulling the strap's onboard cache is not implemented
  correctly, and the reasons are enumerated rather than hidden — see
  [`TODO.md` §5](TODO.md). The documented frame layout and the implemented one currently disagree.
- **The import path is the well-exercised one.** Recovery, Strain and Sleep can all be computed from
  a WHOOP data export, and that path is covered end to end by the test suite.

What *is* solid: the domain model, the scoring maths, the persistence layer, the import pipeline, and
a 405-assertion test runner that pins the behaviour of all of them.

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
| **The strap**, over BLE | Live heart rate, R-R intervals, battery | Requires a real device |
| **Apple Health** | Steps, resting heart rate, HRV, respiratory rate | Read-only, permission never disclosed by iOS |
| **A WHOOP export** | Full history: recovery inputs, sleep stages, strain | The path that makes a fresh install useful |

Everything downstream is computed on-device from stored rows. An imported day is **re-scored through
this app's own `RecoveryScoring`** rather than having WHOOP's percentage copied across, so one formula
covers the whole history instead of two models disagreeing on one chart.

---

## Screens

- **Home** — the day's three rings (Recovery, Strain, Sleep), a month calendar, and metric panels
- **Strain** — the day's cardiovascular load with heart-rate zone breakdown
- **Workout** — a live session with a heart-rate HUD and route
- **Sleep** — last night's stages, efficiency, and the night's sleep need
- **Recovery** — the score, and the four figures it was computed from against their baselines
- **More** — coach insights, device management, settings and import

---

## Documentation

The docs are the spec, not a summary. They are written to be read by whoever touches this next —
including an AI assistant with no memory of the last session.

| File | What it holds |
| :--- | :--- |
| [`TODO.md`](TODO.md) | **The roadmap.** Outstanding work, per CSV column and per component, with the reason each item is still open. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | **App design.** Layer rules, folder layout, component inventory, data-flow diagram. |
| [`ALGORITHMS.md`](ALGORITHMS.md) | **The maths.** RMSSD/SDNN, the Strain model, the Recovery z-score, sleep staging, sleep need — with constants and citations. |
| [`BLE_PROTOCOL.md`](BLE_PROTOCOL.md) | **Bluetooth.** GATT UUIDs for both hardware variants, `0xAA` framing, CRC layout, handshake sequence. |
| [`CLAUDE.md`](CLAUDE.md) | **Working in this repo.** Build and test commands, and the hard-won gotchas that are not obvious from the code. Also the entry point for AI-assisted development. |

---

## Building

Requires Xcode 16+ and Swift 6.

### First: create the data file, or nothing will build

`Sources/Whoopsy/Data/Resources/*.csv` is **gitignored.** What lived there was one real person's
physiological record — recovery score, HRV, resting heart rate, skin temperature, blood oxygen, sleep
staging, and free-text journal notes — and it is not published. **A fresh clone will not compile
until you put one file back.**

| File | Needed? |
| :--- | :--- |
| `physiological_cycles.csv` | **Required to build.** `Package.swift` bundles it and `WhoopExportImporter` reads it through `Bundle.module`. Without it: `Invalid Resource … File not found` |
| `sleeps.csv`, `journal_entries.csv`, `workouts.csv` | Not needed. Nothing in the app reads them |

**If you have a WHOOP export**, drop its `physiological_cycles.csv` into
`Sources/Whoopsy/Data/Resources/` and the app will import your own history.

**If you don't**, a header-only placeholder is enough to compile — this is verified, not assumed —
and the importer will honestly report zero days rather than inventing any:

```bash
cat > Sources/Whoopsy/Data/Resources/physiological_cycles.csv <<'CSV'
Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),Sleep efficiency %,Sleep consistency %
CSV
```

The importer validates that `Cycle start time`, `Cycle timezone` and `Wake onset` are present, so a
file with a different shape fails loudly instead of importing a table of nils.

### Then build

```bash
# Fast edit/compile loop (builds the library and a macOS executable)
swift build

# The iOS app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Whoopsy.xcodeproj -scheme WhoopsyApp \
  -destination 'generic/platform=iOS' build
```

`xcode-select` points at CommandLineTools on some machines, which is what the `DEVELOPER_DIR` prefix
works around. Add `CODE_SIGNING_ALLOWED=NO` to check compilation without a signing team.

### Tests

The suite is a hand-rolled assertion runner rather than XCTest — 14 sections, 405 assertions, and no
test discovery:

```bash
swift build --scratch-path /tmp/whoopsy-verify
swiftc -I /tmp/whoopsy-verify/arm64-apple-macosx/debug/Modules \
  -Xcc -fmodule-map-file=.build/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap \
  /tmp/whoopsy-verify/arm64-apple-macosx/debug/Whoopsy.build/*.o \
  /tmp/whoopsy-verify/arm64-apple-macosx/debug/GRDB.build/*.o \
  Tests/WhoopsyTestRunner/main.swift -o /tmp/whoopsy-verify/WhoopsyTestRunner
/tmp/whoopsy-verify/WhoopsyTestRunner
```

Use a scratch path. `scripts/run_tests.sh` links stale object files from deleted sources and fails;
the full explanation is in [`CLAUDE.md`](CLAUDE.md) §Tests.

Note the runner is **not hermetic** — one section builds the real dependency container and therefore
writes to your own development database. That is documented rather than hidden.

---

## Roadmap and contributing

**[`TODO.md`](TODO.md) is the roadmap**, and it is deliberately blunt: open items carry the reason
they are open, and several are marked as decisions *not* to do something, with the measurement that
justified it.

**Ideas are welcome as issues.** If you have an implementation idea — a better estimator, a new
metric, a fix for something in `TODO.md` — open an issue and describe the approach. Design
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
server, and no network code. It does not phone home, and there is nothing to opt out of.

HealthKit access is read-only, and iOS never tells an app whether read permission was granted — so
Whoopsy treats a denial, an empty day and an unavailable store as the same thing and shows a dash
rather than inventing a zero.

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

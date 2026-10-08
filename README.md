# Whoopsy

A 100% offline iOS companion for WHOOP 4.0 / 5.0 / 5.0 MG straps. Your strap, your data, your
device — no subscription, no account, no analytics.

The hardware is excellent. The membership is the part you rent forever: your own physiology is
uploaded to someone else's servers and handed back to you one screen at a time, for as long as you
keep paying. Whoopsy talks to the same strap directly over Bluetooth, decodes the packets on-device,
stores everything in a local SQLite file, and works out Recovery, Strain and Sleep itself.

**No data leaves the phone, and the app depends on no server.** Not "we don't send much" — no
account, no analytics, nothing you cannot switch off. `Package.swift` declares exactly one
dependency, GRDB.swift, and it is a SQLite library.

**The repository does now contain a `backend/`, and it changes none of that.** It is a Cloudflare
Worker (Hono in front of D1 + R2) with eight resources carried end to end — `recoveries` at
`/v1/recoveries/{date}`, `workouts` at `/v1/workouts/{id}`, `strains` at `/v1/strains/{date}`,
`sleeps` at `/v1/sleeps/{date}`, `stepCounts` at `/v1/step-counts/{date}`,
`receptiveInactivities` at `/v1/receptive-inactivities/{id}`, `biometricSamples` at
`/v1/biometric-samples/{id}` and `userProfiles` at `/v1/profile`, each from the route through the
service and the repository into its own D1 migration — plus the contract generated from those route
definitions rather than written by hand. **Eight of them are the Worker's; the app's sync speaks to
seven** — `biometricSamples` deliberately stays on the phone, because its window is measured in
seconds rather than days — so the two counts in this file differ on purpose, and everything the
Worker carries is described in [§ The backend](#the-backend). **The app reaches it, and only when it
is told where to look.** `ios/Sources/Whoopsy/Data/Networking/` is the HTTP client and `Data/Sync/`
is the sync behind the profile page's `STORAGE` pane — the app's only network code — and both are
inert on a build that has not been configured with a base URL *and* a credential. Such a build draws
a sentence naming the key it is missing and hard-codes no hostname; that is the state every fresh
clone is in, and it is the pattern settled rather than infrastructure. **A configured build is the
other state, and it is the one this repository's owner runs**: the Worker is deployed, every `/v1`
request it serves carries a bearer credential, and the run button on that pane is what moves a
resource.

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
a 2339-assertion test runner that pins the behaviour of all of them.

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
  heart-rate zone rows, each compared against that activity's own recent history. Its rings push the
  recovery, strain and sleep detail pages, and the two ends of its day bar are the only doors to the
  profile page and to the strap's status page
- **Recovery** — the score, and the four figures it was computed from against their baselines
- **Profile** — pushed from Home's day bar, in three panes: **Biometrics** (name, birthday, gender,
  units, height, weight), **Logs** (the Apple Health sync, the four bundled imports and the JSON +
  CSV export), and **Storage** (the cloud sync's key, a `DEVICE STORAGE │ WHOOPSY SYNC API`
  destination that only says where the next write goes, the span of days a run would carry, and the
  seven resources that list names)
- **Device** — pushed from Home's status badge: connection and battery, the strap model picker, the
  pairing controls and the live heart-rate broadcast
- **More** — Settings alone, which is the Anonymous diagnostics toggle

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
│   └── Tests/        WhoopsyTestRunner/ — the hand-rolled 2339-assertion suite,
│                     mirroring Sources/Whoopsy/ file for file
├── backend/          a Cloudflare Worker (Hono · D1 · R2) — eight resources end to end
├── shared/           openapi.json, generated from the Worker's routes
├── docs/             the specs
└── Makefile  scripts/  tmp/  CLAUDE.md  README.md
```

**Everything the app is lives under `ios/`, and every command in this file is run from the repo
root.** `ios/` is a single SwiftPM package: `Package.swift` and `Whoopsy.xcodeproj` sit side by side
there, the project consuming the package product, and every path *inside* either of them is package-
or project-relative. That is why the app could move under `ios/` without a single source file
changing — and why the paths below carry the prefix while the ones inside the package do not.

**`backend/` holds eight resources and a generated contract, and only the first cost design.** The note
at the top of this file says why. Its shape — route → service → repository → migration, with
`shared/openapi.json` produced from the route definitions — was settled by `recoveries`, and the other
seven are that shape written again: `workouts` needed its own migration and nothing else, because a
workout is an aggregate of three tables rather than one row per day, and `strains`, `sleeps` and
`stepCounts` needed no new shape at all — they are the day-keyed upsert the first one established, and
the work they took was in what they *refuse* to invent rather than in how they are wired.
`stepCounts` is the narrowest of the eight. `receptiveInactivities` is the second resource keyed on an
`id` rather than on a day — a day holds several entries — and it is `workouts`' key with none of
`workouts`' aggregate: one table, no children, and two nullable columns (`note`, `startedAt`) whose
absences are the majority case rather than the exception.
**`biometricSamples` is the third keyed on an `id`, and it is the one resource here whose read window
is a span of instants rather than a count of days** — a day of `biometric_samples` is up to 86,400
rows, so a day-counted window would make "give me last month" a read no Worker should be asked for.
It is also the only adapter in this Worker that handles JSON: `rr_intervals_ms` holds a `[Double]` as
text and is published as an array of numbers rather than as the string that is secretly JSON, because
a series of intervals has no interior a decoder would have to agree about — which is exactly why
`sleep_stages`, whose segments carry interior `Date`s, stays an opaque blob. And it is the one
resource whose identity is the **client's** derivation rather than a key this app's storage already
had: the phone's local row key is an autoincrement in that device's own SQLite that never reaches its
entity, so two devices in one partition would both mint from 1 and silently overwrite each other; the
wire id is therefore a client-derived string, and the Worker validates the shape and publishes that
the derivation must be **deterministic** — so that a replay is an upsert rather than a second row —
without reproducing a recipe, because a server that derived an id would be a second implementation of
the client's identity.
**`userProfiles` is the fourth resource with no date key, and it is the one whose shape deviates
furthest — it is a singleton.** A partition holds one profile or none, so its whole surface is
`GET /v1/profile` and `PUT /v1/profile`: no `{id}` to address a member with, no `{date}`, no `/batch`
to chunk, and no `?days=` window to ask for. `PUT` rather than `POST`, because the app's own save is a
whole-row upsert and there is no meaningful "create a second one". **The path is the only segment in
this document that is singular**, because a plural collection path for a resource that can never hold
more than one row reads as "list them" and there is no list — while the file, the type and the D1 table
all keep the resource's own name (`userProfiles.ts`, `UserProfile`, `user_profiles`). It is also the
only resource here whose table has **no `id` column at all** — `PRIMARY KEY (user_id)` alone — and the
only one whose refusal code is `not_found` with **no** service error class behind it: the one rule it
publishes (`restingHeartRate` strictly below `maxHeartRate`) is stated on the write body's `.refine()`
and therefore in the contract, so there is nothing left for a service to refuse.
**Three of the eight have a kebab-case path, and it is the one URL here a reader cannot spell from
the resource's own name**: `/v1/step-counts`, where the type is `StepCount` and the table is
`step_counts`; `/v1/receptive-inactivities`, where the type is `ReceptiveInactivity` and the table is
`receptive_inactivities`; and `/v1/biometric-samples`, where the type is `BiometricSample` and the
table is `biometric_samples`. `receptive-inactivities` is also the only three-segment path in the
document, so it sorts above `/v1/recoveries` rather than among the resources it resembles — and
`biometric-samples` sorts above it, being the document's one entry that precedes every
`/v1/recoveries` path on the letter `b`.
[`§ The backend`](#the-backend) below is how to run it.

---

## Building

Requires Xcode 16+ and Swift 6.


### First: create the data files, or nothing will build

`ios/Sources/Whoopsy/Data/Resources/` holds **three directories, and all three are gitignored.** What
lived in `Whoop/` was one real person's physiological record — recovery score, HRV, resting heart
rate, skin temperature, blood oxygen, sleep staging, and free-text journal notes — and it is not
published. `ZeroFasting/` is ignored for the same reason and holds a fasting tracker's history rather
than a WHOOP export. `Custom/` is the one that names no producer app at all: it holds the owner's own
dream notes, which is the most identifying thing in the repository precisely because nothing about it
looks like data. **A fresh clone will not compile until you put five files back** — every
`.process(…)` entry in `Package.swift` is a build input, and a missing one fails the build with
`couldn't build … because of missing inputs`, not merely a warning.

| File | Needed? |
| :--- | :--- |
| `Whoop/physiological_cycles.csv` | **Required to build.** `Package.swift` bundles it and `WhoopExportImporter` reads it through `Bundle.module` |
| `Whoop/sleeps.csv` | **Required to build**, for the same reason — it is the second `.process(…)` entry. Read only for the **eight nap rows** it carries and nothing else |
| `Whoop/workouts.csv` | **Required to build**, for the same reason — the third `.process(…)` entry, and it is a build input like any other. §17/§19 of the suite also read it for its `HR Zone 1 %`…`5 %` block and its `Activity name` column, so the two zone rows and the activity-name path can only be exercised against a real one |
| `ZeroFasting/fasts.json` | **Required to build.** The fourth `.process(…)` entry, read by `ZeroFastingParser` through `Bundle.module` for the 170 fasts it carries. A placeholder of `{"fast_data": []}` is enough to compile and imports nothing |
| `Custom/dreams.json` | **Required to build.** The fifth `.process(…)` entry, read by `InactivityImporter` through `Bundle.module` for the 62 dreams it carries. A placeholder of `{"receptive_inactivities": []}` is enough to compile and imports nothing. It is generated from `Custom/dreams.csv`, the owner's own notes file, by a generator that is **not part of this repository** — the owner's own tooling, kept untracked like the `Custom/` directory it writes into — and unlike the two files above, its directory names no producer app, which is why the button that reads it is named for the row it produces (`IMPORT RECEPTIVE INACTIVITIES`) rather than for where the file came from |
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

**If you don't**, run the script. It writes a placeholder for each of the five files
`Package.swift` declares as resources — and nothing else — from that producer's own header row, or from
an empty array under each JSON file's own top-level key:

```bash
scripts/create-data-files.sh          # create what is missing, leave the rest alone
scripts/create-data-files.sh --check  # report all five, write nothing
```

The placeholders are enough to compile — **verified, not assumed**: a tree holding only the five
placeholders builds with `swift build` and no `Invalid Resource` warning, and the importer then
honestly reports zero days rather than inventing any. They do **not** make the test suite pass, and
should not: `make test` drives the real export, so §11, §13, §14, §15, §17, §20 and §21 assert those
files' own figures (673 workouts, 910 nights, 170 fasts, 62 dreams over 57 days). Run the suite against
a real export.

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
| **Public** `pk.…` | none | `ios/App/Config/Whoopsy.local.xcconfig` — **gitignored** | Expands into `MBXAccessToken` in `Info.plist` at build time. Kept out of the repository; a clone copies the example and pastes its own |
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
cp ios/App/Config/Whoopsy.local.xcconfig.example ios/App/Config/Whoopsy.local.xcconfig
# edit it and set: MBX_ACCESS_TOKEN = pk.YOUR_PUBLIC_TOKEN
```

`ios/App/Config/Whoopsy.local.xcconfig` is where the token goes and it is gitignored, so it is never
committed; `.example` is tracked purely so a clone knows what to create. With both credentials in
place the switch appears; with either missing the app is exactly what it was before the feature, with
no crash and no half-configured SDK.

**The token is in the second of two xcconfig files, and which one is committed is the whole trick.**
`ios/App/Config/Whoopsy.xcconfig` is **tracked** and carries no token — it sets `MBX_ACCESS_TOKEN` empty and
then ends with `#include? "Whoopsy.local.xcconfig"`, the *optional* include, which pulls in your file
when it exists and is silently skipped when it does not. Because an xcconfig assignment is
last-one-wins, the include coming last is what lets your token override the empty default.

That split exists because of how Xcode treats a base configuration it cannot open. `Whoopsy.xcconfig`
is the app target's `baseConfigurationReference` on both Debug and Release, and a missing one is a
hard build failure, not a warning:

```
ios/Whoopsy.xcodeproj: error: Unable to open base configuration reference file '…/ios/App/Config/Whoopsy.xcconfig'
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

### Optional: the sync database

`STORAGE` — the third pane on the profile page — is a `DEVICE STORAGE │ WHOOPSY SYNC API` switch over
the seven resources the app mirrors into the Worker under `backend/`. This section is the app's half of
turning it on; the Worker's own half is [§ The backend](#the-backend).

**It is off at every layer until you supply both halves of one decision, and neither is in this
repository.**

| Setting | Where it goes | Why |
| :--- | :--- | :--- |
| `WHOOPSY_API_BASE_URL` | `ios/App/Config/Whoopsy.local.xcconfig` — **gitignored** | The deployed Worker's origin. Expands into `WHOOPSYAPIBaseURL` in `Info.plist` at build time; kept out of the repository, so a clone copies the example and pastes its own |
| `WHOOPSY_API_TOKEN` | the same file | **The deployment's shared secret**, sent as `Authorization: Bearer`. The same string in three homes — `backend/.dev.vars` for `npm run dev`, this file for the app, and `wrangler secret put SYNC_API_TOKEN` for the deployment |

**Both or neither, and that is the Worker's rule rather than a preference.** It refuses every `/v1`
request until its own `SYNC_API_TOKEN` is set and the request's credential matches it, so a hostname on
its own is not a half-configured build — it is an install that opens a socket on every read to collect
a `401`. `DIContainer` reads the pair together and wires `UnconfiguredCloudSync` when *either* is
missing, which is what a fresh clone, every SwiftUI preview and the host test runner all get.

**The origin has one home, and it is the table's first row.** `shared/openapi.json` is committed, so
its `servers[0].url` carries `/` — the OpenAPI *relative* form, meaning *the origin this document was
fetched from* — and therefore names no deployment at all: a hostname there would be one operator's
subdomain living in a file every reader opens and every clone regenerates. Nothing in `backend/` has
to agree with it. The Worker serves the origin each request arrived on and `wrangler dev` names
`http://localhost:8787`, so neither needs configuring, and `GET /openapi.json` is where you ask a
deployment what its own hostname is. See [§ The backend](#the-backend).

```bash
cp ios/App/Config/Whoopsy.local.xcconfig.example ios/App/Config/Whoopsy.local.xcconfig
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='   # your secret — the same value in all three homes
# edit the copy and set both keys, beside the Mapbox token if you want the offline map too
```

The `tr` is not decoration: **an xcconfig value containing `//` is truncated at that point**, because
`//` opens a comment. Plain base64 can produce one, and the failure would be a token that silently
differs from the deployment's by everything after the slash.

**The base URL hits that rule every time, because `https://` contains it**, so it has to be written
with an empty `$()` standing in for the second slash:

```
WHOOPSY_API_BASE_URL = https:/$()/whoopsy-sync.your-account-subdomain.workers.dev
```

Get this wrong and the build is **green** and the app's base URL is the string `https:` — an
`NSURLSession` failure at runtime with nothing at build time to suggest why. The `$()` expands to
nothing, so the two slashes never sit adjacently in the file and the expansion puts them back. Both
traps are the same rule seen twice: an xcconfig value is not a string literal, and what looks like
punctuation in one is syntax.

**Your secret is yours, and two deployments sharing one would be sharing rows.** It is not in this
repository. What it buys is bounded and worth stating plainly: it stops scanners, bots and drive-by
requests against a discoverable `*.workers.dev` hostname. It is **not** authentication — the token is
compiled into the app and extractable from the binary, so anyone holding the string has the same access
you do. There is no `accounts` table, no registration and no revocation, and `X-Whoopsy-User-Id` is a
partition name rather than a credential. Real per-install identity is a design that is not built.

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

The suite is a hand-rolled assertion runner rather than XCTest — 22 sections, 2339 assertions, and no
test discovery:

```bash
make test                 # build + run all 22 sections
make test SECTIONS=13,15  # just those two
```

`scripts/test.sh` builds into a scratch path (the default build directory keeps object files from
deleted sources and the link fails) and hands the runner an absolute `#filePath`, so the suite no
longer cares which directory you run it from. It ends with one machine-readable line:

```
SUITE sections=1,2,...,22 assertions=2339 failed=0 exit=0
```

Read that line rather than the scrollback — the suite has no test discovery, so a section that
stopped running looks exactly like one that passed. The full explanation is in
[`CLAUDE.md`](CLAUDE.md) §Tests.

Note the runner is **not hermetic in the migration sense** — one section builds the real dependency
container, so a run applies any pending migration to your own development database before the app is
ever launched. It writes no rows there: every section that stores anything builds its own in-memory
database, and a full run leaves the file byte-identical. That is documented rather than hidden.

---

## The backend

`backend/` is a Cloudflare Worker — [Hono](https://hono.dev) in front of D1 and R2 — and it is a
separate toolchain from everything above. **It is deployed**, at a `*.workers.dev` hostname that is
deliberately written down nowhere in this repository — the committed contract carries `/`, and the
deployment names its own origin in the document it serves — and it refuses every `/v1` request that
does not carry the deployment's own
secret. The app does reach it, and only when it is told where to look: `ios/Sources/Whoopsy/Data/Networking/`
is the HTTP client and `Data/Sync/` is the sync written on it, and both are inert on any build whose
`Info.plist` expands `WHOOPSYAPIBaseURL` or `WHOOPSYAPIToken` to nothing — which is every fresh clone,
so the sync's screen reports an unconfigured database and nothing else happens. Neither half of that
credential is in this repository, and [§ Optional: the sync database](#optional-the-sync-database)
above is where a clone supplies its own.

Eight resources are carried the whole way: `recoveries` at `/v1/recoveries/{date}`, `strains` at
`/v1/strains/{date}`, `sleeps` at `/v1/sleeps/{date}` and `stepCounts` at `/v1/step-counts/{date}` —
one row per day each, keyed on the date — plus `workouts` at `/v1/workouts/{id}`,
`receptiveInactivities` at `/v1/receptive-inactivities/{id}` and `biometricSamples` at
`/v1/biometric-samples/{id}`, each keyed on an id because a day holds several rather than one, and
`userProfiles` at `/v1/profile`. Each
runs from the route through the service and the repository into its own D1 migration,
and every one of them but `userProfiles` takes a `POST /batch` chunk beside its single-row verbs. `workouts` is the one that is not a
single row: a session carries its own `route` and `splits` inline, so a session is one request and
never three, and the server writes parent and children in one transaction. `receptiveInactivities` is
the other id-keyed resource and it is a single row: an entry has a name, an optional start time and an
optional note, and **no end** — which is why it is a table of its own rather than a `workouts` row,
since `workouts`' two instants are `NOT NULL` and the half-open overlap read Home's `ACTIVITIES` card
is built on depends on them. Both of its nullable columns are nullable rather than optional on the
wire, so an absent note has one spelling (`null`) and `""` is refused; and its read orders
`date ASC, started_at ASC NULLS LAST, name ASC`, because SQLite would otherwise sort untimed entries
above the timed ones on their own day and the untimed entry is the majority case. `biometricSamples`
is the third id-keyed resource and the one whose collection read is a different shape: a sample is a
single row with no children, so it carries the `PUT`/`GET /{id}` pair and a batch like the other two,
but its window takes **two instants** rather than a day and a day-count — a day of that table is up to
86,400 rows, so the bound is a span (`MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS`, `604_800`, a constant in
this resource's own unit rather than an alias of the four day-keyed windows') and **both bounds are
required**, because a defaulted `to` would be the Worker's clock answering the caller's question.
**Its id is the client's derivation rather than a key this app's storage already had**: a sample has no
identifier that can travel — the phone's local row key is an autoincrement in that device's own SQLite
and never reaches its entity — so the contract requires a UUID *and* that it be deterministic, and
takes no view of the recipe. It is also **the only adapter in this Worker that handles JSON**:
`rr_intervals_ms` holds a `[Double]` as text and is published as an array of numbers, which is the
honest self-describing shape for a series with no interior a decoder would have to agree about — the
same argument that keeps `sleep_stages`, whose segments carry interior `Date`s, an opaque blob. Two
more of its decisions are worth naming because they are absences rather than values: the series is
published under one name only (`rrIntervalsMs`; the legacy lossy `rrIntervalMs` scalar is deliberately
not carried at all), and nine of its twelve wire fields are nullable with **no default in either
direction** — a channel the strap did not report says `null`, and a substituted `0.0` accelerometer
axis would be free fall, on the *still* side of every movement threshold. **`userProfiles` is the
eighth and it is the one whose shape is a singleton**, so every clause above stops applying to it at
once: no key on the path (`/v1/profile`, the document's only singular segment), no `/batch` chunk, no
window, no `{id}`, no `id` column — `PRIMARY KEY (user_id)` alone — and a `PUT` rather than a `POST`,
because a whole-row upsert is what the app's own save is and there is no second profile to create. Its
absence is a `404 not_found` rather than `no_measurement_for_day`, since no day is the subject; and it
is the only resource here whose service refuses nothing at all, because the one rule it holds — a
resting heart rate strictly below the maximal one — is published on the write body's `.refine()` and
therefore in `shared/openapi.json`, so a `UserProfileError` would be a class no code path could
produce. **No resource here
has a delete route**, so a client can write an entry and read it back but cannot remove it through this
API. **The four day-keyed resources are not copies of each other** — `strains`, `sleeps` and
`stepCounts` share a shape (an upsert, a range read, a chunk) and not an absence rule, because
`strains` stores a `hasMeasurement` flag that can deny a row which exists while `sleeps` and
`stepCounts` have no such column and answer a day with no row as a `404`; a night's day key is its
**wake** day; and `stepCounts` is the narrowest of the three, with no `source` and no nullable column
at all, because the strap is its only producer.
`shared/openapi.json` is **generated from the route definitions** and served live by the Worker at
`GET /openapi.json`, so the committed contract and the
running one cannot disagree.

```bash
cd backend
npm ci                     # or `npm install` the first time
npm run typecheck          # tsc --noEmit, three projects
npm test                   # the real Worker against a local D1 — see the warning below
npm run openapi            # rewrites ../shared/openapi.json
make -C .. backend-check   # all of the above, failing if the contract is stale
```

**It requires a credential, and the credential is one shared secret rather than an identity.** Every
`/v1` path refuses a request that does not carry `Authorization: Bearer <SYNC_API_TOKEN>` — the
deployment's own secret, set with `wrangler secret put` and never in this repository. `GET /health` and
`GET /openapi.json` are the two paths that answer without it. **What that buys is bounded and worth
stating plainly**: it stops scanners, bots and drive-by requests against a discoverable `*.workers.dev`
hostname. It does **not** authenticate a person — the same string is compiled into the app and
extractable from the binary, so anyone holding it has the same access you do.

**`X-Whoopsy-User-Id` is not a credential and is checked second.** It selects which rows a request is
about, the Worker hashes it and never stores it, and nothing verifies it as an identity — what makes it
unguessable is its length, not anything the server checks. There is no `accounts` table, no
registration and no revocation; the migration carries a `user_id` column from the first file so the
table already has its partition the day a verified one exists, and that is a design this repository has
not built.

**A deployment with no secret refuses everything, and it answers `500` rather than `401`.** An unarmed
Worker is the operator's problem and not the caller's, and a `401` there would tell a person holding a
curl that their credential was wrong when the truth is that there is no secret for it to be wrong
about. The body is the shared envelope and carries no detail; the sentence naming `SYNC_API_TOKEN` is
in the Worker's own log. **Set the secret before you deploy** — `wrangler deploy` does not fail on a
missing one, it ships a Worker that refuses every request.

**It is deployed, and the deployment belongs to one account.** `wrangler deploy` ran on 2026-10-07, and
the hostname it printed is written down in exactly one place: the gitignored
`ios/App/Config/Whoopsy.local.xcconfig`, which is what the app reads. It is not in
`shared/openapi.json` — that file is committed, and its `servers[0].url` carries `/` so that it names
no deployment at all. **Nothing reads that field** — the client is handed its base URL through
`Info.plist` — so a fork regenerates the contract unchanged and nothing breaks; it is documentation.
The live document reads its own instead: `GET /openapi.json` names the origin the request arrived on,
which a deployed Worker and `wrangler dev` both answer correctly with nothing configured. The two
Cloudflare resources predate the
deploy: the `whoopsy-sync` D1 database (region ENAM) and the `whoopsy-exports` R2 bucket exist in that
account, and `wrangler.toml`'s `database_id` holds the id `wrangler d1 create` returned — so
`wrangler d1 migrations apply whoopsy-sync --remote` writes to a real schema, and it has been run
there. A fresh clone needs neither `wrangler d1 create` nor `wrangler r2 bucket create` — the names are
taken and both commands fail on an existing resource — only `migrations apply --remote` if it wants the
remote schema, `--local` for `wrangler dev`, and **its own** `SYNC_API_TOKEN`: the secret belongs to the
deployment, and two deployments sharing one would be sharing rows.

To exercise it by hand, note that **`wrangler dev`'s database and the test suite's are two different
databases.** `npm test` builds its own from `migrations/` on every run; `wrangler dev` keeps one under
`backend/.wrangler/state` that starts empty, so a fresh checkout that curls the dev server gets
`500` with `no such table: recoveries` until:

```bash
npx wrangler d1 migrations apply whoopsy-sync --local
npx wrangler dev --port 8787
```

**And it answers `500` on every `/v1` request until `backend/.dev.vars` holds a secret.** `wrangler
dev` reads that file — gitignored, with `backend/.dev.vars.example` committed as the template — and
it is where the local `SYNC_API_TOKEN` goes, and the only thing that goes there:

```bash
cp .dev.vars.example .dev.vars    # from backend/, then paste your own token after the `=`
curl -s localhost:8787/v1/recoveries?days=2 \
  -H "Authorization: Bearer $SYNC_API_TOKEN" -H "X-Whoopsy-User-Id: $ANY_32_CHAR_STRING"
```

Without it the gate throws rather than returning `401`, which is deliberate and is the paragraph
above: an unarmed Worker is the operator's problem, not the caller's. `GET /health` and `GET
/openapi.json` answer either way.

The check that the two readings of the contract really are one document is a shell step rather than a
spec, because a Worker has no filesystem — and `/openapi.json` is one of the two paths that needs no
credential, so this works on an unarmed dev server:

```bash
curl -s localhost:8787/openapi.json | grep -v '"url"' | diff - <(grep -v '"url"' ../shared/openapi.json) \
  && echo IDENTICAL
```

**The `grep` drops one line, and it is the one line the two readings are allowed to disagree about.**
`servers[0].url` is the document's only `"url"` line (`grep -c '"url"' ../shared/openapi.json`) and the
only field in it that belongs to a *deployment* rather than to the API: the dev server names
`http://localhost:8787`, which is the origin its request arrived on, while the committed file names
`/`, which is the origin a document is served from. Everything else — the paths, the schemas, the
pretty-printing — comes out of one `getOpenAPI31Document` call on one `createApp()`, which is what
this compares. The filter is exact rather than approximate, which is why it is a `grep` and not a
hand-trimmed `diff`.

**Local development runs late-2024 `workerd` while a deployment would run `compatibility_date`'s
semantics.** `wrangler` is pinned to exactly `3.95.0` because that is what
`@cloudflare/vitest-pool-workers` pairs with, and it warns on every run that `2026-10-01` is ahead of
the runtime it ships and falls back to `2024-12-05`. Nothing in this resource uses a flag from after
that date, so the fallback is inert here — but a feature that did would be green locally and wrong
deployed. Moving to wrangler 4 is a coordinated bump and is not this pass.

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

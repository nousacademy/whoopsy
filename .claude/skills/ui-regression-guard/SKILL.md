---
name: ui-regression-guard
description: Use when adding a screen, a UI component, a tile/ring/card, or a new value to an existing view under Sources/Whoopsy/Presentation/, and when changing a shared component (GaugeRingView, MetricRingView, DayNavigationBar, Theme) or wiring a screen through DIContainer/MainContainerView. Checks the change against this app's known regression classes — fabricated values, overwritten day-keyed history, unsnapped writes, frozen migrations, moved shared components — and gives a verification sequence that cannot return a false green.
---

# UI Regression Guard

Adding a screen is the cheapest way to break this app, because almost nothing that breaks shows up as
a compile error. A new tile reads a field that is defaulted rather than measured and prints a
number nobody took. A new day picker calls a calculate use case and zeroes 910 imported nights. A
shared ring gains a parameter and four other screens move. Every one of those has happened here.

This skill is the check that runs **around** a UI change: capture a baseline, walk the classes below,
then verify in a way that cannot lie to you. Apply it in the same turn as the change.

## 0. Capture the baseline first

Before editing anything, record what "working" currently means. Without this you cannot tell a
regression from a change you meant.

| What | How | Expected |
| :--- | :--- | :--- |
| Host build | `swift build` | `Build complete!` |
| Suite | build + run the runner — recipe in `CLAUDE.md` §Tests; the scratch path matters | **the assertion count and all `[n/N]` section headers**. Record the count. |
| iOS build | `xcodebuild -scheme WhoopsyApp … CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| Which screens you have actually seen | screenshot, or "not verified" | be honest; most tabs cannot be screenshotted (see §4) |

**The assertion count must not go down.** A dropped assertion is a deleted guarantee, and it is the
only signal this suite gives you — it has no test discovery, so a section that stops running looks
exactly like a section that passed.

## 1. Fabrication — a number on screen that nobody measured

The most common regression here, and the one this codebase's whole no-data discipline exists for. A
defaulted field, a `?? 0`, or a display fallback becomes a confident reading the moment a view draws
it. It has shipped at least five times: `GRDBSleepRepository` handing back `respiratoryRate: 14.0`,
`AnalyzeSleepUseCase` writing a literal `14.4` rpm, `ActiveWorkoutHUDView` rendering an invented
`72` bpm as a live heart rate, `WhoopDevice.batteryPercentage` defaulting to `100` at discovery, and
`CalculateStrainUseCase`'s empty branch writing `score: 0.0` so today's Strain ring reads `0.0`
rather than `—`.

**For every value the new view draws, answer: which path produces it, and can that path produce it
without measuring?** If yes, it renders `—`. Then:

- `grep -rn "?? [0-9]" <new view>` — a numeric display fallback is the tell.
- Read the entity's fields. **A channel with no sensor must be optional**, not a plausible constant:
  `let respiratoryRate: Double?`, not `let respiratoryRate: Double = 14`. Optional-ness is the
  design decision; a default is the bug.
- **All four metrics now say "nothing measured" the same way — no row — but the readers still
  differ, because rows an older build wrote are still on disk.** Handling one is not handling the
  others:

  | Metric | What a writer produces for an unmeasured day | What a **legacy** row looks like on disk | The test a reader applies |
  | :--- | :--- | :--- | :--- |
  | Recovery | **no row** — `CalculateRecoveryUseCase` returns `nil` and writes nothing | a row holding `score: 0, hrvValueMs: 0, restingHeartRate: 0` | `RecoveryMetric.hasMeasurement` (`hrvValueMs > 0`) |
  | Strain | **no row** — `CalculateStrainUseCase` returns `nil` and writes nothing | a row holding `score: 0.0` | `StrainScore.hasMeasurement`, a **required** init parameter with no default |
  | Sleep | **no row** — an unclassifiable night is never written | *(none — this has always been the shape)* | the optional (`SleepSession?`) |
  | Stress | **no row** | *(none)* | the optional |

  The reserved-zero placeholder is what Recovery and Strain used to write, and it was the weaker
  design: every reader had to remember to exclude it, and two did not. The flags survive as **reader
  tolerance** for the rows it left behind — not as a marker any current writer sets. So a screen
  handling a legacy `score: 0` still needs the flag, and `score > 0` is **not** the test: two
  genuinely measured days in the bundled export score exactly `0.0`.

- A value that is `0` is never the way to say "nothing". `0` is a claim: no steps walked, a
  perfectly metronomic heart, 0% recovered. `nil` is the claim that nothing was measured.

## 2. A new screen that writes, or that picks a day

**`CalculateRecoveryUseCase` and `CalculateStrainUseCase` write unconditionally and overwrite.** The
day-keyed tables are primary-keyed on `date`, so pointing either at a past day is an UPDATE that
zeroes whatever the import put there.

- `grep -rn "Calculate.*UseCase" Sources/Whoopsy/Presentation/Screens/<New>/` — any hit must be
  reachable **only** for a day that is today *and* holds no measurement.
- Day selection reads: `getRecovery(for:)`, `getSleepSession(for:)`, `getStrain(for:)`,
  `getWorkouts(for:)`. `HomeViewModel.load(for:)` is the reference implementation.
- `AnalyzeStressUseCase` is the one analyze use case that **writes nothing** — it reads samples and
  returns a value — so unlike its siblings it cannot damage a stored day.

Any new writer must go through `LocalDatabaseManager.save*`, which **snaps `date` to `startOfDay`
centrally**. A row written at a raw timestamp is inserted, never updated, and no keyed read finds it.

## 3. A schema change

- A **new** `registerMigration` block. Never edit a shipped one — GRDB records identifiers and does
  not checksum bodies, so editing `v1` silently changes nothing on any database that ran it.
- A failing migration `fatalError`s at launch. Test it against a **copy** of the real dev database.
  `LocalDatabaseManager` has no path-injecting initialiser and macOS Application Support ignores a
  `HOME` override, so a host tool that writes through it lands in your own dev database. Reset is
  `rm ~/Library/Application\ Support/whoopsy.sqlite`.
- `addMissingColumns` adds **nullable, undefaulted** columns only.
- Choosing a primary key is a decision to state: day-keyed (`recoveries`/`sleeps`/`strains` — one row
  per day) or `id`-keyed (`workouts` — a day can hold several, and forcing it onto a day key makes
  the second session overwrite the first).

## 4. Changing something shared

`GaugeRingView` is drawn by Strain, Sleep, Recovery and the workout HUD. `DayNavigationBar` is used
by four screens. `Theme` tokens are global. `MainContainerView` builds **one** `ActiveWorkoutViewModel`
and gives it to both Home's `+` and the Workout tab.

- `grep -rn "<ComponentName>" Sources/` and list every caller **before** changing its API.
- Prefer a sibling to a modification: `MetricRingView` exists because bending `GaugeRingView` to
  Home's mockup would have moved four screens to restyle one.
- **A compile is not a visual check.** Every caller will still build with a changed default, a new
  parameter, or a re-valued token. Nothing in this repo catches that; only looking does.

## 5. Wiring, and not reaching for a global

- New screen → its use cases constructed in `DIContainer`, its view model built in `MainContainerView`.
- Views get their view model injected. There are no singletons below the container except
  `LocalDatabaseManager.shared`.
- A view that needs a domain rule rendered (a colour, a label) puts that mapping in `Presentation`.
  `Domain` imports only `Foundation`, so it cannot name a `Color` — `RecoveryState+Extensions.swift`
  is the shape to copy.
- **One rule, one definition.** Before writing a threshold, tier or target into a new view, find the
  existing one and read through it: `grep -rn "<the literal>" Sources/`. Two copies that agree today
  are a bug that fires later — `GenerateCoachInsightsUseCase` held its own `>= 67` next to
  `RecoveryMetric.state`, and `RecoveryDashboardView` held a second copy of the tier switch next to
  Home's. If the rule you need doesn't exist as a named thing, name it.

## 6. Affordances

No control without a destination. `CUSTOMIZE`, the pencil, the ACTIVITIES expand icon and the
chevrons are all omitted from Home for this reason — a control that looks tappable and is not reads
as broken. If you add a chevron, wire it or leave it out.

## 7. Verify in a way that cannot lie to you

Each of these has produced a false green in this repo:

| Trap | What actually happened | Do this |
| :--- | :--- | :--- |
| **The runner's exit code** | An uncaught throw inside its `Task` prints no failure; the process idles out the `RunLoop` and exits **0** | Check the `[n/N]` headers **and** the `✅ ALL WHOOPSY TESTS PASSED` banner, never `$?` |
| **The assertion count** | A section that stops running is indistinguishable from one that passed | Compare against the §0 baseline; a drop is a regression |
| **`swift build` "Build complete!"** | An incremental no-op also says that | If you doubt it, confirm the artifact: `strings <built binary> \| grep "<a new literal>"`. Note the real code is in `WhoopsyApp.debug.dylib`, not `WhoopsyApp` |
| **The simulator screenshot** | Installing the wrong build directory, or a stale bundle already on the device, shows the **old** app — a screenshot that "proves" a screen the build does not contain | Verify the bundle you installed contains the change, and `simctl uninstall` before installing |
| **A screenshot as proof of data** | `simctl` cannot tap, so only tap-free screens can be captured, and a fresh install renders **dashes** because nothing has written to it | A screenshot proves layout and the honest-empty state. It does not prove a populated tile, an interaction, or anything behind a tap. Say which you have |
| **The empty-database read** | `sleeps`/`recoveries`/`strains` at 0 rows ⇒ every screen renders `—` and looks broken | On a fresh simulator, import the export (More → Settings) and page the day stepper back — the export ends **2026-08-22**, so today is always a dash. `sqlite3 <container>/Library/Application\ Support/whoopsy.sqlite "select count(*) from sleeps;"` is the quick truth |

Then, to check you did not break a neighbour: `swift build`, the full suite, the iOS build, and the
`architecture-doc-sync` skill for the docs.

**Say what you did not verify.** "The suite covers the populated path; the screenshot proves only the
empty one" is worth more than an implied all-clear, because the next session will believe you.

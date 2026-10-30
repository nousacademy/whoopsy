# Whoopsy Data Flow

**One document, one question: where does a number on a screen come from, and who was allowed to write
it?** `docs/ARCHITECTURE.md` says what the layers *are*; this file says what actually moves through
them, in which order, and which writer owns each stored row. It is the map to hold while changing a
writer, adding a table, or chasing "why is this page blank / slow / stale".

Paths are written from the repo root.

## The shape in one paragraph

A WHOOP strap produces frames over BLE; the app decodes them into **samples**, **motion epochs** and
**steps**, stores them in SQLite through repositories, and — at a handful of defined moments — folds
those rows into **metric rows** (`recoveries`, `sleeps`, `strains`, `stepCounts`, `workouts`). Every
screen then **reads stored rows only**. Nothing a screen displays is computed on the way to the glass.

```
strap ──BLE──> decoder ──> repositories ──> SQLite ──> use cases ──> @Observable VM ──> SwiftUI
                                  ▲                        │
                                  │                        └── writers (drain, night, recovery, strain, steps)
                                  │
          imports (WHOOP CSV, Zero, dreams.json, HealthKit) ──┘
```

Two rules make the rest of this file short. **A screen reads; a writer writes.** And **a writer runs
either from the foreground chain or from a stream, never from a view's body**.

## 1. The ways data comes in

| Source | Enters through | Writes | When |
| :--- | :--- | :--- | :--- |
| Live strap | `WhoopBLEManager.liveTelemetryStream` / `.motionStream` / `.stepCounterStream` → `WhoopPacketDecoder` | `biometric_samples`, `motionEpochs`, `stepCounts` | continuously while connected |
| Strap flash | `DrainCoordinator.drain()` → `historicalTelemetryStream` → same repositories | `biometric_samples` (+ `motionEpochs`) | on connect, on foreground, on `SYNC HISTORY` |
| A recorded session | `LiveSessionUseCase` → `SaveWorkoutUseCase` | `workouts` (+ route points, splits) | when the user ends a session |
| HealthKit | `HealthKitStoreClient` → `HealthKitImporter` | `recoveries` (SDNN), `sleeps`, `biometric_samples` | opt-in, on the profile page's `LOGS` pane |
| WHOOP export (bundled CSV) | `WhoopExportParser` → `WhoopExportImporter` | `recoveries`, `sleeps`, `strains`, `workouts`, `naps`, steps | deliberate tap on `LOGS` |
| Zero Fasting / dreams.json | their own importers | `workouts` (fasts) / `receptive_inactivities` | deliberate tap on `LOGS` |
| Cloud restore | `RestoreFromCloudUseCase` | all seven synced tables | manual `RESTORE`, or a launch that finds no days |

**The drain is the one input that is not live.** A strap worn overnight banks records with no phone
near it; `DrainCoordinator` pulls that flash, and it is the only path that makes a night visible the
morning after. Its two triggers are the BLE `.connected` arm and `scenePhase == .active` — both,
because a phone that stayed connected all night never reconnects.

## 2. Who owns each stored row

Every computed table has **one writer** and records **what it was computed from**. That pair is what
makes "calculated once, stored, read" checkable rather than a slogan.

| Table | Writer | Trigger | Provenance on the row |
| :--- | :--- | :--- | :--- |
| `biometric_samples` | decoder (live + drain), importers | every notification / batch | `timestamp` is an arrival instant; `rrIntervalsMs` is the raw series |
| `motionEpochs` | `RecordMotionUseCase` | every 30 s window | grid-keyed |
| `stepCounts` | `TrackStepsUseCase` (motion + `R18` counter) | motion batch / counter tick | `measuredSeconds`; **no `source` column** |
| `sleeps` | `AnalyzeSleepUseCase` (via `RefreshNightsUseCase` and the sleep page) | drain, foreground, page open when owed | `algorithm`, `scored_through`, `stillness_spine` |
| `recoveries` | `CalculateRecoveryUseCase` (via `RefreshRecoveryUseCase`) | foreground, after the night refresh | `algorithm`, `scored_through` (`v39`) |
| `strains` | `CalculateStrainUseCase` (via `RefreshStrainUseCase`) | 5-minute tick, foreground, after a drain | `algorithm`, `scoredThrough`, `motionLoad` |
| `workouts` | `SaveWorkoutUseCase`, `ActivityEditSheet`, importers | end of session / edit / import | `source`, `rpe` (local-only) |
| `receptive_inactivities` | sheet, importer | write / import | id derived from date+type+note |

**An imported row is never re-scored by a local writer.** Sleep checks `hasWhoopSleepNeed`, strain
checks `isDeviceScored`, recovery checks `isLocallyComputed` — and each of those is a different fact
about a different table, not one shared flag.

## 3. The read path, and where it stops

```
View ──> @Observable ViewModel ──> UseCase (rarely) ──> Repository ──> LocalDatabaseManager
```

- **Views own no reads.** Every read happens in a view model, and every view model is built in
  `MainContainerView` (or the activity-detail factory) out of `DIContainer`'s use cases.
- **Repositories answer from local storage and nothing else.** The seven `Cloud*Repository` decorators
  still carry their cloud fallback, but they are constructed with a **closed read window**, so a local
  miss is `nil` rather than a request. The one path that fills a table from the API is
  `RestoreFromCloudUseCase`.
- **A day with nothing measured has no row**, and a missing row draws `—`. That is true for all four
  metrics; a zero is only ever a real zero (a measured day of no walking, for instance).
- **A day-keyed screen clears the day it leaves, and only then.** Every per-day value on Home, the sleep
  page, strain and recovery is cleared together when the day changes, because their reads replace values
  one at a time and a failed read leaves what it had — so without the clear the previous day's night,
  activities and steps stay under the new day's header. A *same-day* reload clears nothing, which is the
  other half: the screen is re-shown on the way back from a push, and blanking it there is the ring
  "emptying out".
- **A saved row is not a drawn one.** A write behind a screen does not re-run its `.task`, so the four
  writers publish on `AsyncStream` hubs that Home and the pages subscribe to:
  `RefreshStrainUseCase.updates`, `RefreshRecoveryUseCase.updates`, `RefreshNightsUseCase.nightUpdates`,
  `RestoreFromCloudUseCase.completions`.

## 4. The foreground chain, in order

`MainContainerView`'s `scenePhase == .active` handler is the app's one catch-up path. Order matters:

1. `manageBLEConnectionUseCase.rearmConnection()` — a killed process has no outstanding connect.
2. **2-second yield** — lets the first screen finish its load before a day's fold starts.
3. `restoreFromCloudUseCase.restoreIfNeeded()` — only on a phone holding no days; a no-op otherwise.
4. `dailySyncUseCase.runIfDue()` — uploads the drawn span, at most once per evening.
5. `drainCoordinator.drain()` — pulls the strap's flash.
6. `refreshNightsUseCase.refresh(from:nil, to:nil)` — classifies today if the drain did not.
7. `refreshRecoveryUseCase.refreshToday()` — scores today if the **stored row** says it has not seen
   this night (`algorithm` + `scored_through`).
8. `refreshStrainUseCase.refreshToday()` — same shape, against `strains.scoredThrough`.

Steps 6–8 are ordered because each feeds the next: a night is what recovery is scored from. Step 2 is
the answer to "the ring took a while on the first load" — the work is not lost by waiting, and the
five-minute strain tick would score the day anyway.

## 5. How a day becomes current without a screen open

- **Nights.** `RefreshNightsUseCase` classifies up to three of a drain's newest days, using the sleep
  page's own `SleepReclassification` rule; it publishes only a night that `drawsSame`-differs from the
  stored one.
- **Recovery.** `RefreshRecoveryUseCase.isOwed(edge:storedEdge:algorithm:)` — the row must name the
  current formula and its watermark must be at least the night's edge. A refusal writes no row, so the
  *refusal* is remembered in-process, per edge.
- **Strain.** `RefreshStrainUseCase` ticks every five minutes; `strains.scoredThrough` makes an
  unchanged day cost one indexed read.

Each writer's watermark means the same thing: *the newest input instant this row included*. Anything
newer re-scores; anything older or equal does not.

## 6. The outbound path

- **Writes go up only through `SyncEngine`**, driven by `DailySyncUseCase` at 18:00 Eastern over the
  span the user drew. A save never mirrors itself — step counts are saved once a second.
- **Reads come down only through `RestoreFromCloudUseCase`** — a deliberate pull of the last 30 days,
  either automatically on an empty phone (inside the call window) or from the `RESTORE` button (any
  time; it is the one call exempt from the window).
- **Exactly one thing deletes, and it is a deliberate purge.** `PurgeDaysUseCase`, driven by the
  `LOGS` pane's `Delete days` control, removes a span of measured days from the four measured
  day-keyed resources **on the server first** and then from this phone. The order is the rule: with
  the destination on `WHOOPSY SYNC API`, a local delete is a cache eviction, and a failed server
  call aborts the whole operation rather than half-doing it. Nothing else anywhere removes a row —
  no per-row delete, no delete on a batch, no delete in the sync engine — and §22 sweeps for that.
- **Two local-only columns never travel**: their sync rows pass `nil`, and a restore writes `NULL`. A
  synced row that arrives without them must not clear a stored value.

## 7. Concurrency: why a page no longer waits

`LocalDatabaseManager` is backed by a **`DatabasePool`** on a real file (WAL: one writer, concurrent
snapshot readers) and a `DatabaseQueue` only in memory. Its **read methods are `nonisolated`**, so they
do not pass through the actor's mailbox; writers stay isolated. The consequence to remember: **two
separate reads may see different snapshots**, so no flow may assume one repository call sees another's
write. Ordering between a writer and a reader is the writer's own transaction, never a property of the
calls around it.

## 8. Invariants a new writer or reader must honour

1. **Snap every day-keyed write to `date.startOfDay`.** The database snaps again on the way in.
2. **Write nothing when nothing was measured.** The same test the readers use
   (`hasMeasurement`, `measuredSeconds > 0`) must be the writer's test.
3. **Record the formula and the input** on any computed row — `algorithm` plus the input watermark.
   A parameter change is a version bump, never an edit in place.
4. **Absence has one shape**: no row, and the screen draws `—`. Never a zero, never a default.
5. **A local-only column is never sent and never cleared by a sync.**
6. **Do not add a second read of a table to answer a question the row can answer.** If a page needs to
   know whether it is current, the row carries the fact.

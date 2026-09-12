---
name: architecture-doc-sync
description: Keep ARCHITECTURE.md, ALGORITHMS.md, BLE_PROTOCOL.md and CLAUDE.md in sync with the code whenever any Clean Architecture layer, component, protocol, or data-flow path under Sources/Whoopsy/ is added, moved, renamed, or deleted. Use after editing anything in Sources/Whoopsy/{App,Domain,Data,Core,Presentation}/, and when adding a directory, use case, repository implementation, GRDB migration, BLE decoder/encoder, or math formula.
---

# Architecture Documentation Sync

Whoopsy documents its own architecture in four Markdown files. They are load-bearing specs, not
summaries: `ALGORITHMS.md` and `BLE_PROTOCOL.md` are the only written specification of the
physiological math and the wire format. When code moves and docs don't, the next session reads a
spec that describes types that no longer exist.

Apply this skill **in the same turn** as the code change, not as a follow-up.

## Docs this skill owns

| File | Owns |
| :--- | :--- |
| `ARCHITECTURE.md` | Layer philosophy, folder layout, component inventory, unidirectional data-flow diagram |
| `ALGORITHMS.md` | HRV, Strain, Recovery, Sleep math — formulas, constants, thresholds, tiers |
| `BLE_PROTOCOL.md` | GATT UUIDs, `0xAA` framing, CRC layout, handshake command sequence, packet types |
| `CLAUDE.md` | Commands, architecture summary, and durable gotchas — **not** a component inventory |
| `TODO.md` | Which column of which bundled CSV this app reads, and what the rest would take. Owned by `csv-field-coverage` — this skill routes *to* it, and does not edit it |

## Routing table — what to update, by what you touched

| Path touched | Update |
| :--- | :--- |
| `Core/Math/**` | `ALGORITHMS.md` (the formula, its constants, its section); `ARCHITECTURE.md` §2.D. Constants are duplicated — use the table in Rule 5 |
| `Core/Logging/**`, `Core/Extensions/**` | `ARCHITECTURE.md` §2.D |
| `Domain/Entities/**` | `ARCHITECTURE.md` §2.A entity list. **`HeartRateZone.swift` also holds a documented math constant** (`strainWeight`) → `ALGORITHMS.md` §2 |
| `Domain/UseCases/**` | `ARCHITECTURE.md` §2.A use-case list; §3 flow diagram if the pipeline shape changed |
| `Domain/Repositories/**` | `ARCHITECTURE.md` §2.A protocol list; confirm `CLAUDE.md` still points at the right implementation location |
| `Data/BLE/Constants/**` | `BLE_PROTOCOL.md` §1 — UUIDs appear in **both** docs, keep them identical |
| `Data/BLE/Parser/**` | `BLE_PROTOCOL.md` §2 framing, packet types, CRC polynomials/algorithms |
| `Data/BLE/Manager/**` | `ARCHITECTURE.md` §2.B BLE engine; `BLE_PROTOCOL.md` §3 if the handshake changed |
| `Data/Persistence/Models/**` | `ARCHITECTURE.md` §2.B persistence |
| `Data/Persistence/Database/**` — **especially migrations** | `ARCHITECTURE.md` §2.B. Migrations are **frozen once shipped** (GRDB records identifiers, not body checksums) and a failure `fatalError`s at launch — the `CLAUDE.md` gotchas cover both |
| `Data/Persistence/Repositories/**` | `ARCHITECTURE.md` §2.B; if a new GRDB repo is wired in, the no-fallback rule in `CLAUDE.md` |
| `Data/Health/**` | `ARCHITECTURE.md` §2.B and the §3 flow diagram — this is a **second data-flow input**, not a detail of the persistence path. If availability or the import's day rules change, `CLAUDE.md` too |
| `Data/Import/**` | `ARCHITECTURE.md` §2.B and the §3 flow diagram — a **third data-flow input**, same reasoning as `Data/Health/`. The day-key rule, the strain-only-cycle rule and the HRV metric classification are gotchas in `CLAUDE.md`; the metric classification and the "imported strain is WHOOP's number" deviation belong in `ALGORITHMS.md` §1/§2/§3 |
| `Data/Exporters/**`, `Data/Services/**` | `ARCHITECTURE.md` §2.B |
| `Data/Resources/**` | `CLAUDE.md` — which files are bundled and which are not, and the `Bundle.module`-not-`Bundle.main` rule. **`TODO.md`** for the per-column coverage line, via `csv-field-coverage`. Note `Data/Import/` reads `physiological_cycles.csv`, so a change here is also a `Data/Import/**` change |
| `Presentation/DesignSystem/**` | `ARCHITECTURE.md` §2.C; `CLAUDE.md` design-token note (colors live in `Theme.swift`) |
| `Presentation/Screens/**` | `ARCHITECTURE.md` §2.C screen list (`MainContainerView` tab list). Screens that render `RecoveryMetric` also read the no-measurement marker — a row can exist and hold no reading. Screens that render `SleepSession` test the optional instead, because an unclassifiable night has no row at all |
| **A rule that spans layers** (e.g. the no-measurement placeholder, which the entity defines, the use cases write, the scoring filters and the views render) | The doc for the domain it belongs to — `ALGORITHMS.md` §3 here — plus a `CLAUDE.md` gotcha. One rule, one section; don't scatter it across the routing rows it happens to cross. Note the two no-data rules **do not share a mechanism** — Recovery writes a reserved-zero row and tests `hasMeasurement`, Sleep writes no row at all and tests the optional — so a view that handles one has not handled the other |
| `App/DependencyInjection/DIContainer.swift` | `ARCHITECTURE.md` §2.D + §3 flow; `CLAUDE.md` wiring bullet (`shared` vs `preview`) |
| `App/AppEnvironment.swift` | `ARCHITECTURE.md` §2.A/§2.D |
| **A new directory or layer under `Sources/Whoopsy/`** | `ARCHITECTURE.md` §1 ASCII diagram **and** §2 tree **and** the §2.A–D prose; `CLAUDE.md` Architecture section |
| `Package.swift` (targets, deps, resources) | `CLAUDE.md` Commands + Gotchas; `ARCHITECTURE.md` §2.B if it changes persistence |
| Build/test commands (`scripts/**`) | `CLAUDE.md` Commands + Tests only |
| `Tests/**` | `CLAUDE.md` Tests section if the test entry point or its reliability changes |

## Rules

1. **Never name a type in a doc without confirming it exists.** `grep -rn "<TypeName>" Sources/`
   before you write it. A doc that references a deleted type is worse than no doc.
2. **Use the identifier exactly as it appears in code** — and respect the known file↔type mismatch
   (`SwiftDataRecoveryRepository.swift` declares `GRDBRecoveryRepository`). Document the type name.
3. **`ARCHITECTURE.md` holds the layout twice** (§1 ASCII diagram, §2 folder tree). A structural
   change means editing both, plus the prose. They drift easily — check all three.
4. **Don't duplicate math or wire format into `ARCHITECTURE.md`.** Formulas belong in
   `ALGORITHMS.md`; framing and UUIDs belong in `BLE_PROTOCOL.md`. `ARCHITECTURE.md` links, it
   doesn't restate.
5. **Changing a documented constant is a doc change** — and the constants are duplicated across
   files, so check every site. Note that they do **not** all live in `Core/Math/`:

   | Constant | Code site | Doc site |
   | :--- | :--- | :--- |
   | `k = 0.000045`, 21.0 ceiling | `Core/Math/StrainAccumulatorMath.swift` (`strainScalingFactor`) | `ALGORITHMS.md` §2 |
   | Zone weights 1.0/2.0/4.5/9.0/16.0 | `Domain/Entities/HeartRateZone.swift` (`HeartRateZoneIndex.strainWeight`) — **not** `Core/Math/` | `ALGORITHMS.md` §2 zone table |
   | Zone HRR boundaries 50–60…90–100% | `Core/Math/StrainAccumulatorMath.computeZones` | `ALGORITHMS.md` §2 zone table |
   | R-R range 300–2000 ms, 20% ectopic threshold | `Core/Math/HeartRateVariabilityMath.filterRRIntervals` | `ALGORITHMS.md` §1 |
   | Recovery coefficients and clamps | `Core/Math/BaselineStatisticsMath.computeRecoveryScore` (weights), `Domain/UseCases/RecoveryScoring.swift` (metric filter, cold starts, window) | `ALGORITHMS.md` §3 |
   | Recovery guards: 5% CoV floor, ±4σ ceiling | `Core/Math/BaselineStatisticsMath.minimumCoefficientOfVariation` / `.maximumAbsoluteZScore` | `ALGORITHMS.md` §3 degenerate-input guards |
   | HRV cold starts 65 ± 12 (RMSSD), 40 ± 10 (SDNN) | `Domain/Entities/HRVMetric.coldStartMeanMs` / `.coldStartStdDevMs` | `ALGORITHMS.md` §1 |
   | Recovery tiers 67 / 34 | `Domain/Entities/RecoveryMetric.swift` — the `greenRange`/`yellowRange`/`redRange` constants are the only copy and `RecoveryState.init(score:)` is built from them; `RecoveryMetric.state` forwards to it and `GenerateCoachInsightsUseCase` reads the tier rather than comparing against `67`. They are `public` because the calendar's key prints them (`RecoveryTierLegend.entries`), where `>66%` is `greenRange.lowerBound - 1` | `ALGORITHMS.md` §3 tiers |
   | Sleep pivot 0.70 | `Core/Math/BaselineStatisticsMath.sleepPerformancePivot` — public, because a caller with no sleep data needs it | `ALGORITHMS.md` §3 days-with-no-measurement; §3 formula |
   | The no-measurement marker (`score`/`hrvValueMs`/`restingHeartRate` = 0) | `Domain/Entities/RecoveryMetric.hasMeasurement`; written by `Domain/UseCases/CalculateRecoveryUseCase.swift`, read by `RecoveryScoring`, `Data/Health/HealthKitImporter.swift`, `Presentation/Screens/Recovery/` | `ALGORITHMS.md` §3 days-with-no-measurement |
   | Sleep epoch minimum, 30 samples | `Domain/UseCases/AnalyzeSleepUseCase.swift` (`minimumEpochSamples`) | `ALGORITHMS.md` §4 nights-with-no-measurement |
   | The export's HRV metric classification (`hrv_metric = rmssd`) | `Data/Import/WhoopExportImporter.swift` (`todayHrvMetric: .rmssd`) | `ALGORITHMS.md` §1 the-inference subsection, **including its basis and its falsification test** — this one is an inference, not a validated constant, so the doc must say so wherever the value appears |
   | The scoring window, 30 days, and the fetch it needs, 180 | `Domain/UseCases/RecoveryScoring.swift` (`baselineWindowDays`, `baselineWindowLookbackDays`, `baselineWindow(before:in:)`) — **it used to be `Data/Import/WhoopExportImporter.swift`'s private `baselineWindowDays`**, and moved here when the Recovery detail screen needed the same window its score was computed from | `ALGORITHMS.md` §3 the-scoring-window |
   | The baseline display gate, 3 days | `Domain/UseCases/RecoveryScoring.swift` (`minimumBaselineDays`, `Baselines.displayed`) — forwarded from `MetricWeek`, itself forwarded from `StressMath` | `ALGORITHMS.md` §3 the-scoring-window |
   | Cold-start resting heart rate, 54 bpm ± 3.5 | `Domain/UseCases/RecoveryScoring.swift` (`coldStartRestingHeartRateBaseline` / `.coldStartRestingHeartRateStdDev`) | `ALGORITHMS.md` §1, §3 |
   | VO₂ max coefficient 15.3 | `Core/Math/Vo2MaxMath.swift` (`heartRateRatioCoefficient`) | `ALGORITHMS.md` §6 — **including its citation and its error bar**, because unlike the fitted constants above this one is *cited*: it is 15.26 (0.72) as measured, and the SEE is 4.7 mL·kg⁻¹·min⁻¹ (~7.8%) when `HRmax` is age-predicted rather than measured, which is this app's case. It is also **sex-specific** — 15.3 is the male value and `UserProfile` has no sex field, so one constant for everyone is a documented ~5.5% bias rather than a neutral default. An unmarked copy of `15.3` reads as a validated constant |
   | Baseline floor, 3 measured days | `Core/Math/StressMath.swift` (`minimumBaselineDays`) — `MetricWeek.minimumBaselineDays` **forwards** to it, so the two cannot drift | `ALGORITHMS.md` §5; `ALGORITHMS.md` §3 baselines |

   The SDNN cold-start pair is a **documented placeholder**, not a validated constant. If you
   replace it with measured values, say so in `ALGORITHMS.md` §1 — an unmarked guess reads as a
   measurement.

   Verify the code before editing the doc at any of these sites. `ALGORITHMS.md` §3 was reconciled
   to the code once already, and it drifted because the doc was the only place the constants were
   written down.
6. **`CLAUDE.md` stays operational.** It holds commands, invariants, and gotchas that require
   reading several files to discover. Do not grow it into a file listing or a second
   `ARCHITECTURE.md`.
7. **A gotcha that you fixed must be deleted, not softened.** `CLAUDE.md` carries a note about the
   broken test script, which is still true. The notes about incomplete migrations, the
   migration-failing test section, the uncalled `seedFromBundleIfNeeded()`, and the unbundled
   `Data/Resources/` CSVs were all deleted when those were fixed — that is the pattern to follow. If
   a change resolves a note, remove it.
8. **A new gotcha states the constraint, not the walk that found it.** `CLAUDE.md` is loaded on every
   session, so each sentence in it is a per-session tax, and the gotcha list is where that cost
   accumulates. Write three things: the rule, what breaks if it is violated, and what to do instead.
   Leave out the debugging walk, what the code used to look like, and any sentence whose whole
   content is that an earlier version of the doc was wrong. Measured when the section was last
   pruned: seven type names that existed nowhere in `Sources/`, and three correction narratives —
   about 2.3 KB out of 36 KB, with almost nothing else to cut, because the remainder was
   load-bearing. So the failure is rarely padding. It is resolved notes kept past their resolution
   (rule 7), plus constraints written as stories. **A gotcha that names a type which no longer exists
   is the tell that both have happened.**
9. **Sweep for stranded references.** After renaming or deleting a component, grep the whole doc set
   for the old name and its old path. A partial rename leaves the hardest kind of stale doc.

## Procedure

1. List what actually changed, by layer:
   `git status` (if tracked) or the files you edited in this turn.
2. Route each change through the table above to get the exact doc set to touch.
3. Grep the docs for existing mentions before editing, so you update in place rather than append:
   `grep -rn "CalculateStrainUseCase\|StrainAccumulatorMath" *.md`
4. Make the edits. Match the surrounding doc's voice — these files are prose specs, not changelogs.
   Do not add "Recently changed" sections or dates.
5. Verify:
   - `grep -rn "<new name>" *.md` returns the intended hits, and `grep -rn "<old name>" *.md` returns none.
   - Every type you named exists: `grep -rn "class <Type>\|struct <Type>\|protocol <Type>" Sources/`
   - If you touched Swift, `swift build` still succeeds.

## Note on the legacy rule

`.github/workflows/update-architecture.md` used to sit in this repo as an earlier, narrower version
of this rule — not a GitHub Actions workflow, despite the directory, because its `triggers:`
frontmatter is not valid Actions syntax. **Both the file and its mention in `CLAUDE.md` are now
deleted**, so this skill is the only source of truth and there is nothing to keep in sync. If you
extend the rule, extend this file.

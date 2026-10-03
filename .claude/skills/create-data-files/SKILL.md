---
name: create-data-files
description: Use on a fresh clone that will not build, after moving or renaming anything under ios/Sources/Whoopsy/Data/Resources/, or when a bundled resource reports "File not found" or the import throws .notBundled. Creates the four data files `Package.swift` declares as resources — and only those four.
---

# Create Data Files

`ios/Sources/Whoopsy/Data/Resources/` is **gitignored in full**. What lives there is one real
person's physiological record — recovery, HRV, resting heart rate, skin temperature, blood oxygen,
sleep staging, 550 free-text journal notes — and a fasting tracker's history. Neither is published,
so a clone arrives with no such directory while `ios/Package.swift` asks SwiftPM to `.process` four
files inside it.

This skill puts exactly those four back.

```bash
scripts/create-data-files.sh            # create what is missing; touch nothing else
scripts/create-data-files.sh --check    # report all four, write nothing
```

## The four, and why only the four

`ios/Package.swift` is the whole of the list — not the directory listing:

```swift
resources: [
    .process("Data/Resources/Whoop/physiological_cycles.csv"),
    .process("Data/Resources/Whoop/sleeps.csv"),
    .process("Data/Resources/Whoop/workouts.csv"),
    .process("Data/Resources/ZeroFasting/fasts.json"),
]
```

**`journal_entries.csv` is deliberately not among them** and the script does not create it. It is
the fourth CSV on disk and the only one that is unbundled and read by nothing anywhere in
`ios/Sources/` — no `WhoopExportFile` case, no `WhoopImportAction` row, no `docs/TODO.md` consumer.
A placeholder for it would be a file nothing opens. Neither are the other eighteen top-level keys of
a Zero `biodata.json`: this app reads `fast_data` alone.

The three CSV placeholders carry their producer's **own header row**, transcribed verbatim — column
names, no data. That is what makes them more than a build formality: a real export's rows can be
pasted under one, and the parser's up-front column validation passes. The columns the parsers
actually require are `Cycle start time`, `Cycle timezone`, `Wake onset` (cycles), those three plus
`Nap` (sleeps), and `Cycle start time`, `Cycle timezone`, `Workout start time`, `Workout end time`
(workouts) — a header missing one of those throws `missingColumns` rather than importing a table of
nils, which is the failure shape the validation exists to refuse.

## It cannot destroy the record

**This is the property the script is built around, and the reason it is safe to run at any time.**
An export exists on this machine and nowhere else — it is not in git, not in a backup, and the
simulator's container is not a second copy.

So a file that **holds data is never overwritten, by any flag.** A file is replaceable only when it
is empty or already the placeholder this script writes. Anything with rows in it is reported, left
byte-for-byte alone, and the run exits 0 with a sentence saying so. To genuinely replace one, move it
aside yourself (`mv`) — an explicit and reversible act. **Do not add a `--force`.** The one thing
this command could do that nothing could undo is the one thing it must not be able to do.

Run `--check` before and after if you want to see the state rather than infer it; it labels each file
`DATA` or `PLACEHOLDER` and verifies the required columns are present.

## What a placeholder does and does not buy

**It builds, and it imports nothing.** `make build` is green, `make ios` is green, the app launches,
and every import button reports zero days rather than inventing any.

**It does not make the suite green.** `make test` drives the real export through the real importers,
so the sections that read a bundled file assert *that file's* figures — 673 workouts and 21 distinct
activity names in §17, 910 nights in §13 and §15, 170 fasts in §20, the export-backed blocks of §11
and §14. On a placeholder those fail, correctly. **Run `make test` against a real export, never
against placeholders**, and do not read a failing run there as a regression.

**There is no synthetic-data mode, and there should not be.** Making the suite pass would mean
reproducing the real export's counts, its 2024-12-10 zero-restorative night, its 86-hour fasts — that
is reconstructing the record, which is the exact thing the gitignore exists to prevent. A fabricated
export that satisfies those assertions is worse than no export, because it reads as a measurement.

## If you have a real export

Drop your own files in and the placeholders are irrelevant:

| Source | Goes to |
| :--- | :--- |
| WHOOP's `physiological_cycles.csv`, `sleeps.csv`, `workouts.csv` | `ios/Sources/Whoopsy/Data/Resources/Whoop/` |
| Zero's `biodata.json` | projected to `ios/Sources/Whoopsy/Data/Resources/ZeroFasting/fasts.json` (below) |

Zero's export is 19 top-level keys of which this app reads one, so project it down rather than
bundling the whole thing — the trimmed file is 46,584 bytes and every byte of it is read; the source
is 599 KB and 92% of it is data nothing here consumes (`rhr_data` alone is 749 rows of a reserved-zero
resting rate):

```bash
python3 -c "import json;d=json.load(open('ios/Sources/Whoopsy/Data/Resources/ZeroFasting/biodata.json'));open('ios/Sources/Whoopsy/Data/Resources/ZeroFasting/fasts.json','w').write(json.dumps({'fast_data':d['fast_data']},indent=4))"
```

The projection is faithful rather than a re-encoding: every value in `fast_data` is a string, a bool
or an int, and the key keeps its own name, so the file the app reads is a subset of the producer's
bytes.

Then **Profile › LOGS**, four import buttons — one per WHOOP CSV under `Whoop`, one for the fasts
under `Zero Fasting`. Each is idempotent and each skips days that already hold data.

## After running it

1. `scripts/create-data-files.sh --check` — all four must read `DATA` or `PLACEHOLDER`, none `MISSING`.
2. `make build` — the host loop. A missing `.process` target is a SwiftPM *warning*, not an error, so
   the build going green is not by itself proof the files are there; `--check` is.
3. `make ios` — the Xcode path, where the four land in the app bundle instead.
4. If an import reports `This build does not include the WHOOP export file` — `.notBundled` — the file
   reached disk but not the bundle. Rebuild rather than re-running the script.

## Where this is documented

`README.md` §Building is the narrative version and is now a pointer to this script rather than a
second copy of the same heredocs — the reason being that a recipe written out twice drifts, and the
drift here would be a header column quietly missing. `CLAUDE.md`'s resource gotcha carries the
`Bundle.module` rule these files live under (a flattened bundle root, no `subdirectory:`, and a trap
rather than a `nil` when the bundle itself is absent), which is why every import throws `.notBundled`
instead of reporting a clean import of nothing.

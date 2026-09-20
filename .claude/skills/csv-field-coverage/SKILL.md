---
name: csv-field-coverage
description: Use when a WHOOP export column gains or loses a consumer — a new parser field, a new column on a record, a new model, a new screen reading an imported value — and whenever a CSV under Sources/Whoopsy/Data/Resources/ is bundled, unbundled, or newly read. Owns TODO.md, the per-column coverage inventory.
---

# CSV Field Coverage

Four CSVs ship beside this app and **three are read** — `physiological_cycles.csv` in full,
`sleeps.csv` for the eight nap rows it alone carries, and `workouts.csv` for its 673 workouts, its
zone block and its `Activity name` column — neither of the last two is in any other file. The remaining one, `journal_entries.csv`, is not junk: it is **3,403**
rows of measurements the app has never opened, and the only reason a column stays unused is that
nobody wrote down what it would take. (`sleeps.csv`'s 918 rows are *not* part of any such figure — it
is bundled, and 910 of its rows are the same 910 nights the cycle file already carries.) That is what
`TODO.md` at the repo root is for, and this skill is how it stays true.

The failure this skill exists to prevent is not a missing checkbox. It is **a stale inventory** — a
`[x]` next to a column whose only consumer was deleted two refactors ago, or a `[ ]` next to a
column that has been flowing to a screen for a month. A coverage list nobody re-measures is worse
than no list, because it is read as fact.

## The file this skill owns

`TODO.md` — one line per column, per file, in the file's own column order, `[x]` when a named symbol
consumes it. Three things about it are load-bearing and must not be relaxed:

1. **One line per column.** A checklist shorter than the column count is a column nobody looked at.
   Verify the count; do not eyeball it.
2. **File order.** The list is diffable against the CSV header, which is the only way a reader can
   tell that a newly-added column is missing rather than merely last.
3. **`[x]` requires a named consumer, with a file.** "It comes from `MetricWeek`" is not a consumer.
   `strains.maxHeartRate` → `StrainDashboardView` "Peak HR" is.

**§1–§4 are the file's own scope. §5 is not.** It is the strap's historical sync — a wire-protocol
work list, with `- [ ]` items that are tasks rather than columns. It lives in `TODO.md` because that
is where the project's outstanding work is recorded, but the three rules above do not apply to it
and a re-measure must leave it alone.

## When to run this

| Trigger | What changed |
| :--- | :--- |
| A field added to `WhoopExportRow` / `WhoopExportParser` | The column is now parsed — which is **not** the same as covered. See the trap below |
| A column added to a `...Record`, or to a GRDB record's `CodingKeys` | A parsed column now reaches storage |
| A new view, tile, card or panel that prints an imported value | A stored column now reaches a screen |
| A new model that reads a column no model read | One `[ ]` becomes `[x]`, and the line's reason is deleted |
| A file bundled or unbundled in `Package.swift` | The whole file's "Blocker" paragraph and every line under it |
| A new `registerMigration` that adds a table | Whatever file was blocked on that table |

Run it **in the same turn** as the change. A coverage flip recorded later is a flip that gets
recorded wrong.

## Procedure

**1. Re-measure. Never trust the file you are about to edit.**

```bash
python3 - <<'PY'
import csv, os, collections
d = "Sources/Whoopsy/Data/Resources"
for f in sorted(os.listdir(d)):
    if not f.endswith(".csv"): continue
    rows = list(csv.DictReader(open(os.path.join(d, f), newline='')))
    cols = list(rows[0]) if rows else []
    print(f"\n=== {f}  rows={len(rows)}  cols={len(cols)}")
    for name in cols:
        vals = [r[name] for r in rows if r[name].strip() not in ('', 'NaN')]
        rng = ""
        try:
            nums = [float(v) for v in vals]
            if nums: rng = f"{min(nums):g} .. {max(nums):g}"
        except ValueError:
            rng = "text"
        print(f"  {name:<44}{len(vals):>7}   {rng}")
PY
```

Then the invariant, which is the one check this skill cannot skip:

```bash
# expect: entries per section == the column count the section's heading claims
# Scoped to §1–§4 on purpose: §5 is a work list, not a column inventory, and its
# `- [ ]` items are not columns. Counting the whole file makes §5 read as 10 extra
# columns in §1–§4 and sends you looking for a list that is already correct.
awk '/^## 1\./,/^## 5\./' TODO.md | grep -c '^- \['
```

A mismatch is the finding. Fix the list, not the heading.

**2. Trace the consumer before you write it down.** For a column you are about to mark `[x]`:

```bash
grep -rn "<the parsed field name>" Sources/Whoopsy/
```

Follow it all the way out — record field → entity → mapper → view. A field that reaches
`WhoopExportRow` and stops there is `[ ]`, and that is the most common mis-mark in this document —
`inBedMinutes` is parsed on every imported row and read by nothing, which is the plain case. The
subtler one is `asleepMinutes`: the **nap** path consumes it (`WhoopExportImporter.makeNap`), while
the **cycle** path parses it and never reads it, so the same field is covered on one file's rows and
uncovered on the other's. A field's coverage is a fact about a path, not about a name.

**3. Flip the line and fix its reason.** A coverage change is a **move between three states**, and
the line's text has to change with it — a `[x]` carrying a `[ ]`'s justification is the stale-doc
failure in miniature:

| From | To |
| :--- | :--- |
| Not parsed | **Parsed** — still `[ ]`. Say so, and say what it now waits for |
| Parsed, unconsumed | **Covered** — `[x]`, with the consumer symbol and its file |
| Covered | **Covered differently** — update the destination, do not add a second line |

**4. Update the numbers that moved.** The Summary table's `Covered` column, and any fill count in
the line you touched. The counts are the part a reader trusts fastest and checks last.

**5. If a status change has a documented reason, route it.** A column's coverage is often decided by
a rule that lives elsewhere — a **Decision** line (do not cover) is a citation, not an opinion.
When one of those changes, update the source it cites, not just `TODO.md`:

| The line is about | The reason lives in |
| :--- | :--- |
| Recovery inputs, HRV metric classification | `ALGORITHMS.md` §1 / §3, plus the `CLAUDE.md` never-mix gotcha |
| Strain inputs | `ALGORITHMS.md` §2 — an imported strain is WHOOP's number |
| Sleep need, sleep debt, consistency | `ALGORITHMS.md` §4 |
| Why a file is bundled or not | `CLAUDE.md` — the `Bundle.module`-not-`Bundle.main` gotcha names the bundled files by hand |
| A new table, or a new column on a record | `ARCHITECTURE.md` §2.B and the frozen-migration gotcha in `CLAUDE.md` |

Then run the **`architecture-doc-sync`** skill over the change rather than duplicating its routing
table here.

## Rules

1. **A column can be covered and still not be on screen.** `recoveries.skin_temperature` and
   `strains.kilojoules` are stored on every imported day and printed by nothing. Mark them `[x]`
   — they have a consumer — and say plainly in the line that no screen draws them. "Covered" means
   *consumed*, and quietly meaning *visible* is how a fabricated readout gets justified later.
2. **A redundancy is a finding, not a gap.** Where the app derives a column (`Asleep duration` =
   light + deep + rem; `Sleep performance %` = asleep / need) the derivation is what ships and the
   column stays `[ ]`. **Measure the agreement before calling it redundant** — that is what turned
   `In bed duration` from "the same as the others" into a 34-minute disagreement on six nights.
3. **A Decision line is closed.** `Recovery score %`, `Sleep performance %` and `Sleep efficiency %`
   are deliberately unused, each with a reason and a citation. Do not flip one to `[x]` because a
   parser grew a field, and do not delete one because it "looks like an oversight". If the decision
   itself is being revisited, say so in the same turn — with the measurement that changed it. Note
   that a Decision and a covered column can look alike from a distance and are opposites: `Sleep debt
   (min)` reads like the other three and is `[x]`, because the sleep-detail screen's breakdown box
   consumes it. What stays a decision is the *model* — whether `SleepNeedMath` should carry a debt
   term — which is a separate question from whether the column has a reader.
4. **Fill counts are measurements with a date on them.** Re-run the command; do not carry a count
   forward because the CSV "is a fixed file". It is fixed — but `Data/Resources/` is a directory a
   human can replace, and a column that is 909-filled today can be 910 tomorrow.
5. **Never mark a column `[x]` for a consumer that cannot produce a value.** A parsed-but-unused
   field, a `?? 0` default and a fallback are all things this repo has shipped as readings
   (`ui-data-provenance` carries the list). Being *reachable* is not being *produced*.
6. **The file-level blocker is written once, above the list.** Each unread file is unread for one
   reason, and repeating it on every line buries it. State it once, in bold, then let the lines stay
   short.
7. **Say what you did not verify.** If a coverage claim rests on a grep rather than a run — the
   export is only readable at runtime through `Bundle.module`, and the runner's §11 is the only
   place it is actually parsed — write that in the line instead of implying it was observed.

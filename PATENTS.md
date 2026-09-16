# WHOOP Patent Disclosure — What Is Published and What Is Not

What WHOOP's patent filings actually disclose about the mathematics behind Recovery, Strain, Sleep,
Stress and VO₂ max, set against what this app implements. The purpose is narrow and worth stating
plainly: **to establish, model by model, which of this app's constants are calibrations and which are
recoveries — and to make that distinction citable rather than asserted.**

`ALGORITHMS.md` already says of several models that "WHOOP publishes the model's shape and none of its
constants". This document is the evidence for that sentence, and it is also where that sentence turns
out to be **incomplete**: for most metrics WHOOP publishes the shape *and anchors it to an input this
app cannot measure*. That is a stronger and more useful statement than "the constants are secret",
and it is the organising idea of this file.

## How to read this document

A patent is a **third kind of source**. It is not this codebase and it is not a reference
implementation, and it has one failure mode the other two do not: **a claimed range is not an
implemented constant.** A claim is a legal fence, drawn as broadly as the applicant can defend, and
its whole purpose is to cover more than the applicants built. So every statement below carries a tag,
and the tags are not decoration.

| Tag | Meaning |
| :--- | :--- |
| **[claimed]** | Recited in a claim of a **granted, in-force** patent. The legal fence — what WHOOP can exclude others from doing. **Not** evidence of what WHOOP ships. |
| **[described]** | Present in the specification of a granted patent or a published application, but not claimed. Where numbers usually live. |
| **[not disclosed]** | Searched for in the named documents and **absent**. A verified negative, not an assumption. |
| **[pending]** | Stated in a published application that is not granted. May narrow or be abandoned before it ever issues. |
| **[app]** | What this codebase does today. A statement of fact about this repo, not a claim about WHOOP. |

**Two things to internalise before reading a number anywhere below.** First, a `[described]` value is an
*embodiment* — the spec's example of how one might build it, written to support the claim, and it may
be years out of date or may never have been built at all. Second, a `[not disclosed]` does **not** mean
WHOOP has no such constant. It means WHOOP chose not to teach it. A patent that says "a weighted
combination" and stops is consistent with any weights at all.

**The `[app]` rows are the point of the exercise.** They say what this app must label as its own.
They are also the rows that go stale, and they are the reason this file is routed from
`architecture-doc-sync`: when a change moves a value recorded here — a tier, a constant, a band edge,
an averaging window, a model's functional form — the row for it moves in the same turn, and an item in
§8 that has been applied is **deleted**, not ticked off. This is a record of what is disclosed, not a
changelog: no dates, no "recently changed".

---

## 0. The finding, up front

For every metric in this app, the disclosed architecture is real and this app's architecture matches
it — and the disclosed **anchors are physiological measurements this app cannot take.**

| Model | WHOOP's disclosed shape | The anchor it needs | What this app substitutes |
| :--- | :--- | :--- | :--- |
| **Strain** | Full: HRR → piecewise weight → integrate → normalise → arctan → ×21 | The user's **anaerobic threshold** and **creatine-phosphate threshold** | a fixed 50/60/70/80/90 %HRR grid |
| **Recovery HRV** | HRV over a short window inside the **last slow-wave-sleep episode before waking** | sleep staging | a whole-night RMSSD |
| **Sleep staging** | nothing — deferred to a trained classifier | the classifier | actigraphy + heart-rate dip |
| **Sleep need** | `Baseline + f1(strain) + f2(debt) − Naps` | the baseline and the debt term | a fitted linear coefficient |
| **Stress** | `α·f(motion)·[w·HR + (1−w)·HRV]` or an HRRR quantile | a trained distribution and a motion-conditioned context | z-scores against a flat baseline |
| **VO₂ max** | a plurality of regression / GPS models selected by what data is available, with a precedence order | a GPS-tracked run, a clinical measurement, or a trained regression over sleep PPG | one cited heart-rate ratio (`15.3 × HRmax / HRrest`) |

**Every substitution in the right-hand column is forced, not lazy.** This app has no AT measurement,
no slow-wave detector, and no trained model. The correct reading of a mismatch is not "the app got it
wrong" but "the app cannot compute the disclosed quantity, so it computes a different one and must
say so". That is exactly the bargain `ALGORITHMS.md` already documents for `SleepNeedMath` and
`StressMath`; this file extends it to Strain and Recovery, which had been assumed to be closer to
disclosed than they are.

---

## 1. Strain

**Sources.** The HRR-weighting mathematics is **one body of specification text** reused across a large
Whoop / Bobo Analytics family. The same paragraphs, equations included, appear in all of: US20140073486A1
(abandoned), US20140309542A1 (abandoned), WO2015134654A1 (ceased), **US10182726B2 (granted, in force)**,
US9750415B2 (granted), US11185292B2 (granted), US20220079530A1, **US20250380880A1 (pending)**,
EP4169042A1. Paragraph numbers below are EP4169042A1's, which are the cleanest; US20250380880A1 carries
the same text at `[0146]`–`[0160]`.

### 1.1 The architecture, in full

This is the most completely disclosed model in the portfolio — the equations are in the specification
as MathML, extracted from the raw HTML rather than from a rendered page.

```
v(t)   = (H(t) − RHR) / (MHR − RHR)                       [described]
I(t₀,t₁) = ∫[t₀→t₁] w(v(t)) dt                             [described]
I_T    = ∫[T] w(v(t)) dt   ≤  w(1)·|T|                      [described]
N_T    = I_T / ( w(1) · 24 hr )                            [described]
ƒ(x,N,p) = 0.5 · ( arctan( N(x − p) ) / (π/2) + 1 )        [described]
score  = ƒ(N_T, N, p) × 21                                 [described]
```

with the weight function published explicitly:

```
w(v) = {  0 : v = 0
          1 : v ∈ (0, AT]
         18 : v ∈ (AT, CPT]
         42 : v ∈ (CPT, 1] }
```

| Claim | Tag |
| :--- | :--- |
| The intensity score is an integral of a weighted HRR over time | [described] |
| **21** is the display scale multiplier ("multiplied by 21") | [described], twice |
| Band weights **0 / 1 / 18 / 42** | [described] |
| Band boundaries are the user's **AT** and **CPT** | [described] |
| Weight values, band count | **[not disclosed]** as claimed subject matter |
| `N` and `p` in the arctangent | **[not disclosed]** — never defined, never valued, never ranged |
| How AT and CPT are obtained | **[not disclosed]** |
| How RHR and MHR are derived | **[not disclosed]** |

**§2's architecture is not a guess.** `Σ w_z · Δt_z` — a step-weighted integral of heart-rate reserve
over time — **is** WHOOP's structure, and 21 is a disclosed multiplier. Whoever wrote `ALGORITHMS.md`
§2 landed on the right shape.

### 1.2 Where the app diverges, and why it has to

| | this app [app] | WHOOP |
| :--- | :--- | :--- |
| bands | 5 | "a plurality … **(e.g., three)**", then exemplifies **four** |
| boundaries | 50 / 60 / 70 / 80 / 90 %HRR | the user's **AT** and **CPT** |
| weights | 1.0 / 2.0 / 4.5 / 9.0 / 16.0 | **0 / 1 / 18 / 42** |
| saturation | `21·(1 − e^(−k·TotalLoad))`, `k ≈ 0.000045` | linear `/(w(1)·24 hr)`, then arctan |
| muscular | `w_muscular · V_normalized` | separate family; combination **[not disclosed]** |

**The band boundaries are the finding that matters.** WHOOP's bands are not percentages of anything —
they are per-user physiological thresholds. A person's anaerobic threshold is a measurement, it moves
with fitness, and this app has no way to take it. A fixed %HRR grid is a **substitute for an input the
app cannot obtain**, which is a citable design constraint rather than an unexamined guess.

Two smaller things worth recording. The patent's own band count is **internally inconsistent** — the
text says "(e.g., three)" and then gives a four-category example — so the app's five matches no number
WHOOP ever wrote, including their own. And the disclosed ramp is **far steeper** than the app's: WHOOP's
top band is 42× its second band, while the app's is 16× its first.

**The exponential is the app's invention.** No `21(1 − e^(−k·L))`, no logarithm, and **no `k`** appears
anywhere in the family. WHOOP's ceiling comes from bounding the input by construction — `I_T ≤ w(1)·|T|`
— and then an arctan whose steepness `N` and inflection `p` are never defined. **The disclosed scaling
is therefore numerically uninstantiable**: this app could not adopt WHOOP's form even if it wanted to,
because the parameters that would make it a function were never published. `k` belongs in the same
category as `SleepNeedMath`'s 6.40 — a fitted constant of this app's own.

**One structural note.** `N_T = I_T / (w(1)·24 hr)` means the normalisation assumes `w(1) = 42`. The
scale's ceiling is a **function of the top band weight**, so WHOOP's 21, its weights, and its
normalisation are not three independent numbers — change the weights and the 21-scale moves with them.

### 1.3 Which version WHOOP actually protects

This is the part most easily misread, so it is stated flatly:

* **The static-band scheme is abandoned.** US20140309542A1, which claimed "weighting the heart rate
  reserve data according to a weighting scheme", is abandoned.
* **What is granted and in force is the dynamic scheme.** **US10182726B2** (granted 2019-01-22, expires
  2033-09-24) claims weighting "according to a **dynamic** weighting scheme … based on historical heart
  rate reserve data", wherein "**a path of the intensity score over time is used to dynamically
  determine and adjust** the dynamic weighting scheme". The spec's motivating example is that "in the
  case of high intensity interval training, the weights applied may be higher than in the case of a
  more traditional exercise routine."
* **The dynamic scheme is described only in prose** — no update equation, no numerics, no
  path-detection algorithm, and no statement of magnitude beyond "may be higher".
* **US20250380880A1 (pending) is weaker still.** Its claims 1–20 are cancelled and its live claim 21
  recites only "generating an intensity score … based on the continuous heart rate data acquired during
  the exercise activity". The HRR transform, the weighting, the normalisation and the scaling have all
  been dropped from the claims.

So this app reproduces the disclosed *architecture*, the **abandoned** *static* embodiment, and none of
the *granted* dynamic mechanism.

### 1.4 The muscular term is a different family

"Muscular" has **zero occurrences** in the strain family. The non-cardiovascular term lives in
US20240057895A1 / EP4358838B1 (**granted**, 2025-10-01) — "Musculoskeletal strain", inventors
Babakeshizadeh, E. Capodilupo, Chapman, Diraneyya — and computes, per repetition,
`(V_rep / V_max) × (I_rep / I_max)`, summed over repetitions within a set and over sets, from fused
3-axis accelerometer and gyroscope data. Raw MSK strain is described as "an unbounded linearly
cumulative score", then scaled by a two-stage process (exercise-specific normalisation, then
performance normalisation) to **0–21**.

**How the two are combined is [not disclosed].** The whole of it:

> "taking an action may include **refining a daily strain calculation** … based on the musculoskeletal
> strain score" … "a total daily strain for a user may be **updated** to more accurately reflect strain
> due to muscle exertion as well as cardiovascular exertion."

No combination equation, no `w_cardio`, no `w_muscular`, and no statement of whether the combination is
additive or saturating. Both of this app's combination weights are its own.

### 1.5 Grounding measurement

WHOOP's own `Day Strain` over the bundled export (n = 933):

| | |
| :--- | :--- |
| mean | 10.83 |
| sd | 3.96 |
| p25 / p50 / p75 | 7.70 / 10.90 / 13.90 |
| p95 / max | 17.10 / 19.80 |
| days ≥ 20.0 | **0** |
| days exactly 0.0 | **2** |

Two observations, one of which is evidence and one of which is not. **The evidence:** a distribution with
a soft floor near 4 over 933 days is consistent with the disclosed weight function, which gives weight
**1 to every minute above zero HRR** — a day spent entirely under 50 %HRR integrates to zero under this
app's table but not under WHOOP's. **The non-evidence:** this app's integrator cannot be run against the
export, because the export carries no heart-rate series and no database on this machine holds one. The
distribution is consistent with the disclosed model; it does not measure the app's error.

---

## 2. Recovery

**Sources.** US20140323880A1 → **US11574722B2** (granted 2023-02-07), US11602279B2 (granted),
US11410765B2 (granted), US20220108782A1 (pending), US20240021287A1 (pending). The specification text is
byte-identical across the family; paragraph numbers below are US20140323880A1's.

### 2.1 The formula is not disclosed. At all.

The entire disclosure:

> "the recovery score is a **weighted combination** of the user's heart rate variability (HRV), resting
> heart rate, sleep quality indicated by a sleep score, and recent strain" [described]

| Claim | Tag |
| :--- | :--- |
| The four inputs — HRV, resting heart rate, sleep quality, strain | [described], and **[claimed]** in US11574722B2 claim 1 |
| The weights | **[not disclosed]** |
| Any equation of any form | **[not disclosed]** |
| A z-score, a standard deviation, or normalisation-to-baseline | **[not disclosed]** anywhere in the family |
| A 30-day window | **[not disclosed]** |
| Exponential or recency weighting | **[not disclosed]** |
| A clamp or rounding rule | **[not disclosed]** |
| Colour coding of tiers | **[not disclosed]** |

**`ALGORITHMS.md` §3's form is entirely this app's own.** The z-score shape, the `24`, the `−18`, the
`0.70`, the `20`, the `50`, the 30-day flat baseline and the `clamp(1..99)` have **no counterpart in
this patent family**. Anyone citing these patents as the origin of those numbers is citing something
else — most likely WHOOP's public-facing documentation, which is not a patent and is not this file.

### 2.2 The tier thresholds *are* disclosed

This is the most actionable finding in the whole investigation, because it is a number this app already
displays and had no source for.

> "FIG. 13 illustrates an exemplary display of a recovery score index indicated in a circular graphic
> component with **a first threshold of 66% and a second threshold of 33%** indicated." [described]

and in prose:

> recovery "greater than … **66%** that indicates that the user is recovered and is ready for exercise"
> … "lower than … **33%** that indicates that the user has not recovered" [described]

Read against the app's tiers (green 67–100, yellow 34–66, red 0–33 [app]):

* **Green: exact.** The app's lowest green is 67, which is "greater than 66". Identical to the disclosed
  threshold.
* **Red: one value differs.** WHOOP says "lower than 33", i.e. 0–32. The app puts **33** in red. On a
  literal reading, 33 falls in the middle band.

Two honest caveats. The patent **does not settle inclusivity** — the same passage hedges "greater than
(or equal to or greater than)" — and it calls the thresholds **adjustable** ("the thresholds may be
increased for higher planned intensity scores") and loose in the summary ("about 60% to about 80%",
"about 10% to about 40%"). So 66/33 is a **figure callout**, not a stated constant. But it is the only
recovery threshold WHOOP has ever put in print, and the app's green boundary matches it exactly.

The app's tier boundaries are written down once, in `RecoveryState.init(score:)`, which is what makes
this a one-line change if the 33/34 edge is ever revisited.

### 2.3 The HRV window is claimed, twice, and it rules out a whole-night RMSSD

**US9743848B2** (granted 2017-08-29), **claim 1** — and claims 1, 11, 16 and 19 all carry the
limitation:

> "detecting a slow wave sleep period occurring most recently before the waking event; evaluating a
> **quality** of heart rate data using a **data quality metric** for the slow wave sleep period;
> calculating the heart rate variability for **a window of predetermined duration within the slow wave
> sleep period having a highest quality of heart rate data** according to the data quality metric"
> **[claimed]**

**US9750415B2** (granted 2017-09-05), claim 1, claims the timing without the quality gate: "determining
an end of a most recent slow wave sleep state occurring most recently before the waking event;
calculating a heart rate variability of the user **at the end of the most recent slow wave sleep
state** preceding the waking event". **[claimed]**

The rationale, `[0266]`:

> "This moment — the end of the last phase of sleep before waking — is the point at which heart rate
> variability data provides the most accurate and consistent indicator of physical recovery."

| | this app [app] | WHOOP |
| :--- | :--- | :--- |
| what is measured | whole-night RMSSD from the strap's R-R series | HRV in a short window inside the last SWS episode |
| window duration | the night | **[not disclosed]** — "a predetermined duration", no seconds, minutes or beat counts anywhere |
| window selection | n/a | highest **heart-rate data quality** |
| whether it is claimed | — | **yes**, in two granted patents |

**This is the sharpest divergence in the document.** It is not that the app computes WHOOP's HRV less
precisely; it computes a **different measurement**, and on WHOOP's own stated rationale a less stable
one. The app cannot do otherwise — it has no slow-wave detector (§3.1) — but the README-level claim
that the app reproduces WHOOP's recovery must not be read as covering this.

### 2.4 What the patents do corroborate

**RMSSD is named.** `[0161]`: "the HRV metric of the root-mean-square of successive differences of RR
intervals (RMSSD) is used." [described] `ALGORITHMS.md` §1 currently calls the classification of WHOOP's
exported HRV column as RMSSD "an inference". As an *embodiment* that reading is now corroborated; the
inference that WHOOP's *export* is RMSSD remains an inference, because the export does not name it.

**Sleep performance is disclosed, with a worked example.** US9750415B2 `[0271]`:

> "if a user sleeps six hours and needed eight hours of sleep, then the sleep performance may be
> calculated as 75%" [described]

That is this app's `clamp(asleep ÷ need × 100, 0, 100)`. It is the one recovery input the patents
corroborate outright.

**The disclosed HRV *comparison* is a different shape.** `[0161]`: "the magnitude of the differences
between **7-day moving averages and 3-day moving averages** of these readings for a given day"
[described]. A short-vs-long moving-average difference, not a deviation against a 30-day mean. The
baseline is described only as "several days of heart rate data"; a pending application claims a
baseline "measured over two or more days" [pending]. Neither is a 30-day window.

### 2.5 Not in the recovery indicator

**Respiratory rate and SpO₂ do not appear as recovery inputs in any document in this family.** The single
"recovery level … and a respiratory rate" sentence lives in a 2021 menstrual-cycle application
(US20220273232A1), is never quantified, and defines the respiratory rate as itself derived from HRV —
see §5.

---

## 3. Sleep

### 3.1 Sleep stage boundaries: not disclosed, anywhere, confirmed against primary sources

Five documents were read in full for this question — US20240188896A1, US11925473B2, US12575786B2,
US9750415B2, US20220293236A1, including **two granted patents**. The sweep found:

| | |
| :--- | :--- |
| Accelerometer magnitude threshold | **[not disclosed]** |
| Heart-rate criterion for any stage | **[not disclosed]** |
| Epoch length | **[not disclosed]** |
| Minimum stage duration | **[not disclosed]** |
| Any numeric boundary at all | **[not disclosed]** |

Every document either withholds the discrimination rule or explicitly delegates it to an undisclosed
trained model. The most explicit refusal is US20220293236A1 `[0131]`:

> "a machine learning algorithm is trained with user-specific input to determine when he/she is
> awake/asleep and determine from that **the exact parameters that cause the algorithm to deem someone
> asleep**." [described]

The nearest thing to a boundary anywhere is the use of *"slow wave sleep"* as a **selector** for the HRV
window (§2.3) — a use of a stage, never a definition of one. **US9750415B2 claims to key the recovery
score off slow wave sleep without ever defining what makes a period slow wave sleep.**

**`ALGORITHMS.md`'s claim that WHOOP publishes no stage boundaries is confirmed.** The consequence is
worth stating: this app's actigraphy + heart-rate-dip heuristic **cannot be validated against, or
aligned to, anything WHOOP has published.** Any future screen that presents stage boundaries as
WHOOP's would be presenting this app's calibration as a recovered constant.

### 3.2 Sleep need: the shape is disclosed, and one real constant with it

The model's form — the only place in this entire investigation where a **non-trivial numeric constant is
genuinely published**:

```
SleepNeed = Baseline + f1(strain) + f2(debt) − Naps          [described]
f(i)      = 1.7 / (1 + e^((17 − i)/3.5))                     [described]
```

where `i` is strain on a **0–21** scale and `f(i)` is **minutes** of additional sleep. Confirmed
independently in two documents by two separate reads: US9750415B2 `[0273]`/`[0276]` and US12318226 /
US20250380880A1.

| Claim | Tag |
| :--- | :--- |
| The model's functional form, including a `− Naps` term | [described] |
| The strain term is **logistic**, `1.7 / (1 + e^((17−i)/3.5))` | [described] |
| `Baseline` value | **[not disclosed]** |
| `f2(debt)` form and its constants | **[not disclosed]** — "may be scaled, and may be capped at a maximum" |
| The debt cap's **value** | **[not disclosed]** (its **unit**, minutes, is claimed) |
| The accumulation window | **[not disclosed]** |

**This is the one constant this app has never seen and could test.** `SleepNeedMath` fits a **straight
line** — `480 + 6.40 × strain` — where WHOOP describes a **saturating sigmoid**. That is not a different
coefficient; it is a different functional form. And the disclosed form is **bounded by construction**
(asymptote 102 min read as hours), while the app's linear term is unbounded and needs an explicit strain
clamp — the clamp exists to paper over the form.

**Measured against the export, the export does not adjudicate.** 5-fold cross-validation, scored the
repo's own way (implied sleep performance, MAE):

| model | contiguous folds | random folds |
| :--- | ---: | ---: |
| `480 + 6.40 × strain` (shipped) | 3.522 | 3.525 |
| disclosed sigmoid, free scale | 3.700 | 3.594 |

The gap (0.07–0.18 of a point) is **smaller than the spread between fold constructions**, and smaller
than the gap between this measurement and the 3.77 `ALGORITHMS.md` §4 publishes. So the export cannot
choose between them, and the app's linear form is not refuted — it is simply not WHOOP's.

**The disclosure explains an anomaly the doc recorded but could not account for.** §4 notes that
"WHOOP's own API example shows its strain term contributing single-digit minutes where 6.40 implies far
more." The disclosed sigmoid, read as hours, contributes 2.9–51 minutes over the p05–p95 strain range
(4.7–17.0) — single-digit below about strain 8. The observation was real; the patent is why.

**Unit tension in the patent itself.** Read literally as **minutes**, `f(i)` ranges 0.01–1.29, which is
not a sleep duration. Read as **hours** it is plausible. Scale readings tested against the export:
literal minutes → CV 5.971; hours ×60 (asymptote 102 min) → 4.147; free scale (asymptote 171 min) →
3.586. **No natural reading recovers the best fit.** This is unresolved and is recorded as unresolved.

**The accumulated-debt term is granted.** US12318226 is a **grant**, and its abstract states it
calculates "a first sleep debt metric based on user strain and a second sleep debt metric based on
accumulated sleep debt". A live continuation (US 19/225,049, published 2025-09-18) is where a changed
strain coefficient would appear — the one document to watch.

`ALGORITHMS.md` §4 documents the accumulated-debt term as a **deliberate omission**, measured as buying
0.35 of a point (3.77 → 3.41) for a second fitted constant and seven nights of history. That judgement
stands on its own arithmetic; what this file adds is that the patent on the two-term version is granted,
so the omission is a real departure from the disclosed model and should be described as one.

### 3.3 Sleep intention

US11925473B2 (granted 2024-03-12) and US12575786B2 (granted 2026-03-17) — **two grants on one
specification**, an unusually fast second grant that indicates active maintenance.

The decision rule, complete: a probabilistic analysis over historical sleep data using categorical
variables (day of week, season, location) and quantitative variables (duration of the waking event,
duration of the sleep interval, time away from a typical waking time, duration and amount of movement),
optionally a trained ML model, with per-variable weights.

**The threshold is the word "more likely" and nothing else.** [described] / [claimed] — claims 1, 2 and
20 recite "in response to determining … that it is **more likely** that the intention of the user is to
stay awake". **No probability cutoff, no confidence value, no numeric rule.** The only numbers anywhere
in the document are unrelated: a 100% LED duty cycle, "1-2 hours" for REM onset, "24 hours" for the
circadian period, a 75% sleep-performance worked example, and "90%–95%" for sleep achieved during an
opportunity.

### 3.4 The typical range has no patent basis

Nothing in any document read for this investigation describes a per-stage typical range, a percentile
band, or a middle-50% comparison. `SleepTypicalRangeCard`'s window and percentile are this app's own,
as its own documentation already says — this file confirms the negative rather than adding to it.

### 3.5 A correction carried forward

**WO2019168474A1 ("Method, computing device and wearable device for sleep stage detection") is Nitto
Denko Corporation, not WHOOP.** It appears in web searches beside WHOOP patents only because Google
Patents' "similar documents" panel lists them together. It is a PCT (PCT/SG2019/050111), it is ceased,
and **WHOOP's patents do not cite it** — the string does not appear in US11925473B2, US12575786B2,
US20220293236A1 or US20240188896A1. Its logistic-regression-over-11-epochs classifier is a different
approach and is not WHOOP's.

Likewise **US10750958B2 is "Variable brightness and gain for optimizing signal acquisition"**, not a
staging patent.

---

## 4. Stress

**Sources.** Three siblings filed the same day on the same 2022-12-12 priority: **US20240188896A1**
(probability distributions), US20240188865A1 (weighted contributions of cardiac parameters),
US20240194344A1 (machine learning model). All three are **pending applications**; none is granted.
EP counterpart EP4493051A2. Only US20240188896A1 was retrieved in full — the other two were refused by
every source after rate-limiting, and **nothing about their constants is inferred from their sibling.**

### 4.1 Two models, neither of which is a z-score

**The string "z-score" does not occur in the document.** Model 1, the empirical/analytical form:

```
S = alpha · f(motion) · [ w·HR + (1−w)·HRV ]                 [described]
```

where each input is **independently mapped to a 0–3 sub-score first**: HR by a sigmoid over the
resting-to-maximal interval, HRV by **percentile location within a log-transformed 14-day baseline
distribution**. Then the combination is **multiplied** by the motion factor and scaled by `alpha`.

Model 2, the one the title names, scores the **quantile** of a predicted probability distribution of
heart-rate-reserve ratios:

```
HRRR = (HR_cur − HR_base) / (HR_max − HR_rest)               [described]
score = quantile(HRRR | context) / 100                       [described]
```

with the distribution conditioned on motion — "the same elevated heart rate, while a user is at rest,
may indicate greater stress".

### 4.2 What is disclosed

| Constant | Value | Tag |
| :--- | :--- | :--- |
| Output scale | 0–3 | [described] |
| Band edges | 0–1 low · 1–2 medium · 2–3 high | [described] |
| **HRV baseline window** | **14 days** (stated twice) | [described] |
| HRV transform | **log transform** of the baseline distribution | [described] |
| Normalisation | **percentile**, explicitly "percentile based" | [described] |
| Minimum history before personalising | >1000 values or >15 min, or 1–2 full days | [described] |
| Score cadence | every 1 or 5 minutes | [described] |
| Scoring window | 1 or 5 min; useful range 3–10 min | [described] |
| **HR weight `w`** | **0.5** above ~100 bpm; second weight decreases **0.5 → 0** toward rest | [described] |
| Motion factor when idle | "about 1, say 0.98" | [described] |
| HRmax | **220 − age** | [described] |
| Worked example | resting 60, max 190, HR 100 → HR score **2.1** | [described] |
| Worked example | baseline 43–134 ms, current 67 ms → HRV score **2.6** | [described] |

### 4.3 What is not

| | |
| :--- | :--- |
| `alpha` | **[not disclosed]** — "may assume any value or range of values suitable" |
| Accelerometer magnitude threshold | **[not disclosed]** |
| Minimum R-R interval count | **[not disclosed]** |
| An eligibility gate of any kind | **[not disclosed]** — the patent has none |
| A `+1` offset on the output | **[not disclosed]** |
| **Any number recited in a claim** | **[not disclosed]** — every claim recites the comparison structurally |

The full text of US20240188865A1 and US20240194344A1 was **not retrieved**. They share A1's priority,
filing day, publication day and assignee, which makes shared disclosure likely, but that is an
inference and is recorded as one.

### 4.4 This app's stress model, against the disclosure

| | this app [app] | WHOOP |
| :--- | :--- | :--- |
| normalisation | z-score vs 14-day baseline | **percentile** in a **log-transformed** distribution |
| blend | fixed 50/50 | `w = 0.5` above ~100 bpm, rising toward 1 near resting |
| offset | `1.0 + activation` | none |
| motion | **gate** (≤ 1.25 G) | **multiplier**, ≈0.98 at rest |
| minimum R-R | 20 intervals, load-bearing | no gate at all |

**Two things the app landed on independently and can now cite:** the **14-day baseline** and the
**0–3 scale with 1.0/2.0 band edges**. Those are genuine points of agreement.

**A polarity disagreement worth recording rather than resolving.** `[0139]` gives a worked example in
which a *higher* HRV percentile produces a *higher* activation score (2.6), the opposite sign to this
app's `−z_RMSSD`. The example's own arithmetic does not support itself — a log transform of 43–134 ms
puts 67 ms at 4.20, *below* the 4.32 midpoint — and the passage hedges with "(and assuming 67 ms falls
within a relatively high percentile)". So either the example is careless or WHOOP's "activation" framing
differs from this app's stress framing. **This app's convention — higher HRV, lower stress — is the
physiologically standard one and is not changed on the strength of a hedged example.** But the
disagreement is real and is recorded here so it is not rediscovered as a bug.

**One thing this app may be missing.** `[0203]` describes the stress score being "regularized according
to probable physical activities" and "brought closer to an average in proportion to a probability that
the user is active". That is a *shrinkage* of the score toward a mean when the user is probably moving —
a third treatment of motion, distinct from both the gate the app uses and the multiplier in Eq. 1.
Not acted on; noted.

---

## 5. VO₂ max

**The filing.** US 19/561,023 — published as **US20260263002A1**, "Measuring maximal oxygen
consumption", filed **2026-03-09**, published **2026-09-10**. Priority to provisional 63/769,093
(2025-03-09), with a parallel PCT/US26/18336. Assignee Whoop, Inc.

**The publication has now been read** (the assignee register §9 relied on carries no abstract for the
application number, which is why an earlier revision of this file called it a title and a date and
nothing more).

**What it discloses is a model-selection architecture, not a formula** [described]:

* A **plurality of models** (MODEL 1 … MODEL N) held in a data store, each adapted to the data
  available, with a **precedence order** that favours the estimate expected to be more accurate —
  the filing's own example is exact manual entry → passive-plus-manual → active → passive-plus-active →
  passive — and **data-driven transitions** between them as better sources arrive or older ones go
  stale.
* **Inputs named:** photoplethysmography acquired during sleep (and sleep detected from it),
  demographics, *"one or more descriptive statistics for heart rate zones of the user during
  activity"*, GPS acquired during a run, and a clinical measurement.
* A first model that is a **regression model**; a second that uses the run's PPG plus GPS and may
  adjust the first model's result by the difference against a clinical measurement within a week of
  it. Estimates on a daily or weekly cadence over a historical window.

**What it does not disclose is any number.** The description locates the constants explicitly outside
the text — models include *"any data, weights, coefficients, and the like that are **precomputed** and
used at inference time"*. There is **no heart-rate-ratio term and no `15.3`**, and the filing **does
not cite Uth**: the only case-insensitive `uth` matches in the document are *truth* and *authorize*,
and every `220` is a reference numeral (user device 220), not a maximal-heart-rate formula.

**So the comparison with `Vo2MaxMath` resolves the way every other metric here does.** WHOOP discloses
a **regression-and-GPS suite**; this app computes `15.3 × HRmax / HRrest` (Uth et al. 2004, SEE
4.7 mL·kg⁻¹·min⁻¹ when `HRmax` is age-predicted), the one model in `ALGORITHMS.md` whose constant is
quoted from a paper rather than fitted. These are not the same model at two precisions — they are
different models, and the disclosed one needs a GPS-tracked run, a clinical measurement, or a trained
regression over sleep PPG. **The app's ratio is a forced substitute for all three, not a less precise
version of the disclosure.** No patent-sourced replacement for `15.3` exists to adopt.

Adjacent: a 2025 *Nature Communications* paper with WHOOP-affiliated authors (s41467-025-58271-x)
describes exercise strain computed as summated-heart-rate-zones — durations in six zones (0–5)
multiplied by a per-zone factor (`zone 1 = 1; zone 2 = 2; …`) and summed. **That is structurally the
same shape as the patent's `w(v)` and as this app's zone table**, and it is the closest thing to a
published WHOOP strain implementation that exists. It is a paper, not a patent, and the wording above
is second-hand (the article itself redirected to an IdP) — treat it as a strong lead, not a citation.

---

## 6. Respiration, SpO₂, blood pressure

### 6.1 Respiration — no RSA-derived respiration patent

**No WHOOP document was found whose claimed subject is deriving respiration from R-R intervals.** A
full-text search for "respiratory sinus arrhythmia" with a wearable limitation returned no WHOOP
document at all.

What WHOOP does claim in this space:

* **The infection-monitor family** — US20230106450A1 / WO2021252768A1 / EP4165658B1 (granted 2025-01-01).
  "Heart rate data from a wearable physiological monitor can be used to determine a respiratory rate for
  a wearer", then a **respiratory-rate baseline** and deviations from it indicating infection onset.
  Respiration from *heart rate*, in a baseline-plus-deviation wrapper.
* **US20250339036A1** (blood pressure, §6.3) is the **only WHOOP document found that names respiratory
  sinus arrhythmia**, as one of several candidate sources for respiratory onset detection alongside
  accelerometer local extrema and pulse data aligned to deep respirations.
* **The cycle-coaching grants** (US11627946B2, US12220112B2) list respiration among measured parameters
  and say it "may be determined based on heart rate variability" — the closest phrasing to this app's
  mechanism anywhere in the portfolio, but a dependent mention inside a menstrual-cycle claim set.

**For `RespiratoryRateMath` this settles one thing and leaves another open.** The mechanism — band-limited
modulation of the R-R series — is one WHOOP names. **The constants are not published anywhere**, and
this remains the one number in this app with no ground truth: the export carries no R-R series, every
night the app can show was imported, and the estimator's constants come from published window lengths
plus a synthetic noise measurement rather than from a fit. Nothing here changes that.

### 6.2 SpO₂ — a different measurement entirely

**WHOOP owns no arterial SpO₂ pulse-oximetry patent or application.** Its entire oxygen estate is
**muscle/tissue oxygen saturation (SmO₂) via continuous-wave NIRS**, from the **Dynometrics / Humon**
family — a separate tissue-oxygen company in the NIRS space, and **not an earlier name of WHOOP**,
which is the mistake the first grant below invites (§9 has what the registers read here do and do not
show about the transfer):

* US10092228B2 (granted 2018-10-09, assignee shown as **Dynometrics Inc.**) and US10799162B2 (granted
  2020-10-13, assignee Whoop) — "Tissue oxygen saturation detection".
* US12727796 (granted 2026-09-08), US20210045686A1 — the sensor in a compression garment.
* US12594037 — "Pressure sensitive strap", two LEDs near 660 and 855 nm, 3–4 photodetectors at 5–50 mm,
  **plus pressure/tension sensors to flag when strap pressure is corrupting the optical reading**.

**SmO₂ is a NIRS tissue measurement, not a PPG ratio-of-ratios.** If a future screen implies SpO₂, that
is a hardware gap rather than a software one.

### 6.3 Blood pressure — the clearest current R&D signal

Six filings in thirteen months, all naming Ghannad-Rezaie, Tavakoli and Sevakula, all built on **PPG
plus a controlled mechanical perturbation** rather than pure pulse morphology: US20240298895A1 (haptic
calibration, across a frequency range), US20240298904A1 (force sensing, with an **oscillometric
envelope** and an explicit **transfer function**), US20250339036A1 (ML: sleep-session resting HR →
baseline BP indicator), plus EP4661742A1, EP4676316A1, WO2025/230791. **No grant among them.**

---

## 7. The portfolio, and who wrote it

**90 US records** as reported by the IPqwery assignee register: **45 granted** (29 utility + 16 design)
and **45 published applications**. Three lineages that barely overlap:

| Lineage | Who | When | What |
| :--- | :--- | :--- | :--- |
| Algorithmic | Ahmed, J. Capodilupo, Nicolae | 2014–2016, continuing | HRV, recovery, strain, sleep/HRV |
| Coaching / physiology | E. Capodilupo + Ware, Jasinski, Presby | 2020–2026 | stress, cycle, MSK strain, movement score |
| Sensor science | Ghannad-Rezaie + Tavakoli | 2017–2026 | data quality, PPG, BP, tissue, glucose |

Inventor counts over the 88 records carrying a full list:

| Inventor | Records | Note |
| :--- | ---: | :--- |
| John Vincenzo Capodilupo | 33 | most prolific; present in nine of ten families |
| Aurelian Nicolae | 28 | hardware axis from 2021 onward; 9 designs |
| William Ahmed | 25 | the algorithmic lineage — but **9 of the 25 are design patents** |
| Emily Rachel Capodilupo (Breslow) | 23 | female-physiology and coaching; name variant, same person |
| Ghannad-Rezaie / Tavakoli | 16 each | co-occur on 15 of 16; the current technical core |

### The inventor footprint, from a second register

A separate pass read the **Justia inventor pages** — reached through the `r.jina.ai` text-extraction
proxy, since the direct route 403s (§9) — paginating each inventor to the end of the list and merging
the recorded name variants. **These counts are not comparable with the table above and are roughly
double it**, because the two count different populations: IPqwery counts documents *assigned to
"Whoop, Inc."*, while a Justia inventor page counts documents *naming that person*, which includes
the pre-2014 filings made under the company's earlier name (still visible in §1's source list as the
Whoop / **Bobo Analytics** family). Neither is family-deduplicated. Treat the shape as the finding,
not the levels.

| Inventor | Documents | Note |
| :--- | ---: | :--- |
| John Vincenzo Capodilupo | 58 | two recorded name forms, **31 + 27**, verified to share **zero** publication numbers |
| Aurelian Nicolae | 47 | **ahead of founder/CEO William Ahmed** — not the expected shape |
| William Ahmed | 45 | the algorithmic lineage |
| Emily Rachel Breslow → Capodilupo | 31 | 4 + 27, name variant, same person |
| Mostafa Ghannad-Rezaie | 26 | sensor science; near-identical set to Tavakoli |
| Behnoosh Tavakoli | 24 | the pair are each other's most frequent co-inventor |

**The ordering is decided by design patents, and that is worth stating precisely.** Design numbers
begin `D`, and separating them reconciles the two headline counts exactly: Ahmed's 45 is **38 numeric
+ 7 design**, Nicolae's 47 is **38 numeric + 9 design**. On utility and application documents the two
are **tied at 38**, and Nicolae's lead exists only in the design column. Re-measured directly rather
than carried over, because the first pass at this reported a tie that turned out to be an artefact of
a regex that excluded `D`-prefixed numbers.

Two things it also establishes. The **three lineages in the table above are confirmed by an
independent source**, including the split between the founders' algorithmic work and the sensor
science. And the **newest fronts are the sensor scientists', not the founders'**: the 2026 filings on
edge/foundation-model processing and on glucose name Ghannad-Rezaie and Tavakoli essentially alone.

**The four 2014 foundational filings** all name the same three people — Ahmed, J. Capodilupo, Nicolae —
and are the parents of the algorithmic families:

| Filed | Application | Granted as | Title |
| :--- | :--- | :--- | :--- |
| 2014-03-05 | 14/198,437 | US11185241 | Continuous heart rate monitoring and interpretation |
| 2014-05-28 | 14/289,330 | US11602279 | Automated exercise recommendations |
| 2014-07-09 | 14/326,598 | US10264982 | Physiological measurement system with motion sensing |
| 2014-07-09 | 14/326,810 | US11574722 | **Determining a recovery indicator using heart rate data** |

**The single most important priority date in the portfolio is 2012-09-04**, held by 14/326,810 via
provisionals 61/696,525 and 61/736,310 — it predates the company's own name change and everything the
recovery family claims traces back to it.

### Do not attribute these to WHOOP

The `assignee=Whoop` result set contains unrelated entities, and two of them are easy to mistake:

* **US20210361177A1** "Non-Invasive Continuous Blood Pressure Monitoring" — **Huma Therapeutics Limited**.
* **US12193790** / PGR2026-00003 — **Omni MedSci**. WHOOP appears only as the **IPR petitioner**
  challenging it, i.e. the challenger, not the owner. This is the origin of the apparent "WHOOP SpO₂
  patent" hit in searches.
* Also: *Whoop Wireless Llc* (signal-strength adjustment) and a different *Whoop, Inc.* (2009 dynamic
  pricing).

---

## 8. What this changes, and what to do about it

**Nothing in this document has been applied to the code.** It is a record. The changes it argues for,
in rough order of how well-sourced they are:

1. **Cite the tier thresholds.** `ALGORITHMS.md` §3 and `RecoveryState.init(score:)` can now name a
   source for 66/33 rather than presenting the boundaries unsourced. The 33/34 edge is the one open
   question and the patent does not settle it.
2. **Label Strain §2's constants as this app's own**, alongside the labels `SleepNeedMath` and
   `StressMath` already carry. The architecture is disclosed; the five zones, the %HRR boundaries, the
   1.0–16.0 weights and `k` are not, and the boundaries are a **forced substitute** for AT and CPT.
3. **State the HRV divergence in §3.** The app computes whole-night RMSSD where WHOOP claims a
   slow-wave-anchored window. This is a different measurement, and the doc should say so rather than
   leaving it to be read as a less precise version of the same one.
4. **The sleep-need sigmoid is the one constant worth testing.** It is disclosed, it has a different
   functional form from the shipped linear term, and the export does not adjudicate between them — so
   the honest position is that both are available and the app ships the one it fitted. §4 should say
   that rather than implying the fitted form is the only candidate.
5. **Update the §4 note on the omitted debt term** to record that the two-term version is granted.

**What should *not* change.** The app should not adopt disclosed numbers it cannot honour. `ALGORITHMS.md`
§2's zone table is not wrong because WHOOP's is AT/CPT-based — it is the best available substitute for a
measurement this app cannot make, and replacing it with four bands at unrealisable thresholds would be
strictly worse. The same applies to `−z_RMSSD` against the patent's hedged example.

---

## 9. Method and coverage limits

Everything above came from **full-text reads** of paragraph-numbered sources: Google Patents raw HTML
(equations extracted from MathML, because a rendered page mangles them), FreePatentsOnline for granted
claim sets, the EPO publication server, WIPO Patentscope, and the IPqwery assignee register. Where a
source was unreachable, the row says so rather than being reconstructed from memory.

**Limits, stated rather than papered over:**

* **Justia's document pages were never reached directly, but its inventor pages were — through a
  proxy.** `patents.justia.com` returns HTTP 403 (Cloudflare) to plain curl, browser-UA curl, WebFetch
  and two CORS proxies. The `r.jina.ai` text-extraction proxy does return the rendered listing
  (verified: HTTP 200 and a full page with publication numbers, abstracts, inventors and assignees),
  and the inventor footprint in §7 was read through it and paginated to the end of each list. The
  **document-level** reads above still come from the other registers, so the 403 is a limit on method,
  not a claim that the content is unreachable.
* **Google Patents rate-limited after the first page.** Non-US coverage is page-0 only, so the 44 EUIPO
  designs and the EP/WO/CA/AU/JP/GB members listed by the sweep are **representative, not exhaustive**.
* **The two inventor count bases in §7 disagree by roughly 2×, and neither is family-deduplicated.**
  They count different populations (assignee vs inventor-name), so the levels are not comparable and
  the section says so. The name-form splits are verified; the corporate-lineage claim behind the
  Dynometrics / Humon documents (§6.2) is not — no register read here shows the acquisition, only that
  the assignee of record on that family changes from Dynometrics to Whoop between the 2018 and 2020
  grants.
* **Figures were not read.** Google Patents' fetched HTML carries figure *captions*, not images, and the
  USPTO PDF of US9743848B2 is 63 pages of 1-bit CCITT-Fax scans with no OCR available. Every figure
  reference above (FIG. 13's 66/33 in particular) comes from the **specification text that describes
  the figure**, which is why it is tagged [described] and not treated as a stated constant. No figure is
  known or suspected to carry a formula not otherwise in the text, but that cannot be positively ruled
  out.
* **Status is as the register reports it** — "In Force" or "Pending". An abandoned application is
  simply missing from an assignee register rather than marked, so **abandonment is under-represented**
  and no record above is inferred to be abandoned unless a named source says so (US20140309542A1 is).
* **Only 8 of 90 records carried priority data**; the priority spine in §7 is built from filing dates
  and shared specification text (the recovery family's text is byte-identical, which is how the
  continuation links were verified).
* **Three stress publication numbers are unresolved** (applications 18/536,717, 18/536,730, 18/536,748)
  — same-day filings with near-identical titles defeated exact-title matching. The application numbers
  are known; the publication numbers are not.
* **US20240188865A1 and US20240194344A1 were not retrieved** in full. Nothing about their constants is
  inferred from US20240188896A1.
* **US 19/561,023 and US 19/554,044** were surfaced as titles and dates only — neither register carries
  an abstract.

A re-run of any of the blocked sources needs a different network path. The working data from the sweep
is on disk at `/tmp/whoop_us_inventory.json` (90 records with abstracts, IPC and normalised inventors)
and `/tmp/gp_p0.json` (the Google Patents page including non-US family members).

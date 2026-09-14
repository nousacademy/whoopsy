import Foundation

/// Respiratory rate from the R-R series, by respiratory sinus arrhythmia.
///
/// Respiration modulates the R-R interval — inhalation shortens it, exhalation lengthens it — so a
/// tachogram carries the breathing waveform as a slow modulation, and a peak in its 0.1–0.4 Hz band
/// **is** the breathing rate. This is WHOOP's own documented mechanism (they derive the figure from
/// PPG during the main sleep period) and the standard ECG-derived-respiration family.
///
/// ## The contiguity problem, which is the whole of the difficulty here
///
/// `BiometricSample.rrIntervalsMs` holds **one notification's** beats. Within a notification those
/// beats are adjacent, in exact order, by definition. **Across** notifications they are not: a
/// notification is stamped with the instant the app decoded it, which is when the app *heard about*
/// the beats rather than when they happened, and nothing in the schema says whether the first beat of
/// the next notification follows the last beat of this one or comes a minute later. A single
/// notification also carries far fewer than the 32 s of beats one analysis window needs, so packets
/// must be chained — and chained only where the beats really are continuous.
///
/// The test that decides it uses the only two quantities that exist: the beats' own durations and the
/// wall-clock gap between arrivals. Both packets are stamped at decode, and each packet's intervals
/// are the intervals **since the previous notification** (that is what the SIG Heart Rate
/// Measurement characteristic's R-R field means — a collector that could not reconstruct a
/// continuous series across notifications would have no use for the field at all). So packet *i+1*'s
/// intervals span from packet *i*'s last beat to packet *i+1*'s last beat, and
///
///     span = Σ rr of packet i+1 / 1000          (seconds of beats in the later packet)
///     dt   = arrival_{i+1} − arrival_i
///     seam = dt − span
///
/// is the residual: ≈ 0 when nothing was missed, ≈ one R-R interval or more when a beat was
/// dropped. Contiguous iff `|seam| ≤ seamToleranceSeconds`.
///
/// **Pairing the seam against the later packet's span is not an arbitrary choice**, and the earlier
/// packet's span is the tempting wrong answer — the two agree whenever the heart rate is steady,
/// which is most of the time, and differ by exactly one beat otherwise. The seam being measured is
/// the gap *preceding* packet *i+1*'s beats, so it is packet *i+1*'s own duration that has to account
/// for it.
///
/// This is the rule that keeps the model from differencing beats that were never adjacent — the
/// defect `CLAUDE.md` records against the two RMSSD consumers, which this type must not repeat.
///
/// ## What is deliberately *not* reused from `HeartRateVariabilityMath`
///
/// The obvious move is to clean each packet with `HeartRateVariabilityMath.filterRRIntervals`, and it
/// is wrong here for a reason that does not apply to RMSSD. That function **deletes** intervals, and
/// its callers only ever use the surviving *values*, so a deleted interval costs them nothing. A
/// tachogram is a series in **time**, so a deleted interval silently removes that much real elapsed
/// time and stitches the beats on either side together — a 4 s artifact excision becomes a 4 s
/// discontinuity drawn as an adjacent pair. No amount of book-keeping repairs it while the deletion
/// happens.
///
/// So rejection happens at **packet** granularity instead: a packet carrying any interval outside
/// `HeartRateVariabilityMath`'s own `minValidRRMs`/`maxValidRRMs` is dropped whole. That keeps a
/// single definition of what a plausible interval is, and it fails in the safe direction — a dropped
/// packet breaks the run at the seam test, so the night reports `nil` rather than a tachogram with a
/// hole stitched shut.
///
/// ## The estimator
///
/// Charlton et al. 2016 (Physiol Meas) is the reference for the window: it validates adjacent **32 s**
/// windows and finds 60 s materially better, with anything below ~20 s indefensible. 32 s is the
/// shortest defensible window and is what the strap's packet sizes can actually assemble, so that is
/// what this ships.
///
/// Per window: resample the beat series onto a uniform grid, remove the mean and any linear trend,
/// taper with a Hann window, and evaluate a naive DFT **restricted to the band** — at most 61 bins at
/// `frequencyStepHz`, which at 129 samples is a few thousand multiply-adds and needs no FFT and no
/// Accelerate. The report is the **median** of the accepted windows, rounded to one decimal, which is
/// also the shape WHOOP describes for its own figure.
///
/// ## What this cannot claim
///
/// **The estimator is unvalidatable against this app's own data, and that is a fact about the export
/// rather than a gap in the work.** `physiological_cycles.csv` carries WHOOP's own
/// `Respiratory rate (rpm)` for 910 nights and **no R-R series at all**, so there is no night in this
/// app's possession where a known respiratory rate and the beats that produced it are both present.
/// What is testable is the plumbing — a synthetic tachogram modulated at a known rate must be
/// recovered — and what can be quoted is the published error of the algorithm class: the best
/// ECG-derived-respiration algorithms reach bias 0.0 bpm with 95% limits of agreement of ±4.7 bpm,
/// while one older-adult cohort saw 6 of 10 subjects err by 6–17 bpm. The figure is a calibration in
/// the same sense `SleepNeedMath` and `StressMath` are, with a weaker evidence base than either,
/// because those could be fitted against a column and this cannot.
///
/// The band is the one check the export *does* afford: its own respiratory rates are 910 values at
/// mean 15.57, sd 0.83, p05 14.5 / p50 15.5 / p95 17.1 — comfortably inside 6–24 bpm, which is what
/// says the band is right for a sleeping adult even though no tachogram can be checked against it.
public enum RespiratoryRateMath {

    /// One BLE notification's beats, as this model needs them.
    ///
    /// A plain value rather than a `BiometricSample`, because `Core` holds the math and does not reach
    /// into `Domain` — `SleepConsistencyMath.Night` exists for the same reason.
    public struct BeatPacket: Sendable, Equatable {
        /// The instant the app decoded the notification, **not** a beat time. Used to place the
        /// packet's beats and to test contiguity; never read as when any individual beat happened.
        public let arrival: Date
        /// The packet's intervals in milliseconds, in wire order. Adjacent beats, by definition, and
        /// the first one bridges from the previous notification's last beat.
        public let rrIntervalsMs: [Double]

        public init(arrival: Date, rrIntervalsMs: [Double]) {
            self.arrival = arrival
            self.rrIntervalsMs = rrIntervalsMs
        }
    }

    // MARK: - Windowing

    /// The analysis window. Charlton 2016 validates 32 s and finds 60 s better; 32 s is the shortest
    /// window that is defensible at all, and it is what the strap's packets can assemble.
    public static let windowSeconds: Double = 32.0

    /// How far the window advances between estimates. Shorter than the window on purpose: the windows
    /// are overlapping views of one run, and the median over them is the reported figure.
    public static let windowStepSeconds: Double = 5.0

    /// A run of contiguous beats whose own total duration is shorter than one window produces nothing.
    public static let minimumRunSeconds: Double = 32.0

    /// How many windows must survive for a median to mean anything. Two values have no middle.
    public static let minimumWindows = 3

    // MARK: - Contiguity

    /// How much residual time the seam between two notifications may carry and still count as
    /// continuous, in **seconds**.
    ///
    /// Flat, and derived rather than tuned, because there is no data in this app to tune it against.
    /// The residual it has to absorb is arrival jitter plus the R-R quantization the decoder imposes:
    ///
    ///     quantization   1/1024 s per interval, so 0.977 ms; 60 beats of a packet is 58.6 ms worst case
    ///     arrival        BLE scheduling and decode latency, budgeted at 100 ms
    ///     total          ≈ 0.16 s, and 0.20 is ~1.25× that
    ///
    /// The other end is what makes it a *test* rather than a tolerance: 0.20 s is well under
    /// `HeartRateVariabilityMath.minValidRRMs` (300 ms), so a single dropped beat — one whole R-R
    /// interval, 600–1000 ms at a sleeping heart rate — can never hide inside it. There is more than
    /// a 3× margin either way.
    ///
    /// **If the strap does not in fact bridge its intervals across notifications, this rejects every
    /// seam and every night reports `nil`.** That is the failure this constant chooses: a dash, which
    /// is honest, over a tachogram assembled from beats that were never adjacent, which is not. It is
    /// the same trade the whole no-measurement discipline makes.
    public static let seamToleranceSeconds: Double = 0.20

    // MARK: - Spectral estimate

    /// The uniform grid the tachogram is interpolated onto. Well above twice the band's top edge.
    public static let resampleHz: Double = 4.0

    /// How many points one window's uniform grid holds — the window at `resampleHz`, inclusive of
    /// both ends, and therefore the length of every row of `Basis`.
    static let sampleCount = Int((windowSeconds * resampleHz).rounded()) + 1

    /// The respiratory band, in Hz: 6 to 24 breaths per minute. The effective band's top edge may be
    /// lower than `bandHighHz` — see `resolvableHighHz`.
    public static let bandLowHz: Double = 0.1
    public static let bandHighHz: Double = 0.4

    /// Frequency resolution of the DFT sweep — 0.3 bpm, refined below the bin by parabolic
    /// interpolation of the peak's two neighbours.
    public static let frequencyStepHz: Double = 0.005

    /// How many times the band's **mean** power the peak bin must hold to be read as a rate.
    ///
    /// A flatness test: a spectrum with no dominant peak is noise, and reporting its argmax would be
    /// reporting the largest wobble in a signal that has no breathing in it. This is this app's own
    /// threshold, and unlike every other constant here it has **no published counterpart to anchor
    /// it** — there is no tachogram in the export to tune it against.
    ///
    /// **Against the mean, not against a share of the total**, and that is a correction rather than a
    /// preference. A share of the summed band power reads as a property of the signal and is not one:
    /// the probe grid is six times finer than a 32 s window can resolve, so refining
    /// `frequencyStepHz` would move the same tachogram's figure without changing the tachogram — the
    /// ratio is proportional to the probe spacing. Dividing by the mean removes the dependence, since
    /// both the peak and the mean scale alike when the grid is refined.
    ///
    /// The floor it has to clear is arithmetic. The band holds about ten independent resolution cells —
    /// 0.3 Hz of bandwidth against the 1/32 s a 32 s window resolves — so the largest of ten
    /// independent noise bins sits at the tenth harmonic number, `H₁₀ ≈ 2.93`, times the mean. That is
    /// a floor and not a bound, and what matters is the **night**-level rate rather than the
    /// per-window one: a night is scored if `minimumWindows` of its windows clear the bar, so at
    /// roughly 74 windows in a 400 s run even a 3 % per-window rate makes a fabricated figure a near
    /// certainty. Measured over 40 synthetic noise-only nights per noise model (white at 40 ms and at
    /// 60 ms, and a pink series of four AR(1) processes), the fraction of nights reported at all is
    /// 0.80 at 4.5, 0.03 at 5.0, and **0 of the 120 nights at 5.5**.
    ///
    /// The cost is sensitivity, and it is real: at 5.5 a 40 ms modulation on 25 ms of broadband
    /// variability is still reported in every night, but a 30 ms modulation on 40 ms is reported in
    /// one night in five and a 20 ms modulation on 50 ms never. Those nights draw `—`. That is the
    /// honest answer for a tachogram carrying no resolvable respiratory peak, and the trade is made in
    /// this direction deliberately: the alternative is a fabricated breathing rate on a screen whose
    /// entire no-data discipline exists to prevent exactly that. Every figure quoted here is
    /// synthetic, because the export carries no R-R series — see the type's own note on what this
    /// estimator cannot be validated against.
    public static let minimumPeakToMeanRatio: Double = 5.5

    /// How much of the Nyquist frequency the band's top edge may reach.
    ///
    /// The tachogram is sampled at the beat rate, so the highest modulation it can carry is half of
    /// it — a respiratory rate of `bandHighHz × 60` = 24 bpm needs **48** beats per minute to exist at
    /// all. Sleeping heart rates reach down into the 40s, so this is a live constraint rather than a
    /// formality. The 10% margin keeps the estimate off the fold, where a real component and its
    /// alias are the same reading.
    ///
    /// The band narrows rather than the night failing: at 45 bpm the ceiling is 0.3375 Hz (20.3 bpm)
    /// and everything below it is still measured. The night reports `nil` only if the ceiling drops
    /// far enough that no window can hold a peak — a heart rate no living sleeper reaches.
    public static let nyquistMargin: Double = 0.9

    /// The heart rate at which `bandHighHz` stops being resolvable — `2 × bandHighHz × 60`. Named so
    /// the Nyquist constraint is a number in the code rather than an argument in a comment.
    public static let bandTopHeartRateBpm: Double = 48.0

    /// A peak near either edge of the resolvable band is a signal from **outside** the band, not a
    /// breathing rate at its limit.
    ///
    /// Load-bearing, and the reason is arithmetic rather than taste: a Hann taper's main lobe is
    /// `4/T` wide, so for a 32 s window it spans 0.125 Hz. A 5 bpm modulation at 0.083 Hz leaks its
    /// whole main lobe into the bottom of the band and puts its in-band maximum on the *first* bin,
    /// and a 30 bpm modulation at 0.5 Hz leaves a tail that rises toward the top one. Both would pass
    /// a flatness test; neither is a breathing rate.
    public static let rejectsEdgePeak = true

    /// How many bins at each end of the probed band are treated as edge.
    ///
    /// **One bin is not enough**, and that is measured rather than defensive. The in-band maximum of
    /// an out-of-band modulation sits *near* the edge, not necessarily *on* it: a 30 bpm (0.5 Hz)
    /// modulation at a 100 bpm heart rate peaks on bin 59 of 61 — one inside the top — at 5.61× the
    /// band's mean, which clears `minimumPeakToMeanRatio` and was reported as a confident 23.6 bpm for
    /// a signal with no in-band component at all. With this guard the same signal is declined in every
    /// one of 40 seeds, and sweeping the guard across the whole measurement moved nothing else: the
    /// noise columns, the recovered tones and the below-band case are identical at one bin and at two.
    ///
    /// The cost is the top of the band: the effective range becomes 6.4–23.4 bpm at a normal heart rate
    /// rather than 6.3–23.7. That is 0.3 bpm off each end of a range no sleeping adult occupies — the
    /// export's own `Respiratory rate (rpm)` column runs p05 14.5 to p95 17.1 — and it is the right
    /// side of the trade this app makes everywhere else: a narrow band that draws `—` beats a wide one
    /// that invents a rate.
    ///
    /// What it does **not** fix is folding, which is a property of the tachogram rather than of the
    /// band edge and is documented in `ALGORITHMS.md`: a 40 bpm modulation puts its second harmonic at
    /// 1.333 Hz, which the beat-rate sampling folds to 0.333 Hz and reports as ~20 bpm. No edge rule
    /// reaches that, because the peak is not near an edge.
    public static let edgeGuardBins: Int = 2

    /// Fraction of a run's beats that may fall outside a classified-asleep interval before the run is
    /// dropped. WHOOP's own figure is a sleep-period figure, so a run the classifier called awake is
    /// not the measurement being reproduced.
    public static let awakeBeatRatioCeiling: Double = 0.5

    /// The reported figure's own bounds, in breaths per minute. The band already enforces these; they
    /// are named so the conversion back from Hz is checked rather than assumed.
    public static let minimumBreathsPerMinute: Double = 6.0
    public static let maximumBreathsPerMinute: Double = 24.0

    /// The night's respiratory rate in breaths per minute, or `nil` when the beats cannot support one.
    ///
    /// **`nil`, never `0.0`.** An unmeasurable night is absent, and `0` would be the claim that the
    /// user stopped breathing. This deliberately does **not** copy
    /// `HeartRateVariabilityMath.calculateRMSSD`, which returns exactly `0.0` on insufficient data.
    ///
    /// - Parameters:
    ///   - packets: Beat packets in any order; they are sorted by arrival. Packets with no intervals,
    ///     and packets carrying an implausible interval, are dropped — which is what makes an
    ///     export-shaped sample set produce `nil` rather than a fabricated rate.
    ///   - asleepIntervals: The intervals the classifier called asleep, in the same clock as the
    ///     packets' arrivals. **Empty means no classification was available** and the filter is
    ///     skipped; a non-empty list that covers none of a run drops that run.
    public static func respiratoryRate(
        from packets: [BeatPacket],
        asleepIntervals: [DateInterval] = []
    ) -> Double? {
        let usable = usablePackets(from: packets)
        guard !usable.isEmpty else { return nil }

        var estimates: [Double] = []
        for run in contiguousRuns(in: usable) {
            estimates.append(contentsOf: windowEstimates(in: run, asleepIntervals: asleepIntervals))
        }

        guard estimates.count >= minimumWindows else { return nil }
        return (median(of: estimates) * 10).rounded() / 10
    }

    // MARK: - Packets

    /// The packets that can contribute beats, in arrival order.
    ///
    /// A packet is dropped **whole** when any of its intervals is outside
    /// `HeartRateVariabilityMath`'s plausible range. Dropping the interval alone would be the cheaper
    /// edit and the wrong one — see the type's doc comment: the tachogram is a series in time, so
    /// removing an interval removes real elapsed time and joins beats that were not adjacent.
    /// Rejecting the packet leaves a gap instead, and the gap is what the seam test sees.
    public static func usablePackets(from packets: [BeatPacket]) -> [BeatPacket] {
        packets
            .filter { packet in
                !packet.rrIntervalsMs.isEmpty && packet.rrIntervalsMs.allSatisfy {
                    $0 >= HeartRateVariabilityMath.minValidRRMs
                        && $0 <= HeartRateVariabilityMath.maxValidRRMs
                }
            }
            .sorted { $0.arrival < $1.arrival }
    }

    // MARK: - Runs

    /// Maximal chains of packets whose beats are actually continuous. See the type's doc comment.
    public static func contiguousRuns(in packets: [BeatPacket]) -> [[BeatPacket]] {
        var runs: [[BeatPacket]] = []
        var current: [BeatPacket] = []

        for packet in packets {
            if let previous = current.last, !isContiguous(previous, packet) {
                runs.append(current)
                current = []
            }
            current.append(packet)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Whether the later packet's beats continue the earlier packet's without a missed beat.
    ///
    /// The residual is measured against the **later** packet's own span, because that is the packet
    /// whose intervals the seam precedes. See `seamToleranceSeconds`.
    public static func isContiguous(_ previous: BeatPacket, _ next: BeatPacket) -> Bool {
        let span = next.rrIntervalsMs.reduce(0, +) / 1000.0
        guard span > 0 else { return false }

        let gap = next.arrival.timeIntervalSince(previous.arrival)
        guard gap >= 0 else { return false }

        return abs(gap - span) <= seamToleranceSeconds
    }

    // MARK: - Beats

    /// A run's beat series as `(time, interval)` pairs, in seconds since the reference date and
    /// milliseconds.
    ///
    /// **Anchored per packet, not per run.** Each packet's beats are placed by counting backwards from
    /// that packet's own arrival instant, which is where its last beat sits. Anchoring the whole run on
    /// the first arrival and accumulating forward would instead carry every seam's residual into the
    /// rest of the night — a random walk of a fraction of a second per seam, thousands of seams deep,
    /// where the modulation being measured has a period of 2.5 to 10 seconds. Per-packet anchoring
    /// bounds each beat's error by its own packet's seam residual and lets the detrend absorb what is
    /// left.
    ///
    /// An interval is plotted at the **later** of the two beats it spans — the standard tachogram
    /// convention, and the one that makes the bridging interval of a packet land exactly where the
    /// gap it measures began.
    ///
    /// Times are forced strictly increasing. A seam residual can legitimately be slightly negative,
    /// which would place the next packet's first beat a little before this packet's last one; the
    /// overlapping point is dropped rather than interpolated over.
    static func beats(in run: [BeatPacket]) -> (times: [Double], values: [Double]) {
        var times: [Double] = []
        var values: [Double] = []
        var last = -Double.greatestFiniteMagnitude

        for packet in run {
            let arrival = packet.arrival.timeIntervalSinceReferenceDate
            var remaining = packet.rrIntervalsMs.reduce(0, +) / 1000.0
            for rr in packet.rrIntervalsMs {
                remaining -= rr / 1000.0
                let time = arrival - remaining
                guard time > last else { continue }
                times.append(time)
                values.append(rr)
                last = time
            }
        }
        return (times, values)
    }

    /// A run's total beat duration in seconds — what `minimumRunSeconds` is measured against, and
    /// what the seam residual is measured against within a packet.
    static func spanSeconds(of run: [BeatPacket]) -> Double {
        run.reduce(0) { $0 + $1.rrIntervalsMs.reduce(0, +) / 1000.0 }
    }

    /// The highest modulation frequency a run's beats can carry, given their median interval.
    ///
    /// Nyquist is half the beat rate, so the ceiling is `heartRateBpm / 120`, held back by
    /// `nyquistMargin` and never above `bandHighHz`.
    public static func resolvableHighHz(medianRRMs: Double) -> Double {
        guard medianRRMs > 0 else { return bandLowHz }
        let heartRateBpm = 60_000 / medianRRMs
        return min(bandHighHz, heartRateBpm / 120.0 * nyquistMargin)
    }

    // MARK: - Windows

    /// Every accepted estimate, in breaths per minute, for one contiguous run.
    static func windowEstimates(
        in run: [BeatPacket], asleepIntervals: [DateInterval]
    ) -> [Double] {
        guard spanSeconds(of: run) >= minimumRunSeconds else { return [] }

        let (times, values) = beats(in: run)
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else {
            return []
        }

        if !asleepIntervals.isEmpty {
            let asleepBeats = times.filter { time in
                let instant = Date(timeIntervalSinceReferenceDate: time)
                return asleepIntervals.contains { $0.contains(instant) }
            }
            let awakeRatio = 1.0 - Double(asleepBeats.count) / Double(times.count)
            guard awakeRatio <= awakeBeatRatioCeiling else { return [] }
        }

        let ceiling = resolvableHighHz(medianRRMs: median(of: values))
        let binCount = Int(((ceiling - bandLowHz) / frequencyStepHz).rounded()) + 1
        guard binCount >= 3 else { return [] }
        let basis = Basis(binCount: binCount)

        var estimates: [Double] = []
        var offset = first
        while offset + windowSeconds <= last {
            if let bpm = estimateWindow(times: times, values: values, from: offset, basis: basis) {
                estimates.append(bpm)
            }
            offset += windowStepSeconds
        }
        return estimates
    }

    /// The window's DFT basis: one row of cosines and one of sines per in-band bin, plus the Hann
    /// taper.
    ///
    /// The angle at bin `b`, sample `k` is `2π·(bandLowHz + b·frequencyStepHz)·k / resampleHz` — a
    /// function of the geometry alone, and so identical for every window of a run. Evaluating it
    /// inside the window loop instead puts two transcendental calls behind each of the few thousand
    /// multiply-adds one window costs, and a run the strap recorded without a break holds thousands of
    /// overlapping windows: this runs inside a use case the Sleep screen loads through.
    struct Basis {
        let cosines: [[Double]]
        let sines: [[Double]]
        let taper: [Double]

        var binCount: Int { cosines.count }

        init(binCount: Int) {
            var cosines: [[Double]] = []
            var sines: [[Double]] = []
            cosines.reserveCapacity(binCount)
            sines.reserveCapacity(binCount)

            for bin in 0..<binCount {
                let frequency = RespiratoryRateMath.bandLowHz
                    + Double(bin) * RespiratoryRateMath.frequencyStepHz
                var cosineRow: [Double] = []
                var sineRow: [Double] = []
                cosineRow.reserveCapacity(RespiratoryRateMath.sampleCount)
                sineRow.reserveCapacity(RespiratoryRateMath.sampleCount)
                for index in 0..<RespiratoryRateMath.sampleCount {
                    let angle = 2 * Double.pi * frequency
                        * (Double(index) / RespiratoryRateMath.resampleHz)
                    cosineRow.append(cos(angle))
                    sineRow.append(sin(angle))
                }
                cosines.append(cosineRow)
                sines.append(sineRow)
            }

            let last = Double(RespiratoryRateMath.sampleCount - 1)
            self.cosines = cosines
            self.sines = sines
            self.taper = (0..<RespiratoryRateMath.sampleCount).map { index in
                0.5 * (1 - cos(2 * Double.pi * Double(index) / last))
            }
        }
    }

    /// One window's estimate, or `nil` when the window has no dominant in-band peak.
    static func estimateWindow(
        times: [Double], values: [Double], from start: Double, basis: Basis
    ) -> Double? {
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let t = start + Double(index) / resampleHz
            guard let value = interpolated(times: times, values: values, at: t) else { return nil }
            samples.append(value)
        }

        detrend(&samples)
        for index in samples.indices { samples[index] *= basis.taper[index] }

        // The naive DFT, restricted to the band. Not an FFT: at 61 bins over 129 samples the whole
        // sweep is a few thousand multiply-adds, and Core is Foundation-only.
        var power: [Double] = []
        power.reserveCapacity(basis.binCount)
        for bin in 0..<basis.binCount {
            let cosineRow = basis.cosines[bin]
            let sineRow = basis.sines[bin]
            var real = 0.0
            var imaginary = 0.0
            for index in samples.indices {
                real += samples[index] * cosineRow[index]
                imaginary -= samples[index] * sineRow[index]
            }
            power.append(real * real + imaginary * imaginary)
        }

        guard let peak = power.indices.max(by: { power[$0] < power[$1] }) else { return nil }
        let mean = power.reduce(0, +) / Double(power.count)
        guard mean > 0, power[peak] / mean >= minimumPeakToMeanRatio else { return nil }

        // **A harmonic rule was here and is deliberately not.** The idea was to report a peak that is
        // the second harmonic of a slower rhythm at that rhythm rather than at twice it, since the
        // second harmonic of a 0.1–0.2 Hz fundamental lands inside the same band. It is unreachable,
        // and the reason is worth keeping: admitting a window requires its peak to clear
        // `minimumPeakToMeanRatio`, and a sub-harmonic holding a comparable share of that peak's power
        // caps the ratio at about 3.4 — measured, a two-tone 9 bpm-plus-18 bpm tachogram scores 3.38
        // where the same 18 bpm tone alone scores 6.51. So any threshold that rejects noise has already
        // declined every window a harmonic rule could act on, and the rule could never once have
        // changed an answer. A doubling is therefore not corrected, it is **declined**: a slow sleeper
        // whose waveform carries two comparable in-band components draws `—`, which is the same answer
        // this type gives any window with no dominant period. Removing the rule moved no figure in the
        // measurement above, since a halved bin could only ever change a reported rate, never reject a
        // window.
        let index = peak

        // Both ends, not just the top: a below-band modulation leaks its main lobe **downward** into
        // the bottom of the band and can peak several bins inside it — a 34 bpm (0.567 Hz) modulation
        // peaks on bin 1 at 8.81× the mean, which is why the guard is symmetric.
        if rejectsEdgePeak,
           index < power.startIndex + edgeGuardBins
            || index >= power.endIndex - edgeGuardBins {
            return nil
        }

        var frequency = bandLowHz + Double(index) * frequencyStepHz
        if index > power.startIndex, index < power.index(before: power.endIndex) {
            let left = power[index - 1], centre = power[index], right = power[index + 1]
            let denominator = left - 2 * centre + right
            if denominator != 0 {
                let delta = 0.5 * (left - right) / denominator
                if abs(delta) <= 1 { frequency += delta * frequencyStepHz }
            }
        }

        let bpm = frequency * 60
        guard bpm >= minimumBreathsPerMinute, bpm <= maximumBreathsPerMinute else { return nil }
        return bpm
    }

    /// The beat series at an arbitrary instant — **cubic** Lagrange through the four beats around it,
    /// falling back to the linear interpolant at a run's ends, where four points do not exist. Clamped
    /// outside the run.
    ///
    /// Cubic rather than the obvious straight line between two beats, and the reason is a measured
    /// aliasing artefact rather than refinement for its own sake. A tachogram is sampled at the beat
    /// rate, which for a sleeping heart is under 2 Hz, and linear interpolation of a series sampled
    /// that coarsely does not merely attenuate a component near the beat rate — it **generates
    /// harmonics** of it, and a harmonic above the beat-rate Nyquist folds back **into the band**.
    /// Worked: a 30 bpm modulation (0.5 Hz, above the band) reconstructed linearly puts its third
    /// harmonic at 1.5 Hz, which folds to `1.667 − 1.5 = 0.167 Hz` and is then reported as roughly
    /// 10 bpm — a breathing rate read off a signal with no in-band component at all. The same series
    /// reconstructed cubically peaks on the band's **last** bin, where `rejectsEdgePeak` discards it.
    /// That is not a hypothetical: it was the difference between the band-edge assertions passing and
    /// failing, and the fold is invisible in a spectrum plot of the ideal waveform.
    static func interpolated(times: [Double], values: [Double], at t: Double) -> Double? {
        guard let first = times.first, let last = times.last, let firstValue = values.first,
              let lastValue = values.last
        else { return nil }
        if t <= first { return firstValue }
        if t >= last { return lastValue }

        var low = 0
        var high = times.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= t { low = middle } else { high = middle }
        }

        guard low >= 1, low + 2 < times.count else {
            let span = times[high] - times[low]
            guard span > 0 else { return values[low] }
            return values[low] + (t - times[low]) / span * (values[high] - values[low])
        }

        let x0 = times[low - 1], x1 = times[low], x2 = times[low + 1], x3 = times[low + 2]
        let y0 = values[low - 1], y1 = values[low], y2 = values[low + 1], y3 = values[low + 2]

        // Written out rather than looped over an array: this runs once per grid point of every window,
        // and a four-element array per call would allocate on every one of them.
        var total = 0.0
        total += y0 * (t - x1) * (t - x2) * (t - x3) / ((x0 - x1) * (x0 - x2) * (x0 - x3))
        total += y1 * (t - x0) * (t - x2) * (t - x3) / ((x1 - x0) * (x1 - x2) * (x1 - x3))
        total += y2 * (t - x0) * (t - x1) * (t - x3) / ((x2 - x0) * (x2 - x1) * (x2 - x3))
        total += y3 * (t - x0) * (t - x1) * (t - x2) / ((x3 - x0) * (x3 - x1) * (x3 - x2))
        return total
    }

    /// Removes the mean and the least-squares linear trend, in place. The modulation being looked for
    /// is tens of milliseconds on a baseline of hundreds, so a drift left in would dominate the band.
    ///
    /// It also absorbs most of what the seam residuals leave behind: a slow drift across a 32 s window
    /// is exactly a linear trend.
    static func detrend(_ samples: inout [Double]) {
        let count = Double(samples.count)
        guard count >= 2 else { return }

        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for (i, value) in samples.enumerated() {
            let x = Double(i)
            sumX += x; sumY += value; sumXY += x * value; sumXX += x * x
        }
        let denominator = count * sumXX - sumX * sumX
        guard denominator != 0 else { return }
        let slope = (count * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / count

        for i in samples.indices {
            samples[i] -= slope * Double(i) + intercept
        }
    }

    /// A Hann taper, which suppresses the leakage that a rectangular window's discontinuity at the
    /// edges would put across the whole band.
    static func applyHannTaper(_ samples: inout [Double]) {
        let last = Double(samples.count - 1)
        guard last > 0 else { return }
        for i in samples.indices {
            samples[i] *= 0.5 * (1 - cos(2 * Double.pi * Double(i) / last))
        }
    }

    static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

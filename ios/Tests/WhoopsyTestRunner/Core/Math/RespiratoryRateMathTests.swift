import Foundation
import Whoopsy

// MARK: - 13. Sleep Need — respiratory rate, from the R-R series

/// A file of §13's body, cut at the section's own `── Title` boundary and moved verbatim.
/// `SleepNeedTests.run()` calls it, in the order the section ran it in.
///
/// The tachogram builder that sat at the top of this block is on `SleepNeedTests`, because the debt
/// file calls `syntheticPackets` too; `beatPacket` and `rate` are local to this file and are named
/// unqualified below.
enum RespiratoryRateMathTests {
    static func run() async throws {
        // ── Respiratory rate, from the R-R series ────────────────────────────────────────────────────
        //
        // `RespiratoryRateMath` is the first signal processing in this repo and the only model here that
        // **cannot be checked against a column**. The export carries WHOOP's own figure for 910 nights and
        // an R-R series for none of them, so there is no night in this app's possession where a known
        // respiratory rate and the beats that produced it are both present. What the assertions below
        // cover is the plumbing — a synthetic tachogram modulated at a known rate comes back at that rate
        // — and the rules that decide whether the beats may be used at all. They are not evidence that the
        // figure agrees with a real strap, and `docs/ALGORITHMS.md` §4 says so in as many words.
        func beatPacket(
            _ packet: (arrival: Date, intervals: [Double])
        ) -> RespiratoryRateMath.BeatPacket {
            RespiratoryRateMath.BeatPacket(arrival: packet.arrival, rrIntervalsMs: packet.intervals)
        }

        func rate(_ components: [(bpm: Double, amplitudeMs: Double)],
                  packetCount: Int = 20,
                  arrivalSpacing: Double? = nil) -> Double? {
            RespiratoryRateMath.respiratoryRate(
                from: SleepNeedTests.syntheticPackets(
                    components, packetCount: packetCount, arrivalSpacing: arrivalSpacing
                ).map(beatPacket))
        }

        // The estimator recovers a known modulation. 200 intervals at a 600 ms mean is 120 s of beats,
        // which is 18 overlapping windows — well past the three a median needs.
        let fifteen = rate([(bpm: 15, amplitudeMs: 40)])
        assertTest(
            fifteen.map { abs($0 - 15) <= 1 } ?? false,
            "A 600 ms tachogram modulated at 15 bpm is reported at 15 "
                + "(got \(fifteen.map { "\($0)" } ?? "nil")) bpm")

        // A second rate, deliberately not on a DFT bin: 20 bpm is 0.3333 Hz against a 0.005 Hz grid,
        // so it only comes back through the parabolic refinement of the peak's neighbours.
        let twenty = rate([(bpm: 20, amplitudeMs: 40)])
        assertTest(
            twenty.map { abs($0 - 20) <= 1 } ?? false,
            "…and a rate off the bin grid — 20 bpm, between two bins — is still reported at 20 "
                + "(got \(twenty.map { "\($0)" } ?? "nil")) bpm")

        // ── The band edges ───────────────────────────────────────────────────────────────────────
        //
        // These two are the cases `rejectsEdgePeak` exists for, and neither is a flatness question:
        // a Hann taper's main lobe is 4/T = 0.125 Hz wide, so a 5 bpm modulation leaks its whole lobe
        // into the bottom of the band and a 30 bpm one leaks a tail that rises toward the top. Both
        // clear `minimumPeakToMeanRatio`, so a spectrum-only implementation reports a breathing rate
        // for a signal that is not breathing at all.
        //
        // The 30 bpm case is the one that sets `edgeGuardBins`, and it does so because the obvious
        // reading of it is wrong. It does *not* peak on the last bin; it peaks on bin 59 of 61, one
        // inside the top, at 5.61× the mean — so a one-bin edge test let it through as a confident
        // 23.6 bpm. The guard is two bins at each end, and the assertion below is what would fail if
        // anyone narrowed it back on the assumption that leakage peaks *on* the edge.
        let five = rate([(bpm: 5, amplitudeMs: 40)])
        assertTest(
            five == nil,
            "A 5 bpm modulation is below the band and must not be reported as a breathing rate at the "
                + "band's floor (got \(five.map { "\($0)" } ?? "nil")) bpm")
        let thirty = rate([(bpm: 30, amplitudeMs: 40)])
        assertTest(
            thirty == nil,
            "…and a 30 bpm modulation above the band is not reported at its ceiling "
                + "(got \(thirty.map { "\($0)" } ?? "nil")) bpm")

        // ── Contiguity, which is the assertion that matters ──────────────────────────────────────
        //
        // `rrIntervalsMs` holds one notification's beats, adjacent by definition; across notifications
        // they are not, and `timestamp` is an arrival instant rather than a beat time. Nothing in the
        // schema records which packets follow which, so a run has to be inferred — and inferring it
        // wrongly is the defect `CLAUDE.md` records against the two RMSSD consumers, which difference
        // one interval per notification and so difference beats that were never adjacent.
        let joined = SleepNeedTests.syntheticPackets([(bpm: 15, amplitudeMs: 40)], packetCount: 12)
        assertTest(
            RespiratoryRateMath.isContiguous(beatPacket(joined[0]), beatPacket(joined[1])),
            "A seam the later packet's own span accounts for is contiguous")
        // Twelve packets and not six, and the count is load-bearing rather than arbitrary: ten
        // intervals of 600 ms is 6 s of beats per packet, so six packets span 36 s — one 32 s window
        // at a 5 s step, below `minimumWindows`, and the night would come back `nil` for a reason that
        // has nothing to do with contiguity. Twelve packets span 72 s and yield nine windows. Both
        // halves of this pair use the same count so the comparison isolates the arrival spacing.
        assertTest(
            rate([(bpm: 15, amplitudeMs: 40)], packetCount: 12) != nil,
            "Twelve packets arriving one span apart chain into a run long enough to score")

        let split = SleepNeedTests.syntheticPackets([(bpm: 15, amplitudeMs: 40)], packetCount: 12, arrivalSpacing: 90)
        assertTest(
            !RespiratoryRateMath.isContiguous(beatPacket(split[0]), beatPacket(split[1])),
            "The same beats with 90 s between arrivals are not — the seam is 84 s wider than the "
                + "6 s of beats that could account for it")
        assertTest(
            rate([(bpm: 15, amplitudeMs: 40)], packetCount: 12, arrivalSpacing: 90) == nil,
            "…and a night whose notifications are not continuous is a dash, not a tachogram stitched "
                + "across the gap")

        // ── A rejected packet leaves a hole, it does not get spliced ─────────────────────────────
        //
        // `HeartRateVariabilityMath.filterRRIntervals` **deletes** intervals, which costs its own
        // callers nothing because they only read the surviving values. A tachogram is a series in
        // time, so a deleted interval removes that much real elapsed time and draws the beats either
        // side of it as adjacent. Rejecting the whole packet instead leaves a gap, and the structural
        // assertion is that the gap lands the neighbours in *different* runs.
        var holed = SleepNeedTests.syntheticPackets([(bpm: 15, amplitudeMs: 40)], packetCount: 6)
        holed[3].intervals.append(2500)
        let usable = RespiratoryRateMath.usablePackets(from: holed.map(beatPacket))
        assertTest(
            usable.count == 5,
            "A packet carrying a 2500 ms interval — outside the 300–2000 ms range RMSSD already "
                + "defines — is dropped whole (kept \(usable.count) of 6)")
        assertTest(
            RespiratoryRateMath.contiguousRuns(in: usable).count == 2,
            "…and the hole it leaves breaks the run in two rather than being stitched over "
                + "(got \(RespiratoryRateMath.contiguousRuns(in: usable).count) runs)")

        // ── `nil`, never `0.0` ───────────────────────────────────────────────────────────────────
        let nothing = RespiratoryRateMath.respiratoryRate(from: [])
        assertTest(
            nothing == nil,
            "No packets is `nil` and not `0.0` — the value `HeartRateVariabilityMath.calculateRMSSD` "
                + "returns on insufficient data, which here would read as a stopped breath")
        assertTest(
            RespiratoryRateMath.respiratoryRate(from: [
                RespiratoryRateMath.BeatPacket(arrival: SleepNeedTests.start, rrIntervalsMs: [])
            ]) == nil,
            "…and so is a night of samples that carry no R-R series at all, which is the shape every "
                + "imported day has")

        // ── Nyquist: the beats have to be fast enough to carry the band ──────────────────────────
        assertTest(
            abs(RespiratoryRateMath.bandTopHeartRateBpm
                - 2 * RespiratoryRateMath.bandHighHz * 60) < 0.001,
            "The band's top edge of 0.4 Hz needs 48 bpm to exist at all — a modulation cannot be "
                + "observed at a rate above half the beat rate that samples it")
        assertTest(
            RespiratoryRateMath.resolvableHighHz(medianRRMs: 600) == RespiratoryRateMath.bandHighHz,
            "At 100 bpm the whole band is resolvable")
        assertTest(
            abs(RespiratoryRateMath.resolvableHighHz(medianRRMs: 60_000 / 45) - 0.3375) < 0.0001,
            "At 45 bpm — an ordinary sleeping heart rate — the ceiling is 45/120 × 0.9 = 0.3375 Hz, "
                + "so a rate above ~20 bpm is not reported from beats that cannot carry it (got "
                + "\(RespiratoryRateMath.resolvableHighHz(medianRRMs: 60_000 / 45)))")
        assertTest(
            RespiratoryRateMath.resolvableHighHz(medianRRMs: 200) == RespiratoryRateMath.bandHighHz,
            "…and a fast heart rate never raises the ceiling above the band itself")

        // ── Two comparable in-band components, and the harmonic rule that is not there ───────────
        //
        // 9 bpm is 0.15 Hz and its double is 0.30 Hz — inside the same band, so a waveform whose
        // harmonic outweighs its fundamental would report twice the true rate. The estimator does not
        // correct that, it **declines** the window: admitting one requires its peak to clear
        // `minimumPeakToMeanRatio`, and a second comparable tone raises the band's mean as much as the
        // peak, so the ratio collapses. Measured, this tachogram scores 3.38 where the same 18 bpm
        // tone alone scores 6.51.
        //
        // That is the whole of the behaviour and both halves are asserted, because the pair is what
        // distinguishes "declined" from "broken": a bare `nil` here would equally be an estimator that
        // cannot read a slow rhythm at all. A harmonic rule was implemented against this case and
        // removed once the measurement showed it could never fire — every window it could have acted
        // on had already been declined by flatness. If someone reintroduces one, this assertion is
        // what will fail and tell them why.
        let twoTone = rate([(bpm: 9, amplitudeMs: 40), (bpm: 18, amplitudeMs: 44)])
        assertTest(
            twoTone == nil,
            "A tachogram carrying a comparable 9 bpm and 18 bpm component has no dominant period, so "
                + "it is a dash rather than a rate picked from two (got "
                + "\(twoTone.map { "\($0)" } ?? "nil") bpm)")
        let pure = rate([(bpm: 18, amplitudeMs: 44)])
        assertTest(
            pure.map { abs($0 - 18) <= 1 } ?? false,
            "…and a single 18 bpm modulation is read plainly, so the dash above is the second "
                + "component and not an inability to score this rate (got "
                + "\(pure.map { "\($0)" } ?? "nil") bpm)")
        let slow = rate([(bpm: 9, amplitudeMs: 40)])
        assertTest(
            slow.map { abs($0 - 9) <= 1 } ?? false,
            "…nor an inability to score a slow one — 9 bpm alone is reported at 9, which is the "
                + "answer the two-tone case above is denied (got "
                + "\(slow.map { "\($0)" } ?? "nil") bpm)")
    }
}

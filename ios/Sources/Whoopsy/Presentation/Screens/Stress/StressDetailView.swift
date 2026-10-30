import SwiftUI

/// One day's Stress Monitor — the page Home's stress tile pushes.
///
/// **The page carries no view model, and that is the design rather than a shortcut.** Home has
/// already computed the day's `StressDay` to draw its tile, and that value is the whole subject: the
/// average, the band, the windows and the timestamps. Recomputing it here would fold a fortnight of
/// samples a second time for a screen that is about to show the same numbers — and a second
/// evaluation is also a chance for the two to disagree, since the stress model scores every window
/// against a personal baseline.
///
/// **Four controls from the reference are deliberately absent.** The gear and the `i` button have no
/// destinations in this app, the zoom button would open a chart interaction that does not exist, and
/// the day chevrons would page into days whose stress has never been computed — a fold each, and the
/// pushed-ring rule already says a pushed page takes its day as a plain `let`. The footer's *"in line
/// with a typical Thursday"* is a weekday baseline this app does not hold, so the sentence states the
/// time in the band instead and stops there.
public struct StressDetailView: View {
    /// Home's already-computed day — the seed the live monitor extends.
    public let day: StressDay?

    /// The day shown — drawn in the header, and the chart's calendar bounds.
    public let date: Date

    /// The live half: it seeds from `day` and appends completed five-minute windows while the page is
    /// open. Owned by `MainContainerView`, because a view model is built there and nowhere else.
    @State private var monitor: StressLiveViewModel

    private static let gaugeMaximum = StressMath.maximumScore

    public init(day: StressDay?, date: Date, monitor: StressLiveViewModel) {
        self.day = day
        self.date = date
        _monitor = State(initialValue: monitor)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                dayHeader
                gauge
                if !monitor.windows.isEmpty {
                    // **The last few hours, not the day.** This is a live monitor, and a reader who
                    // opens it mid-afternoon wants the stretch that ends now rather than a line whose
                    // right half is in the future. The span is the same one the recent baseline
                    // reaches back over, so the number and the plot describe one stretch of time.
                    StressMonitorChartView(
                        windows: monitor.windows,
                        day: date.startOfDay,
                        now: now,
                        range: chartRange)
                        .padding(.top, 4)
                    footnote
                } else {
                    Text("No measured daytime stress for this day. The model needs still windows "
                        + "with enough beats, and at least three prior days to score against.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        // `StrainDetailView`'s line, for its reason: a `ScrollView` whose content holds nothing
        // flexible lays out at its content's width and paints a column.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .navigationTitle("Stress Monitor")
        .preferredColorScheme(.dark)
        // The tick loop is the `.task`, so leaving the page cancels it and there is no timer to stop.
        .task { await monitor.run(day: day, date: date) }
    }

    /// The gauge's figure: the **latest** scored window, as the reference draws it (its `2.4 / HIGH /
    /// 12:10 AM` is a window, not the day's mean), falling back to the day's average when no window
    /// has a start to print.
    private var gaugeValue: (score: Double, band: StressMath.Band, time: Date?)? {
        if let latest = monitor.latest {
            return (latest.score, latest.band, latest.start)
        }
        guard !monitor.windows.isEmpty else { return nil }
        let day = StressDay(date: date.startOfDay, windows: monitor.windows)
        return (day.score.averageScore, day.score.band, nil)
    }

    /// The window the chart draws: the past few hours, ending now for today and at the last measured
    /// window for a day in the past.
    private var chartRange: Range<Date> {
        let end: Date
        if let now {
            end = now
        } else if let last = monitor.windows.last {
            end = last.start.addingTimeInterval(StressMath.windowSeconds)
        } else {
            end = date.startOfDay
        }
        return end.addingTimeInterval(-StressMath.recentBaselineSpan)..<end
    }

    /// The chart's marker is a claim about the present, so a day in the past has none — the tile's
    /// own rule.
    private var now: Date? {
        Calendar.current.isDateInToday(date) ? Date() : nil
    }

    /// The day, and a **LIVE** marker while the page is extending it.
    ///
    /// The marker is not decoration: the gauge's figure becomes the newest window's while the page is
    /// open, and without a word saying so a reader who comes back to the screen would read a
    /// five-minute value as the day's average.
    private var dayHeader: some View {
        HStack(spacing: 8) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 13, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textPrimary)
                .textCase(.uppercase)

            if monitor.isTicking {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.recoveryGreen)
                        .frame(width: 5, height: 5)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundStyle(Theme.recoveryGreen)
                .accessibilityLabel("Updating as new windows complete")
            }
        }
    }

    /// The reference's 270° arc, drawn with the app's only gauge: the day's average on its 0–3 scale,
    /// the band inside it, and the ends of the scale beneath.
    private var gauge: some View {
        let value = gaugeValue
        return VStack(spacing: 8) {
            GaugeRingView(
                progress: (value?.score ?? 0) / Self.gaugeMaximum,
                scoreText: value.map { $0.score.formattedOneDecimal() } ?? "—",
                label: value.map { $0.band.rawValue.uppercased() } ?? "NO DATA",
                ringColor: value?.band.color ?? Theme.textSecondary,
                labelColor: value?.band.color ?? Theme.textSecondary,
                lineWidth: 16,
                size: 190)

            if let time = value?.time {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }

            HStack {
                Text("0.0")
                Spacer()
                Text(Self.gaugeMaximum.formattedOneDecimal())
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
            .frame(width: 190)
        }
    }

    /// What the reference spends on a weekday comparison, spent on the day's own band time instead.
    private var footnote: some View {
        // The gauge draws the newest window — the live reading — so the day's average has to be
        // stated somewhere, or the page would hold a number the Home tile contradicts. The copy
        // below the average then follows the day's own band; see `message(for:scope:)`.
        let day = StressDay(date: date.startOfDay, windows: monitor.windows)
        return Text(Self.message(for: day, scope: monitor.baselineScope))
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The page's closing paragraph, written for the band the day actually landed in.
    ///
    /// **Not one sentence with the number dropped into it.** The earlier version said *"you spent X in
    /// the high stress zone"* on every day, which on a calm day is a sentence about a band the day
    /// never reached — and a low day is the common case. The level sentence says what the band means,
    /// which is a fact about the model rather than a restatement of the number: the score is
    /// `activationOffset` plus the mean activation in sigma, so below 1.0 is below the reference, up to
    /// 2.0 is within one sigma above it, and 2.0 and over is more than one sigma above.
    ///
    /// Static and `public` so the runner can pin the three variants: a sentence a screenshot cannot
    /// check, because a screenshot only ever shows the band the day happened to be in.
    public static func message(for day: StressDay, scope: StressBaselineScope?) -> String {
        let average = day.score.averageScore.formattedOneDecimal()
        let level: String
        switch day.score.band {
        case .low:
            level = "The day averaged \(average) — a low day, with the measured windows below your "
                + "usual range."
        case .medium:
            level = "The day averaged \(average) — a medium day, running up to a sigma above your "
                + "usual range."
        case .high:
            level = "The day averaged \(average) — a high day, running more than a sigma above "
                + "your usual range."
        }

        // A zero is a real reading here — the day did have scored windows, they were simply not in
        // this band — so it is said in words rather than printed as "0 min".
        let high = day.seconds(in: .high)
        let highSentence = high > 0
            ? "You spent \(duration(high)) in the high band."
            : "No window reached the high band."

        let measured = day.score.windowCount
        let coverage = "\(measured) five-minute window\(measured == 1 ? "" : "s") were still "
            + "enough to score, and a missing bar is a window the model could not read."

        return level + " " + highSentence + " " + coverage
            + " The band edges are the published 0–3 scale; " + referenceSentence(scope)
    }

    /// Which stretch of time each five minutes was compared with.
    ///
    /// The two references are different claims and the page states which one it is showing: a
    /// personal baseline is the model's definition, and the day's own preceding hours are the
    /// fallback that lets the monitor work with no history at all. Saying "your fortnight" on a
    /// relative day would be a claim the numbers do not support.
    public static func referenceSentence(_ scope: StressBaselineScope?) -> String {
        switch scope {
        case .recent(let span):
            let hours = Int((span / 3600).rounded())
            return "and there is not yet a personal baseline — that takes three days of daytime "
                + "stillness — so each five minutes is scored against the previous \(hours) hours of "
                + "this day. It says how this moment compares with your last few hours, and it will "
                + "switch to your personal baseline once three such days exist."
        default:
            return "the score itself is this app's calibration against your previous fortnight's "
                + "waking hours."
        }
    }

    /// `2 hr 44 min`, and `0 min` for a day that never reached the band — a real reading rather than
    /// an absence, since the day did have scored windows.
    public static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes) min" }
        return "\(hours) hr \(minutes) min"
    }
}

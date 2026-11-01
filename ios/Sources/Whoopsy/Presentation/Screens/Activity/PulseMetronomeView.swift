import SwiftUI

/// The pulse metronome: a white square that flashes yellow at the rate the gauge below it sets.
///
/// ## What it is for, and what it is not
///
/// A felt pulse has no producer in this app — the strap cannot see one, and no model here computes
/// one — so the only honest way to put a number on it is to ask the person feeling it. The square
/// flashes, the owner moves the gauge until the flashes keep time with what they feel, and the rate is
/// read off the gauge. **The number is their report**, not a measurement: nothing downstream derives
/// from it, and the entity that stores it says so.
///
/// **Zero means no flashes at all** — the owner's own words, *"if i put it to zero no flashes at
/// all"* — and it is the control's rest position rather than a rate of zero pulses. The draft maps it
/// to `nil`, so an entry with no reading stores nothing rather than a claim that nothing was felt.
///
/// ## Why the clock drives it
///
/// `TimelineView` and `PulseTiming` rather than a repeating animation: the pattern is a function of the
/// clock, so changing the rate takes effect on the next frame with no state to restart, and the whole
/// view can stop working when the gauge is at zero via `paused:`. The clock is **wrapped to a minute**
/// — the same wrap the energy map's rings needed, and for the same reason: the raw interval since the
/// reference date is ~7.8e8, and multiplying that by a rate loses the fraction of a period the screen
/// has to show. A minute is a whole number of periods for every rate on the gauge's grid only when the
/// rate divides 60… so the wrap is chosen instead to be far larger than one period at the top rate
/// (20 s at 180/min), which is what keeps the phase continuous across it.
///
/// ## Flashing
///
/// The rate is capped at `PulseTiming.maximumRate` (three flashes a second), the square is 120 points
/// rather than full-screen, and the duty cycle is under a half. Under **Reduce Motion** the square
/// fades between its two colours instead of switching, so the rate is still readable without a hard
/// flash.
public struct PulseMetronomeView: View {

    /// `0…PulseTiming.maximumRate`, zero meaning off.
    @Binding private var rate: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The click that carries the beat. A class held in `@State` so the audio engine is prepared once
    /// per sheet rather than per frame, and torn down when the sheet closes.
    @State private var sounder = PulseSounder()

    public nonisolated static let sectionTitle = "Pulse"
    public nonisolated static let offText = "OFF"
    public nonisolated static let accessibilityLabel = "Pulse frequency"

    /// The line under the gauge. A constant rather than a literal in the `body`, on this repo's rule:
    /// the runner has no renderer, so copy written into a view is copy nothing can assert.
    public nonisolated static let soundHint = "Turn sound on to hear the pulse."

    private static let squareSize: CGFloat = 120
    private static let trackHeight: CGFloat = 8
    private static let handleDiameter: CGFloat = 22
    private static let maximum = Int(PulseTiming.maximumRate)

    /// `0`, `100`, `200`, … up to the ceiling, evenly spaced because the control is.
    private static let tickLabels: [String] = stride(from: 0, through: maximum, by: maximum / 5)
        .map(String.init)

    public init(rate: Binding<Int>) {
        self._rate = rate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            square
            readout
            gauge

            VStack(alignment: .leading, spacing: 4) {
                Text("Match the flashes to the pulse you feel.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)

                // **The silent switch is why this line exists.** The click is played in the `.ambient`
                // category, which obeys the ringer — so a phone on silent shows the flash and says
                // nothing, and the notice is the only thing telling the reader why. iOS exposes no
                // way to ask whether the switch is on, so the sentence is always drawn rather than
                // appearing in the case it describes.
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 10))
                    Text(Self.soundHint)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.accessibilityLabel))
        .accessibilityValue(Text(valueDescription))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setRate(rate + 1)
            case .decrement: setRate(rate - 1)
            @unknown default: break
            }
        }
        // **The click runs off the same clock as the flash**, because `rate` is the task's id: a drag
        // cancels the old loop and starts one at the new rate on the next frame, and closing the sheet
        // cancels it too. Zero plays nothing and stops the engine.
        .task(id: rate) {
            guard rate > 0 else {
                sounder.finish()
                return
            }
            await sounder.run(ratePerMinute: Double(rate))
        }
        .onDisappear { sounder.finish() }
    }

    // MARK: - The square

    /// The square itself. `paused:` at zero is what makes *off* cost nothing rather than render a
    /// white square sixty times a second.
    private var square: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: rate == 0)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 60)
            let ratePerMinute = Double(rate)
            let lit = PulseTiming.isLit(at: seconds, ratePerMinute: ratePerMinute)
            let travelling = PulseTiming.isTravelling(ratePerMinute: ratePerMinute)
            let phase = PulseTiming.phase(at: seconds, ratePerMinute: ratePerMinute)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.textPrimary)
                .overlay {
                    // Two drawings, one number. At or below 180/min the square flashes, because a
                    // flash is what a slow rhythm is matched against. Above it the flashes would fuse
                    // into a shimmer — and a full-contrast strobe is the photosensitive case — so a
                    // band travels round the square's edge once per pulse instead: same rate, read as
                    // motion rather than as light.
                    if travelling {
                        Self.travellingBand(phase: phase)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.recoveryYellow)
                            .opacity(lit ? 1 : 0)
                    }
                }
                .frame(width: Self.squareSize, height: Self.squareSize)
                // A hard switch at 3 Hz is a strobe; the short ease is what makes it a flash. Under
                // Reduce Motion the same change is spread over a long fade.
                .animation(
                    // Only the flash eases; the travelling band is a position on the clock and
                    // animating it would lag the rate it is meant to show.
                    reduceMotion && !travelling ? .easeInOut(duration: 0.30) : nil,
                    value: lit)
        }
        .frame(width: Self.squareSize, height: Self.squareSize)
    }

    // MARK: - The readout

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(rate == 0 ? Self.offText : "\(rate)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(rate == 0 ? Theme.textMuted : Theme.textPrimary)
                .monospacedDigit()

            if rate > 0 {
                Text("/ min")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                // The same rate in hertz, beside the unit a felt rhythm is matched in — one number in
                // the unit the control counts and the unit the rest of the world writes it in.
                Text(hertzText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .padding(.leading, 2)
            }

            Spacer(minLength: 0)
        }
    }

    /// What VoiceOver reads for the control as a whole.
    private var valueDescription: String {
        rate == 0 ? "Off" : "\(rate) per minute, \(hertzValue) hertz"
    }

    /// The hertz equivalent, to one decimal place — `8.3` at the ceiling, `0.7` at 42 a minute.
    ///
    /// One place rather than two because a tenth of a hertz is as fine as a felt rhythm is ever
    /// matched; the rate above it carries the precision, and this is the same number in another unit.
    private var hertzText: String {
        "\(hertzValue) Hz"
    }

    private var hertzValue: String {
        let hertz = PulseTiming.hertz(ratePerMinute: Double(rate))
        return String(format: "%.1f", hertz)
    }

    // MARK: - The gauge

    /// The track, its fill and its handle, plus the four tick labels beneath.
    ///
    /// **Built rather than a `Slider`**, for the reason `SegmentedPillControl` is: the app styles its
    /// own controls, and the stock slider cannot carry this track and this handle without fighting it.
    private var gauge: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let travel = max(width - Self.handleDiameter, 1)
                let fraction = CGFloat(rate) / CGFloat(Self.maximum)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.segmentedTrack)
                        .frame(height: Self.trackHeight)

                    Capsule()
                        .fill(Theme.textPrimary.opacity(0.9))
                        .frame(width: Self.handleDiameter / 2 + travel * fraction, height: Self.trackHeight)

                    Circle()
                        .fill(Theme.textPrimary)
                        .frame(width: Self.handleDiameter, height: Self.handleDiameter)
                        .offset(x: travel * fraction)
                }
                .frame(height: Self.handleDiameter)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = min(max(value.location.x - Self.handleDiameter / 2, 0), travel)
                            setRate(Int((x / travel * CGFloat(Self.maximum)).rounded()))
                        })
            }
            .frame(height: Self.handleDiameter)

            // Labels every fifth of the track, so the numbers are evenly spaced above an evenly
            // spaced control — the ceiling is the last one and nothing restates it.
            HStack(spacing: 0) {
                ForEach(Array(Self.tickLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                    if index < Self.tickLabels.count - 1 { Spacer() }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textMuted)
            .monospacedDigit()
        }
    }

    /// The band that runs round the square's edge, positioned by the phase.
    ///
    /// **A sliding trim window rather than a rotation**, and the difference is visible: a rectangle
    /// turned about its centre sweeps its corners *outside* its own box, so the band left the square
    /// at the diagonals. Sliding the window along the outline keeps it on the edge at every angle, and
    /// a window that runs past the end is drawn as two pieces — the wrap is the one case a single
    /// `trim` cannot express.
    private static func travellingBand(phase: Double) -> some View {
        let span = 0.18
        let end = phase + span
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let stroke = StrokeStyle(lineWidth: 5, lineCap: .round)
        return ZStack {
            shape
                .trim(from: phase, to: min(end, 1))
                .stroke(Theme.recoveryYellow, style: stroke)
            if end > 1 {
                shape
                    .trim(from: 0, to: end - 1)
                    .stroke(Theme.recoveryYellow, style: stroke)
            }
        }
        .padding(3)
    }

    private func setRate(_ newValue: Int) {
        let clamped = min(max(newValue, 0), Self.maximum)
        guard clamped != rate else { return }
        rate = clamped
    }
}

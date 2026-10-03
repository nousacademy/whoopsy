import SwiftUI

/// The live heart-rate block: the section label, the current reading, the reserve scale the reading
/// sits on, and the strap's state.
///
/// **The reading and the scale are one element, and that is the whole of this type's shape.** The
/// figure is *what* the heart rate is; the scale beneath it is *where that falls* among the five
/// reserve bands. Splitting them into two panels — a reading card and a zones card — is what this
/// replaced, and it was wrong in both directions: the figure arrived without a scale to read it
/// against, and the scale was filled with the session's time-in-band, a different quantity that
/// answered a question nobody had asked.
///
/// It draws no card chrome, and neither does the row of figures below it: the reference puts this
/// block and those figures straight on the background.
public struct LiveHeartRateView: View {

    /// The most recent reading — the figure the block is named for.
    public let currentBPM: Int

    /// Whether the strap is on a body. See `statusLine`.
    public let isOnBody: Bool

    /// Where `currentBPM` falls on the five-band reserve scale, as a `0…1` fraction of its width.
    ///
    /// **Resolved by `LiveSessionAccumulator` from the session's own zone table rather than rebuilt
    /// here**, so the scale the mark is placed on is the one the session was scored against, and this
    /// view holds no opinion about where the band edges are. It is non-optional because the caller
    /// draws this block only when a reading exists, and the two come off the snapshot together.
    public let bandScalePosition: Double

    public init(currentBPM: Int, isOnBody: Bool, bandScalePosition: Double) {
        self.currentBPM = currentBPM
        self.isOnBody = isOnBody
        self.bandScalePosition = bandScalePosition
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEART RATE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
                .tracking(1.0)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(currentBPM)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.textPrimary)
                    .monospacedDigit()

                Text("BPM")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.livePulseCyan)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heart rate, \(currentBPM) beats per minute")

            HeartRateBandScaleView(position: bandScalePosition)

            statusLine
        }
    }

    /// Whether the strap is on a body, as a dot and a word.
    ///
    /// **Kept, and it is not decoration.** It is the only element here that separates a reading taken
    /// from a worn strap from one taken from a strap sitting on a table, which is what makes an odd
    /// number legible instead of alarming. `LiveSessionView` passes `Snapshot.isOnBody` — a `Bool?`
    /// with no default — precisely so this cannot be drawn from an assumption.
    ///
    /// It sits **below** the scale rather than between the figure and the scale, which is where the
    /// mockup puts nothing: the reader's eye goes from the figure to the scale it is marked on, and a
    /// badge in that gap breaks the pair the block exists to hold together.
    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOnBody ? Theme.livePulseCyan : Theme.textMuted)
                .frame(width: 8, height: 8)
                .shadow(color: isOnBody ? Theme.livePulseCyan.opacity(0.8) : Color.clear, radius: 4)

            Text(isOnBody ? "LIVE TELEMETRY" : "STRAP OFF BODY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(isOnBody ? Theme.livePulseCyan : Theme.textMuted)
                .tracking(1.0)
        }
        .accessibilityHidden(true)
    }
}

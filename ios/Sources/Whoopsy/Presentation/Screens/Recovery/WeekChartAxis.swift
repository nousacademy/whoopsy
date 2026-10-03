import SwiftUI

/// The parts of a seven-column week chart that are the same on every week chart.
///
/// The Recovery detail page draws five of them — recovery scores as bars, heart-rate variability,
/// resting heart rate and respiratory rate as lines, then sleep performance as bars — and all five take
/// their columns from `MetricWeek`, so all five need the same column geometry, the same highlighted
/// column and the same weekday/day-of-month strip. They live here rather than in any chart for the
/// reason `Theme` exists: copies of a date label that agree today are a bug that fires later, and the
/// failure would be a chart labelling its columns with another week's dates.
///
/// It is deliberately **not** a `View` that draws a whole chart. Everything that differs between the
/// five — bars against a line, a fixed scale against a fitted one, a tier colour against an accent —
/// stays in the chart that owns it; this holds only the frame they share.
///
/// `StrainRecoveryChartView` on Home draws the same seven columns and does **not** use this. It has
/// gutters for two labelled axes, which moves every x by a constant, so its geometry is genuinely a
/// different one rather than a copy of this. Unifying them means teaching this type about gutters and
/// re-verifying a chart that cannot currently be scrolled to; it is not worth doing to save a
/// `columnWidth`.
enum WeekChartAxis {

    /// The strip above the plot, sized for a value label sitting over the tallest thing the plot can
    /// draw — a 100% bar, or a point on the fitted axis' top bound. Without it the topmost label is
    /// drawn outside the frame and clipped.
    static let valueStripHeight: CGFloat = 20

    /// The two-line weekday/day-of-month strip beneath the plot.
    static let dateLabelHeight: CGFloat = 28

    /// How strongly the anchor's column is tinted behind the data.
    static let anchorFillOpacity: Double = 0.35

    /// One column's width.
    static func columnWidth(_ width: CGFloat) -> CGFloat {
        width / CGFloat(MetricWeek.dayCount)
    }

    /// One column's centre. Half a column in, so a mark sits in the middle of the day it describes
    /// rather than on the boundary between two.
    static func x(slot: Int, columnWidth: CGFloat) -> CGFloat {
        (CGFloat(slot) + 0.5) * columnWidth
    }

    /// The slot the page's own day occupies.
    ///
    /// `MetricWeek.endingOn` is snapped to its start by `MetricWeek.init` and every slot's date is
    /// snapped the same way, so this is an equality test and not a search for the nearest day — which
    /// would chip one day's number under another's column.
    static func anchorSlot(in week: MetricWeek) -> Int? {
        week.days.firstIndex { $0.date == week.endingOn }
    }

    /// The band behind the highlighted column, so the chip under it is anchored to a visible column
    /// rather than floating between two.
    ///
    /// Full plot height rather than the height of the mark in it, so it reads as the column the day
    /// occupies and not as a second bar or a second point.
    static func anchorColumn(slot: Int, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.ringTrack.opacity(anchorFillOpacity))
            .frame(width: columnWidth(width), height: height)
            .position(x: x(slot: slot, columnWidth: columnWidth(width)), y: height / 2)
    }

    /// The weekday and day-of-month under each column, with the anchor's day number chipped so the
    /// highlighted column is named as well as marked.
    ///
    /// Every column is labelled, including the ones drawing nothing — the label is the date the
    /// column belongs to, which a reader needs most for the days that have no mark on them.
    static func dateLabels(week: MetricWeek, width: CGFloat) -> some View {
        let anchor = anchorSlot(in: week)
        return HStack(spacing: 0) {
            ForEach(week.days.indices, id: \.self) { slot in
                let day = week.days[slot]
                let isAnchor = slot == anchor
                VStack(spacing: 2) {
                    Text(day.date.formattedWeekdayAbbreviation())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text(day.date.formattedDayOfMonth())
                        .font(.system(size: 10, weight: isAnchor ? .bold : .medium))
                        .foregroundStyle(isAnchor ? Theme.textPrimary : Theme.textMuted)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            if isAnchor {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.ringTrack)
                            }
                        }
                }
                .frame(width: columnWidth(width))
            }
        }
        .frame(width: width, height: dateLabelHeight)
    }
}

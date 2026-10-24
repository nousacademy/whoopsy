import Foundation

/// The one 30-second grid this app's motion is filed on.
///
/// **Two files have to agree about where a window begins, and a duplicated floor is how they stop.**
/// `RecordMotionUseCase` writes an epoch per window and `CalculateStrainUseCase` reads the day back and
/// buckets heart-rate intervals onto the same windows. If the writer floors with one expression and
/// the reader with another, a batch and an HR interval a millisecond apart can land in different
/// buckets — the motion load then sits beside a window with no heart rate, and the bucket maximum this
/// app's strain model takes pairs the wrong two numbers. Nothing in either file would look wrong.
///
/// **Identity is an integer, not a `Date`.** A `Date` round-trips through GRDB at millisecond precision
/// and compares unequal to the one it was written from, so `Set<Date>` membership and `==` are both
/// traps when the values came off disk. `index(for:)` is an `Int` bucket number and is stable across a
/// write and a read, which is what makes the two sides' dictionaries agree.
///
/// Both grids are absolute — `floor(timeIntervalSince1970 / 30)` — and therefore UTC-aligned. That is
/// deliberate: a device timezone whose offset is not a multiple of 30 s (every real one is, but a test
/// can construct one) would otherwise shift the whole grid retroactively, rewriting where every stored
/// epoch sits relative to a recomputation. The cost is at most 30 seconds of motion at local midnight,
/// and never a pairing of an epoch from the previous day.
public enum MotionEpochGrid {
    /// The window length the sleep classifier consumes and the strain model buckets on. One constant,
    /// because changing it in one place and not the other feeds a reader windows it does not expect.
    public static let epochSeconds: TimeInterval = 30

    /// The start of the window containing `date`.
    public static func start(for date: Date) -> Date {
        Date(timeIntervalSince1970: Double(index(for: date)) * epochSeconds)
    }

    /// The window's integer identity, for dictionaries that survive a database round trip.
    public static func index(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / epochSeconds).rounded(.down))
    }

    /// The start of window `index` — the inverse of ``index(for:)``.
    public static func date(forIndex index: Int) -> Date {
        Date(timeIntervalSince1970: Double(index) * epochSeconds)
    }
}

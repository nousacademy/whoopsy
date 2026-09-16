import SwiftUI

/// The caret drawn on a card's top edge to point it at whatever it explains.
///
/// A shape rather than an `Image`, so it takes the fill of the surface it is attached to and cannot
/// come to be drawn in a colour that surface is not. It is drawn as an **overlay** on the finished
/// card and offset upward by its own height, so it sits over the card's stroke and reads as a notch in
/// the edge rather than as a shape resting on a line.
///
/// It was `private` inside `SleepDetailView` while the breakdown card was its only user. The need card
/// is the second — its breakdown box is notched the same way, for the same reason — so it lives here
/// rather than as a second definition in that file, on this repo's rule that a mark two screens draw is
/// a mark with one definition. The two callers fill it differently, which is the point of it being a
/// shape: the breakdown card fills it with `Theme.cardBackground` and the need card's well fills it
/// with the well's own token, so each merges with the surface beneath it.
public struct CardNotch: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

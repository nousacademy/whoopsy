import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The human body as the app's three reference diagrams draw it, and the flow they describe.
///
/// **This is a traditional map, not a measurement, and the card says so.** Two of the three sources
/// are contemplative traditions — an energy-flow diagram and a qigong instruction for drawing earth
/// qi up through the hands and feet — and the third is a research figure that colours body regions by
/// self-reported emotion. None of them is a physiological model, and none of them is something this
/// strap measures. What the drawing does is put their **geometry** in one place: where each tradition
/// says energy enters, gathers and leaves, on one body.
///
/// **The body is a supplied illustration**, cropped to the figure and re-toned into pale line art by
/// `scripts/prepare-energy-figure.swift` so it reads on a dark card; the overlay is measured against *that* image
/// rather than drawn from scratch. The tool's landmark table is what `Mark` records, and a different
/// figure means re-measuring it rather than nudging pixel values until it looks right.
///
/// **No figure on this view comes from a reading.** There is no value, no band and no colour that
/// changes with the day — deliberately, because the app's rule is that a visualisation of a number
/// needs a producer, and there is no producer for a vortex. This tab is a study of its own and reads
/// none of the app's records; the caption says both things.
///
/// ## What the three sources contribute
///
/// - **Energy-flow map**: a central column of seven **vortices** from crown to root. The figure the
///   owner supplied draws each of its points as one of these, so the points *are* the column, and the
///   app calls them **vortices** on the owner's instruction (*"dont call it a chakra call it a vortex
///   instead"*) — the source's own word for them is not used anywhere in the app. *Divine* energy
///   entering through the crown and travelling to the heart; *earth* energy entering through the feet
///   and rising; *kundalini* rising from the base; the two merging **at the heart** and leaving
///   through the palms. Three constrictions — throat, heart and hips.
/// - **Qigong instruction**: the same body read as **three dantian** — lower (below the navel), middle
///   (chest), upper (between the brows) — with earth qi drawn in through the **hands and feet** and
///   *stored* in the lower one. That is why the palms are drawn as intakes here rather than only as
///   outlets, and why the lower dantian is ringed twice.
/// - **Emotion mapping**: not drawn as a flow at all. It contributes one fact the other two do not
///   state — that these regions are where people **feel** things — which is why the torso carries two
///   faint washes rather than being left as a tube.
///
/// **The seven numbers on the drawing are the seven vortices** — one badge per point of the column,
/// numbered crown downwards and matched to the legend under it — because the diagram the figure came
/// from labels its points that way. They are not a sequence to follow and not a score.
public struct EnergyFlowMapView: View {

    /// The figure's own proportions, measured off the bundled image after it was cropped to the body:
    /// 241 × 535 pixels, so every landmark is a fraction of the drawn height and none is an eyeballed
    /// pixel value.
    private enum Mark {
        static let aspect: CGFloat = 241.0 / 535.0
        static let height: CGFloat = 440

        static let crown: CGFloat = 0.005
        static let brow: CGFloat = 0.055
        static let throat: CGFloat = 0.145
        static let heart: CGFloat = 0.270
        static let solar: CGFloat = 0.350
        static let navel: CGFloat = 0.410
        static let root: CGFloat = 0.500

        static let hand: CGFloat = 0.515
        static let handInset: CGFloat = 0.075
        static let feet: CGFloat = 0.980
    }

    /// The region whose paragraph is showing, or `nil` for none.
    @State private var selected: Int?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Energy flow")

            figure
                .frame(maxWidth: .infinity)

            legend

            Text("A traditional map, not a measurement.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            "Energy flow map. A traditional diagram of seven vortices from crown to root, numbered one "
            + "to seven, divine energy "
            + "entering through the crown, earth energy through the feet, both merging at the heart and "
            + "leaving through the palms, with the lower dantian below the navel. Not a measurement."))
    }

    // MARK: - The figure

    private var figure: some View {
        let width = Mark.height * Mark.aspect
        return ZStack {
            figureImage?
                .resizable()
                .scaledToFit()
                .frame(width: width, height: Mark.height)

            torsoWashes(width: width)
            centralColumn(width: width)
            divineFlow(width: width)
            earthFlow(width: width)
            heartMerge(width: width)
            dantian(width: width)
            constrictions(width: width)
            vortexPoints(width: width)
            badges(width: width)
        }
        .frame(width: width, height: Mark.height)
    }

    /// The supplied figure, loaded **by URL** rather than by name.
    ///
    /// `Image("body", bundle: .module)` resolved to nothing on the simulator while
    /// `Bundle.module.url(forResource:)` answered the file — proven with a probe that printed the
    /// resolved path on the screen. Loading the same URL into a platform image takes the name lookup
    /// out of the question, and a missing asset then draws nothing rather than an empty rectangle.
    private var figureImage: Image? {
        guard let url = Bundle.module.url(forResource: "body", withExtension: "png") else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }

    /// The two regions the emotion figure colours — chest and belly — as faint washes, because their
    /// point is that the body *has* regions, not that either is doing something today.
    private func torsoWashes(width: CGFloat) -> some View {
        Group {
            Ellipse()
                .fill(Theme.recoveryYellow.opacity(0.10))
                .frame(width: width * 0.58, height: Mark.height * 0.12)
                .position(x: width / 2, y: Mark.height * Mark.heart)
            Ellipse()
                .fill(Theme.recoveryGreen.opacity(0.09))
                .frame(width: width * 0.46, height: Mark.height * 0.11)
                .position(x: width / 2, y: Mark.height * Mark.navel)
        }
    }

    /// The dashed column every one of the sources draws from crown to root.
    private func centralColumn(width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: width / 2, y: Mark.height * Mark.crown))
            path.addLine(to: CGPoint(x: width / 2, y: Mark.height * Mark.root))
        }
        .stroke(Theme.textMuted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// Divine energy: down through the crown, along the column, gathering at the heart.
    private func divineFlow(width: CGFloat) -> some View {
        Group {
            ForEach(0..<3, id: \.self) { index in
                Path { path in
                    let x = width / 2 + (CGFloat(index) - 1) * width * 0.09
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: Mark.height * Mark.brow))
                }
                .stroke(Theme.livePulseCyan.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            Path { path in
                path.move(to: CGPoint(x: width / 2, y: Mark.height * 0.03))
                path.addLine(to: CGPoint(x: width / 2, y: Mark.height * Mark.heart))
            }
            .stroke(
                LinearGradient(
                    colors: [Theme.livePulseCyan.opacity(0.95), Theme.livePulseCyan.opacity(0.3)],
                    startPoint: .top, endPoint: .bottom),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }

    /// Earth energy: up from the soles to the root, and the rising channel above it.
    private func earthFlow(width: CGFloat) -> some View {
        Group {
            ForEach([0.36, 0.64], id: \.self) { fraction in
                Path { path in
                    let x = width * CGFloat(fraction)
                    path.move(to: CGPoint(x: x, y: Mark.height * 1.005))
                    path.addLine(to: CGPoint(x: x, y: Mark.height * (Mark.feet - 0.03)))
                    path.addLine(to: CGPoint(x: width / 2, y: Mark.height * Mark.root))
                }
                .stroke(Theme.recoveryGreen.opacity(0.8), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
            Path { path in
                path.move(to: CGPoint(x: width / 2, y: Mark.height * Mark.root))
                path.addLine(to: CGPoint(x: width / 2, y: Mark.height * Mark.heart))
            }
            .stroke(
                LinearGradient(
                    colors: [Theme.recoveryGreen.opacity(0.9), Theme.strainGradientEnd.opacity(0.9)],
                    startPoint: .bottom, endPoint: .top),
                style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// Where the two are said to meet, and where they leave: the heart, then out along each arm.
    private func heartMerge(width: CGFloat) -> some View {
        Group {
            Circle().fill(Theme.recoveryYellow.opacity(0.20))
                .frame(width: width * 0.20, height: width * 0.20)
                .position(x: width / 2, y: Mark.height * Mark.heart)
            Circle().fill(Theme.recoveryYellow)
                .frame(width: 8, height: 8)
                .position(x: width / 2, y: Mark.height * Mark.heart)

            ForEach([-1.0, 1.0], id: \.self) { side in
                Path { path in
                    let hand = CGPoint(
                        x: width / 2 + CGFloat(side) * width * (0.5 - Mark.handInset),
                        y: Mark.height * Mark.hand)
                    path.move(to: CGPoint(x: width / 2, y: Mark.height * Mark.heart))
                    path.addCurve(
                        to: hand,
                        control1: CGPoint(
                            x: width / 2 + CGFloat(side) * width * 0.22,
                            y: Mark.height * 0.33),
                        control2: CGPoint(x: hand.x, y: Mark.height * 0.42))
                }
                .stroke(Theme.recoveryYellow.opacity(0.5), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
        }
    }

    /// The dantian the qigong source names, and the storage the lower one is for.
    private func dantian(width: CGFloat) -> some View {
        Group {
            Circle().strokeBorder(Theme.recoveryGreen.opacity(0.55), lineWidth: 1.1)
                .frame(width: width * 0.30, height: width * 0.30)
                .position(x: width / 2, y: Mark.height * Mark.navel)
            Circle().strokeBorder(Theme.recoveryGreen.opacity(0.3), lineWidth: 1)
                .frame(width: width * 0.44, height: width * 0.44)
                .position(x: width / 2, y: Mark.height * Mark.navel)
            Circle().strokeBorder(Theme.textMuted.opacity(0.45), lineWidth: 1)
                .frame(width: width * 0.26, height: width * 0.26)
                .position(x: width / 2, y: Mark.height * Mark.heart)
        }
    }

    /// The three constrictions the rising channel is drawn through — throat, heart and hips.
    ///
    /// The legend names them, so they are drawn: a legend row describing something absent from the
    /// picture is the same fault as a number with no producer, one layer over.
    private func constrictions(width: CGFloat) -> some View {
        ForEach([Mark.throat, Mark.heart, Mark.root], id: \.self) { y in
            Ellipse()
                .strokeBorder(Theme.textSecondary.opacity(0.35), lineWidth: 1)
                .frame(width: width * (y == Mark.heart ? 0.62 : 0.50), height: 12)
                .position(x: width / 2, y: Mark.height * y)
        }
    }

    /// Seven **vortices**, coloured by the traditional spectrum from root to crown, each with its own
    /// number beside it.
    ///
    /// **Their heights are read off the flow diagram** — above the head, between the brows, the throat,
    /// the chest, above the navel, below the navel, and the base between the legs — rather than spaced
    /// evenly down the body, which is the one thing that diagram is precise about. **Every point on it
    /// is one of these**, which is why the numbers sit on the points rather than on the flow features:
    /// the column and the index are the same seven things.
    ///
    /// The heart is drawn larger because it is the one the other two sources also single out — the
    /// merge point of the two currents — not because it is weighted differently.
    private func vortexPoints(width: CGFloat) -> some View {
        ForEach(Array(Self.vortexY.enumerated()), id: \.offset) { index, fraction in
            Circle()
                .fill(Self.vortexColors[index])
                .frame(width: index == 3 ? 9 : 6.5, height: index == 3 ? 9 : 6.5)
                .overlay(
                    Circle().strokeBorder(Theme.textPrimary.opacity(selected == index + 1 ? 0.95 : 0), lineWidth: 1))
                .position(x: width / 2, y: Mark.height * fraction)
        }
    }

    private static let vortexY: [CGFloat] = [
        0.030, Mark.brow, Mark.throat, Mark.heart, Mark.solar, Mark.navel, Mark.root,
    ]

    private static let vortexColors: [Color] = [
        .purple, .indigo, .blue, Theme.recoveryGreen, Theme.recoveryYellow, .orange, Theme.recoveryRed,
    ]

    /// **Numbers, and no words.** The first draft wrote each label beside its badge, and on a 390-point
    /// phone every one of them collided with the figure or ran off the card — a 9-point sentence needs
    /// about ninety points the margins do not have. The sentences live in the legend below, where they
    /// are legible, and the drawing keeps only what it is good at: a place.
    ///
    /// One badge per vortex, on the point's own height, alternating sides so two numbers never stack.
    /// The side is the frame's edge rather than the body's, so a badge can never sit on the figure.
    private func badges(width: CGFloat) -> some View {
        ForEach(Array(Self.vortexY.enumerated()), id: \.offset) { index, fraction in
            badge(index + 1, x: index.isMultiple(of: 2) ? width * 1.08 : width * 0.02,
                  y: Mark.height * fraction)
        }
    }

    private func badge(_ number: Int, x: CGFloat, y: CGFloat) -> some View {
        Button {
            selected = selected == number ? nil : number
        } label: {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(selected == number ? Theme.textPrimary : Theme.backgroundDark)
                .frame(width: 15, height: 15)
                .background(
                    Circle().fill(selected == number ? Theme.strainPrimary : Theme.textSecondary))
                .overlay(
                    Circle().strokeBorder(
                        Theme.textPrimary.opacity(selected == number ? 0.9 : 0),
                        lineWidth: 1))
                // A 15-point circle is well under a fingertip; the content shape does not change the
                // drawing and gives the tap somewhere to land.
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(number). \(Region.all[number - 1].title)"))
        .position(x: x, y: y)
    }

    // MARK: - The legend

    /// **The information is behind the numbers rather than under the drawing.** Each badge is a
    /// button, and tapping one replaces the list with that region's paragraph — so the card is the
    /// figure plus a line, and the reading appears when it is asked for. Tapping the same number again,
    /// or the close row, puts the list back.
    ///
    /// A list of rows was tried first and it was louder than the drawing: the card's subject is the
    /// map, and seven sentences under it competed with it for the eye.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selected, let region = Region.all.first(where: { $0.number == selected }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(region.number)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.backgroundDark)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.textSecondary))
                    Text(region.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Button("Close") { self.selected = nil }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .buttonStyle(.plain)
                }
                Text(region.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tap a number beside a vortex to read what it marks.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    /// One region of the map: the number on the drawing, its name, its one-line legend entry and the
    /// paragraph a tap reveals.
    private struct Region {
        let number: Int
        let title: String
        let detail: String

        static let all: [Region] = [
            Region(
                number: 1, title: "Crown",
                detail: "The uppermost opening, above the head. Energy from above is drawn in here "
                    + "and carried down the central channel; the same point is the highest of the "
                    + "three centres in the qigong framing, between the brows and above."),
            Region(
                number: 2, title: "Brow",
                detail: "Between the eyes. The tradition places the narrowest of the upper points "
                    + "here, associated with seeing rather than with looking — and it is where the "
                    + "descending current is drawn entering the head."),
            Region(
                number: 3, title: "Throat",
                detail: "The first constriction. The column is drawn pinching at the throat, and the "
                    + "rising current is said to have to pass it — the tradition reads it as the "
                    + "point of expression."),
            Region(
                number: 4, title: "Heart",
                detail: "Where the two are said to meet. The rising and descending currents combine "
                    + "here, and everything above and below is held to pass through the junction — "
                    + "which is why the figure is drawn with a second ring at the chest."),
            Region(
                number: 5, title: "Solar plexus",
                detail: "Above the navel, between the heart and the store. The column narrows again "
                    + "on its way down, and the tradition associates this point with will — the "
                    + "third of the three the qigong source names, at the chest's lower edge."),
            Region(
                number: 6, title: "Sacral",
                detail: "Below the navel. The store: everything drawn in through the hands and feet "
                    + "is gathered here, which is why the lower dantian is ringed twice and the "
                    + "figure is drawn with its hands turned in."),
            Region(
                number: 7, title: "Root",
                detail: "The base, between the legs. Where the rising current starts and the earth "
                    + "current arrives — the floor of the column, and the last constriction the "
                    + "drawing pinches."),
        ]
    }

}

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
            linkingRings(width: width)
            centralColumn(width: width)
            divineFlow(width: width)
            earthFlow(width: width)
            crownWhirl(width: width)
            rootWhirl(width: width)
            heartMerge(width: width)
            dantian(width: width)
            constrictions(width: width)
            selectionFlow(width: width)
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

    /// The static currents fade while one vortex is open, so the one that is moving is the only one
    /// the eye has to separate from the drawing. It is the drawing's existing opacity times this.
    private var staticFlow: Double { selected == nil ? 1 : 0.32 }

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
        .stroke(Theme.textMuted.opacity(0.45 * staticFlow), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// **The ring that joins the column's ends, and the two inside it.**
    ///
    /// The reference draws the ladder inside a circle, and the ends of the ladder — the seventh
    /// vortex and the first — on its rim; the next pair in sits on a smaller one, and so on. So the
    /// drawing carries one circle with crown and root on its circumference, one with brow and sacral,
    /// one with throat and solar plexus. Selecting either end of a pair lights that pair's circle,
    /// which is what makes "connected" a thing the card shows rather than a thing its prose claims.
    ///
    /// A pair is drawn as a true circle, not an ellipse fitted to the body, because the two points it
    /// joins are the only thing it is measured against.
    private func linkingRings(width: CGFloat) -> some View {
        let pairs: [(top: CGFloat, bottom: CGFloat, numbers: (Int, Int))] = [
            (Self.vortexY[0], Self.vortexY[6], (1, 7)),
            (Self.vortexY[1], Self.vortexY[5], (2, 6)),
            (Self.vortexY[2], Self.vortexY[4], (3, 5)),
        ]
        return ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
            let diameter = (pair.bottom - pair.top) * Mark.height
            let lit = selected == pair.numbers.0 || selected == pair.numbers.1
            Circle()
                .strokeBorder(
                    lit ? Theme.textPrimary.opacity(0.55) : Theme.textSecondary.opacity(0.15 * staticFlow),
                    lineWidth: lit ? 1.3 : 0.8)
                .frame(width: diameter, height: diameter)
                .position(x: width / 2, y: Mark.height * (pair.top + pair.bottom) / 2)
        }
    }

    /// **Where the column leaves the body at the top**: the crown's vortex opening, drawn as a shallow
    /// whirl of widening rings over the head. Three, because one ellipse reads as a hat and a stack
    /// reads as something turning.
    private func crownWhirl(width: CGFloat) -> some View {
        let lit = selected == 1
        return whirl(
            width: width, centre: 0.055, colour: Theme.livePulseCyan,
            specs: [(0.30, 0.06), (0.46, 0.10), (0.64, 0.14)],
            boost: lit ? 0.55 : 0)
    }

    /// **And at the bottom**: the same whirl at the soles, where the earth current is drawn entering —
    /// so the column is open at both ends rather than stopping at the ankles.
    private func rootWhirl(width: CGFloat) -> some View {
        let lit = selected == 7
        return whirl(
            width: width, centre: 0.95, colour: Theme.recoveryGreen,
            specs: [(0.30, 0.06), (0.46, 0.10), (0.64, 0.14)],
            boost: lit ? 0.55 : 0)
    }

    private func whirl(
        width: CGFloat, centre: CGFloat, colour: Color,
        specs: [(width: CGFloat, height: CGFloat)], boost: Double
    ) -> some View {
        ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
            Ellipse()
                .strokeBorder(
                    colour.opacity((0.50 * pow(0.72, Double(index)) * staticFlow) + boost),
                    lineWidth: 0.9)
                .frame(width: width * spec.width, height: Mark.height * spec.height)
                .position(x: width / 2, y: Mark.height * centre)
        }
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
                .stroke(Theme.livePulseCyan.opacity(0.9 * staticFlow), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            Path { path in
                path.move(to: CGPoint(x: width / 2, y: Mark.height * 0.03))
                path.addLine(to: CGPoint(x: width / 2, y: Mark.height * Mark.heart))
            }
            .stroke(
                LinearGradient(
                    colors: [Theme.livePulseCyan.opacity(0.95 * staticFlow), Theme.livePulseCyan.opacity(0.3 * staticFlow)],
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
                .stroke(Theme.recoveryGreen.opacity(0.8 * staticFlow), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
            Path { path in
                path.move(to: CGPoint(x: width / 2, y: Mark.height * Mark.root))
                path.addLine(to: CGPoint(x: width / 2, y: Mark.height * Mark.heart))
            }
            .stroke(
                LinearGradient(
                    colors: [Theme.recoveryGreen.opacity(0.9 * staticFlow), Theme.strainGradientEnd.opacity(0.9 * staticFlow)],
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
                .stroke(Theme.recoveryYellow.opacity(0.5 * staticFlow), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
        }
    }

    /// The dantian the qigong source names, and the storage the lower one is for.
    private func dantian(width: CGFloat) -> some View {
        let store = selected == 6
        let chest = selected == 4
        return Group {
            Circle().strokeBorder(Theme.recoveryGreen.opacity(store ? 1 : 0.55), lineWidth: store ? 1.8 : 1.1)
                .frame(width: width * 0.30, height: width * 0.30)
                .position(x: width / 2, y: Mark.height * Mark.navel)
            Circle().strokeBorder(Theme.recoveryGreen.opacity(store ? 0.8 : 0.3), lineWidth: store ? 1.6 : 1)
                .frame(width: width * 0.44, height: width * 0.44)
                .position(x: width / 2, y: Mark.height * Mark.navel)
            Circle().strokeBorder(Theme.textMuted.opacity(chest ? 1 : 0.45), lineWidth: chest ? 1.8 : 1)
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
            let lit = selectionSits(on: y)
            Ellipse()
                .strokeBorder(lit ? Theme.textPrimary.opacity(0.9) : Theme.textSecondary.opacity(0.35),
                              lineWidth: lit ? 1.6 : 1)
                .frame(width: width * (y == Mark.heart ? 0.62 : 0.50), height: 12)
                .position(x: width / 2, y: Mark.height * y)
        }
    }

    /// Whether the selected vortex is the one a constriction carries — 3 throat, 4 heart, 7 hips.
    private func selectionSits(on y: CGFloat) -> Bool {
        switch selected {
        case 3: return y == Mark.throat
        case 4: return y == Mark.heart
        case 7: return y == Mark.root
        default: return false
        }
    }

    // MARK: - The selected vortex's motion

    /// **Tapping a number sets the current it sits on moving, in that current's own direction.**
    ///
    /// The diagram the figure came from draws every point as a junction of rings and flows, and a
    /// selection that only opened a paragraph let the drawing stay still — so the paragraph now
    /// arrives with the motion it describes: the descending current runs down towards the heart for
    /// the upper three, the rising current runs up for the lower ones, the heart takes both, and the
    /// hands and feet draw inward. A ripple leaves the selected point at the same time, which is the
    /// "ring" half of what each point is connected to; the constriction it sits on lights up in
    /// `constrictions(width:)` and the dantian rings in `dantian(width:)`.
    ///
    /// **Direction is the path's own**, because a path is drawn start to end and a negative dash phase
    /// walks the pattern along it — so the geometry below starts where the current starts: at the top
    /// for the descending half, at the feet for the rising one, at the hand for an intake. Reversing a
    /// path would reverse its meaning, not merely its look.
    ///
    /// `TimelineView` rather than a repeating animation, so the phase is a function of the clock and
    /// there is no `@State` to leave running when the card closes — the view exists only while a
    /// vortex is selected, and the motion stops with it.
    @ViewBuilder
    private func selectionFlow(width: CGFloat) -> some View {
        if let selected, Self.vortexColors.indices.contains(selected - 1) {
            let colour = Self.vortexColors[selected - 1]
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                // 20 is one dash period (`7 + 13`), so the wrap at 2 s lands on the same pattern.
                // **Positive, and that is not cosmetic**: measured on the simulator, a negative phase
                // walked the pattern back towards the path's start, so the descending current ran
                // upwards — the sign is the direction, and it was wrong way round the first time.
                let phase = CGFloat(seconds.truncatingRemainder(dividingBy: 2)) * 20
                let ripple = CGFloat(seconds.truncatingRemainder(dividingBy: 1.6)) / 1.6
                ZStack {
                    ForEach(Array(currents(for: selected, width: width).enumerated()), id: \.offset) { _, flow in
                        flow.path
                            .stroke(
                                flow.color,
                                style: StrokeStyle(
                                    lineWidth: 3.2, lineCap: .round, dash: [7, 13], dashPhase: phase))
                            .shadow(color: flow.color.opacity(0.7), radius: 3)
                    }
                    ForEach([0.0, 0.5], id: \.self) { offset in
                        let r = (ripple + offset).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(colour.opacity(0.85 * (1 - r)), lineWidth: 1.6)
                            .frame(width: 24 + r * 46, height: 24 + r * 46)
                            .position(x: width / 2, y: Mark.height * Self.vortexY[selected - 1])
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The currents a vortex sits on, each drawn from where that current starts.
    private func currents(for number: Int, width: CGFloat) -> [(path: Path, color: Color)] {
        let x = width / 2
        func column(_ from: CGFloat, _ to: CGFloat) -> Path {
            Path { path in
                path.move(to: CGPoint(x: x, y: Mark.height * from))
                path.addLine(to: CGPoint(x: x, y: Mark.height * to))
            }
        }
        func intake(side: CGFloat) -> Path {
            let hand = CGPoint(
                x: x + side * width * (0.5 - Mark.handInset), y: Mark.height * Mark.hand)
            return Path { path in
                path.move(to: hand)
                path.addCurve(
                    to: CGPoint(x: x, y: Mark.height * Mark.navel),
                    control1: CGPoint(x: hand.x, y: Mark.height * 0.46),
                    control2: CGPoint(x: x + side * width * 0.16, y: Mark.height * 0.40))
            }
        }
        func sole(_ fraction: CGFloat) -> Path {
            Path { path in
                path.move(to: CGPoint(x: width * fraction, y: Mark.height * 1.005))
                path.addLine(to: CGPoint(x: width * fraction, y: Mark.height * (Mark.feet - 0.03)))
                path.addLine(to: CGPoint(x: x, y: Mark.height * Mark.root))
            }
        }

        switch number {
        case 1: return [(column(0, Mark.heart), Theme.livePulseCyan)]
        case 2: return [(column(Mark.crown, Mark.brow + 0.02), Theme.livePulseCyan)]
        case 3: return [(column(Mark.heart, Mark.throat), Theme.recoveryYellow)]
        case 4:
            return [
                (column(0, Mark.heart), Theme.livePulseCyan),
                (column(Mark.root, Mark.heart), Theme.recoveryGreen),
            ]
        case 5: return [(column(Mark.navel, Mark.solar), Theme.recoveryGreen)]
        case 6: return [(intake(side: -1), Theme.recoveryGreen), (intake(side: 1), Theme.recoveryGreen)]
        case 7: return [(sole(0.36), Theme.recoveryGreen), (sole(0.64), Theme.recoveryGreen)]
        default: return []
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
                .frame(width: index == 3 ? 13 : 8.5, height: index == 3 ? 13 : 8.5)
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

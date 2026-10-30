import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The human body as the app's three reference diagrams draw it, and the flow they describe.
///
/// **This is a traditional map, not a measurement, and the card says so.** Two of the three sources
/// are contemplative traditions — a chakra/energy-flow map and a qigong instruction for drawing earth
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
/// needs a producer, and there is no producer for a chakra. This tab is a study of its own and reads
/// none of the app's records; the caption says both things.
///
/// ## What the three sources contribute
///
/// - **Energy-flow map**: a central column of seven centres from crown to root; *divine* energy
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
/// The numbers on the drawing are this view's own index, matched to the legend under it. They are not
/// a sequence to follow and not a score.
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

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Energy flow")

            figure
                .frame(maxWidth: .infinity)

            legend

            Text(
                "A map of three traditions, not a reading: a chakra flow chart, a qigong instruction "
                + "for drawing earth qi through the hands and feet into the lower dantian, and a "
                + "research figure of where emotions are felt in the body. Together they say where "
                + "energy is said to enter, gather and leave — the crown, the heart, the lower belly, "
                + "the palms and the soles. Nothing on it is measured, and nothing on it changes with "
                + "your day. This tab is a study of its own: it reads none of the app's records and "
                + "writes none, so nothing here can move a figure elsewhere.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            "Energy flow map. A traditional diagram of seven centres from crown to root, divine energy "
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
            centres(width: width)
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

    /// Seven centres, coloured by the traditional spectrum from root to crown.
    private func centres(width: CGFloat) -> some View {
        ForEach(Array(Self.chakraY.enumerated()), id: \.offset) { index, fraction in
            Circle()
                .fill(Self.chakraColors[index])
                .frame(width: index == 3 ? 9 : 6.5, height: index == 3 ? 9 : 6.5)
                .position(x: width / 2, y: Mark.height * fraction)
        }
    }

    private static let chakraY: [CGFloat] = [
        0.030, Mark.brow, Mark.throat, Mark.heart, Mark.solar, Mark.navel, Mark.root,
    ]

    private static let chakraColors: [Color] = [
        .purple, .indigo, .blue, Theme.recoveryGreen, Theme.recoveryYellow, .orange, Theme.recoveryRed,
    ]

    /// **Numbers, and no words.** The first draft wrote each label beside its badge, and on a 390-point
    /// phone every one of the six collided with the figure or ran off the card — a 9-point sentence
    /// needs about ninety points the margins do not have. The sentences live in the legend below,
    /// where they are legible, and the drawing keeps only what it is good at: a place.
    private func badges(width: CGFloat) -> some View {
        Group {
            // Numbered in the order the legend reads, which is the order the flow runs: in through the
            // crown, in through the soles, meeting at the heart, up through the constrictions, out
            // through the palms, stored in the lower dantian.
            badge(1, x: width * 1.08, y: Mark.height * 0.030)
            badge(2, x: width * 0.22, y: Mark.height * 0.925)
            badge(3, x: width * 1.08, y: Mark.height * Mark.heart)
            badge(4, x: width * 0.22, y: Mark.height * 0.600)
            badge(5, x: width * 0.02, y: Mark.height * Mark.hand)
            badge(6, x: width * 1.08, y: Mark.height * Mark.navel)
        }
    }

    private func badge(_ number: Int, x: CGFloat, y: CGFloat) -> some View {
        Text("\(number)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.backgroundDark)
            .frame(width: 15, height: 15)
            .background(Circle().fill(Theme.textSecondary))
            .position(x: x, y: y)
    }

    // MARK: - The legend

    /// The same six numbers, in the order the flow runs. Written here so the drawing carries no
    /// sentence too small to read.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            legendRow(1, "Divine energy enters through the crown and travels down the centre.")
            legendRow(2, "Earth energy enters through the soles and rises to the root.")
            legendRow(3, "At the heart the two are said to meet and blend.")
            legendRow(4, "The rising channel is drawn through three constrictions — throat, heart, hips.")
            legendRow(5, "The blend leaves through the palms.")
            legendRow(6, "What is drawn in is stored in the lower dantian, below the navel.")
        }
    }

    private func legendRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 12, alignment: .leading)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

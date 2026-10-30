import SwiftUI

/// The human body as the app's three reference diagrams draw it, and the flow they describe.
///
/// **This is a traditional map, not a measurement, and the card says so.** Two of the three sources
/// are contemplative traditions — a chakra/energy-flow map and a qigong instruction for drawing earth
/// qi up through the hands and feet — and the third is a research figure that colours body regions by
/// self-reported emotion. None of them is a physiological model, and none of them is something this
/// strap measures. What the drawing does is put their **geometry** in one place: where each tradition
/// says energy enters, gathers and leaves, on one body.
///
/// **No figure on this view comes from a reading.** There is no value, no band and no colour that
/// changes with the day — deliberately, because the app's rule is that a visualisation of a number
/// needs a producer, and there is no producer for a chakra. The measured figure on this page is the
/// ring above it; this card is the map those traditions share, and the caption draws that line.
///
/// ## What the three sources contribute
///
/// - **Energy-flow map**: a central column of seven centres from crown to root; *divine* energy
///   entering through the crown and travelling to the heart; *earth* energy entering through the feet
///   and rising; *kundalini* rising from the base; the two merging **at the heart** and leaving
///   through the palms. Three constrictions — throat, heart and hips — that the rising channel is drawn
///   through.
/// - **Qigong instruction**: the same body read as **three dantian** — lower (below the navel), middle
///   (chest), upper (between the brows) — with earth qi drawn in through the **hands and feet** and
///   *stored* in the lower one. That is why the palms are drawn as intakes here rather than only as
///   outlets, and why the lower dantian is ringed twice.
/// - **Emotion mapping**: not drawn as a flow at all. It contributes one fact the other two do not
///   state — that these regions are where people **feel** things — which is the reason the torso is
///   drawn as regions rather than as a tube.
///
/// The numbers on the drawing are this view's own index, matched to the legend under it. They are not
/// a sequence to follow and not a score.
public struct EnergyFlowMapView: View {

    /// The drawing's own coordinate space, scaled to whatever width the card gives it.
    private static let canvas = CGSize(width: 300, height: 480)

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Energy flow")

            GeometryReader { proxy in
                let scale = min(proxy.size.width / Self.canvas.width, 1.0)
                // **The outer frame reserves the *scaled* size.** `scaleEffect` is a render transform
                // and leaves the layout size alone, so a view scaled up inside an unscaled frame
                // overflows its card — measured on the simulator, where the feet were drawn over the
                // tab bar. Reserving `canvas × scale` and anchoring the transform top-leading is what
                // makes the card's height and the picture's height the same number.
                drawing
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: Self.canvas.width * scale,
                        height: Self.canvas.height * scale,
                        alignment: .topLeading)
            }
            .frame(height: Self.canvas.height)

            legend

            Text(
                "A map of three traditions, not a reading: a chakra flow chart, a qigong instruction "
                + "for drawing earth qi through the hands and feet into the lower dantian, and a "
                + "research figure of where emotions are felt in the body. Together they say where "
                + "energy is said to enter, gather and leave — the crown, the heart, the lower belly, "
                + "the palms and the soles. Nothing on it is measured, and nothing on it changes with "
                + "your day; the ring above is this app's only figure.")
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

    // MARK: - The drawing

    private var drawing: some View {
        ZStack {
            bodySilhouette
                .stroke(Theme.textMuted.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

            regions
            centralColumn
            divineFlow
            earthFlow
            heartMerge
            dantian
            constrictions
            centres
            callouts
        }
        // The body is drawn around `x = 130` in its own terms; the canvas is 300 wide so the numbered
        // badges have margin to sit in. Twenty points of shift centres the figure in the space left.
        .offset(x: 20)
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }

    /// A front-facing figure, symmetric about `x = 130`, with the palms turned out and the feet apart —
    /// the pose all three sources use, because each of them needs the hands and the feet visible.
    private var bodySilhouette: Path {
        Path { path in
            // Head.
            path.addEllipse(in: CGRect(x: 103, y: 18, width: 54, height: 60))

            // Neck and torso: shoulders wide, waist in, hips out again.
            path.move(to: CGPoint(x: 116, y: 76))
            path.addLine(to: CGPoint(x: 116, y: 92))
            path.addCurve(
                to: CGPoint(x: 74, y: 120),
                control1: CGPoint(x: 96, y: 96), control2: CGPoint(x: 80, y: 104))
            path.addLine(to: CGPoint(x: 84, y: 196))
            path.addCurve(
                to: CGPoint(x: 96, y: 262),
                control1: CGPoint(x: 86, y: 220), control2: CGPoint(x: 90, y: 244))
            path.addLine(to: CGPoint(x: 89, y: 420))
            path.addLine(to: CGPoint(x: 110, y: 420))
            path.addLine(to: CGPoint(x: 118, y: 300))
            path.addLine(to: CGPoint(x: 126, y: 420))
            path.addLine(to: CGPoint(x: 147, y: 420))
            path.addLine(to: CGPoint(x: 140, y: 262))
            path.addCurve(
                to: CGPoint(x: 176, y: 196),
                control1: CGPoint(x: 160, y: 244), control2: CGPoint(x: 172, y: 220))
            path.addLine(to: CGPoint(x: 186, y: 120))
            path.addCurve(
                to: CGPoint(x: 144, y: 92),
                control1: CGPoint(x: 180, y: 104), control2: CGPoint(x: 164, y: 96))
            path.addLine(to: CGPoint(x: 144, y: 76))

            // Arms, out to the palms and back.
            path.move(to: CGPoint(x: 74, y: 120))
            path.addCurve(
                to: CGPoint(x: 40, y: 250),
                control1: CGPoint(x: 58, y: 150), control2: CGPoint(x: 44, y: 200))
            path.addLine(to: CGPoint(x: 60, y: 256))
            path.addCurve(
                to: CGPoint(x: 90, y: 140),
                control1: CGPoint(x: 62, y: 205), control2: CGPoint(x: 76, y: 162))

            path.move(to: CGPoint(x: 186, y: 120))
            path.addCurve(
                to: CGPoint(x: 220, y: 250),
                control1: CGPoint(x: 202, y: 150), control2: CGPoint(x: 216, y: 200))
            path.addLine(to: CGPoint(x: 200, y: 256))
            path.addCurve(
                to: CGPoint(x: 170, y: 140),
                control1: CGPoint(x: 198, y: 205), control2: CGPoint(x: 184, y: 162))
        }
    }

    /// The three regions the emotion figure colours — head, chest and belly. Drawn faintly, because
    /// their point is that the body *has* regions, not that any of them is doing something today.
    private var regions: some View {
        Group {
            Circle().fill(Theme.sleepIndigo.opacity(0.10))
                .frame(width: 74, height: 74).position(x: 130, y: 48)
            RoundedRectangle(cornerRadius: 34)
                .fill(Theme.recoveryYellow.opacity(0.08))
                .frame(width: 104, height: 66).position(x: 130, y: 150)
            RoundedRectangle(cornerRadius: 28)
                .fill(Theme.recoveryGreen.opacity(0.07))
                .frame(width: 76, height: 62).position(x: 130, y: 224)
        }
    }

    /// The seven centres, crown to root, on the column every one of the sources draws down the spine.
    private var centralColumn: some View {
        Path { path in
            path.move(to: CGPoint(x: 130, y: 34))
            path.addLine(to: CGPoint(x: 130, y: 268))
        }
        .stroke(Theme.textMuted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// Divine energy: down through the crown, along the column, gathering at the heart.
    private var divineFlow: some View {
        Group {
            ForEach(0..<3, id: \.self) { index in
                Path { path in
                    let x = 114.0 + Double(index) * 16
                    path.move(to: CGPoint(x: x, y: 2))
                    path.addLine(to: CGPoint(x: x, y: 26))
                }
                .stroke(Theme.livePulseCyan.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            Path { path in
                path.move(to: CGPoint(x: 130, y: 30))
                path.addLine(to: CGPoint(x: 130, y: 136))
            }
            .stroke(
                LinearGradient(
                    colors: [Theme.livePulseCyan.opacity(0.95), Theme.livePulseCyan.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }

    /// Earth energy: up from the soles to the root, and on into the lower dantian.
    private var earthFlow: some View {
        Group {
            ForEach([92.0, 168.0], id: \.self) { x in
                Path { path in
                    path.move(to: CGPoint(x: x, y: 446))
                    path.addLine(to: CGPoint(x: x, y: 414))
                    path.addLine(to: CGPoint(x: 130, y: 268))
                }
                .stroke(Theme.recoveryGreen.opacity(0.75), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            // Kundalini: the base of the spine to the heart, drawn thicker as it climbs.
            Path { path in
                path.move(to: CGPoint(x: 130, y: 262))
                path.addLine(to: CGPoint(x: 130, y: 140))
            }
            .stroke(
                LinearGradient(
                    colors: [Theme.recoveryGreen.opacity(0.9), Theme.strainGradientEnd.opacity(0.9)],
                    startPoint: .bottom, endPoint: .top),
                style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// Where the two are said to meet, and where they leave: the heart, then out along each arm.
    private var heartMerge: some View {
        Group {
            Circle().fill(Theme.recoveryYellow.opacity(0.22))
                .frame(width: 30, height: 30).position(x: 130, y: 140)
            Circle().fill(Theme.recoveryYellow)
                .frame(width: 9, height: 9).position(x: 130, y: 140)

            ForEach([PathEdge.left, PathEdge.right], id: \.self) { edge in
                Path { path in
                    let hand = edge == .left ? CGPoint(x: 50, y: 252) : CGPoint(x: 210, y: 252)
                    path.move(to: CGPoint(x: 130, y: 140))
                    path.addCurve(
                        to: hand,
                        control1: CGPoint(x: edge == .left ? 96 : 164, y: 150),
                        control2: CGPoint(x: hand.x + (edge == .left ? 6 : -6), y: 200))
                }
                .stroke(Theme.recoveryYellow.opacity(0.55), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
    }

    private enum PathEdge: Hashable { case left, right }

    /// The two dantian the qigong source names, and the storage the lower one is for.
    private var dantian: some View {
        Group {
            Circle().strokeBorder(Theme.recoveryGreen.opacity(0.6), lineWidth: 1.2)
                .frame(width: 40, height: 40).position(x: 130, y: 224)
            Circle().strokeBorder(Theme.recoveryGreen.opacity(0.35), lineWidth: 1)
                .frame(width: 58, height: 58).position(x: 130, y: 224)
            Circle().strokeBorder(Theme.textMuted.opacity(0.5), lineWidth: 1)
                .frame(width: 34, height: 34).position(x: 130, y: 150)
        }
    }

    /// The three constrictions the rising channel is drawn through — throat, heart and hips.
    ///
    /// The legend names them, so they are drawn: a legend row that describes something absent from the
    /// picture is the same fault as a number with no producer, one layer over.
    private var constrictions: some View {
        ForEach([96.0, 140.0, 236.0], id: \.self) { y in
            Ellipse()
                .strokeBorder(Theme.textSecondary.opacity(0.45), lineWidth: 1)
                .frame(width: y == 140 ? 92 : 78, height: 16)
                .position(x: 130, y: y)
        }
    }

    /// Seven centres, coloured by the traditional spectrum from root to crown.
    private var centres: some View {
        ForEach(Array(Self.chakraY.enumerated()), id: \.offset) { index, y in
            Circle()
                .fill(Self.chakraColors[index])
                .frame(width: index == 3 ? 10 : 7, height: index == 3 ? 10 : 7)
                .position(x: 130, y: y)
        }
    }

    private static let chakraY: [Double] = [40, 62, 96, 140, 176, 212, 258]

    private static let chakraColors: [Color] = [
        .purple, .indigo, .blue, Theme.recoveryGreen, Theme.recoveryYellow, .orange, Theme.recoveryRed,
    ]

    /// **Numbers, and no words.** The first draft wrote each label beside its badge, and on a 390-point
    /// phone every one of the six collided with the figure or ran off the card — a 9-point sentence
    /// needs about ninety points that the margins do not have. The sentences live in the legend below,
    /// where they are legible, and the drawing keeps only what it is good at: a place.
    private var callouts: some View {
        Group {
            // **Numbered in the order the legend reads, which is the order the flow runs**: in
            // through the crown, in through the soles, meeting at the heart, up through the
            // constrictions, out through the palms, stored in the lower dantian. The first draft
            // numbered them by position down the page and the legend said something else at every
            // number — the pairing is the whole of what a badge is for.
            callout(1, at: CGPoint(x: 176, y: 20))
            callout(2, at: CGPoint(x: 78, y: 440))
            callout(3, at: CGPoint(x: 176, y: 140))
            callout(4, at: CGPoint(x: 70, y: 300))
            callout(5, at: CGPoint(x: 40, y: 252))
            callout(6, at: CGPoint(x: 176, y: 224))
        }
    }

    private func callout(_ number: Int, at point: CGPoint) -> some View {
        Text("\(number)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.backgroundDark)
            .frame(width: 15, height: 15)
            .background(Circle().fill(Theme.textSecondary))
            .position(x: point.x, y: point.y)
    }

    // MARK: - The legend

    /// The same six numbers, in the order the flow runs — in down the crown, up from the soles, merge,
    /// and out. Written here so the drawing carries no sentence too small to read.
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

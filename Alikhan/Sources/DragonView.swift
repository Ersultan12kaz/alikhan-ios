import SwiftUI

/// Басты экрандағы айдаһар: ноутбуктағы Dragon (overlay.py) сияқты.
/// Айдаһар қозғалмайды, жүрегі күйге сай боялады, айналасында жарық:
/// ұйқы — баяу тыныстайды, тыңдау — шеті жанып, толқын тарайды, ойлау — жүректі айналған жүктелу белгісі,
/// сөйлеу — шеті дауыс ырғағымен қозғалады, қате — жыпылықтайды.
struct DragonView: View {
    let state: OrbState
    var width: CGFloat = 340

    // Жүректің суреттегі орны (tools/make_assets.py есептеген)
    private let heartX: CGFloat = 0.544
    private let heartY: CGFloat = 0.443
    private let aspect: CGFloat = 1002.0 / 1500.0

    var body: some View {
        let height = width * aspect
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Canvas { ctx, size in halo(ctx, size, t) }
                Image("dragon_big_\(state.rawValue)").resizable().scaledToFit()
                Canvas { ctx, size in effects(ctx, size, t) }
            }
        }
        .frame(width: width, height: height)
    }

    private func center(_ size: CGSize) -> CGPoint { CGPoint(x: size.width * heartX, y: size.height * heartY) }
    private func unit(_ size: CGSize) -> CGFloat { size.width * 0.105 }   // Жүректің жарты ені

    /// Жүрек пішіні: әсерлер жүректің өз пішінімен жүреді
    private func heart(_ c: CGPoint, _ s: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: c.x, y: c.y + s * 1.05))
            p.addCurve(to: CGPoint(x: c.x - s, y: c.y - s * 0.3),
                       control1: CGPoint(x: c.x - s * 0.55, y: c.y + s * 0.6), control2: CGPoint(x: c.x - s, y: c.y + s * 0.2))
            p.addCurve(to: CGPoint(x: c.x - s * 0.5, y: c.y - s * 0.95),
                       control1: CGPoint(x: c.x - s, y: c.y - s * 0.72), control2: CGPoint(x: c.x - s * 0.8, y: c.y - s * 0.95))
            p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.58),
                       control1: CGPoint(x: c.x - s * 0.25, y: c.y - s * 0.95), control2: CGPoint(x: c.x, y: c.y - s * 0.78))
            p.addCurve(to: CGPoint(x: c.x + s * 0.5, y: c.y - s * 0.95),
                       control1: CGPoint(x: c.x, y: c.y - s * 0.78), control2: CGPoint(x: c.x + s * 0.25, y: c.y - s * 0.95))
            p.addCurve(to: CGPoint(x: c.x + s, y: c.y - s * 0.3),
                       control1: CGPoint(x: c.x + s * 0.8, y: c.y - s * 0.95), control2: CGPoint(x: c.x + s, y: c.y - s * 0.72))
            p.addCurve(to: CGPoint(x: c.x, y: c.y + s * 1.05),
                       control1: CGPoint(x: c.x + s, y: c.y + s * 0.2), control2: CGPoint(x: c.x + s * 0.55, y: c.y + s * 0.6))
            p.closeSubpath()
        }
    }

    /// Айдаһардың артындағы жұмсақ жарқыл
    private func halo(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let c = center(size), s = unit(size)
        let breath = 0.5 + 0.5 * sin(t * (state == .sleep ? 1.3 : 3.0))
        let alpha = state == .sleep ? 0.12 + 0.12 * breath : 0.28 + 0.2 * breath
        let r = s * 3.2
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [state.accent.opacity(alpha), state.accent.opacity(0)]),
                                       center: c, startRadius: 0, endRadius: r))
    }

    private func glow(_ ctx: GraphicsContext, _ c: CGPoint, _ s: CGFloat, scale: CGFloat, alpha: Double, width: CGFloat) {
        ctx.stroke(heart(c, s * scale), with: .color(state.accent.opacity(max(0, min(1, alpha)))),
                   style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }

    /// Жүрек айналасындағы жарық: қосылып жанады (plusLighter)
    private func effects(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        var ctx = ctx
        ctx.blendMode = .plusLighter
        let c = center(size), s = unit(size), k = size.width / 340
        let breath = 0.5 + 0.5 * sin(t * 1.3)
        switch state {
        case .listen:   // Шеті жанып тұр, жарық сыртқа тарайды
            for (i, scale) in [1.08, 1.18, 1.3].enumerated() {
                glow(ctx, c, s, scale: scale, alpha: (0.6 - Double(i) * 0.17) * (0.75 + 0.25 * sin(t * 3)), width: (3 - CGFloat(i) * 0.7) * k)
            }
            let phase = (t * 0.8).truncatingRemainder(dividingBy: 1)
            glow(ctx, c, s, scale: 1.08 + phase * 0.6, alpha: 0.55 * (1 - phase), width: 2 * k)
        case .think:    // Жүректі айналып жүрген жүктелу белгісі
            let path = heart(c, s * 1.28)
            let head = (t * 0.55).truncatingRemainder(dividingBy: 1)
            for i in 0..<12 {
                let from = head - Double(i) * 0.012
                let seg = from < 0 ? from + 1 : from
                ctx.stroke(path.trimmedPath(from: seg, to: min(1, seg + 0.012)),
                           with: .color((i < 3 ? Color.white : state.accent).opacity(1 - Double(i) / 12)),
                           style: StrokeStyle(lineWidth: 5 * k, lineCap: .round))
            }
            glow(ctx, c, s, scale: 1.12, alpha: 0.2, width: 2 * k)
        case .speak:    // Дауыс ырғағы: шеттері ішке-сыртқа қозғалады
            for i in 0..<3 {
                let level = 0.5 + 0.5 * abs(sin(t * (7 + Double(i) * 2) + Double(i)))
                glow(ctx, c, s, scale: 1.08 + CGFloat(i) * 0.08 + CGFloat(level) * 0.08, alpha: 0.75 - Double(i) * 0.2, width: (2.6 - CGFloat(i) * 0.6) * k)
            }
        case .error:    // Жыпылықтайды
            glow(ctx, c, s, scale: 1.14, alpha: Int(t * 2) % 2 == 0 ? 0.65 : 0.15, width: 3 * k)
        case .sleep:    // Сыртынан баяу жарқыл
            for (i, scale) in [1.1, 1.24, 1.4].enumerated() {
                glow(ctx, c, s, scale: scale, alpha: (0.38 - Double(i) * 0.1) * (0.4 + 0.6 * breath), width: (3 - CGFloat(i) * 0.7) * k)
            }
        }
    }
}

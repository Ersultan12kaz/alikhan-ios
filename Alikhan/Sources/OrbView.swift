import SwiftUI

/// Ноутбуктағы шардың көшірмесі (overlay.py, Orb). Өлшемдер 84 пиксельдік терезеден масштабталады.
struct OrbView: View {
    let state: OrbState
    var size: CGFloat = 260

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, canvas in
                draw(ctx, canvas, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: size, height: size)
    }

    private func draw(_ ctx: GraphicsContext, _ canvas: CGSize, t: Double) {
        let k = size / 84
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let (light, dark, glow) = state.palette
        let breath = 0.5 + 0.5 * sin(t * (state == .sleep ? 1.2 : 3.0))
        let radius = (25 + (state == .sleep ? 1.5 * breath : 0)) * k
        let half = size / 2

        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }

        // Сыртқы жарқыл
        let haloAlpha = state == .sleep ? 0.10 + 0.08 * breath : 0.30 + 0.25 * breath
        ctx.fill(circle(half), with: .radialGradient(
            Gradient(stops: [.init(color: glow.opacity(haloAlpha), location: 0),
                             .init(color: glow.opacity(haloAlpha), location: radius / half * 0.85),
                             .init(color: glow.opacity(0), location: 1)]),
            center: c, startRadius: 0, endRadius: half))

        if state == .listen {   // Толқындар тарайды
            for i in 0..<3 {
                let phase = (t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let r = radius + phase * (half - radius - k)
                ctx.stroke(circle(r), with: .color(glow.opacity(0.55 * (1 - phase))), lineWidth: 2 * k)
            }
        }

        // Шардың өзі: жоғарғы сол жақтан жарық түседі
        ctx.fill(circle(radius), with: .radialGradient(
            Gradient(stops: [.init(color: light.opacity(1).mix(.white, 0.25), location: 0),
                             .init(color: light, location: 0.55),
                             .init(color: dark, location: 1)]),
            center: CGPoint(x: c.x - radius * 0.35, y: c.y - radius * 0.45), startRadius: 0, endRadius: radius * 1.6))
        ctx.stroke(circle(radius), with: .color(.white.opacity(0.16)), lineWidth: k)

        // Шыны жылтыры
        let shine = Path(ellipseIn: CGRect(x: c.x - radius * 0.62, y: c.y - radius * 0.82, width: radius * 1.1, height: radius * 0.7))
        ctx.fill(shine, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.35), .white.opacity(0)]),
            center: CGPoint(x: c.x - radius * 0.1, y: c.y - radius * 0.6), startRadius: 0, endRadius: radius * 0.8))

        switch state {
        case .think:   // Айналатын доға
            let r = radius + 5 * k
            let angle = Angle.degrees(-t * 260)
            ctx.stroke(circle(r), with: .conicGradient(
                Gradient(stops: [.init(color: .white.opacity(0.9), location: 0),
                                 .init(color: .white.opacity(0), location: 0.35),
                                 .init(color: .white.opacity(0), location: 1)]),
                center: c, angle: angle), style: StrokeStyle(lineWidth: 3 * k, lineCap: .round))
            mark(ctx, c, "•••", 14 * k, 0.9)
        case .speak:   // Дыбыс бағандары
            for i in 0..<5 {
                let level = 0.35 + 0.65 * abs(sin(t * (5 + Double(i) * 1.7) + Double(i) * 1.3))
                let h = (6 + level * 25 * 0.9) * k
                let x = c.x + CGFloat(i - 2) * 6.5 * k
                ctx.fill(Path(roundedRect: CGRect(x: x - 2 * k, y: c.y - h / 2, width: 4 * k, height: h), cornerRadius: 2 * k),
                         with: .color(.white.opacity(0.92)))
            }
        case .listen:
            mark(ctx, c, "А", 20 * k, 0.95)
        case .error:
            mark(ctx, c, "!", 20 * k, 1)
        case .sleep:
            mark(ctx, c, "А", 20 * k, 0.55 + 0.25 * breath)
        }
    }

    private func mark(_ ctx: GraphicsContext, _ c: CGPoint, _ text: String, _ px: CGFloat, _ alpha: Double) {
        ctx.draw(Text(text).font(.system(size: px, weight: .semibold)).foregroundColor(.white.opacity(alpha)), at: c)
    }
}

private extension Color {
    func mix(_ other: Color, _ t: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
    }
}

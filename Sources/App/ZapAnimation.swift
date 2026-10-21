import SwiftUI

/// Plays after an app is removed: the icon charges up, then bursts into particles
/// that keep the icon's own colours. Everything is drawn in code, no media files.
struct ZapAnimationView: View {
    let icon: NSImage
    let iconSize: CGFloat
    /// Dims what's behind; off when playing in the transparent overlay window.
    let showsBackdrop: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Fixed when the view is created: state set later from onAppear doesn't reliably reach
    // the Canvas when this view is the root of a bare NSHostingView (the overlay window).
    private let start = Date()
    private let particles: [ZapParticle]

    private let chargeDuration = 0.45
    private let totalDuration = 1.7

    init(icon: NSImage, iconSize: CGFloat = 128, showsBackdrop: Bool = true, onFinished: @escaping () -> Void) {
        self.icon = icon
        self.iconSize = iconSize
        self.showsBackdrop = showsBackdrop
        self.onFinished = onFinished
        particles = ZapParticle.make(from: icon, iconSize: iconSize)
    }

    var body: some View {
        ZStack {
            if showsBackdrop { Rectangle().fill(.background.opacity(0.85)) }
            if reduceMotion {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(in: &context, size: size, time: timeline.date.timeIntervalSince(start))
                    }
                }
            }
        }
        .onAppear(perform: begin)
    }

    private func begin() {
        let duration = reduceMotion ? 0.5 : totalDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.1 : chargeDuration)) { playSound() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: onFinished)
    }

    private func playSound() {
        for (name, volume) in [("Pop", Float(1.0)), ("Blow", Float(0.35))] {
            let sound = NSSound(named: NSSound.Name(name))
            sound?.volume = volume
            sound?.play()
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        if time < chargeDuration {
            drawCharge(in: &context, center: center, progress: time / chargeDuration, time: time)
            return
        }
        let burst = time - chargeDuration
        drawFlash(in: &context, center: center, burst: burst)
        drawShockwave(in: &context, center: center, burst: burst)
        drawParticles(in: &context, center: center, burst: burst)
        drawSparks(in: &context, center: center, burst: burst)
    }

    /// Fast, glowing streaks drawn additively on top of the icon pieces.
    private func drawSparks(in context: inout GraphicsContext, center: CGPoint, burst: Double) {
        let progress = burst / 0.6
        guard progress < 1 else { return }
        var glow = context
        glow.blendMode = .plusLighter
        let count = 48
        for index in 0..<count {
            // Deterministic per spark, so the pattern is stable from frame to frame.
            let seed = Double(index) * 12.9898
            let angle = Double(index) / Double(count) * 2 * .pi + sin(seed) * 0.2
            let speed = 520 + 380 * abs(sin(seed * 3.1))
            let travel = speed * burst * (1 - 0.5 * progress)
            let tail = 26 * (1 - progress) + 4
            let head = CGPoint(x: center.x + cos(angle) * travel, y: center.y + sin(angle) * travel)
            let back = CGPoint(x: head.x - cos(angle) * tail, y: head.y - sin(angle) * tail)
            var streak = Path()
            streak.move(to: back)
            streak.addLine(to: head)
            glow.stroke(
                streak,
                with: .color((index.isMultiple(of: 3) ? Color.cyan : .white).opacity(0.9 * (1 - progress))),
                style: StrokeStyle(lineWidth: 2.5 * (1 - progress) + 0.5, lineCap: .round))
        }
    }

    /// Shake, swell and brighten.
    private func drawCharge(in context: inout GraphicsContext, center: CGPoint, progress: Double, time: Double) {
        let eased = progress * progress
        let scale = 1 + 0.14 * eased
        let shake = sin(time * 95) * 5 * eased
        let side = iconSize * scale
        let rect = CGRect(x: center.x - side / 2 + shake, y: center.y - side / 2, width: side, height: side)

        // Glow behind the icon.
        let glow = side * (0.9 + 0.5 * eased)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - glow / 2, y: center.y - glow / 2, width: glow, height: glow)),
            with: .radialGradient(
                Gradient(colors: [Color.cyan.opacity(0.55 * eased), .clear]),
                center: center, startRadius: 0, endRadius: glow / 2))

        var iconContext = context
        iconContext.addFilter(.brightness(0.45 * eased))
        iconContext.draw(context.resolve(Image(nsImage: icon)), in: rect)
    }

    private func drawFlash(in context: inout GraphicsContext, center: CGPoint, burst: Double) {
        let progress = burst / 0.3
        guard progress < 1 else { return }
        let radius = iconSize * (0.6 + 1.6 * progress)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.95 * (1 - progress)), Color.cyan.opacity(0.4 * (1 - progress)), .clear]),
                center: center, startRadius: 0, endRadius: radius))
    }

    private func drawShockwave(in context: inout GraphicsContext, center: CGPoint, burst: Double) {
        let progress = burst / 0.55
        guard progress < 1 else { return }
        let eased = 1 - pow(1 - progress, 3)
        let radius = iconSize * (0.4 + 2.2 * eased)
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(.white.opacity(0.8 * (1 - progress))),
            lineWidth: 6 * (1 - progress) + 1)
    }

    private func drawParticles(in context: inout GraphicsContext, center: CGPoint, burst: Double) {
        let gravity: CGFloat = 900
        for particle in particles {
            let t = burst - particle.delay
            guard t > 0 else {
                fill(particle, at: CGPoint(x: center.x + particle.origin.x, y: center.y + particle.origin.y),
                     angle: 0, alpha: 1, in: &context)
                continue
            }
            let life = t / particle.lifetime
            guard life < 1 else { continue }
            let drag = CGFloat(1 - 0.35 * life)
            let x = center.x + particle.origin.x + particle.velocity.dx * CGFloat(t) * drag
            let y = center.y + particle.origin.y + particle.velocity.dy * CGFloat(t) * drag + 0.5 * gravity * CGFloat(t * t)
            fill(particle, at: CGPoint(x: x, y: y), angle: particle.spin * t, alpha: 1 - life * life, in: &context)
        }
    }

    private func fill(_ particle: ZapParticle, at point: CGPoint, angle: Double, alpha: Double, in context: inout GraphicsContext) {
        var copy = context
        copy.translateBy(x: point.x, y: point.y)
        copy.rotate(by: .radians(angle))
        let side = particle.size
        copy.fill(
            Path(roundedRect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), cornerRadius: side * 0.25),
            with: .color(particle.color.opacity(alpha)))
    }
}

struct ZapParticle {
    let origin: CGPoint      // offset from the icon's centre
    let velocity: CGVector
    let color: Color
    let size: CGFloat
    let spin: Double
    let delay: Double        // inner pieces leave first, so the burst spreads outward
    let lifetime: Double

    /// One particle per visible pixel of a small rendering of the icon.
    static func make(from icon: NSImage, iconSize: CGFloat, grid: Int = 26) -> [ZapParticle] {
        guard let pixels = sample(icon, grid: grid) else { return [] }
        let cell = iconSize / CGFloat(grid)
        let maxDistance = iconSize / 2 * sqrt(2)
        var particles: [ZapParticle] = []

        for row in 0..<grid {
            for column in 0..<grid {
                let index = (row * grid + column) * 4
                let alpha = Double(pixels[index + 3]) / 255
                guard alpha > 0.4 else { continue }
                // Pixels are premultiplied; undo that for the colour.
                let color = Color(
                    red: Double(pixels[index]) / 255 / alpha,
                    green: Double(pixels[index + 1]) / 255 / alpha,
                    blue: Double(pixels[index + 2]) / 255 / alpha)

                let origin = CGPoint(
                    x: (CGFloat(column) + 0.5) * cell - iconSize / 2,
                    y: (CGFloat(row) + 0.5) * cell - iconSize / 2)
                let distance = hypot(origin.x, origin.y)
                let angle = atan2(origin.y, origin.x) + CGFloat.random(in: -0.35...0.35)
                // A wide speed range keeps the burst filled instead of a hollow ring.
                let speed = CGFloat.random(in: 70...640) * (0.7 + 0.5 * distance / maxDistance)

                particles.append(ZapParticle(
                    origin: origin,
                    velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - CGFloat.random(in: 120...320)),
                    color: color,
                    size: cell * CGFloat.random(in: 0.7...1.25),
                    spin: Double.random(in: -12...12),
                    delay: Double(distance / maxDistance) * 0.08,
                    lifetime: Double.random(in: 0.7...1.15)))
            }
        }
        return particles
    }

    private static func sample(_ icon: NSImage, grid: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            // Bitmap memory starts with the top row, which matches screen coordinates.
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            return true
        }
        return drawn ? pixels : nil
    }
}

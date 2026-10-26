import SwiftUI
import AppKit

// MARK: - Module tint in the environment

private struct ModuleTintKey: EnvironmentKey { static let defaultValue: Color = .indigo }

extension EnvironmentValues {
    var moduleTint: Color {
        get { self[ModuleTintKey.self] }
        set { self[ModuleTintKey.self] = newValue }
    }
}

// MARK: - Animated background (slow drifting color blobs)

struct AnimatedBackground: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    blob(tint, 0.30, w * 0.55, x: w * (0.25 + 0.10 * sin(t * 0.21)), y: h * (0.20 + 0.08 * cos(t * 0.17)))
                    blob(tint.mix(.purple), 0.22, w * 0.45, x: w * (0.80 + 0.08 * cos(t * 0.15)), y: h * (0.35 + 0.12 * sin(t * 0.19)))
                    blob(tint.mix(.cyan), 0.18, w * 0.50, x: w * (0.50 + 0.15 * sin(t * 0.11)), y: h * (0.90 + 0.06 * cos(t * 0.23)))
                }
            }
        }
        .ignoresSafeArea()
    }

    func blob(_ c: Color, _ opacity: Double, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(c.opacity(opacity)).frame(width: size, height: size).blur(radius: 90).position(x: x, y: y)
    }
}

extension Color {
    /// Rough 50/50 blend with another color.
    func mix(_ other: Color) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? .gray
        return Color(red: (a.redComponent + b.redComponent) / 2,
                     green: (a.greenComponent + b.greenComponent) / 2,
                     blue: (a.blueComponent + b.blueComponent) / 2)
    }
}

// MARK: - Scan orb

enum OrbPhase: Equatable { case idle, scanning, cleaning, done }

struct ScanOrb<Content: View>: View {
    let phase: OrbPhase
    let tint: Color
    var size: CGFloat = 240
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var hover = false
    @State private var press = false
    @State private var doneBounce = false

    var body: some View {
        TimelineView(.animation) { ctx in
            frame(t: ctx.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
        .scaleEffect(press ? 0.95 : (hover && action != nil ? 1.04 : 1))
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hover)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: press)
        .contentShape(Circle())
        .onHover { hover = $0 }
        .onTapGesture {
            guard let action else { return }
            press = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { press = false; action() }
        }
        .onChange(of: phase) { _, p in
            doneBounce = false
            if p == .done { withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { doneBounce = true } }
        }
        .onAppear { if phase == .done { withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { doneBounce = true } } }
    }

    private var active: Bool { phase == .scanning || phase == .cleaning }

    private func frame(t: Double) -> some View {
        ZStack {
            glow(t)
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
            if active {
                arcs(t)
                particles(t)
            }
            if phase == .done { doneRing }
            core(t)
            content()
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(50)
        }
        .frame(width: size, height: size)
    }

    private func glow(_ t: Double) -> some View {
        let s: Double = phase == .idle ? 1.0 + 0.06 * sin(t * 2.2) : 1.12 + 0.04 * sin(t * 6)
        return Circle()
            .fill(tint.opacity(phase == .idle ? 0.35 : 0.5))
            .blur(radius: 45)
            .scaleEffect(s)
    }

    private func arcs(_ t: Double) -> some View {
        let dir: Double = phase == .cleaning ? -1 : 1
        let comet = AngularGradient(colors: [tint.opacity(0), tint.opacity(0.6), tint, .white],
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(252))
        let thick = StrokeStyle(lineWidth: 10, lineCap: .round)
        let thin = StrokeStyle(lineWidth: 3, lineCap: .round)
        let outer = Angle.radians(dir * t * 3.4)
        let inner = Angle.radians(-dir * t * 1.9)
        return ZStack {
            Circle().trim(from: 0, to: 0.7).stroke(comet, style: thick).rotationEffect(outer)
            Circle().inset(by: 18).trim(from: 0, to: 0.32).stroke(tint.opacity(0.7), style: thin).rotationEffect(inner)
            Circle().inset(by: 18).trim(from: 0.5, to: 0.62).stroke(Color.white.opacity(0.5), style: thin).rotationEffect(inner)
        }
    }

    private func particles(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                particle(i, t: t)
            }
        }
    }

    private func particle(_ i: Int, t: Double) -> some View {
        let seed = Double(i)
        let r = Double(size / 2)
        var x: Double, y: Double, dot: Double, alpha: Double
        var color: Color = .white
        if phase == .cleaning {
            // Sucked toward the center
            let p = (t * 0.7 + seed / 12).truncatingRemainder(dividingBy: 1)
            let a = seed * .pi / 6 + p * 2
            let d = (r + 30) * (1 - p)
            x = cos(a) * d; y = sin(a) * d
            dot = 6 * (1 - p) + 2
            alpha = p < 0.85 ? 0.9 : (1 - p) * 6
        } else {
            // Orbiting
            let speed = 1.1 + seed.truncatingRemainder(dividingBy: 3) * 0.25
            let a = t * speed + seed * .pi / 6
            let d = r + 6 + 10 * sin(t * 2.5 + seed)
            x = cos(a) * d; y = sin(a) * d
            dot = i % 4 == 0 ? 6 : 4
            alpha = 0.5 + 0.5 * sin(t * 3 + seed)
            if i % 3 != 0 { color = tint.mix(.white) }
        }
        return Circle().fill(color)
            .frame(width: dot, height: dot)
            .opacity(alpha)
            .offset(x: x, y: y)
    }

    private var doneRing: some View {
        Circle().stroke(tint.gradient, lineWidth: 10)
            .scaleEffect(doneBounce ? 1 : 0.85)
            .opacity(doneBounce ? 1 : 0)
    }

    private func core(_ t: Double) -> some View {
        let fill = LinearGradient(colors: [tint.mix(.white), tint, tint.mix(.black)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        let sheen = AngularGradient(colors: [.clear, .white.opacity(0.25), .clear, .clear], center: .center)
        let spin = Angle.radians(t * (phase == .idle ? 0.4 : 1.6))
        let breathe: Double = phase == .scanning ? 1 + 0.015 * sin(t * 5) : 1
        return ZStack {
            Circle().fill(fill)
            Circle().fill(sheen).rotationEffect(spin).blendMode(.plusLighter)
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .padding(28)
        .shadow(color: tint.opacity(0.55), radius: 22, y: 8)
        .scaleEffect(breathe)
    }
}

// MARK: - Counting number

/// A byte count that rolls up/down smoothly when its value changes.
struct CountingBytes: View, Animatable {
    var value: Double
    var font: Font = .system(size: 30, weight: .bold, design: .rounded)

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Fmt.bytes(Int64(value))).font(font).monospacedDigit()
    }
}

// MARK: - Live ticker of scanned paths

struct LiveTicker: View {
    let text: String
    var body: some View {
        ZStack {
            Text(text.isEmpty ? " " : text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .id(text)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(maxWidth: 520, minHeight: 18)
        .clipped()
        .animation(.easeOut(duration: 0.18), value: text)
    }
}

// MARK: - Step checklist (scan pipeline)

struct StepRow: View {
    enum Phase { case waiting, running, done }
    let title: String
    let icon: String
    let state: Phase
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .waiting: Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 2)
                case .running: ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 22, height: 22)
            Image(systemName: icon).foregroundStyle(state == .waiting ? Color.secondary : tint)
            Text(title).foregroundStyle(state == .waiting ? .secondary : .primary)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: state)
    }
}

// MARK: - Hover lift

struct HoverLift: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.02 : 1)
            .shadow(color: .black.opacity(hover ? 0.15 : 0), radius: hover ? 12 : 0, y: hover ? 6 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .onHover { hover = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

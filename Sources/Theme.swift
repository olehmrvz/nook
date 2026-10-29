import AppKit
import SwiftUI

// MARK: Palette

/// "Сияние": a black notch with glass cards over a soft glow tinted by what is happening now.
enum Palette {
    static let pink = Color(hex: 0xFF5FA2)
    static let yellow = Color(hex: 0xFFD60A)
    static let violet = Color(hex: 0x7A5CFF)
    static let claude = Color(hex: 0xD97757)
    static let orange = Color(hex: 0xFF9F0A)
    static let green = Color(hex: 0x30D158)
    static let mint = Color(hex: 0x63E6BE)
    static let red = Color(hex: 0xFF453A)
    static let coral = Color(hex: 0xFF6B5A)
    static let blue = Color(hex: 0x3D7BFF)
    static let navy = Color(hex: 0x1B2F70)
    static let cyan = Color(hex: 0x5AC8FA)
    static let salmon = Color(hex: 0xFFB3A8)
    static let spotify = Color(hex: 0x1ED760)
    static let music = Color(hex: 0xFA2D48)
    /// Used when the artwork is grey or still loading.
    static let musicGlow = [pink, violet]
}

let accent = Palette.orange
let muted = Color.white.opacity(0.6)
let faint = Color.white.opacity(0.4)

extension Color {
    /// Deeper, calmer version of a colour for large background washes.
    func muted(saturation: CGFloat = 0.55, brightness: CGFloat = 0.62) -> Color {
        let hsb = components
        return Color(hue: hsb.h, saturation: hsb.s * saturation, brightness: hsb.b * brightness)
    }

    /// A lighter, slightly softer version for symbols on dark glass.
    func lifted() -> Color {
        let hsb = components
        return Color(hue: hsb.h, saturation: hsb.s * 0.7, brightness: min(1, hsb.b * 1.1 + 0.08))
    }

    private var components: (h: CGFloat, s: CGFloat, b: CGFloat) {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return (h, s, b)
    }

    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// SF Pro Rounded, for numbers and times.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Small uppercase label above a group, e.g. "СЕЙЧАС ИГРАЕТ".
struct Caps: View {
    let text: String
    var color: Color = .white.opacity(0.55)
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(color)
    }
}

enum Format {
    /// "45 с", "12 мин", "1 ч 5 мин".
    static func span(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 5 { return "сейчас" }
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \(s / 60 % 60) мин"
    }

    /// Time until something: "45 мин", "1 ч 50 мин", "4 дн 6 ч".
    static func until(_ seconds: TimeInterval) -> String {
        let m = Int(max(0, seconds) / 60)
        if m < 60 { return "\(max(1, m)) мин" }
        if m < 24 * 60 { return m % 60 == 0 ? "\(m / 60) ч" : "\(m / 60) ч \(m % 60) мин" }
        let h = m / 60
        return h % 24 == 0 ? "\(h / 24) дн" : "\(h / 24) дн \(h % 24) ч"
    }

    /// A moment in words: "сегодня в 02:40", "завтра в 09:00", "пн в 14:00", "21 нояб.".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "сегодня в \(time)" }
        if cal.isDateInTomorrow(date) { return "завтра в \(time)" }
        if date.timeIntervalSinceNow < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) + " в \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "840 токенов", "35 тыс. токенов", "1,2 млн токенов".
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return (Double(n) / 1_000_000).formatted(.number.precision(.fractionLength(n >= 10_000_000 ? 0 : 1))) + " млн токенов" }
        if n >= 1_000 { return "\(n / 1_000) тыс. токенов" }
        return count(n, "токен", "токена", "токенов")
    }

    /// "≈ $3.40", "≈ $0.05", "< $0.01".
    static func dollars(_ value: Double) -> String {
        if value < 0.01 { return "< $0.01" }
        return "≈ $" + value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 2)).locale(Locale(identifier: "en_US")))
    }

    /// Russian plural: count(3, "файл", "файла", "файлов") → "3 файла".
    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100, ones = n % 10
        let word = (11...14).contains(tens) ? many : (ones == 1 ? one : ((2...4).contains(ones) ? few : many))
        return "\(n) \(word)"
    }
}

// MARK: Motion pause

private struct MotionPausedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the screens sleep or are locked: looping animations stop drawing.
    var motionPaused: Bool {
        get { self[MotionPausedKey.self] }
        set { self[MotionPausedKey.self] = newValue }
    }
}

// MARK: Glass

/// Frosted card: 5.5 % white, an optional colour wash and a hairline border.
struct Glass: ViewModifier {
    var tint: [Color] = []
    var stroke: Color = .white.opacity(0.1)
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            ZStack {
                shape.fill(Color.white.opacity(0.055))
                if !tint.isEmpty {
                    shape.fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                shape.strokeBorder(stroke, lineWidth: 1)
            }
        }
    }
}

extension View {
    func glass(tint: [Color] = [], stroke: Color = .white.opacity(0.1), radius: CGFloat = 20) -> some View {
        modifier(Glass(tint: tint, stroke: stroke, radius: radius))
    }
}

/// Glass card that fills the space it is given.
struct Card<Content: View>: View {
    var tint: [Color] = []
    var stroke: Color = .white.opacity(0.1)
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(tint: tint, stroke: stroke)
    }
}

/// Round badge with a gradient and a white symbol (islands, empty states).
struct Badge: View {
    let symbol: String
    var colors: [Color]
    var size: CGFloat = 40
    /// Tinted glass with a coloured symbol instead of a bright gradient (islands).
    var soft = false
    @State private var bounce = false
    var body: some View {
        let tint = colors.first ?? .white
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: soft ? .semibold : .bold))
            .foregroundStyle(soft ? tint.lifted() : .white)
            .symbolEffect(.bounce, value: bounce)
            .frame(width: size, height: size)
            .background {
                if soft {
                    Circle().fill(tint.opacity(0.16))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.08)],
                                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1))
                } else {
                    Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: tint.opacity(0.5), radius: 10, y: 3)
                }
            }
            .onAppear { if !Motion.reduce { bounce = true } }
    }
}

struct Chip: View {
    let text: String
    var color: Color = .white
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.2)))
    }
}

// MARK: Buttons

struct PillStyle: ButtonStyle {
    enum Kind { case primary, glass, tint(Color), gradient([Color]) }
    var kind: Kind = .glass
    var foreground: Color?
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: self)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PillStyle
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: style.small ? 11 : 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, style.small ? 10 : 14)
            .padding(.vertical, style.small ? 5 : 7)
            .foregroundStyle(style.foreground ?? defaultForeground)
            .background(background)
            .brightness(hover ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }

    @ViewBuilder private var background: some View {
        switch style.kind {
        case .primary: Capsule().fill(Color.white)
        case .glass: Capsule().fill(Color.white.opacity(hover ? 0.2 : 0.14))
        case .tint(let color): Capsule().fill(color)
        case .gradient(let colors):
            Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        }
    }

    private var defaultForeground: Color {
        if case .primary = style.kind { return .black }
        return .white
    }
}

/// Plain icon button that lifts a little on hover.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconBody(configuration: configuration) }
}

private struct IconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(hover ? 1 : 0.88)
            .scaleEffect(configuration.isPressed ? 0.9 : (hover ? 1.06 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == PillStyle {
    static func pill(_ kind: PillStyle.Kind = .glass, foreground: Color? = nil, small: Bool = false) -> PillStyle {
        PillStyle(kind: kind, foreground: foreground, small: small)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// Card-sized button: lifts a little on hover, settles on press.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverLift())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

struct HoverLift: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .brightness(hover ? 0.03 : 0)
            .scaleEffect(hover && !Motion.reduce ? 1.012 : 1)
            .animation(Motion.quick, value: hover)
            .onHover { hover = $0 }
    }
}

/// Cards rise into place one after another when a tab opens.
struct Entrance: ViewModifier {
    var order: Int
    @State private var shown = Motion.reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .scaleEffect(shown ? 1 : 0.98, anchor: .top)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.smooth.delay(0.045 * Double(order))) { shown = true }
            }
    }
}

extension View {
    func entrance(_ order: Int) -> some View { modifier(Entrance(order: order)) }
    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// Vertical list that always opens at its first row.
struct ListScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(showsIndicators: false) { content.padding(.top, 4) }
            .defaultScrollAnchor(.top)
    }
}

// MARK: Meters

/// Gradient progress bar with an optional knob.
struct GlowBar: View {
    var fraction: Double
    var colors: [Color]
    var height: CGFloat = 6
    var knob = false
    var animation: Animation? = Motion.smooth

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: height)
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, width), height: height)
                if knob {
                    Circle().fill(Color.white).frame(width: 12, height: 12)
                        .shadow(color: (colors.first ?? .white).opacity(0.8), radius: 5)
                        .offset(x: min(max(0, width - 6), geo.size.width - 12))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: knob ? 12 : height)
        .animation(animation, value: fraction)
    }
}

/// Fills up from zero when it appears, then follows the value smoothly.
struct RingGauge: View {
    var fraction: Double
    var colors: [Color]
    var lineWidth: CGFloat = 9
    @State private var shown: Double = Motion.reduce ? 1 : 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(Motion.reduce ? fraction : shown, 1)))
                .stroke(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(Motion.smooth.delay(0.12)) { shown = fraction } }
        .onChange(of: fraction) { _, new in withAnimation(Motion.smooth) { shown = new } }
    }
}

// MARK: Ambient glow

/// One soft colour spot; position is relative to the panel (0…1), size is the width in points.
struct Glow: Hashable {
    var color: Color
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var opacity: Double
}

/// The light behind the glass. Elliptical gradients instead of blurred layers keep it cheap to draw.
struct AmbientGlow: View {
    var glows: [Glow]
    /// Height of the band under the camera that stays pure black, like the hardware notch.
    var blackTop: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            ZStack {
                ForEach(glows, id: \.self) { glow in
                    Ellipse()
                        .fill(EllipticalGradient(colors: [glow.color.opacity(glow.opacity),
                                                          glow.color.opacity(glow.opacity * 0.55), .clear],
                                                 center: .center))
                        .frame(width: glow.size, height: glow.size * 0.72)
                        .position(x: glow.x * geo.size.width, y: glow.y * geo.size.height)
                        .transition(.opacity)
                }
            }
            .scaleEffect(breathe ? 1.05 : 0.97)
            // Colour rises from below and never reaches the notch line.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .clear, location: min(1, blackTop / h)),
                                         .init(color: .black, location: min(1, (blackTop + 34) / h)),
                                         .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .animation(.easeInOut(duration: 0.8).speed(Motion.speed), value: glows)
        .allowsHitTesting(false)
        .onAppear {
            guard !Motion.reduce else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Island background: black glass with one clean halo behind the icon.
/// Full-saturation colour at low opacity: a muted colour over black turns into a brown smudge.
struct IslandBackdrop: View {
    var colors: [Color]
    /// Height of the band under the camera that stays pure black.
    var blackTop: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            // The icon's centre: island padding (ear + 14) plus half the 40 pt icon, middle of the content row.
            let icon = UnitPoint(x: (NotchModel.ear + 34) / max(geo.size.width, 1), y: (blackTop + 4 + (h - blackTop - 16) / 2) / h)
            ZStack {
                // Neutral glass depth, not a coloured wash: tinted black reads as brown or mud.
                LinearGradient(colors: [.clear, Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                RadialGradient(stops: [.init(color: colors[0].opacity(0.32), location: 0),
                                       .init(color: colors[0].opacity(0.1), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               center: icon, startRadius: 0, endRadius: 110)
                    .opacity(breathe ? 1 : 0.75)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .clear, location: min(1, blackTop / h)),
                                         .init(color: .black, location: min(1, (blackTop + 30) / h)),
                                         .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .animation(.easeInOut(duration: 0.8).speed(Motion.speed), value: colors)
        .allowsHitTesting(false)
        .onAppear {
            guard !Motion.reduce else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: Artwork colours

extension NSImage {
    /// Two vivid colours of the image for the ambient glow, brightened to read on black.
    /// Returns nil for grey images, so the caller falls back to the default glow.
    func glowColors() -> [Color]? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Twelve hue buckets, weighted towards saturated and bright pixels.
        var weight = [Double](repeating: 0, count: 12)
        var rgb = [(Double, Double, Double)](repeating: (0, 0, 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let hi = max(r, g, b), lo = min(r, g, b)
            guard hi > 0.12, hi > lo else { continue }
            let delta = hi - lo
            var hue = hi == r ? (g - b) / delta : (hi == g ? 2 + (b - r) / delta : 4 + (r - g) / delta)
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let saturation = delta / hi
            let w = saturation * saturation * hi
            let k = min(11, Int(hue * 12))
            weight[k] += w
            rgb[k].0 += w * r; rgb[k].1 += w * g; rgb[k].2 += w * b
        }
        let ranked = weight.indices.sorted { weight[$0] > weight[$1] }
        guard let first = ranked.first, weight[first] > 2 else { return nil }

        func hsb(_ k: Int) -> (CGFloat, CGFloat, CGFloat) {
            let c = NSColor(srgbRed: rgb[k].0 / weight[k], green: rgb[k].1 / weight[k], blue: rgb[k].2 / weight[k], alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            return (h, max(s, 0.55), max(v, 0.85))
        }
        let a = hsb(first)
        let main = Color(hue: a.0, saturation: a.1, brightness: a.2)
        let distance = { (k: Int) in min(abs(k - first), 12 - abs(k - first)) }
        if let second = ranked.dropFirst().first(where: { distance($0) >= 2 && weight[$0] > weight[first] * 0.15 }) {
            let b = hsb(second)
            return [main, Color(hue: b.0, saturation: b.1, brightness: b.2)]
        }
        // A single dominant hue: pair it with a neighbour so the glow keeps some depth.
        let shifted = (a.0 + 0.08).truncatingRemainder(dividingBy: 1)
        return [main, Color(hue: shifted, saturation: a.1, brightness: a.2 * 0.9)]
    }
}

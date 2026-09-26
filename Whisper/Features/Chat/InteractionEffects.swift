import SwiftUI

/// 互动的全屏特效：清淡一点、东西少一点，铺满整个屏幕，三秒多就散掉。
/// 现在只发五种（想你了、抱抱、亲亲、拍一拍、送花）；以前的旧互动点开时用相近的效果。
struct InteractionEffectLayer: View {
    @Environment(AppModel.self) private var app
    @State private var current: InteractionEffectRequest?

    var body: some View {
        ZStack {
            if let current {
                InteractionEffect(interaction: current.interaction)
                    .id(current.id)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: app.interactionEffect) { _, request in
            guard let request else { return }
            current = request
            playHaptics(request.interaction)
            let id = request.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                if current?.id == id { withAnimation(.easeOut(duration: 0.3)) { current = nil } }
            }
        }
    }

    private func playHaptics(_ interaction: String) {
        switch interaction {
        case "pat", "poke":
            for delay in [0.3, 0.7] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Haptics.soft() }
            }
        case "hug":
            Haptics.soft()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Haptics.soft() }
        default:
            Haptics.soft()
        }
    }
}

private struct InteractionEffect: View {
    let interaction: String

    var body: some View {
        switch interaction {
        case "hug": HugEffect()
        case "kiss": KissEffect()
        case "pat", "poke": PatEffect()
        case "flower": PetalEffect()
        case "note": PopEffect(emoji: "🪧")
        case "poop": PopEffect(emoji: "💩")
        case "fireworks": SparkleEffect()
        default: MissEffect()
        }
    }
}

// MARK: - 零件

private struct DriftValues {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 0.5
    var opacity: Double = 0
    var rotation: Double = 0
}

/// 一个会飘的小东西：淡入、弹一下变到正常大小、沿着路线带点左右摆动地移动、最后淡出
private struct Drifting<Content: View>: View {
    let start: UnitPoint
    let travel: CGSize
    let delay: Double
    let duration: Double
    var spin: Double = 0
    var sway: CGFloat = 0
    @ViewBuilder let content: Content
    @State private var run = false

    var body: some View {
        GeometryReader { geometry in
            content
                .keyframeAnimator(initialValue: DriftValues(), trigger: run) { view, value in
                    view
                        .scaleEffect(value.scale)
                        .rotationEffect(.degrees(value.rotation))
                        .opacity(value.opacity)
                        .offset(x: value.x, y: value.y)
                } keyframes: { _ in
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0, duration: delay)
                        LinearKeyframe(1, duration: 0.35)
                        LinearKeyframe(1, duration: max(0.1, duration - 1.1))
                        LinearKeyframe(0, duration: 0.75)
                    }
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.5, duration: delay)
                        SpringKeyframe(1, duration: 0.6, spring: .bouncy)
                    }
                    KeyframeTrack(\.y) {
                        LinearKeyframe(0, duration: delay)
                        CubicKeyframe(travel.height, duration: duration)
                    }
                    KeyframeTrack(\.x) {
                        LinearKeyframe(0, duration: delay)
                        CubicKeyframe(travel.width * 0.4 + sway, duration: duration * 0.35)
                        CubicKeyframe(travel.width * 0.7 - sway, duration: duration * 0.35)
                        CubicKeyframe(travel.width, duration: duration * 0.3)
                    }
                    KeyframeTrack(\.rotation) {
                        LinearKeyframe(0, duration: delay)
                        LinearKeyframe(spin, duration: duration)
                    }
                }
                .position(x: geometry.size.width * start.x, y: geometry.size.height * start.y)
        }
        .onAppear { run = true }
    }
}

/// 整个屏幕铺一层很淡的颜色，慢慢出现又散掉
private struct Wash: View {
    let color: Color
    @State private var run = false

    var body: some View {
        RadialGradient(colors: [color.opacity(0.26), color.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 560)
            .keyframeAnimator(initialValue: 0.0, trigger: run) { view, value in
                view.opacity(value)
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.6)
                LinearKeyframe(1, duration: 1.8)
                LinearKeyframe(0, duration: 0.9)
            }
            .onAppear { run = true }
    }
}

/// 随机生成的一个小东西的路线
private struct Piece: Identifiable {
    let id = UUID()
    let start: UnitPoint
    let travel: CGSize
    let delay: Double
    let duration: Double
    let spin: Double
    let sway: CGFloat
    let size: CGFloat
    let tint: Color
}

private enum Pieces {
    static let pinks = [Color(hex: 0xFF8FAB), Color(hex: 0xFFB3C6), Color(hex: 0xFF6F91), Color(hex: 0xFFC2D1)]

    /// 从下半屏往上飘
    static func rising(_ count: Int, tints: [Color] = pinks) -> [Piece] {
        (0 ..< count).map { index in
            Piece(
                start: UnitPoint(x: .random(in: 0.08 ... 0.92), y: .random(in: 0.7 ... 1.0)),
                travel: CGSize(width: CGFloat.random(in: -30 ... 30), height: -CGFloat.random(in: 380 ... 620)),
                delay: Double(index) * 0.13 + Double.random(in: 0 ... 0.2),
                duration: Double.random(in: 2.2 ... 2.8),
                spin: Double.random(in: -20 ... 20),
                sway: .random(in: 8 ... 18),
                size: .random(in: 16 ... 30),
                tint: tints[index % tints.count].opacity(.random(in: 0.7 ... 0.95))
            )
        }
    }

    /// 从某一点往四周散开
    static func burst(_ count: Int, from start: UnitPoint, tints: [Color] = pinks) -> [Piece] {
        (0 ..< count).map { index in
            let angle = Double(index) / Double(count) * 2 * Double.pi + Double.random(in: -0.2 ... 0.2)
            let radius = CGFloat.random(in: 90 ... 150)
            return Piece(
                start: start,
                travel: CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius - 20),
                delay: 0.35 + Double.random(in: 0 ... 0.1),
                duration: 1.6,
                spin: Double.random(in: -30 ... 30),
                sway: 0,
                size: .random(in: 13 ... 20),
                tint: tints[index % tints.count]
            )
        }
    }

    /// 从屏幕上方飘下来的花瓣
    static func falling(_ count: Int) -> [Piece] {
        let tints = [Color(hex: 0xFFC1D5), Color(hex: 0xFFD6E4), Color(hex: 0xFFB0C8), Color(hex: 0xFFE9F0)]
        return (0 ..< count).map { index in
            Piece(
                start: UnitPoint(x: .random(in: 0.05 ... 0.95), y: -0.05),
                travel: CGSize(width: CGFloat.random(in: -70 ... 70), height: CGFloat.random(in: 820 ... 1000)),
                delay: Double(index) * 0.1 + Double.random(in: 0 ... 0.25),
                duration: Double.random(in: 2.8 ... 3.2),
                spin: Double.random(in: 90 ... 260) * (Bool.random() ? 1 : -1),
                sway: .random(in: 18 ... 36),
                size: .random(in: 14 ... 22),
                tint: tints[index % tints.count]
            )
        }
    }
}

// MARK: - 五种互动

/// 想你了：粉色的光晕，几颗小爱心慢慢往上飘
private struct MissEffect: View {
    @State private var hearts = Pieces.rising(9)

    var body: some View {
        ZStack {
            Wash(color: Color(hex: 0xFF8FAB))
            ForEach(hearts) { heart in
                Drifting(start: heart.start, travel: heart.travel, delay: heart.delay, duration: heart.duration, spin: heart.spin, sway: heart.sway) {
                    Image(systemName: "heart.fill").font(.system(size: heart.size)).foregroundStyle(heart.tint)
                }
            }
        }
    }
}

/// 抱抱：两团暖光从两边靠到中间，一个拥抱的表情轻轻出现
private struct HugEffect: View {
    @State private var hearts = Pieces.burst(5, from: UnitPoint(x: 0.5, y: 0.44), tints: [Color(hex: 0xFFB38A), Color(hex: 0xFF9FB2)])

    var body: some View {
        ZStack {
            Wash(color: Color(hex: 0xFFB38A))
            SideGlow(side: -1)
            SideGlow(side: 1)
            Drifting(start: UnitPoint(x: 0.5, y: 0.44), travel: CGSize(width: 0, height: -36), delay: 0.45, duration: 2.6) {
                Text("🤗").font(.system(size: 92))
            }
            ForEach(hearts) { heart in
                Drifting(start: heart.start, travel: heart.travel, delay: heart.delay + 0.5, duration: heart.duration, spin: heart.spin) {
                    Image(systemName: "heart.fill").font(.system(size: heart.size)).foregroundStyle(heart.tint.opacity(0.85))
                }
            }
        }
    }
}

/// 一团暖光从屏幕一侧靠到中间
private struct SideGlow: View {
    let side: CGFloat
    @State private var run = false

    private struct Values {
        var progress: CGFloat = 0
        var opacity: Double = 0
    }

    var body: some View {
        GeometryReader { geometry in
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFC39E).opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 170))
                .frame(width: 340, height: 340)
                .keyframeAnimator(initialValue: Values(), trigger: run) { view, value in
                    view
                        .offset(x: side * geometry.size.width * 0.5 * (1 - value.progress))
                        .opacity(value.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.progress) { CubicKeyframe(0.82, duration: 1.0) }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(1, duration: 0.5)
                        LinearKeyframe(1, duration: 1.8)
                        LinearKeyframe(0, duration: 0.8)
                    }
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.44)
        }
        .onAppear { run = true }
    }
}

/// 亲亲：唇印弹出来往上飘，身边散开几颗小心心
private struct KissEffect: View {
    @State private var hearts = Pieces.burst(7, from: UnitPoint(x: 0.5, y: 0.44))

    var body: some View {
        ZStack {
            Wash(color: Color(hex: 0xFF8FAB))
            ForEach(hearts) { heart in
                Drifting(start: heart.start, travel: heart.travel, delay: heart.delay, duration: heart.duration, spin: heart.spin) {
                    Image(systemName: "heart.fill").font(.system(size: heart.size)).foregroundStyle(heart.tint)
                }
            }
            Drifting(start: UnitPoint(x: 0.5, y: 0.44), travel: CGSize(width: 0, height: -80), delay: 0.1, duration: 2.8, spin: -8) {
                Text("💋").font(.system(size: 86))
            }
        }
    }
}

/// 拍一拍：一只手从上面落下来轻轻拍两下，每拍一下漾开一圈
private struct PatEffect: View {
    @State private var run = false

    private struct Values {
        var y: CGFloat = -60
        var rotation: Double = 20
        var scale: CGFloat = 0.6
        var opacity: Double = 0
    }

    var body: some View {
        GeometryReader { geometry in
            let point = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.38)
            ZStack {
                Ripple(delay: 0.3).position(x: point.x, y: point.y + 36)
                Ripple(delay: 0.7).position(x: point.x, y: point.y + 36)
                Text("🖐️")
                    .font(.system(size: 84))
                    .keyframeAnimator(initialValue: Values(), trigger: run) { view, value in
                        view
                            .scaleEffect(value.scale)
                            .rotationEffect(.degrees(value.rotation), anchor: .bottom)
                            .opacity(value.opacity)
                            .offset(y: value.y)
                    } keyframes: { _ in
                        KeyframeTrack(\.y) {
                            SpringKeyframe(0, duration: 0.3, spring: .snappy)
                            CubicKeyframe(10, duration: 0.12)
                            CubicKeyframe(0, duration: 0.28)
                            CubicKeyframe(10, duration: 0.12)
                            CubicKeyframe(0, duration: 0.28)
                        }
                        KeyframeTrack(\.rotation) {
                            CubicKeyframe(-16, duration: 0.3)
                            CubicKeyframe(6, duration: 0.12)
                            CubicKeyframe(-16, duration: 0.28)
                            CubicKeyframe(6, duration: 0.12)
                            CubicKeyframe(0, duration: 0.3)
                        }
                        KeyframeTrack(\.scale) {
                            SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                            CubicKeyframe(0.93, duration: 0.12)
                            CubicKeyframe(1, duration: 0.28)
                            CubicKeyframe(0.93, duration: 0.12)
                            CubicKeyframe(1, duration: 0.28)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.2)
                            LinearKeyframe(1, duration: 1.9)
                            LinearKeyframe(0, duration: 0.6)
                        }
                    }
                    .position(point)
            }
        }
        .background(Wash(color: Color(hex: 0xF4B183)))
        .onAppear { run = true }
    }
}

/// 拍下去时漾开的一圈
private struct Ripple: View {
    let delay: Double
    @State private var run = false

    private struct Values {
        var scale: CGFloat = 0.3
        var opacity: Double = 0
    }

    var body: some View {
        Circle()
            .strokeBorder(Color(hex: 0xF4B183).opacity(0.7), lineWidth: 3)
            .frame(width: 120, height: 120)
            .keyframeAnimator(initialValue: Values(), trigger: run) { view, value in
                view.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.3, duration: delay)
                    CubicKeyframe(1.9, duration: 0.9)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: delay)
                    LinearKeyframe(0.9, duration: 0.05)
                    LinearKeyframe(0, duration: 0.85)
                }
            }
            .onAppear { run = true }
    }
}

/// 送花：几片花瓣从上面慢慢飘落，中间开一朵花
private struct PetalEffect: View {
    @State private var petals = Pieces.falling(11)

    var body: some View {
        ZStack {
            Wash(color: Color(hex: 0xFFB0C8))
            ForEach(petals) { petal in
                Drifting(start: petal.start, travel: petal.travel, delay: petal.delay, duration: petal.duration, spin: petal.spin, sway: petal.sway) {
                    PetalShape()
                        .fill(LinearGradient(colors: [petal.tint, .white.opacity(0.85)], startPoint: .bottom, endPoint: .top))
                        .frame(width: petal.size, height: petal.size * 1.35)
                        .shadow(color: Color(hex: 0xFF8FAB).opacity(0.2), radius: 2, y: 1)
                }
            }
            Drifting(start: UnitPoint(x: 0.5, y: 0.42), travel: CGSize(width: 0, height: -30), delay: 0.2, duration: 2.8, spin: 18) {
                Text("🌸").font(.system(size: 76))
            }
        }
    }
}

/// 一片樱花瓣，顶上有个小缺口
private struct PetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: width * 0.5, y: height))
        path.addCurve(to: CGPoint(x: width * 0.36, y: 0), control1: CGPoint(x: -width * 0.15, y: height * 0.7), control2: CGPoint(x: width * 0.02, y: height * 0.08))
        path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.16))
        path.addLine(to: CGPoint(x: width * 0.64, y: 0))
        path.addCurve(to: CGPoint(x: width * 0.5, y: height), control1: CGPoint(x: width * 0.98, y: height * 0.08), control2: CGPoint(x: width * 1.15, y: height * 0.7))
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

// MARK: - 旧互动

/// 一个表情在中间弹出来再飘走
private struct PopEffect: View {
    let emoji: String

    var body: some View {
        Drifting(start: UnitPoint(x: 0.5, y: 0.42), travel: CGSize(width: 0, height: -50), delay: 0.05, duration: 2.4) {
            Text(emoji).font(.system(size: 92))
        }
    }
}

/// 几颗星光在屏幕上闪一下（旧的“放烟花”、抽到传说卡）
private struct SparkleEffect: View {
    @State private var sparkles = Pieces.rising(10, tints: [Color(hex: 0xFFD27A), Color(hex: 0xFFB3C6), Color(hex: 0xFFE6A8)]).map { piece in
        Piece(
            start: UnitPoint(x: piece.start.x, y: CGFloat.random(in: 0.15 ... 0.6)),
            travel: CGSize(width: 0, height: -CGFloat.random(in: 30 ... 70)),
            delay: piece.delay,
            duration: 1.8,
            spin: Double.random(in: -40 ... 40),
            sway: 0,
            size: piece.size,
            tint: piece.tint
        )
    }

    var body: some View {
        ZStack {
            Wash(color: Color(hex: 0xFFD27A))
            ForEach(sparkles) { sparkle in
                Drifting(start: sparkle.start, travel: sparkle.travel, delay: sparkle.delay, duration: sparkle.duration, spin: sparkle.spin) {
                    Image(systemName: "sparkle").font(.system(size: sparkle.size)).foregroundStyle(sparkle.tint)
                }
            }
        }
    }
}

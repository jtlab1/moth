import MeasurementCore
import SwiftUI

// Continuous animations here are slow, dim (under ~⅓ opacity), never flash, and freeze when motion is off.

// MARK: - Screen background

private struct MothScreenBackground: ViewModifier {
    @Environment(\.mothPalette) private var palette

    func body(content: Content) -> some View {
        content.background {
            palette.background.ignoresSafeArea()
        }
    }
}

extension View {
    public func mothScreenBackground() -> some View {
        modifier(MothScreenBackground())
    }
}

// MARK: - Titles

private struct MothCenteredTitle: ViewModifier {
    let title: String
    @Environment(\.mothPalette) private var palette

    func body(content: Content) -> some View {
        content
            // Still set so the back button and VoiceOver read it.
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.moth(.title3, weight: .heavy))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

extension View {
    /// Use instead of `.navigationTitle(_:)`, whose large titles are always leading-aligned.
    public func mothCenteredTitle(_ title: String) -> some View {
        modifier(MothCenteredTitle(title: title))
    }
}

// MARK: - Fields

private struct MothFieldStyle: ViewModifier {
    @Environment(\.mothPalette) private var palette
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous)
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(14)
            .background(palette.accentSoft, in: shape)
            .overlay(shape.strokeBorder(isFocused ? palette.accent : palette.cardBorder, lineWidth: isFocused ? 1.5 : 1))
            .foregroundStyle(palette.primaryText)
            .animation(MothTheme.Motion.snappy, value: isFocused)
    }
}

extension View {
    public func mothField() -> some View {
        modifier(MothFieldStyle())
    }
}

// MARK: - Headers and status

public struct MothIconBadge: View {
    let systemImage: String
    var color: Color?
    var size: CGFloat = 36

    @Environment(\.mothPalette) private var palette

    public init(systemImage: String, color: Color? = nil, size: CGFloat = 36) {
        self.systemImage = systemImage
        self.color = color
        self.size = size
    }

    public var body: some View {
        let tint = color ?? palette.accent
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(palette.accentSoft, in: Circle())
    }
}

public struct MothSectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: String?

    @Environment(\.mothPalette) private var palette

    public init(_ title: String, subtitle: String? = nil, trailing: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.moth(.title3, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct MothStatusSymbol: View {
    let severity: FlickerSeverity
    var size: Font = .title3
    @Environment(\.mothPalette) private var palette

    var body: some View {
        Image(systemName: severity.calmSymbolName)
            .font(size.weight(.medium))
            .foregroundStyle(palette.color(for: severity))
            .accessibilityHidden(true)
    }
}

struct SeverityDot: View {
    let severity: FlickerSeverity
    @Environment(\.mothPalette) private var palette

    var body: some View {
        Circle()
            .fill(palette.color(for: severity))
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

// MARK: - Progress

struct MothProgressBar: View {
    let value: Double
    @Environment(\.mothPalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.divider)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(8, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(MothTheme.Motion.smooth, value: value)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text("\(Int((value * 100).rounded())) percent"))
    }
}

// MARK: - Orb

public struct MothOrb: View {
    var size: CGFloat = 120
    var systemImage: String = "waveform"
    var isAnimating: Bool = true

    @Environment(\.mothPalette) private var palette
    @Environment(\.mothMotionEnabled) private var motionEnabled
    private let ringPeriod: Double = 4.8
    private let ringCount = 3

    public init(size: CGFloat = 120, systemImage: String = "waveform", isAnimating: Bool = true) {
        self.size = size
        self.systemImage = systemImage
        self.isAnimating = isAnimating
    }

    private var moves: Bool { isAnimating && motionEnabled }

    public var body: some View {
        let core = size * 0.5
        ZStack {
            if moves {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<ringCount, id: \.self) { ring in
                            // Linear on purpose; ease-out bunched the rings into two quick pulses and a pause.
                            let progress = (t / ringPeriod + Double(ring) / Double(ringCount))
                                .truncatingRemainder(dividingBy: 1)
                            Circle()
                                .strokeBorder(palette.accent, lineWidth: 1.5)
                                .frame(width: core, height: core)
                                .scaleEffect(1 + progress)
                                .opacity(0.32 * (1 - progress))
                        }
                    }
                }
            } else {
                Circle()
                    .strokeBorder(palette.accent.opacity(0.12), lineWidth: 1.5)
                    .frame(width: size, height: size)
                Circle()
                    .strokeBorder(palette.accent.opacity(0.22), lineWidth: 1.5)
                    .frame(width: size * 0.75, height: size * 0.75)
            }
            Circle()
                .fill(palette.accentSoft)
                .frame(width: core, height: core)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.17, weight: .medium))
                .foregroundStyle(palette.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Waveform

struct SineWaveShape: Shape {
    var phase: Double
    var cycles: Double = 2.5
    var amplitude: Double = 0.38

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = max(Int(rect.width / 2), 2)
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let y = 0.5 + amplitude * sin((x * cycles + phase) * 2 * .pi)
            let point = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct MothWaveform: View {
    var cycles: Double = 2.5
    var speed: Double = 0.6
    var lineWidth: CGFloat = 3

    @Environment(\.mothPalette) private var palette
    @Environment(\.mothMotionEnabled) private var motionEnabled

    var body: some View {
        TimelineView(.animation(paused: !motionEnabled)) { context in
            // Capped low so it reads as drifting, not flickering.
            let phase = motionEnabled ? context.date.timeIntervalSinceReferenceDate * min(speed, 0.4) : 0
            ZStack {
                SineWaveShape(phase: phase + 0.25, cycles: cycles, amplitude: 0.22)
                    .stroke(palette.accent.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                SineWaveShape(phase: phase, cycles: cycles)
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Viewfinder

/// Overlay only, so it never touches the single preview layer.
struct ViewfinderOverlay: View {
    let isScanning: Bool

    @Environment(\.mothPalette) private var palette
    @Environment(\.mothMotionEnabled) private var motionEnabled

    var body: some View {
        TimelineView(.animation(paused: !(isScanning && motionEnabled))) { context in
            let breathing = isScanning && motionEnabled
            let t = context.date.timeIntervalSinceReferenceDate
            let opacity = breathing ? 0.525 + 0.175 * sin(t * 2 * .pi / 3.6) : 0.55
            GeometryReader { proxy in
                Path { path in
                    let rect = proxy.frame(in: .local).insetBy(dx: 18, dy: 18)
                    let arm: CGFloat = 26
                    for (corner, dx, dy) in [
                        (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                        (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                        (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                        (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)
                    ] {
                        path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                        path.addLine(to: corner)
                        path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                    }
                }
                .stroke(Color(white: 0.9).opacity(opacity), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Entrance

private struct MothAppear: ViewModifier {
    let delay: Double
    @State private var isVisible = false
    @Environment(\.mothMotionEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || !motionEnabled ? 1 : 0)
            .offset(y: isVisible || !motionEnabled ? 0 : 8)
            .onAppear {
                guard motionEnabled else {
                    isVisible = true
                    return
                }
                withAnimation(MothTheme.Motion.gentle.delay(delay)) { isVisible = true }
            }
    }
}

extension View {
    public func mothAppear(delay: Double = 0) -> some View {
        modifier(MothAppear(delay: delay))
    }
}

extension AnyTransition {
    static var mothSwap: AnyTransition {
        .opacity
    }
}

// MARK: - Segmented control

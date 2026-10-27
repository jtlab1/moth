import MeasurementCore
import SwiftUI

/// Built for photophobic users: no pure white, no neon, no gradients, glows, or shadows.
/// Hierarchy comes from size, weight, and order, not brightness.
public enum MothTheme {
    public struct Palette: Sendable {
        public let background: Color
        public let cardBackground: Color
        /// Carries card separation in dark mode, where shadows on near-black don't read.
        public let cardBorder: Color
        public let primaryText: Color
        public let secondaryText: Color
        public let accent: Color
        /// Not white: white on the dark accent measures under 2:1.
        public let onAccent: Color
        public let accentSoft: Color
        public let divider: Color
        public let success: Color
        public let warning: Color
        public let danger: Color
        /// Dark in the dark palette, where white on the soft clay fails contrast.
        public let onDanger: Color
        public let isDark: Bool
    }

    // WCAG ≈ primary 13:1, secondary 6.5:1, onAccent 6:1, status ≥ 5:1. The off-white ground cuts the most glare.
    public static let light = Palette(
        background: Color(red: 0.945, green: 0.941, blue: 0.918),
        cardBackground: Color(red: 0.973, green: 0.969, blue: 0.949),
        cardBorder: Color.black.opacity(0.07),
        primaryText: Color(red: 0.122, green: 0.141, blue: 0.125),
        secondaryText: Color(red: 0.337, green: 0.369, blue: 0.341),
        accent: Color(red: 0.247, green: 0.420, blue: 0.282),
        onAccent: .white,
        accentSoft: Color(red: 0.882, green: 0.918, blue: 0.875),
        divider: Color.black.opacity(0.08),
        success: Color(red: 0.184, green: 0.420, blue: 0.369),
        warning: Color(red: 0.522, green: 0.376, blue: 0.102),
        danger: Color(red: 0.643, green: 0.286, blue: 0.227),
        onDanger: .white,
        isDark: false
    )

    // WCAG ≈ primary 13:1, secondary 6.7:1, onAccent 8:1. Off-white text and muted sage keep things dim.
    public static let dark = Palette(
        background: Color(red: 0.078, green: 0.090, blue: 0.082),
        cardBackground: Color(red: 0.110, green: 0.125, blue: 0.114),
        cardBorder: Color(red: 0.149, green: 0.169, blue: 0.153),
        primaryText: Color(red: 0.886, green: 0.898, blue: 0.867),
        secondaryText: Color(red: 0.631, green: 0.659, blue: 0.624),
        accent: Color(red: 0.576, green: 0.722, blue: 0.592),
        onAccent: Color(red: 0.063, green: 0.125, blue: 0.082),
        accentSoft: Color(red: 0.141, green: 0.188, blue: 0.157),
        divider: Color(red: 0.165, green: 0.188, blue: 0.173),
        success: Color(red: 0.612, green: 0.796, blue: 0.745),
        warning: Color(red: 0.867, green: 0.749, blue: 0.514),
        danger: Color(red: 0.878, green: 0.627, blue: 0.561),
        onDanger: Color(red: 0.137, green: 0.071, blue: 0.055),
        isDark: true
    )

    public static let cardCornerRadius: CGFloat = 22
    public static let controlCornerRadius: CGFloat = 14
    public static let sectionSpacing: CGFloat = 20
    public static let cardPadding: CGFloat = 20

    /// Shared curves so motion feels like one app. None overshoot.
    public enum Motion {
        public static let snappy = Animation.snappy(duration: 0.28)
        public static let smooth = Animation.smooth(duration: 0.45)
        public static let gentle = Animation.smooth(duration: 0.6)
    }
}

extension Font {
    /// Body copy stays in the default face, which reads better small.
    public static func moth(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension MothTheme.Palette {
    /// The one severity-to-colour mapping, so lists, cards, and badges can't drift.
    public func color(for severity: FlickerSeverity) -> Color {
        switch severity {
        case .unknown: return secondaryText
        case .none, .noObservableEffect: return success
        case .lowRisk: return warning
        case .detectedUnrated, .exceedsLowRisk: return danger
        }
    }
}

extension FlickerSeverity {
    /// A distinct shape per status so it reads without colour; outline so it isn't a bright blob.
    public var calmSymbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .none, .noObservableEffect: return "checkmark.circle"
        case .lowRisk: return "minus.circle"
        case .detectedUnrated: return "waveform.circle"
        case .exceedsLowRisk: return "exclamationmark.triangle"
        }
    }
}

private struct MothPaletteKey: EnvironmentKey {
    static let defaultValue = MothTheme.light
}

extension EnvironmentValues {
    /// Screens read this instead of branching on colour scheme.
    public var mothPalette: MothTheme.Palette {
        get { self[MothPaletteKey.self] }
        set { self[MothPaletteKey.self] = newValue }
    }
}

private struct MothMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Requires both the Animations setting and system Reduce Motion to allow it.
    public var mothMotionEnabled: Bool {
        get { self[MothMotionEnabledKey.self] }
        set { self[MothMotionEnabledKey.self] = newValue }
    }
}

/// Also strips animation from everything below when motion is off, so screens don't have to check.
public struct MothThemedRoot<Content: View>: View {
    private let appearance: AppearanceMode
    private let animationsEnabled: Bool
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(appearance: AppearanceMode, animationsEnabled: Bool = true, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.animationsEnabled = animationsEnabled
        self.content = content()
    }

    public var body: some View {
        let isDark = appearance == .dark
        let palette = isDark ? MothTheme.dark : MothTheme.light
        let motionEnabled = animationsEnabled && !reduceMotion
        content
            .environment(\.mothPalette, palette)
            .environment(\.mothMotionEnabled, motionEnabled)
            .transaction { transaction in
                if !motionEnabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .tint(palette.accent)
            .preferredColorScheme(isDark ? .dark : .light)
    }
}

public struct MothFlowLayout: Layout {
    private let spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                totalHeight += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, anchor: .topLeading, proposal: .unspecified)
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Hairline border, no shadow, so nothing appears to glow or float.
public struct MothCard<Content: View>: View {
    @Environment(\.mothPalette) private var palette
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous)
        content
            .padding(MothTheme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardBackground, in: shape)
            .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 1))
    }
}

/// Flat fill: stands out by being the only filled shape, not the brightest.
public struct MothPrimaryButtonStyle: ButtonStyle {
    @Environment(\.mothPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var isDestructive: Bool = false

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous)
        configuration.label
            .font(.moth(.headline, weight: .bold))
            .foregroundStyle(isDestructive ? palette.onDanger : palette.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isDestructive ? palette.danger : palette.accent, in: shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(MothTheme.Motion.snappy, value: configuration.isPressed)
            .animation(MothTheme.Motion.smooth, value: isEnabled)
    }
}

public struct MothSecondaryButtonStyle: ButtonStyle {
    @Environment(\.mothPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.moth(.headline, weight: .semibold))
            .foregroundStyle(palette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(MothTheme.Motion.snappy, value: configuration.isPressed)
    }
}

public struct MothPressableButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(MothTheme.Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MothPrimaryButtonStyle {
    public static var mothPrimary: MothPrimaryButtonStyle { MothPrimaryButtonStyle() }
    public static var mothDestructive: MothPrimaryButtonStyle { MothPrimaryButtonStyle(isDestructive: true) }
}

extension ButtonStyle where Self == MothSecondaryButtonStyle {
    public static var mothSecondary: MothSecondaryButtonStyle { MothSecondaryButtonStyle() }
}

extension ButtonStyle where Self == MothPressableButtonStyle {
    public static var mothPressable: MothPressableButtonStyle { MothPressableButtonStyle() }
}

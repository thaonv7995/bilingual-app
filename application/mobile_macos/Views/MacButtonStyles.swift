import SwiftUI

/// Adds full-bounds hit testing via `.contentShape(...)` and subtle desktop hover feedback
/// for controls (including `Menu` labels) that cannot use a custom `ButtonStyle`.
struct MacHoverHighlightModifier<HitShape: Shape>: ViewModifier {
    let shape: HitShape
    var hoverColor: Color = Color.white.opacity(0.12)
    var isEnabled: Bool = true

    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .overlay {
                shape
                    .fill(hoverColor)
                    .opacity(isEnabled && isHovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

extension View {
    func macHoverHighlight<HitShape: Shape>(
        _ shape: HitShape,
        hoverColor: Color = Color.white.opacity(0.12),
        isEnabled: Bool = true
    ) -> some View {
        modifier(MacHoverHighlightModifier(shape: shape, hoverColor: hoverColor, isEnabled: isEnabled))
    }
}

/// Responsive macOS button style that guarantees full-bounds hit testing via `.contentShape(...)`
/// (preventing SwiftUI `.buttonStyle(.plain)` from ignoring transparent padding or SF Symbol hollows)
/// while adding crisp desktop hover and press feedback.
struct MacInteractiveButtonStyle<HitShape: Shape>: ButtonStyle {
    let shape: HitShape
    var hoverColor: Color = Color.white.opacity(0.12)
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        MacInteractiveButtonBody(
            configuration: configuration,
            shape: shape,
            hoverColor: hoverColor,
            pressedScale: pressedScale
        )
    }
}

private struct MacInteractiveButtonBody<HitShape: Shape>: View {
    let configuration: ButtonStyle.Configuration
    let shape: HitShape
    let hoverColor: Color
    let pressedScale: CGFloat

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .macHoverHighlight(shape, hoverColor: hoverColor, isEnabled: isEnabled)
            .scaleEffect(isEnabled && configuration.isPressed ? pressedScale : 1.0)
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MacInteractiveButtonStyle<RoundedRectangle> {
    static var macInteractive: MacInteractiveButtonStyle<RoundedRectangle> {
        MacInteractiveButtonStyle(shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func macInteractive(
        cornerRadius: CGFloat = 8,
        hoverColor: Color = Color.white.opacity(0.12),
        pressedScale: CGFloat = 0.96
    ) -> MacInteractiveButtonStyle<RoundedRectangle> {
        MacInteractiveButtonStyle(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            hoverColor: hoverColor,
            pressedScale: pressedScale
        )
    }
}

extension ButtonStyle where Self == MacInteractiveButtonStyle<Circle> {
    static var macCircle: MacInteractiveButtonStyle<Circle> {
        MacInteractiveButtonStyle(shape: Circle())
    }

    static func macCircle(
        hoverColor: Color = Color.white.opacity(0.15),
        pressedScale: CGFloat = 0.93
    ) -> MacInteractiveButtonStyle<Circle> {
        MacInteractiveButtonStyle(
            shape: Circle(),
            hoverColor: hoverColor,
            pressedScale: pressedScale
        )
    }
}

extension ButtonStyle where Self == MacInteractiveButtonStyle<Capsule> {
    static var macCapsule: MacInteractiveButtonStyle<Capsule> {
        MacInteractiveButtonStyle(shape: Capsule())
    }

    static func macCapsule(
        hoverColor: Color = Color.white.opacity(0.12),
        pressedScale: CGFloat = 0.96
    ) -> MacInteractiveButtonStyle<Capsule> {
        MacInteractiveButtonStyle(
            shape: Capsule(),
            hoverColor: hoverColor,
            pressedScale: pressedScale
        )
    }
}

extension ButtonStyle where Self == MacInteractiveButtonStyle<Rectangle> {
    static var macRect: MacInteractiveButtonStyle<Rectangle> {
        MacInteractiveButtonStyle(shape: Rectangle())
    }

    static func macRect(
        hoverColor: Color = Color.white.opacity(0.11),
        pressedScale: CGFloat = 0.97
    ) -> MacInteractiveButtonStyle<Rectangle> {
        MacInteractiveButtonStyle(
            shape: Rectangle(),
            hoverColor: hoverColor,
            pressedScale: pressedScale
        )
    }
}

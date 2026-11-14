import AppKit
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

    func macReaderKeyboardShortcuts(
        allowsInSheet: Bool = false,
        isBlocked: @escaping () -> Bool = { false },
        onLeftArrow: @escaping () -> Bool,
        onRightArrow: @escaping () -> Bool,
        onEscape: @escaping () -> Bool = { false },
        onToggleFullscreen: (() -> Bool)? = nil
    ) -> some View {
        modifier(
            MacReaderKeyMonitorModifier(
                allowsInSheet: allowsInSheet,
                isBlocked: isBlocked,
                onLeftArrow: onLeftArrow,
                onRightArrow: onRightArrow,
                onEscape: onEscape,
                onToggleFullscreen: onToggleFullscreen
            )
        )
    }
}

/// Installs a scoped AppKit local `keyDown` monitor so reader keyboard shortcuts
/// continue working even when `WKWebView` holds AppKit `firstResponder`.
struct MacReaderKeyMonitorModifier: ViewModifier {
    let allowsInSheet: Bool
    let isBlocked: () -> Bool
    let onLeftArrow: () -> Bool
    let onRightArrow: () -> Bool
    let onEscape: () -> Bool
    let onToggleFullscreen: (() -> Bool)?

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                installMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let keyWindow = NSApp.keyWindow, event.window === keyWindow else {
                return event
            }
            if !allowsInSheet && (keyWindow.sheetParent != nil || keyWindow.attachedSheet != nil) {
                return event
            }
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return event
            }
            guard !isBlocked() else { return event }

            let isEditingText = NSApp.keyWindow?.firstResponder is NSText
            switch event.keyCode {
            case 123: // Left Arrow
                guard !isEditingText else { return event }
                return onLeftArrow() ? nil : event
            case 124: // Right Arrow
                guard !isEditingText else { return event }
                return onRightArrow() ? nil : event
            case 53: // Escape
                return onEscape() ? nil : event
            default:
                if !isEditingText,
                   event.charactersIgnoringModifiers?.lowercased() == "f",
                   let onToggleFullscreen {
                    return onToggleFullscreen() ? nil : event
                }
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
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

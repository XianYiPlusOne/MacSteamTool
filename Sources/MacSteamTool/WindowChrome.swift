import AppKit
import SwiftUI

// Leave the leading corner free for the window's native traffic lights.
let windowControlsInset: CGFloat = 80

struct WindowHeaderBackground: NSViewRepresentable {
    final class HeaderView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> HeaderView { HeaderView() }
    func updateNSView(_ view: HeaderView, context: Context) {}
}

struct SheetHeader<Content: View>: View {
    var canClose = true
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) {
            SheetWindowControls(canClose: canClose, onClose: onClose).fixedSize()
            content
        }
    }
}

private struct SheetWindowControls: NSViewRepresentable {
    let canClose: Bool
    let onClose: () -> Void

    final class Coordinator: NSObject {
        var onClose: () -> Void
        init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
        @objc func closeSheet() { onClose() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onClose) }

    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        // Attached sheets can dismiss but cannot minimize or enter full screen independently.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.isEnabled = kind == .closeButton && canClose
            if kind == .closeButton {
                button.target = context.coordinator
                button.action = #selector(Coordinator.closeSheet)
            }
            stack.addArrangedSubview(button)
        }
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        context.coordinator.onClose = onClose
        (stack.arrangedSubviews.first as? NSButton)?.isEnabled = canClose
    }
}

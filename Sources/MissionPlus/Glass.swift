import AppKit

enum Glass {
    /// Wraps `content` in a Liquid Glass capsule (macOS 26+), or a HUD material on older systems.
    static func capsule(around content: NSView, size: NSSize, tint: NSColor? = nil, interactive: Bool = false) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        content.frame = frame
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = size.height / 2
            glass.style = .regular
            glass.tintColor = tint
            if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = size.height / 2
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return blur
    }
}

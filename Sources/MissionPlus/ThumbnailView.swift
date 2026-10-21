import AppKit

/// A small round button drawn like a window's traffic light, shown on a highlighted thumbnail.
final class CircleButton: NSView {
    enum Kind { case close, minimize }
    let kind: Kind
    var action: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        toolTip = kind == .close ? "Close (⌘W)" : "Minimize (⌘M)"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor(white: 0.12, alpha: 0.92).setFill()
        circle.fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let glyph = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r: CGFloat = 4.5
        if kind == .close {
            glyph.move(to: NSPoint(x: c.x - r, y: c.y - r)); glyph.line(to: NSPoint(x: c.x + r, y: c.y + r))
            glyph.move(to: NSPoint(x: c.x - r, y: c.y + r)); glyph.line(to: NSPoint(x: c.x + r, y: c.y - r))
        } else {
            glyph.move(to: NSPoint(x: c.x - r, y: c.y)); glyph.line(to: NSPoint(x: c.x + r, y: c.y))
        }
        glyph.lineWidth = 2
        glyph.lineCapStyle = .round
        NSColor.white.setStroke()
        glyph.stroke()
    }

    override func mouseDown(with event: NSEvent) { action?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One window in the overview: its live image, app icon, title and hover buttons.
final class ThumbnailView: NSView {
    /// Space around the image inside this view, for the buttons (top/sides) and the app icon (bottom).
    static let sideInset: CGFloat = 12
    static let bottomInset: CGFloat = 24

    let item: WindowItem
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?

    private let ring = NSView()
    private let imageView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = CircleButton(kind: .close)
    private let minimizeButton = CircleButton(kind: .minimize)

    var isHighlighted = false { didSet { updateChrome() } }
    var showsTitleAlways = false { didSet { updateChrome() } }
    var showsButtons = true { didSet { updateChrome() } }

    /// The view frame that places the window image at `imageRect`.
    static func frame(forImageRect r: CGRect) -> CGRect {
        CGRect(x: r.minX - sideInset, y: r.minY - bottomInset,
               width: r.width + 2 * sideInset, height: r.height + sideInset + bottomInset)
    }

    var imageRectInSuperview: CGRect { imageView.frame.offsetBy(dx: frame.minX, dy: frame.minY) }

    init(item: WindowItem, imageRect: CGRect) {
        self.item = item
        super.init(frame: Self.frame(forImageRect: imageRect))
        wantsLayer = true

        let imageFrame = NSRect(x: Self.sideInset, y: Self.bottomInset,
                                width: bounds.width - 2 * Self.sideInset, height: bounds.height - Self.sideInset - Self.bottomInset)

        ring.frame = imageFrame.insetBy(dx: -5, dy: -5)
        ring.autoresizingMask = [.width, .height]
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 15
        ring.layer?.borderWidth = 4
        ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        addSubview(ring)

        imageView.frame = imageFrame
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.85).cgColor
        imageView.layer?.contentsGravity = .resize
        addSubview(imageView)

        iconView.image = item.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: bounds.midX - 22, y: Self.bottomInset - 26, width: 44, height: 44)
        iconView.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        addSubview(iconView)

        titleLabel.stringValue = item.displayTitle
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.wantsLayer = true
        titleLabel.drawsBackground = false
        titleLabel.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.75).cgColor
        titleLabel.layer?.cornerRadius = 11
        addSubview(titleLabel)

        closeButton.frame.origin = NSPoint(x: Self.sideInset - 10, y: bounds.height - Self.sideInset - 14)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.action = { [weak self] in self?.onClose?() }
        addSubview(closeButton)

        minimizeButton.frame.origin = NSPoint(x: closeButton.frame.maxX + 4, y: closeButton.frame.minY)
        minimizeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        minimizeButton.action = { [weak self] in self?.onMinimize?() }
        addSubview(minimizeButton)

        setThumbnail(item.thumbnail)
        updateChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: CGImage?) {
        imageView.layer?.contents = image
        if image == nil {
            // No capture yet (or no Screen Recording permission): show a large app icon as placeholder.
            imageView.layer?.contents = item.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            imageView.layer?.contentsGravity = .center
        } else {
            imageView.layer?.contentsGravity = .resize
        }
    }

    private func updateChrome() {
        ring.isHidden = !isHighlighted
        titleLabel.isHidden = !(isHighlighted || showsTitleAlways)
        closeButton.isHidden = !(isHighlighted && showsButtons)
        minimizeButton.isHidden = closeButton.isHidden
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let maxWidth = max(40, imageView.frame.width - 24)
        let width = min(maxWidth, titleLabel.intrinsicContentSize.width + 24)
        titleLabel.frame = NSRect(x: imageView.frame.midX - width / 2, y: imageView.frame.midY - 11, width: width, height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [closeButton, minimizeButton] where !button.isHidden && button.frame.contains(local) {
            return button
        }
        return imageView.frame.insetBy(dx: -4, dy: -4).contains(local) || iconView.frame.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onOpen?() }
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) { onClose?() } // middle-click closes, like a browser tab
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

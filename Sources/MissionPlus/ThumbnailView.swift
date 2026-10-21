import AppKit

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
    private let lights = TrafficLights()

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

        lights.frame.origin = NSPoint(x: Self.sideInset - TrafficLights.cornerOffset,
                                      y: bounds.height - Self.sideInset + TrafficLights.cornerOffset - TrafficLights.size.height)
        lights.autoresizingMask = [.maxXMargin, .minYMargin]
        lights.interactive = true
        lights.onPress = { [weak self] kind in kind == .close ? self?.onClose?() : self?.onMinimize?() }
        addSubview(lights)

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
        lights.setShown(isHighlighted && showsButtons)
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
        if lights.isShown, lights.frame.contains(local) { return lights }
        return imageView.frame.insetBy(dx: -4, dy: -4).contains(local) || iconView.frame.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onOpen?() }
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) { onClose?() } // middle-click closes, like a browser tab
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

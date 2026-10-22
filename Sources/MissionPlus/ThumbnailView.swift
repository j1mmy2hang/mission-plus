import AppKit
import CoreImage

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
    private let titleLabel = PillLabel(labelWithString: "")
    private let badge = PillLabel(labelWithString: "")
    /// The large icon over a window with no image yet.
    private let placeholderIcon = NSImageView()
    private var isPlaceholder = false
    private let lights = TrafficLights()

    var isHighlighted = false { didSet { updateChrome() } }
    var showsTitleAlways = false { didSet { updateChrome() } }

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

        // Where a window that isn't on screen is: "Desktop 2", "Minimized"…
        if let text = item.place.badge {
            badge.stringValue = text
            badge.font = .systemFont(ofSize: 11, weight: .semibold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.drawsBackground = false
            badge.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.75).cgColor
            badge.layer?.cornerRadius = 9
            let width = max(18, badge.intrinsicContentSize.width + 12) // a circle for a single letter
            badge.frame = NSRect(x: imageFrame.maxX - width - 6, y: imageFrame.maxY - 24, width: width, height: 18)
            badge.autoresizingMask = [.minXMargin, .minYMargin]
            addSubview(badge)
        }

        lights.frame.origin = NSPoint(x: Self.sideInset - TrafficLights.cornerOffset,
                                      y: bounds.height - Self.sideInset + TrafficLights.cornerOffset - TrafficLights.size.height)
        lights.autoresizingMask = [.maxXMargin, .minYMargin]
        lights.interactive = true
        lights.onPress = { [weak self] kind in kind == .close ? self?.onClose?() : self?.onMinimize?() }
        addSubview(lights)

        placeholderIcon.image = item.icon
        placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholderIcon, positioned: .above, relativeTo: imageView)

        setThumbnail(item.thumbnail)
        updateChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: CGImage?) {
        isPlaceholder = image == nil
        if let image {
            imageView.layer?.contents = image
            imageView.layer?.contentsGravity = .resize
        } else {
            // No capture (a window that has never been on screen while Mission Plus watched, or no Screen Recording
            // permission): a blurred wash of the app's colours, with its icon and the window's title on top.
            imageView.layer?.contents = Self.wash(for: item)
            imageView.layer?.contentsGravity = .resizeAspectFill
        }
        placeholderIcon.isHidden = !isPlaceholder
        iconView.isHidden = isPlaceholder // the large icon already says which app
        updateChrome()
    }

    private static var washes: [pid_t: CGImage] = [:]

    /// The middle of the app's icon, blurred and laid thinly over the tile's grey: a hint of the app's colours.
    private static func wash(for item: WindowItem) -> CGImage? {
        if let cached = washes[item.pid] { return cached }
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        guard let icon = item.icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        // The centre skips the icon's transparent margin and rounded corners.
        let centre = CGRect(x: icon.width / 4, y: icon.height / 4, width: icon.width / 2, height: icon.height / 2)
        let tint = CIImage(cgImage: icon).cropped(to: centre).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(icon.width) / 10)
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.4)])
        let image = tint.composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))).cropped(to: centre)
        let wash = CIContext().createCGImage(image, from: centre)
        washes[item.pid] = wash
        return wash
    }

    private func updateChrome() {
        ring.isHidden = !isHighlighted
        titleLabel.isHidden = !(isHighlighted || showsTitleAlways || isPlaceholder)
        lights.setShown(isHighlighted)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let image = imageView.frame
        let maxWidth = max(40, image.width - 24)
        let width = min(maxWidth, titleLabel.intrinsicContentSize.width + 24)
        guard isPlaceholder else {
            titleLabel.frame = NSRect(x: image.midX - width / 2, y: image.midY - 11, width: width, height: 22)
            return
        }
        // Icon and title stacked as one group in the middle of the tile.
        let side = min(96, image.height * 0.45, image.width * 0.45)
        let gap: CGFloat = 8
        let top = image.midY + (side + gap + 22) / 2
        placeholderIcon.frame = NSRect(x: image.midX - side / 2, y: top - side, width: side, height: side)
        titleLabel.frame = NSRect(x: image.midX - width / 2, y: top - side - gap - 22, width: width, height: 22)
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

/// A label whose text sits in the vertical middle of its frame, for the title and badge pills
/// (a plain label draws its text at the top).
private final class PillLabel: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredCell.self }
        set {}
    }

    private final class CenteredCell: NSTextFieldCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            let drawing = super.drawingRect(forBounds: rect)
            let height = cellSize(forBounds: rect).height
            return NSRect(x: drawing.minX, y: rect.minY + (rect.height - height) / 2, width: drawing.width, height: height)
        }
    }
}

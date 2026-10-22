import AppKit
import QuartzCore

/// Close and minimize controls styled after macOS's window traffic lights, set in a Liquid Glass capsule.
///
/// Like real traffic lights, the glyphs (× and −) only appear while the pointer is over the group.
/// In `interactive` mode the view tracks the mouse itself; otherwise its owner drives
/// `hoveredKind`, `groupHovered` and `pressedKind` (used above Mission Control, where the window is click-through).
final class TrafficLights: NSView {
    enum Kind: CaseIterable { case close, minimize }

    static let diameter: CGFloat = 16
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 8
    static let size = NSSize(width: padding * 2 + diameter * 2 + spacing, height: diameter + padding * 2)
    /// How far the capsule sits outside a thumbnail's top-left corner.
    static let cornerOffset: CGFloat = 10

    /// A light's circle inside the capsule. Vertically centred, so it reads the same in flipped and unflipped coordinates.
    static func lightRect(_ kind: Kind) -> CGRect {
        let index = CGFloat(Kind.allCases.firstIndex(of: kind)!)
        return CGRect(x: padding + index * (diameter + spacing), y: padding, width: diameter, height: diameter)
    }

    /// A light's click target: larger than the circle, meeting its neighbour halfway across the gap.
    static func hitRect(_ kind: Kind) -> CGRect {
        lightRect(kind).insetBy(dx: -spacing / 2, dy: -padding)
    }

    var onPress: ((Kind) -> Void)?
    var interactive = false { didSet { updateTrackingAreas() } }

    var hoveredKind: Kind? { didSet { if hoveredKind != oldValue { updateLights() } } }
    var groupHovered = false { didSet { if groupHovered != oldValue { updateLights() } } }
    var pressedKind: Kind? { didSet { if pressedKind != oldValue { updateLights() } } }
    private(set) var isShown = false

    private let lights: [Kind: Light]

    init() {
        var lights: [Kind: Light] = [:]
        for kind in Kind.allCases { lights[kind] = Light(kind: kind, frame: Self.lightRect(kind)) }
        self.lights = lights
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true

        let content = NSView(frame: bounds)
        lights.values.forEach(content.addSubview)
        // A light smoke tint keeps the window's own traffic lights from showing through the glass.
        addSubview(Glass.capsule(around: content, size: bounds.size, tint: NSColor(white: 0.05, alpha: 0.45), interactive: true))

        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.28)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        isHidden = true
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    /// Fades the capsule in and springs the lights up, or fades it out.
    func setShown(_ shown: Bool, animated: Bool = true) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animated ? 0.16 : 0
                animator().alphaValue = 1
            }
            if animated {
                for (i, kind) in Kind.allCases.enumerated() { lights[kind]?.popIn(delay: Double(i) * 0.035) }
            }
        } else {
            hoveredKind = nil
            groupHovered = false
            pressedKind = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = animated ? 0.12 : 0
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isShown else { return }
                self.isHidden = true
            })
        }
    }

    /// Re-plays the appear animation, for when the controls jump to another thumbnail.
    func replayAppear() {
        alphaValue = 0
        isShown = false
        setShown(true)
    }

    private func updateLights() {
        for (kind, light) in lights {
            light.update(glyphVisible: groupHovered || pressedKind != nil,
                         hovered: hoveredKind == kind,
                         pressed: pressedKind == kind)
        }
    }

    func kind(at point: NSPoint) -> Kind? {
        Kind.allCases.first { Self.hitRect($0).contains(point) }
    }

    // MARK: Mouse (interactive mode)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard interactive else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { trackPointer(event) }
    override func mouseMoved(with event: NSEvent) { trackPointer(event) }
    override func mouseExited(with event: NSEvent) {
        groupHovered = false
        hoveredKind = nil
    }

    private func trackPointer(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        groupHovered = bounds.contains(p)
        hoveredKind = kind(at: p)
    }

    override func mouseDown(with event: NSEvent) {
        pressedKind = kind(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) { trackPointer(event) }

    override func mouseUp(with event: NSEvent) {
        let released = kind(at: convert(event.locationInWindow, from: nil))
        let pressed = pressedKind
        pressedKind = nil
        if let pressed, pressed == released { onPress?(pressed) } // dragging off a light cancels, like a real button
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One traffic light: a coloured lens with a soft highlight, a darker rim, and a glyph that fades in on hover.
private final class Light: NSView {
    let kind: TrafficLights.Kind

    private let body = CALayer()           // scaled for hover/press springs
    private let fill = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let shade = CAShapeLayer()     // darkens while pressed
    private let glyph = CAShapeLayer()

    private var scale: CGFloat = 1

    private var base: NSColor {
        kind == .close ? NSColor(srgbRed: 1.00, green: 0.373, blue: 0.341, alpha: 1)   // #FF5F57
                       : NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)  // #FEBC2E
    }
    private var edge: NSColor {
        kind == .close ? NSColor(srgbRed: 0.886, green: 0.275, blue: 0.247, alpha: 1)  // #E2463F
                       : NSColor(srgbRed: 0.882, green: 0.631, blue: 0.086, alpha: 1)  // #E1A116
    }
    private var glyphColor: NSColor {
        kind == .close ? NSColor(srgbRed: 0.30, green: 0, blue: 0, alpha: 0.85)        // macOS's deep red ×
                       : NSColor(srgbRed: 0.60, green: 0.34, blue: 0, alpha: 0.85)     // and amber −
    }

    init(kind: TrafficLights.Kind, frame: NSRect) {
        self.kind = kind
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        let d = frame.width
        let bounds = CGRect(x: 0, y: 0, width: d, height: d)
        let circle = CGPath(ellipseIn: bounds, transform: nil)

        body.frame = bounds

        fill.frame = bounds
        fill.cornerRadius = d / 2
        fill.colors = [base.blended(withFraction: 0.18, of: .white)!.cgColor, base.cgColor]
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)

        // A lens-like highlight across the upper half, the "glass" in the light.
        sheen.frame = CGRect(x: d * 0.18, y: d * 0.48, width: d * 0.64, height: d * 0.42)
        sheen.cornerRadius = sheen.frame.height / 2
        sheen.colors = [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)

        rim.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.25, dy: 0.25), transform: nil)
        rim.fillColor = nil
        rim.strokeColor = edge.withAlphaComponent(0.9).cgColor
        rim.lineWidth = 0.5

        shade.path = circle
        shade.fillColor = NSColor(white: 0, alpha: 0.22).cgColor
        shade.opacity = 0

        let g = CGMutablePath()
        let c = CGPoint(x: d / 2, y: d / 2)
        if kind == .close {
            let r = d * 0.2
            g.move(to: CGPoint(x: c.x - r, y: c.y - r)); g.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            g.move(to: CGPoint(x: c.x - r, y: c.y + r)); g.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
        } else {
            let r = d * 0.26
            g.move(to: CGPoint(x: c.x - r, y: c.y)); g.addLine(to: CGPoint(x: c.x + r, y: c.y))
        }
        glyph.path = g
        glyph.strokeColor = glyphColor.cgColor
        glyph.lineWidth = max(1.5, d * 0.1)
        glyph.lineCap = .round
        glyph.fillColor = nil
        glyph.opacity = 0

        body.shadowColor = NSColor(white: 0, alpha: 1).cgColor
        body.shadowOpacity = 0.25
        body.shadowRadius = 1.2
        body.shadowOffset = CGSize(width: 0, height: -0.5)
        body.shadowPath = circle

        [fill, sheen, rim, shade, glyph].forEach(body.addSublayer)
        layer?.addSublayer(body)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        [body, fill, sheen, rim, shade, glyph].forEach { $0.contentsScale = s }
    }

    func update(glyphVisible: Bool, hovered: Bool, pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(pressed ? 0.06 : 0.14)
        glyph.opacity = glyphVisible ? 1 : 0
        shade.opacity = pressed ? 1 : 0
        CATransaction.commit()
        spring(to: pressed ? 0.88 : hovered ? 1.1 : 1)
    }

    func popIn(delay: TimeInterval) {
        let anim = springAnimation(from: 0.45, to: scale)
        anim.beginTime = CACurrentMediaTime() + delay
        anim.fillMode = .backwards
        body.add(anim, forKey: "pop")
    }

    private func spring(to target: CGFloat) {
        guard target != scale else { return }
        let current = (body.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? scale
        scale = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.setValue(target, forKeyPath: "transform.scale")
        CATransaction.commit()
        body.add(springAnimation(from: current, to: target), forKey: "scale")
    }

    private func springAnimation(from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: "transform.scale")
        anim.fromValue = from
        anim.toValue = to
        anim.mass = 1
        anim.stiffness = 420
        anim.damping = 18
        anim.duration = anim.settlingDuration
        return anim
    }
}

import AppKit

/// The overview's search field: a real text field (caret, selection, input methods, paste) in a glass capsule.
///
/// Navigation keys typed into the field (arrows, Tab, Return, Escape) are handed to `onCommand`
/// so they can move between windows instead of moving the caret.
final class SearchBar: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 440, height: 44)

    let field = NSTextField()
    private let icon = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")

    var onChange: ((String) -> Void)?
    /// Return true if the command was handled.
    var onCommand: ((Selector) -> Bool)?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let content = NSView()

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        icon.contentTintColor = NSColor(white: 1, alpha: 0.6)
        icon.frame = NSRect(x: 16, y: (Self.size.height - 20) / 2, width: 20, height: 20)
        content.addSubview(icon)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = NSColor(white: 1, alpha: 0.5)
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: Self.size.width - 96, y: (Self.size.height - 17) / 2, width: 80, height: 17)
        content.addSubview(countLabel)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = .white
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.placeholderAttributedString = NSAttributedString(string: "Search windows", attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.4),
            .font: NSFont.systemFont(ofSize: 17),
        ])
        field.delegate = self
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: icon.frame.maxX + 10, y: (Self.size.height - height) / 2,
                             width: countLabel.frame.minX - icon.frame.maxX - 18, height: height)
        content.addSubview(field)

        addSubview(Glass.capsule(around: content, size: Self.size, tint: NSColor(white: 0.05, alpha: 0.35)))
    }
    required init?(coder: NSCoder) { fatalError() }

    var text: String { field.stringValue }

    func clear() {
        field.stringValue = ""
        onChange?("")
    }

    func focus() {
        window?.makeFirstResponder(field)
        styleEditor()
    }

    /// Shows "3 of 7" while a search is active.
    func setCount(matching: Int, total: Int) {
        countLabel.stringValue = text.isEmpty ? "" : "\(matching) of \(total)"
    }

    private func styleEditor() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = .white
        editor.allowsUndo = true
    }

    // Clicking anywhere on the capsule focuses the field rather than falling through to the background.
    override func mouseDown(with event: NSEvent) { focus() }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) { styleEditor() }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        onCommand?(selector) ?? false
    }
}

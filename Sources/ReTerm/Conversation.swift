import AppKit

// What TERM, HOMO and CHAT share: the history of conversations on the left, the one shown (its newest at
// the bottom, as a conversation), the line to type under it, and its name at the top.

// ── the history: the conversations' names, the one shown underlined; a click shows it ──

struct Item {
    let id: String
    let title: String
    var badge: String? = nil
    var hint: String? = nil
}

final class HistoryList: Flipped {
    let scroll = FadeScroll()
    private let doc = RowsDrawer()
    var items: [Item] = [] { didSet { relayout() } }
    var shown: String? { didSet { doc.needsDisplay = true } }
    /// NOVA, always at the top: a new conversation (underlined while it is the one shown)
    var fresh: (() -> Void)?
    var freshShown = false { didSet { doc.needsDisplay = true } }
    var pick: ((String) -> Void)?

    private let rowH: CGFloat = 31
    private let gap: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        doc.list = self
        scroll.documentView = doc
        addSubview(scroll)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        doc.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(forName: Lang.changed, object: nil, queue: .main) { [weak self] _ in self?.doc.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: [(id: String?, title: String, badge: String?, on: Bool)] {
        var all: [(String?, String, String?, Bool)] = []
        if fresh != nil { all.append((nil, t("NOVA"), nil, freshShown)) }
        for i in items { all.append((i.id, i.title, i.badge, i.id == shown)) }
        return all
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        relayout()
    }

    private func relayout() {
        let n = CGFloat(rows.count)
        doc.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(n * rowH + max(0, n - 1) * gap, scroll.contentSize.height))
        doc.needsDisplay = true
        doc.toolTip = nil
        doc.removeAllToolTips()
        for (i, item) in items.enumerated() {
            let r = rect(i + (fresh != nil ? 1 : 0))
            doc.addToolTip(r, owner: (item.hint ?? item.title) as NSString, userData: nil)
        }
        scroll.update()
    }

    private func rect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(i) * (rowH + gap), width: doc.bounds.width, height: rowH)
    }

    override func draw(_ dirtyRect: NSRect) {}

    @objc private func clicked(_ g: NSClickGestureRecognizer) {
        let p = g.location(in: doc)
        let i = Int(p.y / (rowH + gap))
        let all = rows
        guard i >= 0, i < all.count else { return }
        if let id = all[i].id { pick?(id) } else { fresh?() }
    }

    func drawRows(in view: NSView) {
        for (i, row) in rows.enumerated() {
            let r = rect(i)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: Fonts.words(14),
                .foregroundColor: NSColor(white: 1, alpha: 0.8 * (row.on ? 1 : 0.75)),
            ]
            if row.on {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = Ink.text
            }
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            attrs[.paragraphStyle] = p
            let badgeW: CGFloat
            if let badge = row.badge {
                let b = attributed(badge, Fonts.words(11.2), NSColor(white: 1, alpha: 0.8 * 0.6))
                badgeW = b.size().width + 10
                b.draw(at: NSPoint(x: r.maxX - b.size().width, y: r.minY + 8))
            } else {
                badgeW = 0
            }
            NSAttributedString(string: row.title, attributes: attrs)
                .draw(with: NSRect(x: 6.3, y: r.minY + 5, width: r.width - 12.6 - badgeW, height: 21), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// the one shown kept in sight
    func reveal() {
        guard let i = rows.firstIndex(where: { $0.on }) else { return }
        doc.scrollToVisible(rect(i).insetBy(dx: 0, dy: -FadeScroll.fade))
    }

}

/// draws the history's rows (its document view is a plain Flipped)
private final class RowsDrawer: Flipped {
    weak var list: HistoryList?
    override func draw(_ dirtyRect: NSRect) { list?.drawRows(in: self) }
}

// ── the conversation: its newest at the bottom; selectable; its edges fading where more is hidden ──

final class Transcript: NSTextView {
    /// the conversation's pieces (a message, an answer…), each one or more paragraphs
    private(set) var segments: [NSAttributedString] = []
    var onWidth: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0
    /// the room under the last piece
    var bottomPad: CGFloat = 12

    static func make() -> (FadeScroll, Transcript) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let text = Transcript(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: container)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.textContainerInset = .zero
        text.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.18)]
        text.linkTextAttributes = [.foregroundColor: Ink.text, .underlineStyle: NSUnderlineStyle.single.rawValue]
        let scroll = FadeScroll()
        scroll.documentView = text
        return (scroll, text)
    }

    /// the pieces sit at the bottom while they don't fill it
    override var textContainerOrigin: NSPoint {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let used = layout.usedRect(for: container).height
        let visible = enclosingScrollView?.contentSize.height ?? bounds.height
        return NSPoint(x: 0, y: max(0, visible - used - bottomPad))
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        let visible = enclosingScrollView?.contentSize.height ?? 0
        if let layout = layoutManager, let container = textContainer {
            size.height = max(visible, layout.usedRect(for: container).height + bottomPad)
        }
        super.setFrameSize(size)
        if abs(size.width - lastWidth) > 0.5 {
            lastWidth = size.width
            onWidth?(size.width)
        }
    }

    private func refit() {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        setFrameSize(NSSize(width: frame.width, height: 0))
        needsDisplay = true
        (enclosingScrollView as? FadeScroll)?.update()
    }

    private var nearBottom: Bool {
        guard let scroll = enclosingScrollView else { return true }
        let y = scroll.contentView.bounds.maxY
        return frame.height - y < 80
    }

    func scrollToBottom() {
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, frame.height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// all the pieces anew
    func set(_ pieces: [NSAttributedString], stick: Bool = false) {
        let near = nearBottom
        segments = pieces
        let all = NSMutableAttributedString()
        for (i, p) in pieces.enumerated() {
            if i > 0 { all.append(NSAttributedString(string: "\n", attributes: pieces[i - 1].length > 0 ? pieces[i - 1].attributes(at: pieces[i - 1].length - 1, effectiveRange: nil) : [:])) }
            all.append(p)
        }
        textStorage?.setAttributedString(all)
        refit()
        if stick || near { scrollToBottom() }
    }

    /// one piece changed (an answer coming)
    func update(_ i: Int, _ piece: NSAttributedString) {
        guard i < segments.count, let storage = textStorage else { return set(segments + [piece]) }
        let near = nearBottom
        var start = 0
        for j in 0..<i { start += segments[j].length + 1 }
        storage.replaceCharacters(in: NSRange(location: start, length: segments[i].length), with: piece)
        segments[i] = piece
        refit()
        if near { scrollToBottom() }
    }

    func append(_ piece: NSAttributedString, stick: Bool = true) {
        set(segments + [piece], stick: stick)
    }
}

// ── the line to type: no frame, a line under it; it grows with what is typed ──

final class InputBox: Flipped, NSTextViewDelegate {
    let text: InputText
    private let scroll = NSScrollView()
    var size: CGFloat = 14 { didSet { restyle() } }
    var lineHeight: CGFloat = 1.25
    var maxHeight: CGFloat = 300
    /// a key, before the line takes it: whether it was taken
    var onKey: ((NSEvent) -> Bool)?
    var onChange: (() -> Void)?
    var onHeight: (() -> Void)?
    var secure = false

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        text = InputText(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        super.init(frame: frame)
        text.box = self
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.textContainerInset = .zero
        text.insertionPointColor = Ink.text
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.smartInsertDeleteEnabled = false
        text.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.22)]
        text.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = text
        addSubview(scroll)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = size * lineHeight
        p.maximumLineHeight = size * lineHeight
        let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.words(size), .foregroundColor: Ink.text, .paragraphStyle: p]
        text.typingAttributes = attrs
        text.font = Fonts.words(size)
        if let s = text.textStorage, s.length > 0 { s.setAttributes(attrs, range: NSRange(location: 0, length: s.length)) }
        needsLayout = true
    }

    var string: String {
        get { text.string }
        set {
            text.string = newValue
            restyle()
            text.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            changed()
        }
    }

    /// how tall it is now: its lines (up to its most), the room above and under them, the line
    var height: CGFloat {
        guard let layout = text.layoutManager, let container = text.textContainer else { return 30 }
        layout.ensureLayout(for: container)
        let used = max(layout.usedRect(for: container).height, size * lineHeight)
        return min(used, maxHeight) + 4 + 8 + 1
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 4, width: bounds.width, height: max(0, bounds.height - 13))
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.line.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func textDidChange(_ notification: Notification) { changed() }

    private func changed() {
        onChange?()
        onHeight?()
    }

    func focus() {
        window?.makeFirstResponder(text)
    }

    var focused: Bool { window?.firstResponder === text }

    /// the caret on the first line (↑ the commands before), or the last (↓)
    var caretOnFirstLine: Bool {
        let s = text.string as NSString
        return !s.substring(to: text.selectedRange().location).contains("\n")
    }

    var caretOnLastLine: Bool {
        let s = text.string as NSString
        let r = text.selectedRange()
        return !s.substring(from: r.location + r.length).contains("\n")
    }
}

final class InputText: NSTextView {
    weak var box: InputBox?

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), box?.onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    // pasted as words only
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

/// the conversation shown: its name at the top, in the middle
func titleLabel() -> NSTextField {
    let f = label("", Fonts.words(18), align: .center)
    f.lineBreakMode = .byTruncatingTail
    return f
}

/// "12 Nov, 14:05"
func when(_ ms: Double) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

/// a line in the conversation: its words, its size, how it stands
func paragraph(_ text: String, font: NSFont, color: NSColor = Ink.text, align: NSTextAlignment = .left,
               lineHeight: CGFloat, before: CGFloat = 0, indentLeft: CGFloat = 0, indentRight: CGFloat = 0) -> NSMutableAttributedString {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.minimumLineHeight = font.pointSize * lineHeight
    p.maximumLineHeight = font.pointSize * lineHeight
    p.paragraphSpacingBefore = before
    p.firstLineHeadIndent = indentLeft
    p.headIndent = indentLeft
    p.tailIndent = -indentRight
    p.lineBreakMode = .byWordWrapping
    return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}

import AppKit

// ReTerm: three ways to talk, as the other Re apps have their side buttons: TERM the shell, HOMO people
// (Telegram), CHAT an LLM (claude, codex). Each goes on while another is shown. FULL: the one shown has the
// whole window, the buttons go (⌘⇧F back).

/// one of the three: laid out in the area between the side buttons, the history on its left
class ModePage: Flipped {
    weak var main: MainView?
    /// where the conversation is, and how wide its history (0: none)
    var area: NSRect = .zero
    var list: CGFloat = 0
    var small = false
    /// the line to type, for a key typed anywhere
    var input: InputBox? { nil }

    var active = false {
        didSet {
            isHidden = !active
            if active && !oldValue { shown() }
        }
    }

    /// the window opened: what it starts (the shell, Telegram…)
    func start() {}
    /// shown: the keys are its
    func shown() {}
    func key(_ e: NSEvent) -> Bool { false }
    /// the window goes: what is kept, kept
    func leave() {}
    /// the window has gone: what it started ends
    func end() {}
    func focusChanged(_ focused: Bool) {}

    /// the name of the conversation shown, at the top
    let title = titleLabel()

    func layoutTitle() {
        let W = bounds.width
        let maxW = small ? W - 200 : W * 0.5
        title.frame = NSRect(x: (W - maxW) / 2, y: small ? 6 : 28, width: maxW, height: 32)
    }
}

final class MainView: Flipped {
    let term = TermPage()
    let homo = HomoPage()
    let chat = ChatPage()
    private var pages: [String: ModePage] { ["term": term, "homo": homo, "chat": chat] }

    private let termButton = SideButton("TERM") {}
    private let homoButton = SideButton("HOMO") {}
    private let chatButton = SideButton("CHAT") {}
    private let fullButton = SideButton("FULL") {}
    private let marks = Marks()
    private let strip = DragStrip()

    private(set) var mode = "term"
    private(set) var full = false
    var pinned = false { didSet { marks.pinned = pinned } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        if let saved = Saved.json("view") as? [String: Any] {
            if let m = saved["mode"] as? String, ["term", "homo", "chat"].contains(m) { mode = m }
            full = saved["full"] as? Bool ?? false
        }
        for page in [term, homo, chat] {
            page.main = self
            page.autoresizingMask = [.width, .height]
            page.isHidden = true
            addSubview(page)
        }
        termButton.action = { [weak self] in self?.show("term") }
        termButton.title = "Terminal (⌘⇧T)"
        homoButton.action = { [weak self] in self?.show("homo") }
        homoButton.title = "People (⌘⇧H)"
        chatButton.action = { [weak self] in self?.show("chat") }
        chatButton.title = "LLM (⌘⇧C)"
        fullButton.action = { [weak self] in self?.toggleFull() }
        fullButton.title = "The whole window (⌘⇧F)"
        [termButton, homoButton, chatButton, fullButton].forEach(addSubview)
        addSubview(strip)
        addSubview(marks)
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        for page in [term, homo, chat] { page.start(); tick("started \(type(of: page))") }
        show(mode)
    }

    func show(_ m: String) {
        mode = m
        for (name, page) in pages { page.active = name == m }
        termButton.chosen = m == "term"
        homoButton.chosen = m == "homo"
        chatButton.chosen = m == "chat"
        keep()
    }

    func toggleFull() {
        full.toggle()
        fullButton.chosen = full
        keep()
        needsLayout = true
    }

    private func keep() {
        Saved.setJSON("view", ["mode": mode, "full": full])
    }

    var page: ModePage? { pages[mode] }

    func leave() { for p in [term, homo, chat] { p.leave() } }
    func end() { for p in [term, homo, chat] { p.end() } }

    func focusChanged(_ focused: Bool) {
        marks.focused = focused
        for p in [term, homo, chat] { p.focusChanged(focused) }
    }

    // ── laid out: the area between the side buttons, or the whole window (FULL, or a small window) ──

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let small = W < 760 || H < 560
        let list: CGFloat = small ? 0 : min(300, max(190, W * 0.24))
        let area: NSRect
        if full || small {
            area = NSRect(x: 34, y: 36, width: max(0, W - 34 - 30), height: max(0, H - 36 - 22))
        } else {
            let side = max(W * 0.0625 + 80, W * 0.5 - 380 - list / 2)
            let top = H * 0.0625 + 24
            area = NSRect(x: side, y: top, width: max(0, W - side * 2), height: max(0, H - top * 2))
        }
        for p in [term, homo, chat] {
            p.area = area
            p.list = list
            p.small = small
            p.frame = bounds
            p.needsLayout = true
        }
        fullButton.chosen = full
        for (b, c) in [(termButton, Corner.topLeft), (homoButton, .topRight), (chatButton, .bottomLeft), (fullButton, .bottomRight)] {
            let h = CGFloat(b.shown.count) * SideButton.advance + SideButton.size * 0.55
            b.top = true
            let left = c == .topLeft || c == .bottomLeft
            let x = left ? W * 0.0625 - 28 : W - (W * 0.0625 - 28) - SideButton.width
            let y = c == .topLeft || c == .topRight ? H * 0.0625 + 8 : H - H * 0.0625 - h
            b.frame = NSRect(x: x, y: y, width: SideButton.width, height: h)
            b.isHidden = small || full
        }
        strip.frame = NSRect(x: 0, y: 0, width: W, height: 28)
        marks.frame = NSRect(x: 14, y: 14, width: 13, height: 40)
    }

    // ── keys ──

    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == [.command, .shift] {
            switch e.keyCode {
            case 17: show("term"); return true
            case 4: show("homo"); return true
            case 8: show("chat"); return true
            case 3: toggleFull(); return true
            default: break
            }
        }
        if mods == .command && e.keyCode == 45 { // ⌘N: another window
            (NSApp.delegate as? AppDelegate)?.newWindow(from: window)
            return true
        }
        if mods == .command && e.keyCode == 13 { // ⌘W: this one closes, its shell with it
            window?.close()
            return true
        }
        if let page, page.key(e) { return true }
        // typing anywhere goes to the line
        if mods.subtracting(.shift).isEmpty, let input = page?.input, !(window?.firstResponder is NSTextView),
           !(window?.firstResponder is TerminalScreen), let chars = e.characters, !chars.isEmpty, e.keyCode != 53 {
            input.focus()
            input.text.keyDown(with: e)
            return true
        }
        return false
    }
}

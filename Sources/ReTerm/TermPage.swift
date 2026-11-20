import AppKit
import SwiftTerm

// TERM: the terminal as a conversation. Each command is a message (on the right), the shell's answer under
// it, written in its colours; the line to type is at the bottom (↑ ↓ the commands before, Tab completes).
// The shell is the user's zsh in a pseudo-terminal, its marks (Resources/zsh) saying where each command
// starts and ends. A program that takes the whole screen (vim, htop, less…) has the whole column while it
// runs. Another shell than zsh: a plain terminal. When the shell ends, the window closes.
// Each session is kept (its commands and their answers as text): ⌘K starts a new one, the ones before are on
// the left, each to go on with (the shell goes to where it was); ⇧↑ / ⇧↓ the one above / below.

private final class Block {
    let id: Int
    /// what was typed; nil: output with no message of its own
    var command: String?
    /// the answer while it comes: a terminal of its own
    var live: Terminal?
    /// the answer done, kept as text in its colours
    var html = ""
    /// the shell's status when done; nil while running
    var status: Int?
    /// it took the whole window (vim…)
    var fullscreen = false

    init(id: Int, command: String?) {
        self.id = id
        self.command = command
    }
}

/// a live answer's terminal: what it answers the program (where the cursor is…) goes to the shell
private final class Sink: TerminalDelegate {
    var send: (([UInt8]) -> Void)?
    func send(source: Terminal, data: ArraySlice<UInt8>) { send?(Array(data)) }
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func hostCurrentDirectoryUpdated(source: Terminal) {}
    func hostCurrentDocumentUpdated(source: Terminal) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setForegroundColor(source: Terminal, color: SwiftTerm.Color) {}
    func setBackgroundColor(source: Terminal, color: SwiftTerm.Color) {}
    func setCursorColor(source: Terminal, color: SwiftTerm.Color?) {}
    func getColors(source: Terminal) -> (foreground: SwiftTerm.Color, background: SwiftTerm.Color) {
        (SwiftTerm.Color(red8: 204, green8: 204, blue8: 204), SwiftTerm.Color(red8: 31, green8: 32, blue8: 35))
    }
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func clipboardCopy(source: Terminal, content: Data) {}
    func clipboardRead(source: Terminal) -> Data? { nil }
    func notify(source: Terminal, title: String, body: String) {}
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
    func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {}
    func mouseModeChanged(source: Terminal) {}
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
}

final class TermPage: ModePage, LocalProcessDelegate, TerminalViewDelegate {
    private let history = HistoryList()
    private let talkScroll: FadeScroll
    private let talk: Transcript
    private let box = InputBox()
    private let whereLabel = label("", Fonts.words(11.2), NSColor(white: 1, alpha: 0.4))
    private let hintsLabel = NSTextField(wrappingLabelWithString: "")
    private let screen: TerminalScreen

    // typed in at once: what is typed before the shell is ready waits for it (the terminal keeps it)
    override var input: InputBox? { mode != .plain && !full ? box : nil }

    private var process: LocalProcess?
    private enum Mode { case starting, chat, plain }
    private var mode = Mode.starting
    private var running = false
    private var full = false
    private var blocks: [Block] = []
    private var nextId = 1
    private var sink = Sink()

    private var cwd = NSHomeDirectory()
    private let home = NSHomeDirectory()
    private var shellPath = ""
    private var place: String {
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    private var commands: [String] = []
    private var historyAt = -1
    private var draft = ""

    private static let sizes = (min: CGFloat(9), max: CGFloat(28), plain: CGFloat(14))
    private var fontSize: CGFloat = 14

    // the sessions: this one, live, and the ones before
    private var sessionId = Date().timeIntervalSince1970 * 1000
    private var started = Date().timeIntervalSince1970 * 1000
    private var past: [[String: Any]] = []

    /// --render: the user's own zsh files (and history) left alone, a folder of its own in their place
    static var userFiles: String?

    private var pending = ""
    private var ready = false
    private var startup = ""
    private var held: [UInt8] = []
    private var redraw: DispatchWorkItem?

    override init(frame: NSRect) {
        (talkScroll, talk) = Transcript.make()
        screen = TerminalScreen(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init(frame: frame)
        if let n = Saved.get("font-size").flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), n >= 9, n <= 28 {
            fontSize = CGFloat(n)
        }
        addSubview(title)
        history.pick = { [weak self] id in self?.pick(id) }
        history.fresh = { [weak self] in self?.newSession() }
        addSubview(history)
        talk.onWidth = { [weak self] _ in self?.render() }
        addSubview(talkScroll)
        hintsLabel.font = Fonts.words(12)
        hintsLabel.textColor = NSColor(white: 1, alpha: 0.48)
        hintsLabel.maximumNumberOfLines = 4
        addSubview(hintsLabel)
        addSubview(whereLabel)
        box.size = fontSize
        box.onKey = { [weak self] e in self?.typed(e) ?? false }
        box.onHeight = { [weak self] in self?.needsLayout = true }
        addSubview(box)

        screen.terminalDelegate = self
        screen.sendBytes = { [weak self] b in self?.send(b) }
        screen.font = Fonts.mono(fontSize)
        screen.installColors(terminalColors())
        screen.nativeForegroundColor = Ink.text
        screen.nativeBackgroundColor = .clear
        screen.caretColor = Ink.text
        screen.optionAsMetaKey = false
        screen.isHidden = true
        addSubview(screen)
        past = stored()
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── the shell ──

    override func start() {
        layoutSubtreeIfNeeded()
        tick("  term: laid out")
        commands = zshHistory()
        tick("  term: zsh history read")
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ReTerm"
        // opened from the Dock an app has no LANG: without it the shell can't write anything but ASCII
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        var marked = false
        if (shell as NSString).lastPathComponent == "zsh", let dir = zshFiles() {
            env["RETERM_USER_ZDOTDIR"] = Self.userFiles ?? env["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home
            env["ZDOTDIR"] = dir
            marked = true
        }
        let p = LocalProcess(delegate: self, dispatchQueue: .main)
        process = p
        p.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0)=\($1)" }, currentDirectory: home)
        sink.send = { [weak self] b in self?.send(b) }
        if !marked { plainTerminal() } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.plainTerminal() }
        }
    }

    /// ReTerm's zsh files: the user's own are read through them, and the marks around each command added
    private func zshFiles() -> String? {
        let dir = Saved.dir.appendingPathComponent("zsh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["zshenv", "zprofile", "zshrc", "zlogin"] {
            guard let src = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "zsh"),
                  let text = try? String(contentsOf: src, encoding: .utf8) else { return nil }
            try? text.write(to: dir.appendingPathComponent("." + name), atomically: true, encoding: .utf8)
        }
        return dir.path
    }

    /// no marks, or none in time: a plain terminal, with what the shell wrote meanwhile
    private func plainTerminal() {
        guard mode == .starting else { return }
        mode = .plain
        screen.feed(text: startup)
        startup = ""
        needsLayout = true
        if active { window?.makeFirstResponder(screen) }
    }

    override func end() {
        if let p = process, p.running { kill(p.shellPid, SIGHUP) }
        process = nil
    }

    private func send(_ bytes: [UInt8]) {
        process?.send(data: bytes[...])
    }

    private func send(_ text: String) { send(Array(text.utf8)) }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        // the shell ended: the window closes
        DispatchQueue.main.async { [weak self] in
            guard let self, self.process != nil else { return }
            self.process = nil
            self.window?.close()
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        held.append(contentsOf: slice)
        // a character the read cut in two: its start kept for the next
        var whole = held.count
        var back = 0
        while back < min(3, held.count) {
            let b = held[held.count - 1 - back]
            if b & 0xC0 == 0x80 { back += 1; continue }
            if b & 0x80 != 0 {
                let need = b & 0xE0 == 0xC0 ? 2 : b & 0xF0 == 0xE0 ? 3 : 4
                if back + 1 < need { whole = held.count - 1 - back }
            }
            break
        }
        let text = String(decoding: held[..<whole], as: UTF8.self)
        held.removeFirst(whole)
        if !text.isEmpty { received(text) }
    }

    func getWindowSize() -> winsize {
        let t = screen.getTerminal()
        return winsize(ws_row: UInt16(max(1, t.rows)), ws_col: UInt16(max(1, t.cols)), ws_xpixel: 0, ws_ypixel: 0)
    }

    // the window resized (or tiled by ReDesk): as many characters as now fit
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let p = process, p.running else { return }
        var size = winsize(ws_row: UInt16(max(1, newRows)), ws_col: UInt16(max(1, newCols)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(p.childfd, TIOCSWINSZ, &size)
        for b in blocks { b.live?.resize(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { send(Array(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // ── what the shell writes ──

    /// the shell's marks: OSC 133 (A ready, C a command starts, D done), 7 where, 6973 its PATH
    private func mark(_ body: String) {
        if body.hasPrefix("133;") {
            let parts = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            let kind = parts.count > 1 ? parts[1] : ""
            let arg = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            if kind == "A" {
                tick("  term: shell ready (its first prompt)")
                if mode == .starting {
                    mode = .chat
                    startup = ""
                    needsLayout = true
                    if active { box.focus() }
                }
                ready = true
            } else if kind == "C" {
                startBlock()
            } else if kind == "D" && ready && running {
                finishBlock(arg)
            } else if kind == "D" && ready, let last = blocks.last, last.status == nil, last.live == nil {
                last.status = arg
                render()
            }
        } else if body.hasPrefix("7;") {
            var url = String(body.dropFirst(2))
            if url.hasPrefix("file://") {
                url = String(url.dropFirst(7))
                if let slash = url.firstIndex(of: "/") { url = String(url[slash...]) }
            }
            if !url.isEmpty { cwd = url.removingPercentEncoding ?? url }
            showWhere()
        } else if body.hasPrefix("6973;") {
            shellPath = String(body.dropFirst(5))
        }
    }

    private static let alt = try! NSRegularExpression(pattern: "\u{1b}\\[\\?(?:1049|1047|47)([hl])")

    /// text for where it goes now: the screen, the live answer, or nowhere (the shell's own prompt)
    private func route(_ text: String) {
        if text.isEmpty { return }
        if mode == .plain { return screen.feed(text: text) }
        if mode == .starting {
            startup += text
            return
        }
        guard running else { return }
        var rest = text
        while !rest.isEmpty {
            let ns = rest as NSString
            let m = Self.alt.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length))
            let on = m.map { ns.substring(with: $0.range(at: 1)) == "h" } ?? false
            let cut = m.map { $0.range.location + (on ? 0 : $0.range.length) } ?? ns.length
            let before = ns.substring(to: cut)
            if full { screen.feed(text: before) } else if let live = blocks.last?.live {
                live.feed(text: before)
                scheduleRender()
            }
            guard let m else { break }
            if on {
                enterFull()
                screen.feed(text: ns.substring(with: m.range))
            } else {
                leaveFull()
            }
            rest = ns.substring(from: m.range.location + m.range.length)
        }
    }

    /// what the shell wrote: its marks taken out (never cut in two), the rest routed
    private func received(_ chunk: String) {
        let s = pending + chunk
        pending = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard let j = s.range(of: "\u{1b}]", range: i..<s.endIndex) else {
                route(String(s[i...]))
                break
            }
            let bel = s.range(of: "\u{07}", range: j.upperBound..<s.endIndex)
            let st = s.range(of: "\u{1b}\\", range: j.upperBound..<s.endIndex)
            let end: Range<String.Index>?
            switch (bel, st) {
            case let (b?, t?): end = b.lowerBound < t.lowerBound ? b : t
            case let (b?, nil): end = b
            case let (nil, t?): end = t
            default: end = nil
            }
            guard let end else {
                route(String(s[i..<j.lowerBound]))
                // the mark goes on in the next piece (a broken one is let through)
                if s.distance(from: j.lowerBound, to: s.endIndex) < 8192 { pending = String(s[j.lowerBound...]) } else { route(String(s[j.lowerBound...])) }
                break
            }
            let body = String(s[j.upperBound..<end.lowerBound])
            if body.hasPrefix("133;") || body.hasPrefix("7;") || body.hasPrefix("6973;") {
                route(String(s[i..<j.lowerBound]))
                mark(body)
            } else {
                route(String(s[i..<end.upperBound]))
            }
            i = end.upperBound
        }
    }

    // ── the answers while they come ──

    private func newTerminal() -> Terminal {
        let t = screen.getTerminal()
        let term = Terminal(delegate: sink, options: TerminalOptions(cols: max(1, t.cols), rows: max(1, t.rows), scrollback: 5000))
        return term
    }

    private func startBlock() {
        if blocks.last == nil || blocks.last!.status != nil || blocks.last!.live != nil || !blocks.last!.html.isEmpty {
            blocks.append(Block(id: nextId, command: nil))
            nextId += 1
        }
        blocks.last!.live = newTerminal()
        running = true
        showWhere()
        render()
    }

    private func finishBlock(_ status: Int) {
        if full { leaveFull() }
        running = false
        showWhere()
        guard let block = blocks.last, let live = block.live else {
            if let last = blocks.last, last.status == nil { last.status = status }
            render()
            return
        }
        redraw?.cancel()
        block.html = toHTML(live)
        block.status = status
        block.live = nil
        let words = (block.command ?? "").trimmingCharacters(in: .whitespaces)
        if words == "clear" || words == "reset" { newSession() } else { keepSession() }
        render(stick: true)
        if active { box.focus() }
    }

    private func scheduleRender() {
        guard redraw == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.redraw = nil
            self?.renderLive()
        }
        redraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // ── a program with the whole window ──

    private func enterFull() {
        full = true
        blocks.last?.fullscreen = true
        screen.getTerminal().resetToInitialState()
        needsLayout = true
        window?.makeFirstResponder(screen)
    }

    private func leaveFull() {
        full = false
        needsLayout = true
        if active { box.focus() }
    }

    // ── the conversation drawn ──

    private var said: NSParagraphStyle!

    private func pieces() -> (all: [NSAttributedString], live: Int?) {
        let width = talk.bounds.width
        var out: [NSAttributedString] = []
        var live: Int?
        let small = Fonts.words(fontSize * 0.85)
        for (n, b) in blocks.enumerated() {
            if let command = b.command {
                let p = paragraph(plain(command), font: Fonts.words(fontSize), color: Ink.text.withAlphaComponent(b.status == nil && running && n == blocks.count - 1 ? 0.45 : 0.8),
                                  align: .right, lineHeight: 1.25, before: out.isEmpty ? 0 : 18, indentLeft: width * 0.2)
                out.append(p)
            }
            if b.live != nil || !b.html.isEmpty {
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = fontSize * 1.25
                style.maximumLineHeight = fontSize * 1.25
                style.paragraphSpacingBefore = out.isEmpty ? 0 : 10
                style.lineBreakMode = .byCharWrapping
                let html = b.live.map(toHTML) ?? b.html
                if b.live != nil { live = out.count }
                let a = answer(html, size: fontSize, paragraph: style)
                if a.length == 0 && b.live != nil { a.append(paragraph(" ", font: Fonts.mono(fontSize), lineHeight: 1.25)) }
                if a.length > 0 { out.append(a) } else if b.live != nil { out.append(paragraph("", font: small, lineHeight: 1.25)) }
            } else if b.fullscreen {
                out.append(paragraph("⋯", font: small, color: NSColor(white: 1, alpha: 0.4), lineHeight: 1.25, before: 10))
            }
            if let s = b.status, s != 0 {
                out.append(paragraph("✕ \(s)", font: small, color: NSColor(white: 1, alpha: 0.4), lineHeight: 1.25, before: 4))
            }
        }
        return (out, live)
    }

    private func render(stick: Bool = false) {
        talk.set(pieces().all, stick: stick)
        title.stringValue = sessionTitle(blocks.map(\.command), place)
        refreshHistory()
    }

    /// the live answer only, as it comes
    private func renderLive() {
        let (all, live) = pieces()
        if let live, all.count == talk.segments.count { talk.update(live, all[live]) } else { talk.set(all) }
    }

    private func showWhere() {
        whereLabel.stringValue = place + (running ? " ⋯" : "")
    }

    // ── the sessions ──

    private func stored() -> [[String: Any]] {
        (Saved.json("sessions") as? [[String: Any]]) ?? []
    }

    private func kept(_ b: Block) -> [String: Any] {
        var html = b.html
        if html.count > 100_000, let cut = html.dropFirst(html.count - 100_000).firstIndex(of: "\n") {
            html = String(html[html.index(after: cut)...])
        }
        return ["command": b.command as Any, "html": html, "status": b.status as Any, "fullscreen": b.fullscreen]
    }

    /// this session written over what is kept (the other windows' sessions kept too)
    private func keepSession() {
        let done = blocks.filter { $0.live == nil && ($0.command != nil || !$0.html.isEmpty) }
        var all = stored().filter { ($0["id"] as? Double) != sessionId }
        if done.contains(where: { $0.command != nil }) {
            all.insert(["id": sessionId, "started": started, "last": Date().timeIntervalSince1970 * 1000, "place": place, "cwd": cwd,
                        "blocks": done.map(kept)], at: 0)
        }
        all.sort { ($0["last"] as? Double ?? 0) > ($1["last"] as? Double ?? 0) }
        all = Array(all.prefix(100))
        func size(_ a: [[String: Any]]) -> Int { (try? JSONSerialization.data(withJSONObject: a))?.count ?? 0 }
        while all.count > 1 && size(all) > 2_500_000 { all.removeLast() }
        Saved.setJSON("sessions", all)
        past = all.filter { ($0["id"] as? Double) != sessionId }
        refreshHistory()
    }

    /// ⌘K: this session kept on the left, a new one begun (a command running goes on in it)
    private func newSession() {
        if !blocks.contains(where: { $0.command != nil }) { return box.focus() }
        keepSession()
        blocks = blocks.filter { $0.live != nil }
        sessionId = Date().timeIntervalSince1970 * 1000
        started = sessionId
        past = stored().filter { ($0["id"] as? Double) != sessionId }
        render(stick: true)
        box.focus()
    }

    private func sessionTitle(_ commands: [String?], _ at: String) -> String {
        let first = commands.compactMap { $0 }.first ?? (at.isEmpty ? "~" : at)
        let line = String((first.components(separatedBy: "\n").first ?? "").prefix(80))
        return plain(line.isEmpty ? "~" : line)
    }

    private var listed: [(id: Double, started: Double, title: String, hint: String)] {
        var all = [(sessionId, started, sessionTitle(blocks.map(\.command), place), place)]
        for p in past {
            let cmds = ((p["blocks"] as? [[String: Any]]) ?? []).map { $0["command"] as? String }
            let at = p["place"] as? String ?? ""
            all.append((p["id"] as? Double ?? 0, p["started"] as? Double ?? 0, sessionTitle(cmds, at), "\(when(p["started"] as? Double ?? 0)) · \(at)"))
        }
        return all.sorted { $0.1 > $1.1 }
    }

    private func refreshHistory() {
        let fresh = !blocks.contains { $0.command != nil }
        history.items = listed.filter { $0.id != sessionId || !fresh }.map { Item(id: String($0.id), title: $0.title, hint: $0.hint) }
        history.shown = String(sessionId)
        history.freshShown = fresh
    }

    /// a session before, gone on with: its commands and answers here again, the shell where it was
    private func pick(_ id: String) {
        guard let n = Double(id), let session = past.first(where: { ($0["id"] as? Double) == n }) else { return box.focus() }
        keepSession()
        let runningBlocks = blocks.filter { $0.live != nil }
        blocks = ((session["blocks"] as? [[String: Any]]) ?? []).map { k in
            let b = Block(id: nextId, command: k["command"] as? String)
            nextId += 1
            b.html = k["html"] as? String ?? ""
            b.status = k["status"] as? Int
            b.fullscreen = k["fullscreen"] as? Bool ?? false
            return b
        } + runningBlocks
        sessionId = n
        started = session["started"] as? Double ?? n
        past = stored().filter { ($0["id"] as? Double) != sessionId }
        let at = session["place"] as? String ?? ""
        let folder = session["cwd"] as? String ?? (at.hasPrefix("~") ? home + at.dropFirst() : at)
        // a cd of its own, with no message (its answer, none, not kept)
        if !folder.isEmpty && folder != cwd && !running && mode == .chat { send(" cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'\r") }
        render(stick: true)
        box.focus()
    }

    /// ⇧↑ / ⇧↓: the session above / below on the left
    private func step(_ by: Int) {
        let all = listed
        guard let at = all.firstIndex(where: { $0.id == sessionId }) else { return }
        let next = all[min(all.count - 1, max(0, at + by))]
        if next.id != sessionId { pick(String(next.id)) }
    }

    // ── the line to type ──

    private func submit() {
        let text = box.string
        if running || mode == .plain {
            // to the program running: a line it reads
            send(text + "\r")
            box.string = ""
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blocks.append(Block(id: nextId, command: text))
        nextId += 1
        if commands.last != text { commands.append(text) }
        historyAt = -1
        box.string = ""
        hints([])
        // more than a line: pasted whole, run as one
        send(text.contains("\n") ? "\u{1b}[200~\(text)\u{1b}[201~\r" : text + "\r")
        render(stick: true)
    }

    private func completeWord() {
        let s = box.string as NSString
        let caret = box.text.selectedRange().location
        let before = s.substring(to: caret)
        let wordRegex = try! NSRegularExpression(pattern: "(?:\\\\.|[^\\s\\\\])*$")
        let m = wordRegex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
        let word = m.map { (before as NSString).substring(with: $0.range) } ?? ""
        let head = String(before.dropLast(word.count))
        let lastPart = head.components(separatedBy: CharacterSet(charactersIn: "|;&")).last ?? ""
        let command = lastPart.trimmingCharacters(in: .whitespaces).isEmpty
        let items = completions(cwd: cwd, word: word, command: command, path: shellPath.isEmpty ? (ProcessInfo.processInfo.environment["PATH"] ?? "") : shellPath)
        guard var common = items.first else { return }
        for item in items { while !item.hasPrefix(common) { common.removeLast() } }
        let done = items.count == 1
        let put = done && !common.hasSuffix("/") ? common + " " : common
        let after = s.substring(from: caret)
        box.string = head + put + after
        box.text.setSelectedRange(NSRange(location: (head + put as NSString).length, length: 0))
        hints(done ? [] : items.prefix(60).map { item in
            let name = item.hasSuffix("/") ? String(item.dropLast()) : item
            return (name.components(separatedBy: "/").last ?? name) + (item.hasSuffix("/") ? "/" : "")
        })
    }

    private func hints(_ list: [String]) {
        hintsLabel.stringValue = list.joined(separator: "    ")
        hintsLabel.isHidden = list.isEmpty
        needsLayout = true
    }

    private func setSize(_ n: CGFloat) {
        fontSize = min(Self.sizes.max, max(Self.sizes.min, n))
        Saved.set("font-size", "\(Int(fontSize))")
        box.size = fontSize
        screen.font = Fonts.mono(fontSize)
        render()
        needsLayout = true
    }

    private func typed(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let isRunning = running || mode == .plain
        if e.keyCode != 48 { hints([]) }
        switch (e.keyCode, mods) {
        case (36, []), (76, []):
            submit()
        case (48, []) where !isRunning:
            completeWord()
        case (8, .control): // ⌃C
            if isRunning { send([0x03]) } else { box.string = "" }
        case (2, .control): // ⌃D
            if isRunning || box.string.isEmpty { send([0x04]) }
        case (6, .control) where isRunning: // ⌃Z
            send([0x1a])
        case (37, .control), (40, .command): // ⌃L, ⌘K
            newSession()
        case (126, .shift): step(-1)
        case (125, .shift): step(1)
        case (126, []) where box.caretOnFirstLine:
            guard !commands.isEmpty else { return false }
            if historyAt < 0 {
                draft = box.string
                historyAt = commands.count
            }
            historyAt = max(0, historyAt - 1)
            box.string = commands[historyAt]
        case (125, []) where historyAt >= 0 && box.caretOnLastLine:
            historyAt += 1
            if historyAt >= commands.count {
                historyAt = -1
                box.string = draft
            } else {
                box.string = commands[historyAt]
            }
        case (24, .command), (24, [.command, .shift]): setSize(fontSize + 1) // ⌘=
        case (27, .command): setSize(fontSize - 1)                          // ⌘-
        case (29, .command): setSize(Self.sizes.plain)                      // ⌘0
        default:
            return false
        }
        return true
    }

    /// --render: commands typed one after another, each when the shell is ready for it
    func typeForRender(_ list: [String]) {
        var left = list
        func next() {
            guard !left.isEmpty else { return }
            if running || mode == .plain {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { next() }
                return
            }
            box.string = left.removeFirst()
            submit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
        }
        next()
    }

    // ── shown ──

    override func shown() {
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.full || self.mode == .plain { self.window?.makeFirstResponder(self.screen) } else { self.box.focus() }
        }
    }

    override func key(_ e: NSEvent) -> Bool {
        if window?.firstResponder === screen, screen.macKey(e) { return true }
        if window?.firstResponder === screen, e.modifierFlags.contains(.command) {
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            if mods == .command, [24, 27, 29].contains(e.keyCode) { return typed(e) }
        }
        // ⇧↑ / ⇧↓ from anywhere in the page
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .shift && (e.keyCode == 126 || e.keyCode == 125) && !full && mode == .chat && !box.focused {
            step(e.keyCode == 126 ? -1 : 1)
            return true
        }
        return false
    }

    override func leave() { if blocks.contains(where: { $0.command != nil }) { keepSession() } }

    // ── laid out ──

    override func layout() {
        super.layout()
        layoutTitle()
        let A = area
        let L = list
        history.isHidden = L == 0
        history.frame = NSRect(x: A.minX, y: A.minY, width: max(0, L - 40), height: A.height)
        let column = NSRect(x: A.minX + L, y: A.minY, width: max(0, A.width - L), height: A.height)
        box.maxHeight = bounds.height * 0.4
        let boxH = box.height
        box.frame = NSRect(x: column.minX, y: column.maxY - boxH, width: column.width, height: boxH)
        let whereH: CGFloat = 18
        whereLabel.frame = NSRect(x: column.minX, y: box.frame.minY - 4 - whereH, width: column.width, height: whereH)
        var top = whereLabel.frame.minY
        if !hintsLabel.isHidden && !hintsLabel.stringValue.isEmpty {
            hintsLabel.preferredMaxLayoutWidth = column.width
            let h = min(hintsLabel.fittingSize.height, 12 * 8)
            hintsLabel.frame = NSRect(x: column.minX, y: top - 8 - h, width: column.width, height: h)
            top = hintsLabel.frame.minY
        }
        talkScroll.frame = NSRect(x: column.minX, y: column.minY, width: column.width, height: max(0, top - 6 - column.minY))
        talk.frame.size.width = talkScroll.contentSize.width

        // the program with the whole column; a plain terminal the whole area; the measure of the window meanwhile
        let showScreen = full || mode == .plain
        screen.frame = mode == .plain ? A : column
        screen.isHidden = !showScreen
        for v in [talkScroll, box, whereLabel, hintsLabel, history, title] as [NSView] {
            v.alphaValue = showScreen ? 0 : 1
        }
        if mode == .plain { history.isHidden = true }
    }
}

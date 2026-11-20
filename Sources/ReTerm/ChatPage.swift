import AppKit

// CHAT: a conversation with an LLM, as TERM's with the shell: what is said on the right, the answer under it
// as it comes. Through the programs installed and signed in (claude: Claude Code; codex: ChatGPT's): each
// message runs the program once, the conversation going on by its session until ⌘K starts a new one. They run
// in their own folder, with no tools: a conversation only. The ones before on the left, each to go on with;
// ⇧↑ / ⇧↓ the one above / below. Kept between launches.

private final class Message {
    let id: Int
    let me: Bool
    var text: String
    var provider: String?
    var coming = false
    var error: String?

    init(id: Int, me: Bool, text: String, provider: String? = nil) {
        self.id = id
        self.me = me
        self.text = text
        self.provider = provider
    }

    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "me": me, "text": text, "coming": false]
        if let provider { d["provider"] = provider }
        if let error { d["error"] = error }
        return d
    }
}

private final class Conversation {
    let id: Double
    let started: Double
    var last: Double
    var messages: [Message]
    var sessions: [String: String]

    init(id: Double, started: Double, last: Double, messages: [Message], sessions: [String: String]) {
        self.id = id
        self.started = started
        self.last = last
        self.messages = messages
        self.sessions = sessions
    }

    var json: [String: Any] {
        ["id": id, "started": started, "last": last, "messages": messages.map(\.json), "sessions": sessions]
    }

    static func from(_ d: [String: Any]) -> Conversation? {
        guard let id = (d["id"] as? NSNumber)?.doubleValue else { return nil }
        let messages = ((d["messages"] as? [[String: Any]]) ?? []).compactMap { m -> Message? in
            guard let mid = (m["id"] as? NSNumber)?.intValue else { return nil }
            let msg = Message(id: mid, me: m["me"] as? Bool ?? false, text: m["text"] as? String ?? "", provider: m["provider"] as? String)
            msg.error = m["error"] as? String
            return msg
        }
        return Conversation(id: id, started: (d["started"] as? NSNumber)?.doubleValue ?? id, last: (d["last"] as? NSNumber)?.doubleValue ?? id,
                            messages: messages, sessions: d["sessions"] as? [String: String] ?? [:])
    }
}

/// a program answering, line by line
private final class Answer {
    let process = Process()
    var buffer = Data()
    var errors = Data()
}

final class ChatPage: ModePage {
    private let history = HistoryList()
    private let talkScroll: FadeScroll
    private let talk: Transcript
    private let box = InputBox()
    private let who = Flipped()

    override var input: InputBox? { box }

    private static let names = ["claude": "CLAUDE", "codex": "CODEX"]
    private var conversations: [Conversation] = []
    private var shownId: Double = 0
    private var shownConversation: Conversation? { conversations.first { $0.id == shownId } }
    /// changed in this window since kept: what is written back (another window keeps its own)
    private var changed = Set<Double>()
    private var provider = "claude"
    private var available: [String] = []
    private var nextId = 1
    private var commands: [String] = []
    private var historyAt = -1
    private var draft = ""
    private var answering: Int?
    private var streamed = false
    private var answers: [Int: Answer] = [:]

    override init(frame: NSRect) {
        (talkScroll, talk) = Transcript.make()
        super.init(frame: frame)
        addSubview(title)
        history.pick = { [weak self] id in self?.show(Double(id) ?? 0) }
        history.fresh = { [weak self] in self?.fresh() }
        addSubview(history)
        talk.onWidth = { [weak self] _ in self?.render() }
        addSubview(talkScroll)
        addSubview(who)
        box.size = 14
        box.onKey = { [weak self] e in self?.typed(e) ?? false }
        box.onHeight = { [weak self] in self?.needsLayout = true }
        addSubview(box)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func start() {
        load()
        // the ones installed, found as the user's shell finds them
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "for c in claude codex; do command -v $c >/dev/null 2>&1 && echo $c; done"]
            let out = Pipe()
            p.standardOutput = out
            p.standardInput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0 == "claude" || $0 == "codex" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.available = found
                if let first = found.first, !found.contains(self.provider) { self.provider = first }
                self.drawWho()
            }
        }
    }

    // ── kept ──

    private func stored() -> (conversations: [Conversation], provider: String?) {
        if let saved = Saved.json("chats") as? [String: Any], let list = saved["conversations"] as? [[String: Any]] {
            return (list.compactMap(Conversation.from), saved["provider"] as? String)
        }
        // the one conversation of before: the first of the history
        if let old = Saved.json("chat") as? [String: Any], let messages = old["messages"] as? [[String: Any]], !messages.isEmpty {
            let now = Date().timeIntervalSince1970 * 1000 - 1
            if let c = Conversation.from(["id": now, "started": now, "last": now, "messages": messages, "sessions": old["sessions"] ?? [:]]) {
                return ([c], old["provider"] as? String)
            }
        }
        return ([], nil)
    }

    private func load() {
        let saved = stored()
        conversations = saved.conversations
        if Saved.get("chats") == nil { for c in conversations { changed.insert(c.id) } }
        provider = saved.provider ?? "claude"
        nextId = (conversations.flatMap { $0.messages.map(\.id) }.max() ?? 0) + 1
        commands = conversations.sorted { $0.last < $1.last }.flatMap { $0.messages.filter(\.me).map(\.text) }
        fresh()
    }

    /// this window's changes written over what is kept (another window's kept too)
    private func keep() {
        let saved = stored().conversations.filter { !changed.contains($0.id) }
        let mine = conversations.filter { changed.contains($0.id) && !$0.messages.isEmpty }
        let all = Array((saved + mine).sorted { $0.last > $1.last }.prefix(200))
        Saved.setJSON("chats", ["conversations": all.map(\.json), "provider": provider])
        Saved.remove("chat")
        changed.removeAll()
        // what another window said meanwhile: on the left here too
        for c in all where !conversations.contains(where: { $0.id == c.id }) { conversations.append(c) }
        refreshHistory()
    }

    private func titleOf(_ c: Conversation) -> String {
        let first = c.messages.first { $0.me }?.text ?? "NOVA"
        return plain(String((first.components(separatedBy: "\n").first ?? "").prefix(80)))
    }

    private var listed: [Conversation] {
        conversations.filter { !$0.messages.isEmpty || $0.id == shownId }
            .sorted { ($0.messages.isEmpty ? 0 : 1, -$0.last) < ($1.messages.isEmpty ? 0 : 1, -$1.last) }
    }

    private func refreshHistory() {
        history.items = listed.filter { !$0.messages.isEmpty }.map { Item(id: String($0.id), title: titleOf($0), hint: when($0.started)) }
        history.shown = String(shownId)
        history.freshShown = shownConversation?.messages.isEmpty ?? false
        title.stringValue = shownConversation.map(titleOf) ?? ""
    }

    // ── a little markdown: code blocks, `code`, **bold**, headings ──

    private func markdown(_ text: String, into out: NSMutableAttributedString, style: NSParagraphStyle) {
        let font = Fonts.words(14)
        let parts = plain(text).components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                // a block of code: its first line (the language) left out, a little in from the edge
                var code = part
                if let nl = code.firstIndex(of: "\n") { code = String(code[code.index(after: nl)...]) }
                if code.hasSuffix("\n") { code.removeLast() }
                let p = style.mutableCopy() as! NSMutableParagraphStyle
                p.firstLineHeadIndent = 14
                p.headIndent = 14
                p.paragraphSpacingBefore = 6
                p.paragraphSpacing = 6
                if let last = out.string.last, last != "\n" { out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style])) }
                out.append(NSAttributedString(string: code + "\n", attributes: [.font: Fonts.mono(13), .foregroundColor: NSColor(white: 1, alpha: 0.72), .paragraphStyle: p]))
                continue
            }
            inline(part, into: out, font: font, style: style)
        }
    }

    private static let inlinePattern = try! NSRegularExpression(pattern: "`([^`\\n]+)`|\\*\\*([^*\\n]+)\\*\\*|^#{1,6} (.*)$", options: [.anchorsMatchLines])

    private func inline(_ text: String, into out: NSMutableAttributedString, font: NSFont, style: NSParagraphStyle) {
        let ns = text as NSString
        var last = 0
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Ink.text, .paragraphStyle: style]
        for m in Self.inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: last, length: m.range.location - last)), attributes: base))
            if m.range(at: 1).location != NSNotFound {
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 1)), attributes: base.merging([.font: Fonts.mono(13), .foregroundColor: NSColor(white: 1, alpha: 0.64)]) { $1 }))
            } else {
                let r = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
                out.append(NSAttributedString(string: ns.substring(with: r), attributes: base.merging([.strokeWidth: -2.5, .strokeColor: Ink.text]) { $1 }))
            }
            last = m.range.location + m.range.length
        }
        out.append(NSAttributedString(string: ns.substring(from: last), attributes: base))
    }

    private func render(stick: Bool = false) {
        let width = talk.bounds.width
        var out: [NSAttributedString] = []
        for m in shownConversation?.messages ?? [] {
            if m.me {
                out.append(paragraph(plain(m.text), font: Fonts.words(14), align: .right, lineHeight: 1.5, before: out.isEmpty ? 0 : 22, indentLeft: width * 0.2))
            } else {
                let p = NSMutableParagraphStyle()
                p.minimumLineHeight = 21
                p.maximumLineHeight = 21
                p.paragraphSpacingBefore = out.isEmpty ? 0 : 14
                p.tailIndent = -width * 0.08
                let a = NSMutableAttributedString()
                markdown(m.text, into: a, style: p)
                if m.coming && m.text.isEmpty { a.append(NSAttributedString(string: "⋯", attributes: [.font: Fonts.words(14), .foregroundColor: NSColor(white: 1, alpha: 0.4), .paragraphStyle: p])) }
                if a.length == 0 { a.append(NSAttributedString(string: " ", attributes: [.font: Fonts.words(14), .paragraphStyle: p])) }
                out.append(a)
                if let error = m.error {
                    out.append(paragraph("✕ " + error, font: Fonts.words(12), color: NSColor(white: 1, alpha: 0.4), lineHeight: 1.5, before: 6))
                }
            }
        }
        talk.set(out, stick: stick)
        refreshHistory()
    }

    // ── who answers: CLAUDE, CODEX (the one chosen underlined); Tab the other ──

    private func drawWho() {
        who.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        if available.isEmpty {
            let l = label("claude / codex: not installed", Fonts.words(11.2), NSColor(white: 1, alpha: 0.4))
            l.sizeToFit()
            l.frame.origin = NSPoint(x: 0, y: 2)
            who.addSubview(l)
            x = l.frame.maxX
        }
        for name in available {
            let word = Self.names[name] ?? name.uppercased()
            let b = WhoButton(word, chosen: name == provider) { [weak self] in self?.choose(name) }
            let w = b.intrinsicContentSize.width
            b.frame = NSRect(x: x, y: 0, width: w, height: 20)
            who.addSubview(b)
            x += w + 18
        }
        if answering != nil {
            let busy = label("⋯", Fonts.words(11.2), NSColor(white: 1, alpha: 0.4))
            busy.sizeToFit()
            busy.frame.origin = NSPoint(x: x, y: 2)
            who.addSubview(busy)
        }
    }

    private func choose(_ name: String) {
        provider = name
        keep()
        drawWho()
        box.focus()
    }

    // ── talking ──

    private func send() {
        let text = box.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, answering == nil, available.contains(provider), let conversation = shownConversation else { return }
        conversation.messages.append(Message(id: nextId, me: true, text: text))
        let reply = Message(id: nextId + 1, me: false, text: "", provider: provider)
        reply.coming = true
        nextId += 2
        conversation.messages.append(reply)
        conversation.last = Date().timeIntervalSince1970 * 1000
        changed.insert(conversation.id)
        if commands.last != text { commands.append(text) }
        historyAt = -1
        box.string = ""
        answering = reply.id
        streamed = false
        render(stick: true)
        drawWho()
        keep()
        run(reply.id, provider: provider, prompt: text, session: conversation.sessions[provider])
    }

    /// one message to `provider`, going on with `session` if there is one
    private func run(_ id: Int, provider: String, prompt: String, session: String?) {
        var args: [String]
        if provider == "claude" {
            args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", "", "--strict-mcp-config"]
            if let session, !session.isEmpty { args += ["--resume", session] }
        } else {
            args = ["exec"]
            if let session, !session.isEmpty { args += ["resume", session] }
            args += ["--skip-git-repo-check", "--json", "-"]
        }
        let dir = Saved.dir.appendingPathComponent("chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = Answer()
        let p = a.process
        // through the login shell: the PATH (nvm, Homebrew…) as in the terminal
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \"$@\"", "reterm", provider] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        // started from a Claude Code session, its own mark would stop claude here
        env.removeValue(forKey: "CLAUDECODE")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.output(id, data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            DispatchQueue.main.async { a.errors.append(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                self?.output(id, rest)
                if !a.buffer.isEmpty { self?.line(id, String(decoding: a.buffer, as: UTF8.self)) }
                let errs = String(decoding: a.errors, as: UTF8.self).split(separator: "\n").suffix(6).joined(separator: "\n")
                self?.finish(id, proc.terminationStatus == 0 ? "" : (errs.isEmpty ? "exit \(proc.terminationStatus)" : errs))
            }
        }
        answers[id] = a
        do {
            try p.run()
            // the message on its input, so nothing in it is taken for an option
            stdin.fileHandleForWriting.write(Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
        } catch {
            finish(id, error.localizedDescription)
        }
    }

    private func output(_ id: Int, _ data: Data) {
        guard let a = answers[id], !data.isEmpty else { return }
        a.buffer.append(data)
        while let nl = a.buffer.firstIndex(of: 10) {
            let lineData = a.buffer[a.buffer.startIndex..<nl]
            a.buffer.removeSubrange(a.buffer.startIndex...nl)
            line(id, String(decoding: lineData, as: UTF8.self))
        }
    }

    private func byId(_ id: Int) -> (Message, Conversation)? {
        for c in conversations { if let m = c.messages.first(where: { $0.id == id }) { return (m, c) } }
        return nil
    }

    /// a line the program wrote
    private func line(_ id: Int, _ text: String) {
        guard let (message, conversation) = byId(id) else { return }
        changed.insert(conversation.id)
        guard let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            // not its JSON (a program that writes plain text)
            if message.provider != "claude" { message.text += text + "\n" }
            return renderIfShown(conversation)
        }
        if message.provider == "claude" {
            if let s = event["session_id"] as? String { conversation.sessions["claude"] = s }
            let type = event["type"] as? String
            let inner = event["event"] as? [String: Any]
            let delta = inner?["delta"] as? [String: Any]
            if type == "stream_event", inner?["type"] as? String == "content_block_delta", delta?["type"] as? String == "text_delta" {
                message.text += delta?["text"] as? String ?? ""
                streamed = true
            } else if type == "stream_event", inner?["type"] as? String == "content_block_start", !message.text.isEmpty, !message.text.hasSuffix("\n") {
                message.text += "\n\n"
            } else if type == "assistant", !streamed {
                let content = ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                message.text += content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            } else if type == "result", event["is_error"] as? Bool == true {
                message.error = "\(event["result"] ?? "Error")"
            }
        } else {
            // codex exec --json: the thread, and each message as it is done
            if let t = event["thread_id"] as? String { conversation.sessions["codex"] = t }
            let item = (event["item"] ?? event["msg"]) as? [String: Any]
            let type = event["type"] as? String
            if type == "item.completed", item?["type"] as? String == "agent_message", let words = item?["text"] as? String, !words.isEmpty {
                message.text += (message.text.isEmpty ? "" : "\n\n") + words
            } else if type == "error" || type == "turn.failed" {
                message.error = (event["message"] as? String) ?? ((event["error"] as? [String: Any])?["message"] as? String) ?? "Error"
            }
        }
        renderIfShown(conversation)
    }

    private func renderIfShown(_ c: Conversation) {
        if c.id == shownId { render() }
    }

    private func finish(_ id: Int, _ error: String) {
        answers[id] = nil
        if let (message, conversation) = byId(id) {
            changed.insert(conversation.id)
            message.coming = false
            if !error.isEmpty && message.text.isEmpty { message.error = message.error ?? error }
        }
        if answering == id { answering = nil }
        keep()
        render()
        drawWho()
    }

    private func stop() {
        if let id = answering { answers[id]?.process.terminate() }
    }

    /// a new conversation: the one before kept on the left (one said nothing in: it is the new one)
    private func fresh() {
        if let s = shownConversation, s.messages.isEmpty { return box.focus() }
        let now = Date().timeIntervalSince1970 * 1000
        conversations.append(Conversation(id: now, started: now, last: now, messages: [], sessions: [:]))
        shownId = now
        render(stick: true)
        box.focus()
    }

    private func show(_ id: Double) {
        guard id != shownId else { return }
        // the new one said nothing in: no need of it
        if let s = shownConversation, s.messages.isEmpty { conversations.removeAll { $0.id == shownId } }
        shownId = id
        render(stick: true)
        box.focus()
    }

    /// ⇧↑ / ⇧↓: the conversation above / below on the left
    private func step(_ by: Int) {
        let all = listed
        guard let at = all.firstIndex(where: { $0.id == shownId }) else { return }
        show(all[min(all.count - 1, max(0, at + by))].id)
    }

    private func typed(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (e.keyCode, mods) {
        case (36, []), (76, []):
            send()
        case (8, .control), (53, []): // ⌃C, Esc: the answer stopped
            if answering != nil { stop() } else if mods == .control { box.string = "" } else { return false }
        case (40, .command), (37, .control): // ⌘K, ⌃L
            fresh()
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
        case (48, []) where available.count > 1: // Tab: the other one
            choose(available[((available.firstIndex(of: provider) ?? 0) + 1) % available.count])
        default:
            return false
        }
        return true
    }

    override func shown() {
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.box.focus()
            self?.talk.scrollToBottom()
        }
    }

    override func end() {
        for a in answers.values { a.process.terminate() }
    }

    override func layout() {
        super.layout()
        layoutTitle()
        let A = area, L = list
        history.isHidden = L == 0
        history.frame = NSRect(x: A.minX, y: A.minY, width: max(0, L - 40), height: A.height)
        let column = NSRect(x: A.minX + L, y: A.minY, width: max(0, A.width - L), height: A.height)
        box.maxHeight = bounds.height * 0.4
        let boxH = box.height
        box.frame = NSRect(x: column.minX, y: column.maxY - boxH, width: column.width, height: boxH)
        who.frame = NSRect(x: column.minX, y: box.frame.minY - 6 - 20, width: column.width, height: 20)
        talkScroll.frame = NSRect(x: column.minX, y: column.minY, width: column.width, height: max(0, who.frame.minY - 6 - column.minY))
        talk.frame.size.width = talkScroll.contentSize.width
    }
}

/// CLAUDE, CODEX: a word to click, the one chosen underlined
private final class WhoButton: NSView {
    let word: String
    let chosen: Bool
    let action: () -> Void
    private var hover = false { didSet { needsDisplay = true } }

    init(_ word: String, chosen: Bool, _ action: @escaping () -> Void) {
        self.word = word
        self.chosen = chosen
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var text: NSAttributedString {
        var a: [NSAttributedString.Key: Any] = [.font: Fonts.buttons(11), .foregroundColor: NSColor(white: 1, alpha: 0.8 * (hover || chosen ? 1 : 0.75)), .kern: 3.3]
        if chosen {
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            a[.underlineColor] = Ink.text
        }
        return NSAttributedString(string: word, attributes: a)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.size().width) + 10, height: 20) }

    override func draw(_ dirtyRect: NSRect) { text.draw(at: NSPoint(x: 5, y: 3)) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

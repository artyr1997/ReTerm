import AppKit
import SwiftTerm

// The shell's side: the palette, the answers kept as text (HTML of a few spans, as the app always kept them)
// and read back, zsh's history, Tab's completions, the program with the whole window.

enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

// ── the ink's colours: quiet, as the paper's grey is (the night's) ──

let PALETTE: [String] = [
    "#3a3a3a", "#b0645e", "#7f9a70", "#b09a62", "#6f8aa8", "#9c7a99", "#6f9c98", "#a6a6a6",
    "#666666", "#c27a73", "#93ad84", "#c4ae76", "#86a0bc", "#b090ad", "#86b0ac", "#d0d0d0",
]

func hexColor(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

/// a 256-colour index past the 16: its colour, as CSS
func color256(_ code: Int) -> String {
    if code >= 232 {
        let v = 8 + (code - 232) * 10
        return "rgb(\(v),\(v),\(v))"
    }
    let n = code - 16
    let step = { (v: Int) in v > 0 ? 55 + v * 40 : 0 }
    return "rgb(\(step(n / 36)),\(step((n / 6) % 6)),\(step(n % 6)))"
}

// ── an answer as text: its colours (the 16 by the palette), bold, dim, italic, underline; lines the
// terminal wrapped joined again, so the text wraps with the window ──

private func css(_ c: Attribute.Color) -> String {
    switch c {
    case .ansi256(let code): return code < 16 ? "var(--c\(code))" : color256(Int(code))
    case .trueColor(let r, let g, let b): return String(format: "#%02x%02x%02x", r, g, b)
    default: return ""
    }
}

private func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func toHTML(_ term: Terminal) -> String {
    var lines: [String] = []
    var row = term.buffer.totalLinesTrimmed
    while let line = term.getScrollInvariantLine(row: row) {
        row += 1
        let count = line.count
        func blank(_ c: CharData) -> Bool {
            let ch = c.getCharacter()
            return ch == "\u{0}" || ch == " "
        }
        var end = count
        while end > 0 {
            let c = line[end - 1]
            if !blank(c) || c.width == 0 || css(c.attribute.bg) != "" || c.attribute.style.contains(.inverse) { break }
            end -= 1
        }
        var html = "", style = "", run = ""
        func flush() {
            guard !run.isEmpty else { return }
            html += style.isEmpty ? escapeHTML(run) : "<span style=\"\(style)\">\(escapeHTML(run))</span>"
            run = ""
        }
        for x in 0..<end {
            let c = line[x]
            if c.width == 0 { continue }
            let a = c.attribute
            var fg = css(a.fg), bg = css(a.bg)
            if a.style.contains(.inverse) { (fg, bg) = (bg.isEmpty ? "var(--bg)" : bg, fg.isEmpty ? "var(--text)" : fg) }
            var next = ""
            if !fg.isEmpty { next += "color:\(fg);" }
            if !bg.isEmpty { next += "background:\(bg);" }
            if a.style.contains(.bold) { next += "font-weight:700;" }
            if a.style.contains(.italic) { next += "font-style:italic;" }
            if a.style.contains(.dim) { next += "opacity:0.6;" }
            if a.style.contains(.underline) { next += "text-decoration:underline;" }
            if a.style.contains(.crossedOut) { next += "text-decoration:line-through;" }
            if a.style.contains(.invisible) { next += "visibility:hidden;" }
            if next != style {
                flush()
                style = next
            }
            let ch = c.getCharacter()
            run.append(ch == "\u{0}" ? " " : ch)
        }
        flush()
        if line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += html } else { lines.append(html) }
    }
    while lines.last == "" { lines.removeLast() }
    while lines.first == "" { lines.removeFirst() }
    return lines.joined(separator: "\n")
}

// ── and read back: the answer in its colours, in the terminal's lettering ──

private var styles: [String: [NSAttributedString.Key: Any]] = [:]

private func cssColor(_ v: String) -> NSColor? {
    let v = v.trimmingCharacters(in: .whitespaces)
    if v.hasPrefix("var(--c"), let n = Int(v.dropFirst(7).dropLast(1)), n >= 0, n < 16 { return hexColor(PALETTE[n]) }
    if v == "var(--bg)" { return Ink.paper }
    if v == "var(--text)" { return Ink.text }
    if v.hasPrefix("#") { return hexColor(v) }
    if v.hasPrefix("rgb(") {
        let parts = v.dropFirst(4).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 { return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1) }
    }
    return nil
}

private func attributes(_ style: String, size: CGFloat, base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
    let key = "\(size)|\(style)"
    if let a = styles[key] { return a.merging(base) { a, _ in a } }
    var a: [NSAttributedString.Key: Any] = [:]
    var color = Ink.text
    var bold = false
    for part in style.split(separator: ";") {
        let kv = part.split(separator: ":", maxSplits: 1).map { String($0) }
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "color": if let c = cssColor(kv[1]) { color = c }
        case "background": if let c = cssColor(kv[1]) { a[.backgroundColor] = c }
        case "font-weight": bold = true
        case "font-style": a[.obliqueness] = 0.18
        case "opacity": color = color.withAlphaComponent(color.alphaComponent * 0.6)
        case "text-decoration":
            if kv[1] == "underline" { a[.underlineStyle] = NSUnderlineStyle.single.rawValue } else { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        case "visibility": color = .clear
        default: break
        }
    }
    a[.foregroundColor] = color
    a[.font] = Fonts.mono(size, bold: bold)
    styles[key] = a
    return a.merging(base) { a, _ in a }
}

private let spans = try! NSRegularExpression(pattern: "<span style=\"([^\"]*)\">([^<]*)</span>|([^<]+)")

private func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
}

/// an answer kept as text, in its colours
func answer(_ html: String, size: CGFloat, paragraph: NSParagraphStyle) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    let base: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
    let ns = html as NSString
    for m in spans.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        if m.range(at: 3).location != NSNotFound {
            out.append(NSAttributedString(string: unescape(plain(ns.substring(with: m.range(at: 3)))), attributes: attributes("", size: size, base: base)))
        } else {
            out.append(NSAttributedString(string: unescape(plain(ns.substring(with: m.range(at: 2)))),
                                          attributes: attributes(ns.substring(with: m.range(at: 1)), size: size, base: base)))
        }
    }
    return out
}

// ── zsh's history: the commands typed before, oldest first, each once (where it was last) ──

func zshHistory() -> [String] {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history")
    guard let bytes = try? Data(contentsOf: url) else { return [] }
    // zsh "metafies" some bytes: 0x83 and the next one xor 32
    var plainBytes = [UInt8]()
    plainBytes.reserveCapacity(bytes.count)
    var it = bytes.makeIterator()
    while let b = it.next() {
        if b == 0x83 { if let n = it.next() { plainBytes.append(n ^ 32) } } else { plainBytes.append(b) }
    }
    let text = String(decoding: plainBytes, as: UTF8.self)
    var all: [String] = []
    var current = ""
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(raw)
        if current.isEmpty {
            // ": 1700000000:0;the command" (extended history), or just the command
            if line.hasPrefix(": "), let i = line.firstIndex(of: ";") { line = String(line[line.index(after: i)...]) }
            current = line
        } else {
            current += "\n" + line
        }
        // a line ending with a backslash goes on
        if current.hasSuffix("\\") {
            current.removeLast()
            continue
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { all.append(current) }
        current = ""
    }
    var seen = Set<String>()
    var kept: [String] = []
    for c in all.reversed() where seen.insert(c).inserted {
        kept.append(c)
        if kept.count >= 5000 { break }
    }
    return kept.reversed()
}

// ── Tab: what the word being typed can become. The first word of the line: the commands on the PATH (and
// folders); any other: the files and folders it starts. Each written whole, as it goes into the line ──

func completions(cwd: String, word: String, command: Bool, path: String) -> [String] {
    let special = Set(" '\"()&;|<>$`\\!*?[]#{}")
    let escape = { (name: String) -> String in name.map { special.contains($0) ? "\\\($0)" : String($0) }.joined() }
    var unescaped = ""
    var chars = word.makeIterator()
    while let c = chars.next() {
        if c == "\\" { if let n = chars.next() { unescaped.append(n) } } else { unescaped.append(c) }
    }
    var found = Set<String>()
    let fm = FileManager.default
    if command && !unescaped.contains("/") {
        for dir in path.split(separator: ":") {
            for name in (try? fm.contentsOfDirectory(atPath: String(dir))) ?? [] where name.hasPrefix(unescaped) {
                found.insert(escape(name))
            }
        }
    }
    // the folder it is in, as typed (kept), and the start of the name
    let folder = word.lastIndex(of: "/").map { String(word[...$0]) } ?? ""
    let start = unescaped.components(separatedBy: "/").last ?? ""
    let unescapedFolder = String(unescaped.dropLast(start.count))
    var base = URL(fileURLWithPath: cwd.isEmpty ? NSHomeDirectory() : cwd)
    if unescapedFolder.hasPrefix("~") {
        base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(unescapedFolder.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    } else if unescapedFolder.hasPrefix("/") {
        base = URL(fileURLWithPath: unescapedFolder)
    } else if !unescapedFolder.isEmpty {
        base = base.appendingPathComponent(unescapedFolder)
    }
    for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
        guard name.hasPrefix(start), !name.hasPrefix(".") || start.hasPrefix(".") else { continue }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: base.appendingPathComponent(name).path, isDirectory: &isDir)
        if command && !isDir.boolValue && folder.isEmpty { continue }
        found.insert(folder + escape(name) + (isDir.boolValue ? "/" : ""))
    }
    return Array(found.sorted().prefix(300))
}

// ── the program with the whole window (vim, htop, less…), and a plain terminal (another shell than zsh) ──

final class TerminalScreen: TerminalView {
    /// the Mac's keys a terminal on it is expected to know (TermPage.key): ⌘← ⌘→ ⌘⌫ ⌘K
    var sendBytes: (([UInt8]) -> Void)?

    func macKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods == .command else { return false }
        switch event.keyCode {
        case 123: sendBytes?([0x01])  // ⌘←: the line's start
        case 124: sendBytes?([0x05])  // ⌘→: its end
        case 51: sendBytes?([0x15])   // ⌘⌫: the line gone
        case 40: getTerminal().resetToInitialState() // ⌘K
        default: return false
        }
        return true
    }
}

/// the palette, for SwiftTerm
func terminalColors() -> [SwiftTerm.Color] {
    PALETTE.map { hex in
        var v: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        return SwiftTerm.Color(red8: UInt16((v >> 16) & 255), green8: UInt16((v >> 8) & 255), blue8: UInt16(v & 255))
    }
}

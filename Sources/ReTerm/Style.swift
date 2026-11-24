import AppKit
import CoreText

// The look: glass, as every Re app on the desk. The window is the system's blur of what is behind it, the
// words on it in the desk's white ink; the buttons in Noto Sans JP, the words in M PLUS 1p, the terminal's
// answers in Noto Sans Mono.

enum Ink {
    /// the words (as --text on glass)
    static let text = NSColor(white: 1, alpha: 0.8)
    /// lines, frames, quieter words (as --line)
    static let line = NSColor(white: 1, alpha: 0.5)
    /// what is written in something inked: a dark solid (as --bg)
    static let paper = NSColor(red: 0x1f / 255, green: 0x20 / 255, blue: 0x23 / 255, alpha: 1)
    /// the popups' pane over the blur
    static let pane = NSColor(white: 0, alpha: 0.32)
    /// a drawing's lines: the desk's white
    static let drawing = NSColor(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf4 / 255, alpha: 1)
}

enum Fonts {
    private static func descriptor(_ name: String, _ ext: String = "woff") -> CTFontDescriptor? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "fonts"),
              let all = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        return all.first
    }

    private static func cascade(_ first: CTFontDescriptor?, _ rest: [CTFontDescriptor?]) -> CTFontDescriptor? {
        guard let first else { return nil }
        let others = rest.compactMap { $0 }
        return others.isEmpty ? first : CTFontDescriptorCreateCopyWithAttributes(first, [kCTFontCascadeListAttribute: others] as CFDictionary)
    }

    private static let mplus = descriptor("MPLUS1p", "ttf")
    /// the emoji in one colour, the ink's (Noto Emoji), before the Mac's colour ones
    private static let emoji: [CTFontDescriptor?] = (0...11).map { descriptor("noto-emoji-\($0)-400-normal") }

    /// Noto Sans JP: its Latin letters, the Japanese ones after them
    private static let noto = cascade(descriptor("noto-sans-jp-latin-400-normal"), [descriptor("noto-sans-jp-japanese-400-normal")])

    /// the words: M PLUS 1p, the emoji in the ink
    private static let wordsFace = cascade(mplus, emoji)

    /// the terminal's answers: Noto Sans Mono (its columns stand), then M PLUS 1p, then the emoji
    private static func monoFace(_ weight: Int) -> CTFontDescriptor? {
        let parts = ["latin", "latin-ext", "cyrillic", "cyrillic-ext", "greek"].map { descriptor("noto-sans-mono-\($0)-\(weight)-normal") }
        return cascade(parts[0], Array(parts.dropFirst()) + [mplus] + emoji)
    }
    private static let monoRegular = monoFace(400)
    private static let monoBold = monoFace(700)

    private static var cache: [String: NSFont] = [:]

    private static func font(_ d: CTFontDescriptor?, _ key: String, _ size: CGFloat, fallback: NSFont) -> NSFont {
        let id = "\(key)-\(size)"
        if let f = cache[id] { return f }
        let f = d.map { CTFontCreateWithFontDescriptor($0, size, nil) as NSFont } ?? fallback
        cache[id] = f
        return f
    }

    /// the buttons' lettering
    static func buttons(_ size: CGFloat) -> NSFont {
        font(noto, "noto", size, fallback: .systemFont(ofSize: size, weight: .light))
    }

    /// the words
    static func words(_ size: CGFloat) -> NSFont {
        font(wordsFace, "words", size, fallback: .systemFont(ofSize: size))
    }

    /// the terminal's lettering, of one width
    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        font(bold ? monoBold : monoRegular, bold ? "mono-bold" : "mono", size, fallback: .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular))
    }
}

/// The emoji in one colour, the ink's: one asked to be drawn in colour (U+FE0F after it) would take the Mac's
/// colour emoji whatever the font; it is asked for as text instead (U+FE0E).
func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{FE0F}", with: "\u{FE0E}") }

// ── the desk's language: ReDesk's Settings › Language (English or Japanese) ──

final class Lang {
    static let shared = Lang()
    static let changed = Notification.Name("ReTerm.language")

    private(set) var japanese = false

    // four characters each, as the English words are four letters
    // four characters each, as the English words are four letters
    private let words: [String: String] = [
        "TERM": "端末画面", "CHAT": "人工知能", "FULL": "全画面化", "NOVA": "新規作成",
    ]

    private let texts: [String: String] = [
        "Search": "検索", "Delete": "削除",
    ]

    // The language turning, as on a departures board: each letter runs through others (Latin and katakana)
    // before it stops at its new one, the first soonest, the next a little later.
    private let pool = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private let step = 55.0, settle = 260.0, stagger = 110.0, length = 1200.0
    private var frame = -1
    private var timer: Timer?

    /// a button's word in the desk's language; `as` names it where the same word means another thing
    func t(_ word: String, as key: String? = nil) -> String {
        let target = japanese ? (words[key ?? word] ?? word) : word
        guard frame >= 0 else { return target }
        let elapsed = Double(frame) * step
        var out = ""
        for (i, letter) in target.enumerated() {
            if letter == " " || elapsed >= settle + Double(i) * stagger {
                out.append(letter)
                continue
            }
            var hash = Int32(truncatingIfNeeded: frame &* 31 &+ i &* 17)
            for unit in (key ?? word).utf16 { hash = hash &* 33 &+ Int32(unit) }
            out.append(pool[Int(hash.magnitude % UInt32(pool.count))])
        }
        return out
    }

    /// the popups' words (any length); {name} in them is filled from `values`
    func tx(_ text: String, _ values: [String: Any] = [:]) -> String {
        var out = japanese ? (texts[text] ?? text) : text
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: "\(value)") }
        return out
    }

    private func set(_ code: String, animate: Bool) {
        let ja = code == "ja"
        if animate && ja != japanese && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { turn() }
        japanese = ja
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func turn() {
        timer?.invalidate()
        frame = 0
        timer = Timer.scheduledTimer(withTimeInterval: step / 1000, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if Double(self.frame + 1) * self.step > self.length {
                self.frame = -1
                t.invalidate()
                self.timer = nil
            } else {
                self.frame += 1
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// once, at start: the language ReDesk keeps, and its word when it changes
    func follow() {
        set(UserDefaults(suiteName: "com.artursavytskyi.redesk")?.string(forKey: "language") ?? "en", animate: false)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.artursavytskyi.re.language"), object: nil, queue: .main) { [weak self] note in
            self?.set(note.object as? String ?? "en", animate: true)
        }
    }
}

func t(_ word: String, as key: String? = nil) -> String { Lang.shared.t(word, as: key) }
func tx(_ text: String, _ values: [String: Any] = [:]) -> String { Lang.shared.tx(text, values) }

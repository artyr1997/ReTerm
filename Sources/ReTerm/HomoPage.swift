import AppKit
import AVKit

// HOMO: conversations with people, through Telegram (TDLib, Telegram's own library: `brew install tdlib`).
// Signed in once (the app's api_id and api_hash from my.telegram.org, then the phone, its code, the password
// if there is one), it stays so: its database is kept in Application Support/…/telegram. The chats on the
// left, the one open on the right as TERM's and CHAT's: what I say on the right, theirs on the left, the line
// to type at the bottom. ⇧↑ / ⇧↓ the chat above / below. NOVA: someone to write to, found by @username,
// phone number or name.

// ── TDLib: one client for the app, loaded when first asked for ──

struct TelegramError: Error { let message: String }

final class Telegram {
    static let shared = Telegram()
    /// what TDLib says unasked (an update), to every window
    static let update = Notification.Name("ReTerm.telegram")

    private var client: Int32 = 0
    private var sendFn: (@convention(c) (Int32, UnsafePointer<CChar>) -> Void)?
    private var waiting: [String: ([String: Any]) -> Void] = [:]
    private var extra = 0
    private var started: Result<String, TelegramError>?

    /// TDLib started (once), and where it keeps its database; an error if it isn't installed
    func start() -> Result<String, TelegramError> {
        if let started { return started }
        let r = load()
        started = r
        return r
    }

    private func load() -> Result<String, TelegramError> {
        let places = ["/opt/homebrew/lib/libtdjson.dylib", "/usr/local/lib/libtdjson.dylib", "libtdjson.dylib"]
        guard let lib = places.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else { return .failure(TelegramError(message: "TDLib isn't installed: brew install tdlib")) }
        typealias Create = @convention(c) () -> Int32
        typealias Send = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
        typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
        typealias Execute = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
        guard let c = dlsym(lib, "td_create_client_id"), let s = dlsym(lib, "td_send"),
              let r = dlsym(lib, "td_receive"), let e = dlsym(lib, "td_execute") else { return .failure(TelegramError(message: "TDLib: no JSON interface")) }
        let create = unsafeBitCast(c, to: Create.self)
        let receive = unsafeBitCast(r, to: Receive.self)
        let execute = unsafeBitCast(e, to: Execute.self)
        sendFn = unsafeBitCast(s, to: Send.self)
        // quiet: only its errors in the log
        _ = execute(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":1}"#)
        client = create()
        let thread = Thread {
            while true {
                // the text is TDLib's until the next td_receive: copied at once
                guard let text = receive(5.0) else { continue }
                let json = String(cString: text)
                DispatchQueue.main.async { Telegram.shared.received(json) }
            }
        }
        thread.start()
        let dir = Saved.dir.appendingPathComponent("telegram")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return .success(dir.path)
    }

    private func received(_ json: String) {
        guard let u = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        if let id = u["@extra"] as? String, let done = waiting.removeValue(forKey: id) {
            done(u)
        } else if u["@extra"] == nil {
            NotificationCenter.default.post(name: Self.update, object: nil, userInfo: ["u": u])
        }
    }

    /// a request to TDLib, and its answer
    func request(_ body: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        extra += 1
        let id = "r\(extra)"
        var b = body
        b["@extra"] = id
        guard let send = sendFn, let data = try? JSONSerialization.data(withJSONObject: b) else {
            return done(["@type": "error", "message": "Not started"])
        }
        waiting[id] = done
        String(decoding: data, as: UTF8.self).withCString { send(client, $0) }
    }

    func tell(_ body: [String: Any]) {
        guard let send = sendFn, let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        String(decoding: data, as: UTF8.self).withCString { send(client, $0) }
    }
}

private func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? Int64(v as? String ?? "") ?? 0 }

private struct Chat {
    let id: Int64
    var title: String
    var order: Int64
    var unread: Int
}

private struct Media {
    enum Kind { case photo, video, gif, round }
    let kind: Kind
    let file: Int
    var thumb: Int?
    var mini: Data?
    let w: CGFloat
    let h: CGFloat
}

private struct Msg {
    let id: Int64
    let mine: Bool
    var text: String
    let sender: Int64
    let date: Int
    var media: Media?
    var sticker: (file: Int, w: CGFloat, h: CGFloat, outline: [Any]?)?
}

// ── what a message says, in words ──

private func said(_ content: [String: Any]?) -> String {
    guard let content else { return "" }
    let caption = ((content["caption"] as? [String: Any])?["text"] as? String).map { " " + $0 } ?? ""
    let type = content["@type"] as? String ?? ""
    func inner(_ key: String) -> [String: Any]? { content[key] as? [String: Any] }
    switch type {
    case "messageText": return (inner("text")?["text"] as? String) ?? ""
    case "messagePhoto": return "[photo]" + caption
    case "messageVideo": return "[video]" + caption
    case "messageAnimation": return "[gif]" + caption
    case "messageDocument": return "[\((inner("document")?["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "file")]" + caption
    case "messageAudio": return "[\((inner("audio")?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "audio")]" + caption
    case "messageVoiceNote": return "[voice]" + caption
    case "messageVideoNote": return "[video message]"
    case "messageSticker": return "[\(inner("sticker")?["emoji"] as? String ?? "") sticker]"
    case "messageLocation": return "[location]"
    case "messageContact": return "[contact \(inner("contact")?["first_name"] as? String ?? "")]"
    case "messagePoll":
        let q = inner("poll")?["question"]
        return "[poll: \((q as? [String: Any])?["text"] as? String ?? q as? String ?? "")]"
    case "messageCall": return "[call]"
    default:
        let name = type.hasPrefix("message") ? String(type.dropFirst(7)) : type
        var words = ""
        for (i, c) in name.enumerated() {
            if c.isUppercase && i > 0 { words += " " }
            words += c.lowercased()
        }
        return "[\(words)]"
    }
}

final class HomoPage: ModePage, NSTextViewDelegate {
    private enum Stage { case loading, missing, app, phone, code, password, ready, closed }
    private var stage = Stage.loading

    private let history = HistoryList()
    override var modeWord: String { "HOMO" }
    override var historyList: HistoryList? { history }
    override var searchable: Bool { stage == .ready }
    private let talkScroll: FadeScroll
    private let talk: Transcript
    private let box = InputBox()
    private let sign = Flipped()
    private let find = Flipped()
    private let quiet = label("TELEGRAM", Fonts.buttons(12), NSColor(white: 1, alpha: 0.32), kern: 3.6, align: .center)
    private var player: AVPlayerView?

    override var input: InputBox? { stage == .ready && open != nil ? box : nil }

    private var problem = ""
    private var hint = ""
    private var apiId = ""
    private var apiHash = ""
    private var folder = ""
    private var askFields: [NSTextField] = []
    private var findField: NSTextField?

    private var chats: [Int64: Chat] = [:]
    private var ordered: [Chat] { chats.values.filter { $0.order != 0 }.sorted { $0.order > $1.order } }
    private var open: Int64?
    private var messages: [Msg] = []
    private var users: [Int64: String] = [:]
    private var paths: [Int: String] = [:]
    private var fetching = Set<Int>()
    private var outlines: [Int: NSBezierPath?] = [:]
    private var found: [(id: Int64, title: String)] = []
    private var finding = false
    private var redraw: DispatchWorkItem?

    override init(frame: NSRect) {
        (talkScroll, talk) = Transcript.make()
        super.init(frame: frame)
        addSubview(title)
        history.pick = { [weak self] id in self?.openChat(Int64(id) ?? 0) }
        history.fresh = { [weak self] in self?.fresh() }
        addSubview(history)
        talk.delegate = self
        talk.onWidth = { [weak self] _ in self?.render() }
        addSubview(talkScroll)
        box.size = 14
        box.onKey = { [weak self] e in self?.typed(e) ?? false }
        box.onHeight = { [weak self] in self?.needsLayout = true }
        addSubview(box)
        addSubview(sign)
        addSubview(find)
        addSubview(quiet)
        NotificationCenter.default.addObserver(forName: Telegram.update, object: nil, queue: .main) { [weak self] n in
            if let u = n.userInfo?["u"] as? [String: Any] { self?.update(u) }
        }
        if let kept = Saved.json("telegram-app") as? [String: Any] {
            apiId = kept["apiId"] as? String ?? ""
            apiHash = kept["apiHash"] as? String ?? ""
        }
        show()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tg: Telegram { .shared }

    /// --render: Telegram not started (its chats are not made up)
    static var off = false

    override func start() {
        if Self.off { return }
        switch tg.start() {
        case .failure(let e):
            stage = .missing
            problem = e.message
            show()
        case .success(let dir):
            folder = dir
            tg.request(["@type": "getAuthorizationState"]) { [weak self] s in self?.authorization(s) }
        }
    }

    // ── signing in ──

    private func authorization(_ s: [String: Any]) {
        problem = ""
        switch s["@type"] as? String ?? "" {
        case "authorizationStateWaitTdlibParameters":
            guard !apiId.isEmpty, !apiHash.isEmpty else {
                stage = .app
                return show()
            }
            let parameters: [String: Any] = [
                "use_test_dc": false, "database_directory": folder, "files_directory": folder, "use_file_database": false,
                "use_chat_info_database": true, "use_message_database": true, "use_secret_chats": false,
                "api_id": Int(apiId) ?? 0, "api_hash": apiHash, "system_language_code": "en", "device_model": "Mac",
                "system_version": "", "application_version": "0.2", "enable_storage_optimizer": true,
            ]
            // TDLib 1.8.0 takes them inside "parameters", newer ones as they are
            var body = parameters
            body["@type"] = "setTdlibParameters"
            body["parameters"] = parameters.merging(["@type": "tdlibParameters"]) { $1 }
            body["database_encryption_key"] = ""
            tg.request(body) { [weak self] r in
                if r["@type"] as? String == "error" {
                    self?.problem = r["message"] as? String ?? ""
                    self?.stage = .app
                    self?.show()
                }
            }
            return
        case "authorizationStateWaitEncryptionKey":
            tg.tell(["@type": "checkDatabaseEncryptionKey", "encryption_key": ""])
            return
        case "authorizationStateWaitPhoneNumber":
            stage = .phone
        case "authorizationStateWaitCode":
            stage = .code
            let type = ((s["code_info"] as? [String: Any])?["type"] as? [String: Any])?["@type"] as? String ?? ""
            hint = type.contains("TelegramMessage") ? "The code is in Telegram on another device." : "The code was sent to the phone."
        case "authorizationStateWaitPassword":
            stage = .password
            hint = (s["password_hint"] as? String).flatMap { $0.isEmpty ? nil : "Hint: \($0)" } ?? ""
        case "authorizationStateReady":
            stage = .ready
            loadChats()
        case "authorizationStateClosed", "authorizationStateLoggingOut", "authorizationStateClosing":
            stage = .closed
        default:
            return
        }
        show()
    }

    private func submitAsk() {
        if stage == .app {
            let id = askFields.first?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            let hash = askFields.dropFirst().first?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            guard !id.isEmpty, id.allSatisfy(\.isNumber), !hash.isEmpty else {
                problem = "Both, as my.telegram.org gives them."
                return show()
            }
            apiId = id
            apiHash = hash
            Saved.setJSON("telegram-app", ["apiId": apiId, "apiHash": apiHash])
            tg.request(["@type": "getAuthorizationState"]) { [weak self] s in self?.authorization(s) }
            return
        }
        let value = askFields.first?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        guard !value.isEmpty else { return }
        let body: [String: Any]
        switch stage {
        case .phone: body = ["@type": "setAuthenticationPhoneNumber", "phone_number": value]
        case .code: body = ["@type": "checkAuthenticationCode", "code": value]
        case .password: body = ["@type": "checkAuthenticationPassword", "password": value]
        default: return
        }
        tg.request(body) { [weak self] r in
            if r["@type"] as? String == "error" {
                self?.problem = r["message"] as? String ?? ""
                self?.show()
            }
        }
    }

    private func loadChats() {
        tg.request(["@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": 100]) { [weak self] _ in
            self?.tg.request(["@type": "getChats", "chat_list": ["@type": "chatListMain"], "limit": 100]) { r in
                for id in (r["chat_ids"] as? [NSNumber]) ?? [] where self?.chats[id.int64Value] == nil {
                    self?.tg.request(["@type": "getChat", "chat_id": id]) { c in
                        if c["@type"] as? String == "chat" { self?.chats[int64(c["id"])] = self?.chatFrom(c) }
                        self?.refreshHistory()
                    }
                }
            }
        }
    }

    private func chatFrom(_ c: [String: Any]) -> Chat {
        let main = ((c["positions"] as? [[String: Any]]) ?? []).first { ($0["list"] as? [String: Any])?["@type"] as? String == "chatListMain" }
        return Chat(id: int64(c["id"]), title: plain((c["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                    order: int64(main?["order"]), unread: (c["unread_count"] as? Int) ?? 0)
    }

    // ── a message ──

    private func toMessage(_ m: [String: Any]) -> Msg {
        let content = m["content"] as? [String: Any]
        let senderObj = m["sender_id"] as? [String: Any]
        var msg = Msg(id: int64(m["id"]), mine: m["is_outgoing"] as? Bool ?? false, text: plain(said(content)),
                      sender: int64(senderObj?["user_id"] ?? senderObj?["chat_id"]), date: m["date"] as? Int ?? 0)
        if let (media, caption) = withMedia(content) {
            msg.media = media
            msg.text = caption
        }
        if content?["@type"] as? String == "messageSticker", let st = content?["sticker"] as? [String: Any],
           let file = (st["sticker"] as? [String: Any])?["id"] as? Int {
            msg.sticker = (file, CGFloat((st["width"] as? Int) ?? 512), CGFloat((st["height"] as? Int) ?? 512), st["outline"] as? [Any])
        }
        return msg
    }

    /// a file known: where it is on the disk, once downloaded
    private func known(_ f: Any?) -> Int? {
        guard let f = f as? [String: Any], let id = f["id"] as? Int else { return nil }
        if let local = f["local"] as? [String: Any], local["is_downloading_completed"] as? Bool == true, let path = local["path"] as? String, !path.isEmpty {
            paths[id] = path
        }
        return id
    }

    private func mini(_ m: Any?) -> Data? {
        ((m as? [String: Any])?["data"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// a message with a picture or video: its media, and its words only the caption
    private func withMedia(_ content: [String: Any]?) -> (Media, String)? {
        guard let content else { return nil }
        let caption = plain(((content["caption"] as? [String: Any])?["text"] as? String) ?? "")
        switch content["@type"] as? String {
        case "messagePhoto":
            guard let photo = content["photo"] as? [String: Any] else { return nil }
            let sizes = ((photo["sizes"] as? [[String: Any]]) ?? []).sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
            guard let size = sizes.filter({ ($0["width"] as? Int ?? 0) <= 1280 }).last ?? sizes.last, let file = known(size["photo"]) else { return nil }
            return (Media(kind: .photo, file: file, mini: mini(photo["minithumbnail"]), w: CGFloat(size["width"] as? Int ?? 1), h: CGFloat(size["height"] as? Int ?? 1)), caption)
        case "messageVideo", "messageAnimation", "messageVideoNote":
            let type = content["@type"] as! String
            let key = type == "messageVideo" ? "video" : type == "messageAnimation" ? "animation" : "video_note"
            guard let v = content[key] as? [String: Any], let file = known(v[type == "messageVideoNote" ? "video" : key]) else { return nil }
            let kind: Media.Kind = type == "messageVideo" ? .video : type == "messageAnimation" ? .gif : .round
            let thumb = known((v["thumbnail"] as? [String: Any])?["file"])
            let w = kind == .round ? 1 : CGFloat(v["width"] as? Int ?? 16), h = kind == .round ? 1 : CGFloat(v["height"] as? Int ?? 9)
            return (Media(kind: kind, file: file, thumb: thumb, mini: mini(v["minithumbnail"]), w: max(1, w), h: max(1, h)), kind == .round ? "" : caption)
        default:
            return nil
        }
    }

    private func download(_ file: Int?, then: (() -> Void)? = nil) {
        guard let file, paths[file] == nil, !fetching.contains(file) else { return }
        fetching.insert(file)
        tg.request(["@type": "downloadFile", "file_id": file, "priority": 16, "offset": 0, "limit": 0, "synchronous": true]) { [weak self] f in
            guard let self else { return }
            self.fetching.remove(file)
            if let local = f["local"] as? [String: Any], local["is_downloading_completed"] as? Bool == true, let path = local["path"] as? String {
                self.paths[file] = path
                self.scheduleRender()
                then?()
            }
        }
    }

    // ── stickers as their outlines: Telegram's vector contour of each, filled in the ink ──

    private func outline(_ s: (file: Int, w: CGFloat, h: CGFloat, outline: [Any]?)) {
        guard outlines[s.file] == nil else { return }
        outlines[s.file] = .some(nil)
        if let o = s.outline, !o.isEmpty {
            outlines[s.file] = pathOf(o)
            return
        }
        let ask: [String: Any] = ["sticker_file_id": s.file, "for_animated_emoji": false, "for_clicked_animated_emoji_message": false]
        tg.request(ask.merging(["@type": "getStickerOutlineSvgPath"]) { $1 }) { [weak self] r in
            guard let self else { return }
            if r["@type"] as? String == "text", let d = r["text"] as? String, !d.isEmpty {
                self.outlines[s.file] = svgPath(d)
                self.scheduleRender()
            } else {
                self.tg.request(ask.merging(["@type": "getStickerOutline"]) { $1 }) { r in
                    self.outlines[s.file] = r["@type"] as? String == "outline" ? self.pathOf((r["paths"] as? [Any]) ?? []) : nil
                    self.scheduleRender()
                }
            }
        }
    }

    /// TDLib's closed vector paths: each starts where its last command ends
    private func pathOf(_ paths: [Any]) -> NSBezierPath {
        let out = NSBezierPath()
        func pt(_ p: Any?) -> NSPoint {
            let d = p as? [String: Any]
            return NSPoint(x: (d?["x"] as? NSNumber)?.doubleValue ?? 0, y: (d?["y"] as? NSNumber)?.doubleValue ?? 0)
        }
        for case let path as [String: Any] in paths {
            let commands = (path["commands"] as? [[String: Any]]) ?? []
            guard let last = commands.last else { continue }
            out.move(to: pt(last["end_point"]))
            for c in commands {
                if c["@type"] as? String == "vectorPathCommandCubicBezierCurve" {
                    out.curve(to: pt(c["end_point"]), controlPoint1: pt(c["start_control_point"]), controlPoint2: pt(c["end_control_point"]))
                } else {
                    out.line(to: pt(c["end_point"]))
                }
            }
            out.close()
        }
        return out
    }

    // ── what TDLib says ──

    private func update(_ u: [String: Any]) {
        let type = u["@type"] as? String ?? ""
        let chatId = int64(u["chat_id"])
        switch type {
        case "updateAuthorizationState":
            if let s = u["authorization_state"] as? [String: Any] { authorization(s) }
            return
        case "updateNewChat":
            if let c = u["chat"] as? [String: Any] { chats[int64(c["id"])] = chatFrom(c) }
        case "updateChatTitle":
            chats[chatId]?.title = plain(u["title"] as? String ?? "")
        case "updateChatPosition":
            if let p = u["position"] as? [String: Any], (p["list"] as? [String: Any])?["@type"] as? String == "chatListMain" { chats[chatId]?.order = int64(p["order"]) }
        case "updateChatLastMessage":
            let main = ((u["positions"] as? [[String: Any]]) ?? []).first { ($0["list"] as? [String: Any])?["@type"] as? String == "chatListMain" }
            if let main { chats[chatId]?.order = int64(main["order"]) }
        case "updateChatReadInbox":
            chats[chatId]?.unread = u["unread_count"] as? Int ?? 0
        case "updateNewMessage":
            guard let m = u["message"] as? [String: Any], int64(m["chat_id"]) == open else { break }
            let msg = toMessage(m)
            guard !messages.contains(where: { $0.id == msg.id }) else { break }
            messages.append(msg)
            if !msg.mine { userName(msg.sender) }
            if active, let open { tg.tell(["@type": "viewMessages", "chat_id": open, "message_ids": [msg.id], "force_read": true]) }
            prepare()
            render()
        case "updateMessageSendSucceeded":
            if let i = messages.firstIndex(where: { $0.id == int64(u["old_message_id"]) }), let m = u["message"] as? [String: Any] {
                messages[i] = toMessage(m)
                render()
            }
        case "updateMessageContent" where chatId == open:
            if let i = messages.firstIndex(where: { $0.id == int64(u["message_id"]) }) {
                let content = u["new_content"] as? [String: Any]
                messages[i].text = plain(said(content))
                if let (media, caption) = withMedia(content) {
                    messages[i].media = media
                    messages[i].text = caption
                }
                render()
            }
        case "updateDeleteMessages" where chatId == open && (u["is_permanent"] as? Bool ?? false):
            let gone = Set(((u["message_ids"] as? [NSNumber]) ?? []).map(\.int64Value))
            messages.removeAll { gone.contains($0.id) }
            render()
        default:
            return
        }
        refreshHistory()
    }

    private func userName(_ id: Int64) {
        guard id != 0, users[id] == nil else { return }
        users[id] = ""
        tg.request(["@type": "getUser", "user_id": id]) { [weak self] u in
            if u["@type"] as? String == "user" {
                self?.users[id] = plain([u["first_name"] as? String, u["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
                self?.scheduleRender()
            }
        }
    }

    // ── a chat open ──

    private func openChat(_ id: Int64) {
        guard open != id else { return }
        if let open { tg.tell(["@type": "closeChat", "chat_id": open]) }
        found = []
        problem = ""
        open = id
        messages = []
        tg.tell(["@type": "openChat", "chat_id": id])
        show()
        render(stick: true)
        // TDLib gives what it has at hand first: asked again from the oldest, until there are enough
        var got: [Msg] = []
        func more(_ from: Int64, _ round: Int) {
            tg.request(["@type": "getChatHistory", "chat_id": id, "from_message_id": from, "offset": 0, "limit": 50, "only_local": false]) { [weak self] r in
                guard let self, self.open == id else { return }
                let batch = ((r["messages"] as? [[String: Any]]) ?? []).map(self.toMessage)
                got += batch
                if let last = batch.last, round < 5, got.count < 40 { return more(last.id, round + 1) }
                self.messages = got.reversed()
                for m in self.messages where !m.mine { self.userName(m.sender) }
                if !self.messages.isEmpty && self.active {
                    self.tg.tell(["@type": "viewMessages", "chat_id": id, "message_ids": self.messages.suffix(50).map(\.id), "force_read": true])
                }
                self.prepare()
                self.render(stick: true)
                self.box.focus()
            }
        }
        more(0, 0)
    }

    /// what is on the page: its pictures, the videos' stills, the stickers' outlines
    private func prepare() {
        for m in messages {
            if let media = m.media {
                if media.kind == .photo { download(media.file) }
                download(media.thumb)
            }
            if let s = m.sticker { outline(s) }
        }
    }

    private func fresh() {
        if let open { tg.tell(["@type": "closeChat", "chat_id": open]) }
        open = nil
        messages = []
        problem = ""
        found = []
        show()
        DispatchQueue.main.async { [weak self] in if let f = self?.findField { self?.window?.makeFirstResponder(f) } }
    }

    private func chatOf(_ userId: Int64, _ done: @escaping ([String: Any]?) -> Void) {
        tg.request(["@type": "createPrivateChat", "user_id": userId, "force": false]) { c in done(c["@type"] as? String == "chat" ? c : nil) }
    }

    /// what was typed: a phone number, an @username, or a name among the chats and contacts
    private func search(_ q: String, then: @escaping () -> Void) {
        guard !q.isEmpty else { found = []; return then() }
        finding = true
        problem = ""
        showFind()
        var results: [(Int64, String)] = []
        func add(_ c: [String: Any]?) {
            guard let c, c["@type"] as? String == "chat" else { return }
            let id = int64(c["id"])
            if !results.contains(where: { $0.0 == id }) { results.append((id, (c["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—")) }
        }
        let group = DispatchGroup()
        let digits = q.filter(\.isNumber)
        if q.range(of: #"^\+?[\d\s()-]{5,}$"#, options: .regularExpression) != nil {
            group.enter()
            tg.request(["@type": "searchUserByPhoneNumber", "phone_number": digits]) { [weak self] u in
                if u["@type"] as? String == "user" { self?.chatOf(int64(u["id"])) { add($0); group.leave() } } else { group.leave() }
            }
        } else {
            let name = q.hasPrefix("@") ? String(q.dropFirst()) : q
            if name.range(of: #"^[A-Za-z][\w]{3,}$"#, options: .regularExpression) != nil {
                group.enter()
                tg.request(["@type": "searchPublicChat", "username": name]) { add($0); group.leave() }
            }
            group.enter()
            tg.request(["@type": "searchChats", "query": q, "limit": 20]) { [weak self] r in
                for id in (r["chat_ids"] as? [NSNumber]) ?? [] {
                    if let c = self?.chats[id.int64Value] { add(["@type": "chat", "id": id, "title": c.title]) } else {
                        group.enter()
                        self?.tg.request(["@type": "getChat", "chat_id": id]) { add($0); group.leave() }
                    }
                }
                group.leave()
            }
            group.enter()
            tg.request(["@type": "searchContacts", "query": q, "limit": 20]) { [weak self] r in
                for id in (r["user_ids"] as? [NSNumber]) ?? [] {
                    group.enter()
                    self?.chatOf(id.int64Value) { add($0); group.leave() }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.found = results.map { (id: $0.0, title: $0.1) }
            self.finding = false
            if self.found.isEmpty { self.problem = "No one found." }
            self.showFind()
            then()
        }
    }

    private var lastFind = ""

    @objc private func findEnter() {
        let q = findField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        // a second Enter, the same words: the first found
        if q == lastFind, let first = found.first, !finding { return openChat(first.id) }
        lastFind = q
        search(q) { [weak self] in
            if self?.found.count == 1, let only = self?.found.first { self?.openChat(only.id) }
        }
    }

    private func sendMessage() {
        let text = box.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let open else { return }
        box.string = ""
        tg.request(["@type": "sendMessage", "chat_id": open,
                    "input_message_content": ["@type": "inputMessageText", "text": ["@type": "formattedText", "text": text]]]) { [weak self] r in
            guard let self else { return }
            if r["@type"] as? String == "message", int64(r["chat_id"]) == self.open {
                let m = self.toMessage(r)
                if !self.messages.contains(where: { $0.id == m.id }) {
                    self.messages.append(m)
                    self.render(stick: true)
                }
            } else if r["@type"] as? String == "error" {
                self.problem = r["message"] as? String ?? ""
            }
        }
    }

    private func step(_ by: Int) {
        let all = ordered
        guard !all.isEmpty else { return }
        let at = all.firstIndex { $0.id == open }
        let next = all[min(all.count - 1, max(0, at.map { $0 + by } ?? 0))]
        openChat(next.id)
    }

    private func typed(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (e.keyCode, mods) {
        case (36, []), (76, []): sendMessage()
        case (126, .shift): step(-1)
        case (125, .shift): step(1)
        default: return false
        }
        return true
    }

    override func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if let player, e.keyCode == 53 {
            player.player?.pause()
            player.removeFromSuperview()
            self.player = nil
            return true
        }
        if stage == .ready && mods == .shift && (e.keyCode == 126 || e.keyCode == 125) && !box.focused {
            step(e.keyCode == 126 ? -1 : 1)
            return true
        }
        // typing with no chat open: into the search for someone
        if stage == .ready, open == nil, mods.subtracting(.shift).isEmpty, let f = findField, f.currentEditor() == nil, e.keyCode != 53 {
            window?.makeFirstResponder(f)
            f.currentEditor()?.keyDown(with: e)
            return true
        }
        return false
    }

    // ── drawn ──

    private func scheduleRender() {
        guard redraw == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.redraw = nil
            self?.render()
        }
        redraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func refreshHistory() {
        history.items = ordered.map { Item(id: String($0.id), title: $0.title, badge: $0.unread > 0 ? "\($0.unread)" : nil) }
        history.shown = open.map(String.init)
        history.freshShown = open == nil
        title.stringValue = open.flatMap { chats[$0]?.title } ?? ""
    }

    private func picture(_ media: Media) -> NSImage? {
        if media.kind == .photo, let p = paths[media.file], let img = NSImage(contentsOfFile: p) { return img }
        if let t = media.thumb, let p = paths[t], let img = NSImage(contentsOfFile: p) { return img }
        return media.mini.flatMap { NSImage(data: $0) }
    }

    /// a picture or a video's still, the size it is shown at; ▶ on a video, round for a round one
    private func mediaImage(_ media: Media) -> NSImage {
        let w = media.kind == .round ? 240 : min(420, max(160, media.w))
        let h = min(420, w * media.h / media.w)
        let size = NSSize(width: w, height: h)
        let still = picture(media)
        return NSImage(size: size, flipped: false) { rect in
            if media.kind == .round { NSBezierPath(ovalIn: rect).addClip() }
            NSColor(white: 1, alpha: 0.06).setFill()
            rect.fill()
            if let still {
                // as cover: the whole place filled
                let s = still.size
                let k = max(rect.width / max(1, s.width), rect.height / max(1, s.height))
                let d = NSSize(width: s.width * k, height: s.height * k)
                still.draw(in: NSRect(x: (rect.width - d.width) / 2, y: (rect.height - d.height) / 2, width: d.width, height: d.height))
            }
            if media.kind != .photo {
                NSColor(white: 0, alpha: 0.25).setFill()
                rect.fill(using: .sourceAtop)
                let play = attributed("▶", Fonts.words(28), NSColor(white: 1, alpha: 0.85))
                play.draw(at: NSPoint(x: (rect.width - play.size().width) / 2, y: (rect.height - play.size().height) / 2))
            }
            return true
        }
    }

    private func stickerImage(_ path: NSBezierPath, w: CGFloat, h: CGFloat) -> NSImage {
        let height: CGFloat = 110
        let width = height * w / h
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            let t = AffineTransform(scale: height / h)
            let p = path.copy() as! NSBezierPath
            p.transform(using: t)
            Ink.text.setFill()
            p.fill()
            return true
        }
    }

    private func render(stick: Bool = false) {
        guard stage == .ready, open != nil else { return talk.set([]) }
        let width = talk.bounds.width
        let others = Set(messages.filter { !$0.mine }.map(\.sender))
        let isGroup = others.count > 1
        var out: [NSAttributedString] = []
        for m in messages {
            let align: NSTextAlignment = m.mine ? .right : .left
            let p = paragraph("", font: Fonts.words(14), align: align, lineHeight: 1.5, before: out.isEmpty ? 0 : 10,
                              indentLeft: m.mine ? width * 0.2 : 0, indentRight: m.mine ? 0 : width * 0.2)
            let style = p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle()
            let base: [NSAttributedString.Key: Any] = [.font: Fonts.words(14), .foregroundColor: Ink.text, .paragraphStyle: style]
            let piece = NSMutableAttributedString()
            if isGroup && !m.mine, let name = users[m.sender], !name.isEmpty {
                piece.append(NSAttributedString(string: name + "\n", attributes: base.merging([.font: Fonts.words(11.2), .foregroundColor: NSColor(white: 1, alpha: 0.4)]) { $1 }))
            }
            if let media = m.media {
                let a = NSTextAttachment()
                a.image = mediaImage(media)
                let s = NSMutableAttributedString(attachment: a)
                s.addAttributes(base, range: NSRange(location: 0, length: s.length))
                if media.kind != .photo { s.addAttribute(.link, value: "reterm-media:\(media.file)", range: NSRange(location: 0, length: s.length)) }
                piece.append(s)
                if !m.text.isEmpty { piece.append(NSAttributedString(string: "\n" + m.text, attributes: base)) }
            } else if let st = m.sticker, let outline = outlines[st.file] ?? nil {
                let a = NSTextAttachment()
                a.image = stickerImage(outline, w: st.w, h: st.h)
                let s = NSMutableAttributedString(attachment: a)
                s.addAttributes(base, range: NSRange(location: 0, length: s.length))
                piece.append(s)
            } else {
                piece.append(NSAttributedString(string: m.text, attributes: base))
            }
            out.append(piece)
        }
        talk.set(out, stick: stick)
    }

    /// a video clicked: it plays over the conversation (Esc, or a click beside it, stops it)
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let s = link as? String, s.hasPrefix("reterm-media:"), let file = Int(s.dropFirst(13)) else { return false }
        let media = messages.compactMap(\.media).first { $0.file == file }
        let play = { [weak self] in
            guard let self, let path = self.paths[file] else { return }
            self.player?.removeFromSuperview()
            let view = AVPlayerView()
            let item = AVPlayer(url: URL(fileURLWithPath: path))
            view.player = item
            view.controlsStyle = media?.kind == .gif ? .none : .inline
            if media?.kind == .gif {
                item.isMuted = true
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item.currentItem, queue: .main) { _ in
                    item.seek(to: .zero)
                    item.play()
                }
            }
            self.addSubview(view)
            self.player = view
            self.needsLayout = true
            item.play()
        }
        if paths[file] != nil { play() } else { download(file, then: play) }
        return true
    }

    // ── the sign-in form, the search for someone ──

    private func lineField(_ placeholder: String, secure: Bool = false, value: String = "") -> NSTextField {
        let f = secure ? NSSecureTextField() : NSTextField()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = Fonts.words(14)
        f.textColor = Ink.text
        f.stringValue = value
        f.placeholderAttributedString = attributed(placeholder, Fonts.words(14), NSColor(white: 1, alpha: 0.3))
        return f
    }

    private func underline(_ f: NSView, in parent: NSView, y: CGFloat, width: CGFloat) -> CGFloat {
        f.frame = NSRect(x: 0, y: y + 4, width: width, height: 22)
        parent.addSubview(f)
        let line = Flipped()
        line.wantsLayer = true
        line.layer?.backgroundColor = Ink.line.cgColor
        line.frame = NSRect(x: 0, y: y + 34, width: width, height: 1)
        parent.addSubview(line)
        return y + 35
    }

    private func note(_ text: String, color: NSColor = NSColor(white: 1, alpha: 0.48)) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Fonts.words(12)
        l.textColor = color
        return l
    }

    /// what is shown for where signing in is
    private func show() {
        sign.subviews.forEach { $0.removeFromSuperview() }
        askFields = []
        quiet.isHidden = stage != .loading
        let ready = stage == .ready
        sign.isHidden = ready || stage == .loading
        history.isHidden = !ready
        title.isHidden = !ready
        talkScroll.isHidden = !ready || open == nil
        box.isHidden = !ready || open == nil
        find.isHidden = !ready || open != nil
        refreshHistory()
        if ready { showFind() }
        if !ready && stage != .loading { buildSign() }
        needsLayout = true
        if active { focusFirst() }
    }

    private func buildSign() {
        let width = min(420, max(200, area.width))
        var y: CGFloat = 0
        let heading = label("TELEGRAM", Fonts.buttons(14), kern: 5.6, align: .center)
        heading.frame = NSRect(x: 0, y: y, width: width, height: 22)
        sign.addSubview(heading)
        y += 22 + 14
        func addNote(_ text: String, color: NSColor = NSColor(white: 1, alpha: 0.48)) {
            let n = note(text, color: color)
            n.preferredMaxLayoutWidth = width
            let h = n.fittingSize.height
            n.frame = NSRect(x: 0, y: y, width: width, height: h)
            sign.addSubview(n)
            y += h + 14
        }
        switch stage {
        case .missing: addNote("TDLib isn't installed. In TERM: brew install tdlib")
        case .closed: addNote("Signed out.")
        case .app:
            addNote("The app's api_id and api_hash, from my.telegram.org → API development tools")
            for (p, v) in [("api_id", apiId), ("api_hash", apiHash)] {
                let f = lineField(p, value: v)
                f.target = self
                f.action = #selector(enter)
                askFields.append(f)
                y = underline(f, in: sign, y: y, width: width) + 14
            }
        default:
            addNote(stage == .phone ? "The phone number, with its country code" : stage == .code ? hint : (hint.isEmpty ? "The password (two-step verification)" : hint))
            let f = lineField(stage == .phone ? "+380…" : stage == .code ? "code" : "password", secure: stage == .password)
            f.target = self
            f.action = #selector(enter)
            askFields.append(f)
            y = underline(f, in: sign, y: y, width: width) + 14
        }
        if !problem.isEmpty { addNote(problem, color: hexColor(PALETTE[1])) }
        if stage != .missing && stage != .closed {
            let go = WordButton(">", font: Fonts.buttons(20)) { [weak self] in self?.submitAsk() }
            go.frame = NSRect(x: width - 30, y: y, width: 30, height: 28)
            sign.addSubview(go)
            y += 28
        }
        sign.frame.size = NSSize(width: width, height: y)
    }

    @objc private func enter() { submitAsk() }

    private func showFind() {
        find.subviews.forEach { $0.removeFromSuperview() }
        let width = max(200, area.width - list)
        var y: CGFloat = 0
        let n = note("@username, the phone number, or a name")
        n.frame = NSRect(x: 0, y: y, width: width, height: 18)
        find.addSubview(n)
        y += 18 + 12
        let f = findField ?? lineField("")
        f.target = self
        f.action = #selector(findEnter)
        findField = f
        y = underline(f, in: find, y: y, width: width) + 12
        if finding {
            let dots = note("⋯")
            dots.frame = NSRect(x: 0, y: y, width: width, height: 18)
            find.addSubview(dots)
            y += 30
        }
        for person in found {
            let b = WordButton(person.title, font: Fonts.words(14)) { [weak self] in self?.openChat(person.id) }
            let w = min(width, attributed(person.title, Fonts.words(14)).size().width + 4)
            b.frame = NSRect(x: 0, y: y, width: w, height: 22)
            find.addSubview(b)
            y += 22 + 12
        }
        if !problem.isEmpty {
            let p = note(problem, color: hexColor(PALETTE[1]))
            p.frame = NSRect(x: 0, y: y, width: width, height: 18)
            find.addSubview(p)
            y += 18
        }
        find.frame.size = NSSize(width: width, height: y)
        needsLayout = true
    }

    private func focusFirst() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.stage == .ready, self.open != nil { self.box.focus() } else if self.stage == .ready, let f = self.findField {
                self.window?.makeFirstResponder(f)
            } else if let f = self.askFields.first { self.window?.makeFirstResponder(f) }
        }
    }

    override func shown() {
        needsLayout = true
        focusFirst()
        if stage == .ready, let open, !messages.isEmpty {
            tg.tell(["@type": "viewMessages", "chat_id": open, "message_ids": messages.suffix(50).map(\.id), "force_read": true])
        }
    }

    override func layout() {
        super.layout()
        layoutTitle()
        let A = area
        history.isHidden = stage != .ready || list == 0
        history.frame = historyFrame
        let column = self.column
        box.maxHeight = bounds.height * 0.4
        let boxH = box.height
        box.frame = NSRect(x: column.minX, y: column.maxY - boxH, width: column.width, height: boxH)
        talkScroll.frame = NSRect(x: column.minX, y: column.minY, width: column.width, height: max(0, box.frame.minY - 6 - column.minY))
        talk.frame.size.width = talkScroll.contentSize.width
        sign.frame.origin = NSPoint(x: A.midX - sign.frame.width / 2, y: A.midY - sign.frame.height / 2)
        find.frame.origin = NSPoint(x: column.minX, y: column.midY - find.frame.height / 2)
        quiet.frame = NSRect(x: A.minX, y: A.midY - 10, width: A.width, height: 20)
        if let player {
            let w = min(column.width, 720), h = min(column.height * 0.8, w * 9 / 16 + 40)
            player.frame = NSRect(x: column.midX - w / 2, y: column.midY - h / 2, width: w, height: h)
        }
    }
}

// ── an SVG path (a sticker's outline): M L H V C Q Z, absolute and relative ──

func svgPath(_ d: String) -> NSBezierPath {
    let path = NSBezierPath()
    var tokens: [String] = []
    var number = ""
    func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
    for c in d {
        if c.isLetter && c != "e" && c != "E" {
            flush()
            tokens.append(String(c))
        } else if c == "," || c == " " || c == "\n" || c == "\t" {
            flush()
        } else if c == "-" && !number.isEmpty && !number.hasSuffix("e") && !number.hasSuffix("E") {
            flush()
            number = "-"
        } else if c == "." && number.contains(".") && !number.contains("e") {
            flush()
            number = "."
        } else {
            number.append(c)
        }
    }
    flush()
    var i = 0
    var cmd = "M"
    var cur = NSPoint.zero
    var start = NSPoint.zero
    func num() -> CGFloat? {
        guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
        i += 1
        return CGFloat(v)
    }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1 }
        let rel = cmd == cmd.lowercased() && cmd != "z" ? true : false
        let base = rel ? cur : .zero
        switch cmd.uppercased() {
        case "M":
            guard let x = num(), let y = num() else { i += 1; continue }
            cur = NSPoint(x: base.x + x, y: base.y + y)
            path.move(to: cur)
            start = cur
            cmd = rel ? "l" : "L"
        case "L":
            guard let x = num(), let y = num() else { i += 1; continue }
            cur = NSPoint(x: base.x + x, y: base.y + y)
            path.line(to: cur)
        case "H":
            guard let x = num() else { i += 1; continue }
            cur = NSPoint(x: (rel ? cur.x : 0) + x, y: cur.y)
            path.line(to: cur)
        case "V":
            guard let y = num() else { i += 1; continue }
            cur = NSPoint(x: cur.x, y: (rel ? cur.y : 0) + y)
            path.line(to: cur)
        case "C":
            guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num() else { i += 1; continue }
            let end = NSPoint(x: base.x + x, y: base.y + y)
            path.curve(to: end, controlPoint1: NSPoint(x: base.x + x1, y: base.y + y1), controlPoint2: NSPoint(x: base.x + x2, y: base.y + y2))
            cur = end
        case "Q":
            guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { i += 1; continue }
            let q = NSPoint(x: base.x + x1, y: base.y + y1), end = NSPoint(x: base.x + x, y: base.y + y)
            path.curve(to: end, controlPoint1: NSPoint(x: cur.x + 2 / 3 * (q.x - cur.x), y: cur.y + 2 / 3 * (q.y - cur.y)),
                       controlPoint2: NSPoint(x: end.x + 2 / 3 * (q.x - end.x), y: end.y + 2 / 3 * (q.y - end.y)))
            cur = end
        case "Z":
            path.close()
            cur = start
        default:
            i += 1
        }
    }
    return path
}

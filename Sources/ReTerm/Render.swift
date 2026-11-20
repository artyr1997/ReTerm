import AppKit

// --render <dir>: the three drawn into pictures, out of sight, from what is made up in a folder of its own:
// a few commands run in /tmp, a conversation with an LLM; Telegram not started.

enum Render {
    static func run(into dir: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reterm-render-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Saved.root = root
        TermPage.userFiles = root.path
        HomoPage.off = true
        let t = Date().timeIntervalSince1970 * 1000
        Saved.setJSON("chats", ["provider": "claude", "conversations": [
            ["id": t, "started": t, "last": t, "sessions": [:], "messages": [
                ["id": 1, "me": true, "text": "What is a pseudo-terminal?"],
                ["id": 2, "me": false, "provider": "claude", "text": "A **pseudo-terminal** is a pair of devices: the program writes to one end, and the terminal reads from the other.\n\n```sh\nscript -q /dev/null ls\n```\n\nThat is how `ssh` and `tmux` work."],
            ]],
        ]])
        Saved.setJSON("sessions", [["id": t - 5000, "started": t - 5000, "last": t - 5000, "place": "~/Projects", "cwd": "/tmp",
                                    "blocks": [["command": "git status", "html": "On branch main", "status": 0, "fullscreen": false]]]])
        for (name, size) in [("wide", NSSize(width: 1280, height: 820)), ("small", NSSize(width: 640, height: 420))] {
            let w = TermWindow(frame: NSRect(origin: .zero, size: size))
            w.main.start()
            w.main.term.typeForRender(["cd /tmp", "echo 'hello from ReTerm'", "printf '\\e[31mred\\e[0m \\e[32mgreen\\e[0m \\e[1mbold\\e[0m\\n'", "false"])
            let until = Date().addingTimeInterval(4)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            for mode in ["term", "chat", "homo"] {
                w.main.show(mode)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                shoot(w, "\(dir)/\(mode)-\(name).png")
            }
            w.main.end()
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func shoot(_ w: NSWindow, _ path: String) {
        guard let view = w.contentView else { return }
        view.frame = NSRect(origin: .zero, size: w.frame.size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        NSColor(white: 0.16, alpha: 1).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

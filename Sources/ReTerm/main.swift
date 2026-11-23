import AppKit

// ReTerm: the shell, people and an LLM, each as a conversation. A native Mac app on the ReSpace desk.

let launched = Date()
func tick(_ what: String) { if ProcessInfo.processInfo.environment["RETERM_TIMING"] != nil { FileHandle.standardError.write("\(Int(Date().timeIntervalSince(launched) * 1000)) ms  \(what)\n".data(using: .utf8)!) } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // the distances from the windows' edges, as set with ReDesk's keys
        Spacing.start()
        // keys of one's own, as set in ReDesk's keys popup (⌘/)
        OwnKeys.start(app: "ReTerm", standard: [
            "newWindow": .init(45, "n"), "wholeWindow": .init(3, "f", [.command, .shift]), "newConversation": .init(40, "k"),
        ])
        tick("did finish launching")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = menu()
        Lang.shared.follow()
        Desk.listen()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 820)
        let size = NSSize(width: min(1280, screen.width), height: min(820, screen.height))
        open(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height))
    }

    @discardableResult
    func open(_ frame: NSRect) -> TermWindow {
        tick("window: make")
        let w = TermWindow(frame: frame)
        tick("window: made")
        w.open()
        tick("window: opened")
        return w
    }

    /// ⌘N: another window, the size of the one in front, a little lower and to the right of it
    func newWindow(from front: NSWindow?) {
        let frame = front?.frame ?? NSRect(x: 200, y: 200, width: 1280, height: 820)
        open(frame.offsetBy(dx: 28, dy: -28))
    }

    /// the last window gone: so is ReTerm, as nothing is left to it
    // quits when its last window is closed, not when its windows are put away on another of ReDesk's desktops
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { putAway.isEmpty }

    func applicationWillTerminate(_ notification: Notification) {
        for case let w as TermWindow in NSApp.windows {
            w.main.leave()
            w.main.end()
        }
        _exit(0)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSApp.windows.compactMap({ $0 as? TermWindow }).isEmpty { newWindow(from: nil) }
        return true
    }

    private func menu() -> NSMenu {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Hide ReTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ReTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.addItem(withTitle: "ReTerm", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        bar.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        bar.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return bar
    }
}

let app = ReApp.shared
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    Lang.shared.follow()
    Render.run(into: CommandLine.arguments[i + 1])
    _exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

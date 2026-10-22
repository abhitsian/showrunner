// Showrunner: a floating presenter console for any talk that mixes slides, live demos and a talk track.
// Open a show (.show.json or .show.md). Next walks it: each item brings its window forward (a Chrome tab
// by URL, an app, a file, a Keynote slide, a video) and shows what to do and what to say. The clock tracks
// pace against each section's budget, and Save run keeps rehearsal timings. Hidden from screen sharing.
//
// Global hotkeys: ⌃⌥↓ next · ⌃⌥↑ back · ⌃⌥→ / ⌃⌥← next or previous beat (or demo step) · ⌥Space pause
// Remote: GET 127.0.0.1:4977/state · /next · /prev · /go/N · /primary · /toggle · /beat · /start · /pause · /reload
// Check a show without the window: Showrunner --check <show>
import AppKit
import Carbon.HIToolbox
import Network
import SwiftUI

final class Hotkeys {
    private var refs: [EventHotKeyRef?] = []
    private static var actions: [UInt32: () -> Void] = [:]
    private(set) var failed: [String] = []

    init(_ m: Model) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Hotkeys.actions[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        let co = UInt32(controlKey | optionKey)
        add(1, kVK_DownArrow, co, "⌃⌥↓") { m.go(m.pos + 1) }
        add(2, kVK_UpArrow, co, "⌃⌥↑") { m.back() }
        add(3, kVK_RightArrow, co, "⌃⌥→") { m.step(1) }
        add(4, kVK_LeftArrow, co, "⌃⌥←") { m.step(-1) }
        add(5, kVK_Space, UInt32(optionKey), "⌥Space") { m.toggle() }
        if !failed.isEmpty { m.notice = "Hotkeys taken by another app (Autopilot?): \(failed.joined(separator: " ")). Use the buttons." }
    }

    private func add(_ id: UInt32, _ key: Int, _ mods: UInt32, _ name: String, _ f: @escaping () -> Void) {
        Hotkeys.actions[id] = { DispatchQueue.main.async(execute: f) }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5348_4F57), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        if st != noErr { failed.append(name) }
        refs.append(ref)
    }
}

// a tiny HTTP server on localhost, so a clicker, Stream Deck, phone shortcut or script can drive the show
final class Remote {
    var listener: NWListener?
    init(_ m: Model, port: UInt16 = 4977) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { m.say("Remote control off: port \(port) busy"); return }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let req = String(decoding: data ?? Data(), as: UTF8.self)
                let first = req.components(separatedBy: "\r\n").first ?? ""
                let parts = first.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                let body = m.remote(path)
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        l.start(queue: .main)
        listener = l
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NSPanel!
    var item: NSStatusItem!
    var hotkeys: Hotkeys!
    var remote: Remote!
    var model: Model!
    var pending: String?

    func applicationWillFinishLaunching(_ note: Notification) { model = Model() }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel, .utilityWindow],
                         backing: .buffered, defer: false)
        panel.title = "Showrunner"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none  // left out of screenshots and screen sharing that honour it
        panel.contentView = FirstClickHostingView(rootView: ContentView(m: model))
        panel.setFrameAutosaveName("ShowrunnerPanel")
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }), let scr = NSScreen.screens.first {
            let f = scr.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 20, y: f.maxY - 20))
        }
        panel.orderFrontRegardless()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "SR"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        hotkeys = Hotkeys(model)
        remote = Remote(model)
        if let p = pending { model.open(p) }
    }

    // rebuild the menu each time it opens, so Recent stays current
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Show Showrunner", action: #selector(show), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Show…", action: #selector(openShow), keyEquivalent: "o")
        let recent = NSMenu()
        for p in UserDefaults.standard.stringArray(forKey: "recent") ?? [] {
            let mi = NSMenuItem(title: (p as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            mi.representedObject = p
            mi.toolTip = p
            recent.addItem(mi)
        }
        let r = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        r.submenu = recent
        menu.addItem(r)
        menu.addItem(withTitle: "Edit Show File", action: #selector(editShow), keyEquivalent: "e")
        menu.addItem(withTitle: "Reload", action: #selector(reloadShow), keyEquivalent: "r")
        menu.addItem(withTitle: "New Show from Template", action: #selector(newShow), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for mi in menu.items where mi.action != nil && mi.action != #selector(NSApplication.terminate(_:)) { mi.target = self }
    }

    @objc func show() { panel.orderFrontRegardless() }
    @objc func reloadShow() { model.reload() }
    @objc func editShow() { if let p = model.path { NSWorkspace.shared.open(URL(fileURLWithPath: (p as NSString).resolvingSymlinksInPath)) } }
    @objc func openRecent(_ s: NSMenuItem) { if let p = s.representedObject as? String { model.open(p) } }

    @objc func openShow() {
        NSApp.activate(ignoringOtherApps: true)
        let o = NSOpenPanel()
        o.allowsMultipleSelection = false
        o.canChooseDirectories = false
        o.directoryURL = URL(fileURLWithPath: (("~/Showrunner") as NSString).expandingTildeInPath)
        if o.runModal() == .OK, let u = o.url { model.open(u.path) }
    }

    @objc func newShow() {
        let dir = ("~/Showrunner" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let path = (dir as NSString).appendingPathComponent("Untitled \(f.string(from: Date())).show.md")
        let tpl = Bundle.main.path(forResource: "template", ofType: "md").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "title: Untitled\n\n# Intro (2m)\n\n## [talk] Hello\n\nWhat you say.\n"
        try? tpl.write(toFile: path, atomically: true, encoding: .utf8)
        model.open(path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if model != nil && panel != nil { model.open(filename); show() } else { pending = filename }
        return true
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return true }
}

// Showrunner --check <show>: parse it, list the run of show and run the preflight checks, without the window
let args = CommandLine.arguments
if let k = args.firstIndex(of: "--check"), args.count > k + 1 {
    do {
        let s = try Loader.load(args[k + 1])
        let es = Loader.entries(s)
        print("\(s.title): \(s.sections.count) sections, \(es.count) items, \(fmt(es.map { $0.planned }.reduce(0, +) * 60)) planned, \(s.qa.count) Q&A")
        for e in es {
            let acts = e.item.go.map(Runner.label).joined(separator: "; ")
            print(String(format: "%3d", e.index + 1), "[\(e.item.kind)]", e.sectionTitle, "·", e.item.title,
                  e.planned > 0 ? "(\(fmt(e.planned * 60)))" : "", acts.isEmpty ? "" : "→ \(acts)",
                  e.item.image.map { FileManager.default.fileExists(atPath: $0) ? "" : "  MISSING IMAGE \($0)" } ?? "")
        }
        for c in Preflight.run(s) { print(c.ok == nil ? "○" : c.ok! ? "✓" : "✗", c.label, "·", c.detail) }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

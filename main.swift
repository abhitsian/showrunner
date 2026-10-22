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

// window options, kept across launches
enum Pref {
    static func bool(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    static var floatOnTop: Bool { get { bool("floatOnTop", true) } set { UserDefaults.standard.set(newValue, forKey: "floatOnTop") } }
    static var hideFromSharing: Bool { get { bool("hideFromSharing", true) } set { UserDefaults.standard.set(newValue, forKey: "hideFromSharing") } }
    static var keepFocus: Bool { get { bool("keepFocus", true) } set { UserDefaults.standard.set(newValue, forKey: "keepFocus") } }
    static var menuBarIcon: Bool { get { bool("menuBarIcon", true) } set { UserDefaults.standard.set(newValue, forKey: "menuBarIcon") } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var panel: NSPanel!
    var item: NSStatusItem?
    var hotkeys: Hotkeys!
    var remote: Remote!
    var model: Model!
    var pending: String?

    func applicationWillFinishLaunching(_ note: Notification) { model = Model() }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = mainMenu()
        makeWindow()
        applyMenuBarIcon()
        hotkeys = Hotkeys(model)
        remote = Remote(model)
        if let p = pending { model.open(p) }
        NSApp.activate(ignoringOtherApps: true)
    }

    // "Don't take focus" makes a non-activating panel: clicking it leaves Chrome or Keynote in front.
    // That style can't be switched on a live window, so changing it rebuilds the window.
    func makeWindow() {
        let old = panel
        var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        if Pref.keepFocus { style.insert(.nonactivatingPanel) }
        panel = KeyPanel(contentRect: old?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: style, backing: .buffered, defer: false)
        panel.title = "Showrunner"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstClickHostingView(rootView: ContentView(m: model))
        panel.contentMinSize = NSSize(width: 760, height: 420)
        applyWindowPrefs()
        if old == nil {
            panel.setFrameAutosaveName("ShowrunnerPanel")
            if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }), let scr = NSScreen.screens.first {
                let f = scr.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 20, y: f.maxY - 20))
            }
        } else {
            old?.setFrameAutosaveName("")
            old?.close()
            panel.setFrameAutosaveName("ShowrunnerPanel")
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func applyWindowPrefs() {
        panel.level = Pref.floatOnTop ? .floating : .normal
        panel.isFloatingPanel = Pref.floatOnTop
        panel.sharingType = Pref.hideFromSharing ? .none : .readOnly  // .none leaves it out of screenshots and shares that honour it
    }

    func applyMenuBarIcon() {
        if Pref.menuBarIcon, item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.title = "SR"
            let menu = NSMenu()
            menu.delegate = self
            item?.menu = menu
        } else if !Pref.menuBarIcon, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    // MARK: the app's menu bar

    func mainMenu() -> NSMenu {
        let bar = NSMenu()
        func sub(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            build(m)
            mi.submenu = m
            bar.addItem(mi)
            return m
        }
        func add(_ m: NSMenu, _ t: String, _ a: Selector, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let mi = NSMenuItem(title: t, action: a, keyEquivalent: k)
            mi.keyEquivalentModifierMask = mods
            mi.target = target ?? self
            m.addItem(mi)
        }
        let arrow = { (c: Int) in String(UnicodeScalar(UInt16(c)).map(Character.init) ?? " ") }

        _ = sub("Showrunner") { m in
            add(m, "About Showrunner", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
            m.addItem(.separator())
            add(m, "Hide Showrunner", #selector(NSApplication.hide(_:)), "h", target: NSApp)
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
            m.addItem(.separator())
            add(m, "Quit Showrunner", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        }
        _ = sub("File") { m in
            add(m, "New Show from Template", #selector(newShow), "n")
            add(m, "Open Show…", #selector(openShow), "o")
            let r = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let rm = NSMenu(title: "Open Recent")
            rm.delegate = self
            r.submenu = rm
            m.addItem(r)
            m.addItem(.separator())
            add(m, "Edit Show File", #selector(editShow), "e")
            add(m, "Reveal in Finder", #selector(revealShow), "r", [.command, .shift])
            add(m, "Reload", #selector(reloadShow), "r")
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil)
        }
        _ = sub("Edit") { m in
            add(m, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)
        }
        _ = sub("Show") { m in
            add(m, "Start / Next", #selector(primary), "\r")
            add(m, "Next Item", #selector(nextItem), arrow(NSDownArrowFunctionKey))
            add(m, "Previous Item", #selector(prevItem), arrow(NSUpArrowFunctionKey))
            add(m, "Next Beat", #selector(nextBeat), arrow(NSRightArrowFunctionKey))
            add(m, "Previous Beat", #selector(prevBeat), arrow(NSLeftArrowFunctionKey))
            add(m, "Pause / Resume", #selector(toggle), "p")
            m.addItem(.separator())
            add(m, "Bring It Forward Again", #selector(arrive), "g")
            add(m, "Use Fallback", #selector(fallback), "f", [.command, .option])
            m.addItem(.separator())
            add(m, "Save Run", #selector(saveRun), "s")
            add(m, "Restart Clock", #selector(restartClock), "k", [.command, .shift])
            add(m, "Run Checks", #selector(runChecks), "k")
        }
        _ = sub("View") { m in
            add(m, "Bigger Text", #selector(bigger), "+")
            add(m, "Smaller Text", #selector(smaller), "-")
            m.addItem(.separator())
            add(m, "Float on Top", #selector(toggleFloat))
            add(m, "Hide from Screen Sharing", #selector(toggleSharing))
            add(m, "Don't Take Focus When Clicked", #selector(toggleKeepFocus))
            add(m, "Menu Bar Icon", #selector(toggleMenuBarIcon))
        }
        let win = sub("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
            add(m, "Showrunner", #selector(show), "1")
        }
        NSApp.windowsMenu = win
        _ = sub("Help") { m in
            add(m, "Showrunner Guide", #selector(openGuide))
            add(m, "Example Shows", #selector(openExamples))
        }
        return bar
    }

    func validateMenuItem(_ mi: NSMenuItem) -> Bool {
        switch mi.action {
        case #selector(toggleFloat): mi.state = Pref.floatOnTop ? .on : .off
        case #selector(toggleSharing): mi.state = Pref.hideFromSharing ? .on : .off
        case #selector(toggleKeepFocus): mi.state = Pref.keepFocus ? .on : .off
        case #selector(toggleMenuBarIcon): mi.state = Pref.menuBarIcon ? .on : .off
        case #selector(editShow), #selector(revealShow), #selector(reloadShow), #selector(saveRun), #selector(restartClock), #selector(runChecks):
            return model.path != nil
        case #selector(arrive): return !(model.current?.item.go.isEmpty ?? true)
        case #selector(fallback): return !(model.current?.item.fallback.isEmpty ?? true)
        case #selector(primary), #selector(nextItem), #selector(prevItem), #selector(nextBeat), #selector(prevBeat), #selector(toggle):
            return !model.entries.isEmpty
        default: break
        }
        return true
    }

    // rebuild the status menu and Open Recent each time they open, so the recent list stays current
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Open Recent" {
            for mi in recentItems() { menu.addItem(mi) }
            if menu.items.isEmpty { menu.addItem(withTitle: "No recent shows", action: nil, keyEquivalent: "") }
            return
        }
        menu.addItem(withTitle: "Show Showrunner", action: #selector(show), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Show…", action: #selector(openShow), keyEquivalent: "")
        let r = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu()
        for mi in recentItems() { recent.addItem(mi) }
        r.submenu = recent
        menu.addItem(r)
        menu.addItem(withTitle: "Edit Show File", action: #selector(editShow), keyEquivalent: "")
        menu.addItem(withTitle: "Reload", action: #selector(reloadShow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for mi in menu.items where mi.action != nil && mi.action != #selector(NSApplication.terminate(_:)) { mi.target = self }
    }

    func recentItems() -> [NSMenuItem] {
        (UserDefaults.standard.stringArray(forKey: "recent") ?? []).map { p in
            let mi = NSMenuItem(title: (p as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            mi.representedObject = p
            mi.toolTip = p
            mi.target = self
            return mi
        }
    }

    @objc func show() { panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless() }
    @objc func reloadShow() { model.reload() }
    @objc func editShow() { if let p = model.path { NSWorkspace.shared.open(URL(fileURLWithPath: (p as NSString).resolvingSymlinksInPath)) } }
    @objc func revealShow() { if let p = model.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (p as NSString).resolvingSymlinksInPath)]) } }
    @objc func openRecent(_ s: NSMenuItem) { if let p = s.representedObject as? String { open(p) } }

    @objc func primary() { model.primary() }
    @objc func nextItem() { model.go(model.pos + 1) }
    @objc func prevItem() { model.back() }
    @objc func nextBeat() { model.step(1) }
    @objc func prevBeat() { model.step(-1) }
    @objc func toggle() { model.toggle() }
    @objc func arrive() { model.arrive() }
    @objc func fallback() { model.fallback() }
    @objc func saveRun() { model.saveRun() }
    @objc func restartClock() { model.resetClock(); model.go(model.pos, act: false) }
    @objc func runChecks() { model.runChecks() }
    @objc func bigger() { model.fontSize = min(40, model.fontSize + 2) }
    @objc func smaller() { model.fontSize = max(11, model.fontSize - 2) }
    @objc func toggleFloat() { Pref.floatOnTop.toggle(); applyWindowPrefs() }
    @objc func toggleSharing() { Pref.hideFromSharing.toggle(); applyWindowPrefs() }
    @objc func toggleKeepFocus() { Pref.keepFocus.toggle(); makeWindow() }
    @objc func toggleMenuBarIcon() { Pref.menuBarIcon.toggle(); applyMenuBarIcon() }
    @objc func openGuide() { if let p = Bundle.main.path(forResource: "README", ofType: "md") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    @objc func openExamples() { if let p = Bundle.main.path(forResource: "examples", ofType: nil) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }

    func open(_ p: String) {
        model.open(p)
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: p))
        show()
    }

    @objc func openShow() {
        NSApp.activate(ignoringOtherApps: true)
        let o = NSOpenPanel()
        o.allowsMultipleSelection = false
        o.canChooseDirectories = false
        o.message = "Choose a .show.md or .show.json"
        o.directoryURL = URL(fileURLWithPath: (("~/Showrunner") as NSString).expandingTildeInPath)
        if o.runModal() == .OK, let u = o.url { open(u.path) }
    }

    @objc func newShow() {
        let dir = ("~/Showrunner" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let path = (dir as NSString).appendingPathComponent("Untitled \(f.string(from: Date())).show.md")
        let tpl = Bundle.main.path(forResource: "template", ofType: "md").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "title: Untitled\n\n# Intro (2m)\n\n## [talk] Hello\n\nWhat you say.\n"
        try? tpl.write(toFile: path, atomically: true, encoding: .utf8)
        open(path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if model != nil && panel != nil { open(filename) } else { pending = filename }
        return true
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
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
app.setActivationPolicy(.regular)
app.run()

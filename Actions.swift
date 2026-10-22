// What an item does when you arrive: bring a Chrome tab, an app, a file, a slide or a video forward.
// Chrome tabs are found by URL or title, through Handle's bridge when it runs (no permission prompt) and
// through AppleScript when it doesn't. Shell commands never run on arrival; they become buttons.
import AppKit

enum Handle {
    static let base = "http://127.0.0.1:4910"

    static func call(_ method: String, _ params: J = [:], timeout: Double = 20, done: ((Data?) -> Void)? = nil) {
        var req = URLRequest(url: URL(string: base + "/ext/cmd")!, timeoutInterval: timeout + 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params, "timeout": timeout])
        URLSession.shared.dataTask(with: req) { data, _, _ in done?(data) }.resume()
    }

    // a panel action on the demo tab: play, pause, toggle, next, prev, stop, jumpplay, resetall, tab
    static func send(_ action: String, _ extra: J = [:]) {
        var p = extra
        p["panel"] = action
        p["src"] = "app"
        call("panel_msg", p, timeout: ["play", "toggle", "jumpplay"].contains(action) ? 600 : action == "resetall" ? 120 : 30)
    }

    static func sync(_ path: String, timeout: Double = 3) -> Data? {
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: URL(string: base + path)!, timeoutInterval: timeout)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return out
    }

    static func syncCmd(_ method: String, _ params: J = [:], timeout: Double = 5) -> J? {
        var out: J?
        let sem = DispatchSemaphore(value: 0)
        call(method, params, timeout: timeout) { d in
            if let d, let j = try? JSONSerialization.jsonObject(with: d) as? J { out = (j["result"] as? J) ?? j }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout + 6)
        return out
    }

    // every Chrome tab Handle knows: (ext tab id, url, title)
    static func tabs() -> [(id: Int, url: String, title: String)]? {
        guard let d = sync("/api/state"), let j = try? JSONSerialization.jsonObject(with: d) as? J,
              let st = j["state"] as? J, let tabs = st["tabs"] as? [String: J] else { return nil }
        return tabs.values.compactMap { t in
            guard let id = t.int("ext_tab_id") else { return nil }
            return (id, t.str("url") ?? "", t.str("title") ?? "")
        }
    }

    // the tab pinned to an autopilot flow
    static func tabId(flow: Int) -> Int? {
        guard let s = syncCmd("panel_state"), let tabs = s["tabs"] as? [J] else { return nil }
        return tabs.first { $0.int("flowIdx") == flow }?.int("id")
    }
}

enum Script {
    @discardableResult
    static func run(_ src: String) -> (ok: Bool, out: String) {
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { return (false, (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error") }
        return (true, r?.stringValue ?? "")
    }
    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}

enum Runner {
    static func matcher(_ pat: String) -> (String) -> Bool {
        let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive])
        return { s in
            if s.localizedCaseInsensitiveContains(pat) { return true }
            guard let re else { return false }
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    static func activate(bundle: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
    }

    static func chrome(_ a: J) -> String {
        let front = a.bool("front") ?? true
        if let f = a.int("handleFlow"), let id = Handle.tabId(flow: f) {
            Handle.send("tab", ["tabId": id])
            if front { activate(bundle: "com.google.Chrome") }
            return "Chrome: demo tab \(f)"
        }
        if let pat = a.str("chrome"), !pat.isEmpty {
            let hit = matcher(pat)
            if let tabs = Handle.tabs(), let t = tabs.first(where: { hit($0.url) || hit($0.title) }) {
                Handle.send("tab", ["tabId": t.id])
                if front { activate(bundle: "com.google.Chrome") }
                return "Chrome: \(t.title)"
            }
            // without Handle: ask Chrome for every tab, pick the first match, bring its window forward
            let list = Script.run("""
            tell application "Google Chrome"
              set out to ""
              repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                  set out to out & w & tab & t & tab & (URL of tab t of window w) & tab & (title of tab t of window w) & linefeed
                end repeat
              end repeat
              return out
            end tell
            """)
            if list.ok {
                for row in list.out.split(separator: "\n") {
                    let c = row.components(separatedBy: "\t")
                    guard c.count >= 4, hit(c[2]) || hit(c[3]) else { continue }
                    Script.run("""
                    tell application "Google Chrome"
                      set active tab index of window \(c[0]) to \(c[1])
                      set index of window \(c[0]) to 1
                      \(front ? "activate" : "")
                    end tell
                    """)
                    return "Chrome: \(c[3])"
                }
            }
        }
        if let u = a.str("open") {
            open(u, app: "Google Chrome")
            return "Chrome: opened \(u)"
        }
        return "Chrome: no tab matches \(a.str("chrome") ?? "")"
    }

    static func open(_ target: String, app: String? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = (app.map { ["-a", $0] } ?? []) + [target]
        try? p.run()
    }

    // run one action; returns a line for the log
    static func run(_ a: J, base: String) -> String {
        if a["chrome"] != nil || a["handleFlow"] != nil { return chrome(a) }
        if let app = a.str("app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app] + (a.str("file").map { [resolvePath($0, base)] } ?? [])
            try? p.run()
            return "App: \(app)"
        }
        if let o = a.str("open") {
            open(o.contains("://") ? o : resolvePath(o, base))
            return "Opened \(o)"
        }
        if let n = a.int("keynote") {
            let r = Script.run("""
            tell application "Keynote"
              activate
              if playing then
                show slide \(n) of front document
              else
                start front document from slide \(n) of front document
              end if
            end tell
            """)
            return r.ok ? "Keynote: slide \(n)" : "Keynote: \(r.out)"
        }
        if let n = a.int("powerpoint") {
            // best effort: PowerPoint shows on the screen that holds the deck window, and can't jump inside a running show
            let r = Script.run("""
            tell application "Microsoft PowerPoint"
              activate
              set p to active presentation
              if (count of slide show windows) > 0 then exit slide show (slide show view of slide show window 1)
              set s to slide show settings of p
              set range type of s to slide show range
              set starting slide of s to \(n)
              set ending slide of s to (count of slides of p)
              run slide show s
              set range type of s to slide show range show all
              set starting slide of s to 1
              set ending slide of s to 1
            end tell
            """)
            return r.ok ? "PowerPoint: slide \(n)" : "PowerPoint: \(r.out)"
        }
        if let v = a.str("video") {
            let path = resolvePath(v, base)
            let r = Script.run("""
            tell application "QuickTime Player"
              activate
              set d to open POSIX file \(Script.quote(path))
              set presenting of d to true
              play d
            end tell
            """)
            return r.ok ? "Video: \((v as NSString).lastPathComponent)" : "Video: \(r.out)"
        }
        if let h = a.str("handle") { Handle.send(h); return "Handle: \(h)" }
        if let w = a.num("wait") { Thread.sleep(forTimeInterval: w); return "" }
        if a["shell"] != nil { return "" }  // shell runs from its button only
        return "Unknown action: \(a.keys.sorted().joined(separator: ", "))"
    }

    static func runAll(_ actions: [J], base: String, log: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for a in actions {
                let line = run(a, base: base)
                if !line.isEmpty { DispatchQueue.main.async { log(line) } }
            }
        }
    }

    // shell: in a visible Terminal window (the audience sees it), or in the background with output in the log
    static func shell(_ a: J, base: String, log: @escaping (String) -> Void) {
        guard let cmd = a.str("shell") else { return }
        let cwd = resolvePath(a.str("cwd") ?? "~", base)
        if a.bool("terminal") ?? true {
            let r = Script.run("""
            tell application "Terminal"
              activate
              do script \(Script.quote("cd \(cwdQuoted(cwd)) && \(cmd)"))
            end tell
            """)
            log(r.ok ? "Terminal: \(cmd)" : "Terminal: \(r.out)")
            return
        }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { log("$ \(cmd) → exit \(p.terminationStatus)\n" + out.suffix(800)) }
        }
    }

    static func cwdQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // a short label for a button or the outline
    static func label(_ a: J) -> String {
        if let s = a.str("shell") { return "Run: \(s)" }
        if let v = a.str("video") { return "Play \((v as NSString).lastPathComponent)" }
        if let c = a.str("chrome") { return "Chrome: \(c)" }
        if let f = a.int("handleFlow") { return "Demo tab \(f)" }
        if let app = a.str("app") { return app }
        if let o = a.str("open") { return "Open \((o as NSString).lastPathComponent)" }
        if let n = a.int("keynote") { return "Keynote slide \(n)" }
        if let n = a.int("powerpoint") { return "PowerPoint slide \(n)" }
        return a.keys.sorted().joined(separator: ", ")
    }
}

// Preflight: is everything the show needs open and reachable?
struct Check: Identifiable { let id: Int; let label: String; var ok: Bool?; var detail: String; let fix: J? }

enum Preflight {
    static func run(_ show: Show) -> [Check] {
        var checks: [Check] = []
        var tabs: [(id: Int, url: String, title: String)]?? = nil
        func chromeTabs() -> [(id: Int, url: String, title: String)]? {
            if tabs == nil { tabs = .some(Handle.tabs()) }
            return tabs!
        }
        for (k, c) in show.preflight.enumerated() {
            var label = c.str("label") ?? ""
            var ok = false
            var detail = ""
            var fix: J?
            if let pat = c.str("chrome") {
                if label.isEmpty { label = "Chrome tab: \(pat)" }
                if let t = chromeTabs() {
                    let hit = Runner.matcher(pat)
                    ok = t.contains { hit($0.url) || hit($0.title) }
                    detail = ok ? "open" : "no tab matches"
                } else { detail = "Handle not running; can't see tabs" }
                if !ok, let u = c.str("open") { fix = ["open": u] }
            } else if let app = c.str("app") {
                if label.isEmpty { label = "\(app) running" }
                ok = NSWorkspace.shared.runningApplications.contains { $0.localizedName == app }
                detail = ok ? "running" : "not running"
                if !ok { fix = ["app": app] }
            } else if let f = c.str("file") {
                let p = resolvePath(f, show.base)
                if label.isEmpty { label = "File: \((p as NSString).lastPathComponent)" }
                ok = FileManager.default.fileExists(atPath: p)
                detail = ok ? "found" : "missing: \(p)"
            } else if let u = c.str("url") {
                if label.isEmpty { label = "Reachable: \(u)" }
                (ok, detail) = reach(u)
            } else if let n = c.int("displays") {
                if label.isEmpty { label = "\(n) displays" }
                let have = NSScreen.screens.count
                ok = have >= n
                detail = "\(have) connected"
            } else if c["handle"] != nil {
                if label.isEmpty { label = "Handle bridge" }
                ok = Handle.sync("/ext/status") != nil
                detail = ok ? "connected" : "not reachable on :4910"
            } else {
                label = label.isEmpty ? "Manual check" : label
                checks.append(Check(id: k, label: label, ok: nil, detail: c.str("note") ?? "tick it yourself", fix: nil))
                continue
            }
            checks.append(Check(id: k, label: label, ok: ok, detail: detail, fix: fix))
        }
        return checks
    }

    static func reach(_ u: String) -> (Bool, String) {
        guard let url = URL(string: u) else { return (false, "bad URL") }
        var res = (false, "no answer")
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, r, e in
            if let h = r as? HTTPURLResponse { res = (h.statusCode < 400, "HTTP \(h.statusCode)") } else if let e { res = (false, e.localizedDescription) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8)
        return res
    }
}

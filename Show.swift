// Show files: the run of show a presenter follows. A show is sections of items. Each item says what to do
// (cue), what to say (say, or a list of lines), what to have ready if asked (note), and which windows to
// bring forward when you arrive (go). Shows are JSON (*.show.json) or Markdown (*.show.md); see README.md.
import Foundation

typealias J = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func num(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue ?? (self[k] as? String).flatMap(Double.init) }
    func int(_ k: String) -> Int? { num(k).map { Int($0) } }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func list(_ k: String) -> [J] { (self[k] as? [J]) ?? ((self[k] as? J).map { [$0] } ?? []) }
}

struct Line { var say: String; var note: String = ""; var step: Int? = nil }

struct Item {
    var kind = "talk"          // slide, demo, talk, app, video, break (sets the icon; behaviour comes from go)
    var title = ""
    var cue = ""               // what to do
    var say = ""               // what to say
    var note = ""              // if asked
    var lines: [Line] = []     // what to say, beat by beat
    var image: String?         // slide thumbnail or screenshot, to match what is on screen
    var slide: Int?
    var minutes: Double?
    var owner: String?         // who presents it
    var go: [J] = []           // actions run on arrival
    var fallback: [J] = []     // actions behind the "Use fallback" button
    var handle = false         // a Handle autopilot flow plays on this item's tab
    var handleFlow: Int?
    var autoGo = true
}

struct Section { var title: String; var minutes: Double?; var owner: String?; var items: [Item] }
struct QA { var q: String; var a: String }

struct Show {
    var title = ""
    var path = ""
    var base = ""
    var sections: [Section] = []
    var qa: [QA] = []
    var preflight: [J] = []
    var autoGo = true
    var attach: [String] = []  // files to keep with the show (a deck, a handout); packed with it and listed in the window
    var usesHandle: Bool { sections.contains { $0.items.contains { $0.handle } } }
}

struct Entry { let index: Int; let section: Int; let sectionTitle: String; let item: Item; let planned: Double }

func resolvePath(_ p: String, _ base: String) -> String {
    let e = (p as NSString).expandingTildeInPath
    if e.hasPrefix("/") || e.contains("://") { return e }
    return (base as NSString).appendingPathComponent(e)
}

struct LoadError: Error, CustomStringConvertible { let description: String }

enum Loader {
    static func load(_ path: String) throws -> Show {
        let real = (path as NSString).resolvingSymlinksInPath
        let base = (real as NSString).deletingLastPathComponent
        guard let text = try? String(contentsOfFile: real, encoding: .utf8) else { throw LoadError(description: "can't read \(path)") }
        var show = real.lowercased().hasSuffix(".md") ? Markdown.parse(text, base: base) : try fromJSON(text, base: base)
        show.path = path
        show.base = base
        if show.title.isEmpty { show.title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        return show
    }

    static func fromJSON(_ text: String, base: String) throws -> Show {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) } catch {
            throw LoadError(description: "not valid JSON: \(error.localizedDescription)")
        }
        guard let d = obj as? J else { throw LoadError(description: "the top level must be an object with sections") }
        var s = Show()
        s.title = d.str("title") ?? ""
        s.autoGo = d.bool("autoGo") ?? true
        s.preflight = d.list("preflight")
        s.attach = ((d["attach"] as? [String]) ?? (d["attach"] as? String).map { [$0] } ?? []).map { resolvePath($0, base) }
        s.qa = d.list("qa").map { QA(q: $0.str("q") ?? "", a: $0.str("a") ?? "") }
        s.sections = d.list("sections").map { sd in
            Section(title: sd.str("title") ?? "", minutes: sd.num("minutes"), owner: sd.str("owner"),
                    items: sd.list("items").map { item($0, base) })
        }
        return s
    }

    static func item(_ d: J, _ base: String) -> Item {
        var it = Item()
        it.kind = d.str("kind") ?? "talk"
        it.title = d.str("title") ?? ""
        it.cue = d.str("cue") ?? ""
        it.say = d.str("say") ?? ""
        it.note = d.str("note") ?? ""
        it.image = d.str("image").map { resolvePath($0, base) }
        it.slide = d.int("slide")
        it.minutes = d.num("minutes")
        it.owner = d.str("owner")
        it.lines = d.list("lines").map { Line(say: $0.str("say") ?? "", note: $0.str("note") ?? "", step: $0.int("step")) }
        it.go = d.list("go")
        it.fallback = d.list("fallback")
        it.handleFlow = it.go.compactMap { $0.int("handleFlow") }.first
        it.handle = d.bool("handle") ?? (it.handleFlow != nil && !["slide", "talk"].contains(it.kind))
        it.autoGo = d.bool("autoGo") ?? true
        return it
    }

    // planned minutes per item: its own, else an even share of its section's
    static func entries(_ s: Show) -> [Entry] {
        var out: [Entry] = []
        for (k, sec) in s.sections.enumerated() {
            let fixed = sec.items.compactMap { $0.minutes }.reduce(0, +)
            let open = sec.items.filter { $0.minutes == nil }.count
            let share = open > 0 ? max(0, (sec.minutes ?? fixed) - fixed) / Double(open) : 0
            for it in sec.items {
                out.append(Entry(index: out.count, section: k, sectionTitle: sec.title, item: it, planned: it.minutes ?? share))
            }
        }
        return out
    }
}

// Markdown shows, for writing a run of show by hand:
//   title: Quarterly review          front matter, before the first heading
//   attach: deck.pptx                a file to keep with the show (repeatable); packed when you share it
//   # Branding (4m)                  a section, with an optional time budget
//   ## [slide 2] Home page (1m)      an item: [slide N], [demo], [talk], [app], [video], [break]
//   > Switch to the Admin Console    what to do (cue)
//   Plain paragraphs                 what to say
//   - one beat                       what to say, beat by beat (⌃⌥→ steps through them)
//   ? If asked: …                    a note (after a beat, it belongs to that beat)
//   @chrome admin\.example | https://… bring a Chrome tab forward, matched by URL or title; open the URL if none
//   @handle 3 · @app Visual Studio Code | ~/src/x.ts · @open ~/file · @keynote 4 · @powerpoint 4
//   @video ~/rec.mp4 · @shell npm run build · @cwd ~/src · @wait 1 · @image slides/02.png
//   @owner Akul · @min 2 · @noauto · @fallback video ~/rec.mp4
//   # Q&A                            then ## question / answer text
enum Markdown {
    static func parse(_ text: String, base: String) -> Show {
        var s = Show()
        var sec: Section?
        var it: Item?
        var para: [String] = []
        var inQA = false
        var q: String?
        var a: [String] = []
        var lastWasLine = false

        func flushPara() {
            guard !para.isEmpty else { return }
            let p = para.joined(separator: " ")
            para = []
            if inQA { a.append(p); return }
            if it == nil { it = Item(); it!.title = "Intro" }
            it!.say += (it!.say.isEmpty ? "" : "\n\n") + p
        }
        func flushQA() {
            if let qq = q { s.qa.append(QA(q: qq, a: a.joined(separator: "\n\n"))) }
            q = nil; a = []
        }
        func flushItem() {
            flushPara()
            if let i = it {
                if sec == nil { sec = Section(title: "", minutes: nil, owner: nil, items: []) }
                sec!.items.append(i)
            }
            it = nil
        }
        func flushSection() {
            flushItem()
            if let x = sec { s.sections.append(x) }
            sec = nil
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); continue }
            if sec == nil, it == nil, !inQA, line.lowercased().hasPrefix("title:") {
                s.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue
            }
            if sec == nil, it == nil, !inQA, line.lowercased().hasPrefix("attach:") {
                s.attach.append(resolvePath(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces), base)); continue
            }
            if line == "---" { continue }
            if line.hasPrefix("# ") {
                if inQA { flushPara(); flushQA() } else { flushSection() }
                let (t, m) = minutes(String(line.dropFirst(2)))
                let lower = t.lowercased()
                inQA = lower == "q&a" || lower == "qa" || lower.hasPrefix("questions")
                if !inQA { sec = Section(title: t, minutes: m, owner: nil, items: []) }
                continue
            }
            if inQA && (line.hasPrefix("## ") || line.hasPrefix("### ")) {
                flushPara(); flushQA()
                q = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                continue
            }
            if inQA { para.append(line); continue }
            if line.hasPrefix("## ") {
                flushItem()
                var t = String(line.dropFirst(3))
                var i = Item()
                if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
                    let tag = t[t.index(after: t.startIndex)..<close].split(separator: " ").map(String.init)
                    i.kind = tag.first?.lowercased() ?? "talk"
                    if tag.count > 1 { i.slide = Int(tag[1]) }
                    t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                let (tt, m) = minutes(t)
                i.title = tt.isEmpty ? (i.slide.map { "Slide \($0)" } ?? i.kind.capitalized) : tt
                i.minutes = m
                it = i
                lastWasLine = false
                continue
            }
            if it == nil { it = Item(); it!.title = "Intro" }
            if line.hasPrefix(">") {
                flushPara()
                let c = line.dropFirst().trimmingCharacters(in: .whitespaces)
                it!.cue += (it!.cue.isEmpty ? "" : " ") + c
                continue
            }
            if line.hasPrefix("? ") {
                flushPara()
                let n = String(line.dropFirst(2))
                if lastWasLine, !it!.lines.isEmpty {
                    let k = it!.lines.count - 1
                    it!.lines[k].note += (it!.lines[k].note.isEmpty ? "" : " ") + n
                } else {
                    it!.note += (it!.note.isEmpty ? "" : "\n") + n
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushPara()
                it!.lines.append(Line(say: String(line.dropFirst(2))))
                lastWasLine = true
                continue
            }
            if line.hasPrefix("@") {
                flushPara()
                directive(String(line.dropFirst()), &it!, base)
                continue
            }
            lastWasLine = false
            para.append(line)
        }
        if inQA { flushPara(); flushQA() } else { flushSection() }
        if sec != nil { flushSection() }
        return s
    }

    // "Branding (4m)" or "Branding (1.5 min)" → ("Branding", 4)
    static func minutes(_ t: String) -> (String, Double?) {
        let re = try! NSRegularExpression(pattern: #"\s*\((\d+(?:\.\d+)?)\s*(?:m|min|mins|minutes)\)\s*$"#)
        let r = NSRange(t.startIndex..., in: t)
        guard let m = re.firstMatch(in: t, range: r), let nr = Range(m.range(at: 1), in: t), let all = Range(m.range, in: t) else {
            return (t.trimmingCharacters(in: .whitespaces), nil)
        }
        return (t.replacingCharacters(in: all, with: "").trimmingCharacters(in: .whitespaces), Double(t[nr]))
    }

    static func action(_ verb: String, _ rest: String) -> J? {
        let parts = rest.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        switch verb {
        case "chrome", "tab": var a: J = ["chrome": parts[0]]; if parts.count > 1 { a["open"] = parts[1] }; return a
        case "handle": return ["handleFlow": Int(rest) ?? 0]
        case "app": var a: J = ["app": parts[0]]; if parts.count > 1 { a["file"] = parts[1] }; return a
        case "open", "url": return ["open": rest]
        case "keynote", "powerpoint": return [verb: Int(rest) ?? 1]
        case "video": return ["video": rest]
        case "shell", "run": return ["shell": rest]
        case "wait": return ["wait": Double(rest) ?? 1]
        default: return nil
        }
    }

    static func directive(_ d: String, _ it: inout Item, _ base: String) {
        let sp = d.firstIndex(of: " ")
        let verb = (sp.map { String(d[..<$0]) } ?? d).lowercased()
        let rest = sp.map { String(d[d.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
        switch verb {
        case "image": it.image = resolvePath(rest, base)
        case "owner": it.owner = rest
        case "min", "minutes": it.minutes = Double(rest)
        case "noauto": it.autoGo = false
        case "cwd": if !it.go.isEmpty { it.go[it.go.count - 1]["cwd"] = rest }
        case "fallback":
            let sp2 = rest.firstIndex(of: " ")
            let v = (sp2.map { String(rest[..<$0]) } ?? rest).lowercased()
            let r = sp2.map { String(rest[rest.index(after: $0)...]) } ?? ""
            if let a = action(v, r) { it.fallback.append(a) }
        default:
            if let a = action(verb, rest) {
                it.go.append(a)
                if verb == "handle" { it.handle = !["slide", "talk"].contains(it.kind); it.handleFlow = a.int("handleFlow") }
            }
        }
    }
}

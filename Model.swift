// The presenter's state: which show, where you are in it, the clock, rehearsal timings, Handle's demo state.
import AppKit
import SwiftUI

struct PanelState: Decodable {
    let title: String?; let flow: Bool?; let tabId: Int?
    let steps: [String]?; let says: [String]?; let notes: [String]?; let intro: String?; let i: Int?; let n: Int?
    let status: String?; let error: String?; let pausedBy: String?
    let dwellEnd: Double?; let dwellMs: Double?
    struct Tab: Decodable { let id: Int; let active: Bool?; let flowIdx: Int? }
    let tabs: [Tab]?
}

final class Model: ObservableObject {
    @Published var show = Show()
    @Published var entries: [Entry] = []
    @Published var loadError: String?
    @Published var pos = 0
    @Published var beat = 0                  // the current line of a beat-by-beat item
    @Published var now = Date()
    @Published var running = false
    @Published var log: [String] = []
    @Published var handle: PanelState?
    @Published var handleUp = false
    @Published var checks: [Check] = []
    @Published var checking = false
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 18 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var notice: String?
    @Published var lastRun: [String: Double] = [:]   // section title → seconds, from the last saved rehearsal

    var path: String? { didSet { UserDefaults.standard.set(path, forKey: "showPath") } }
    private var stamp: Date?
    private var elapsedBefore: TimeInterval = 0
    private var runStart: Date?
    private var itemStart: Date?
    private(set) var spent: [Int: TimeInterval] = [:]
    private var lastGo = Date.distantPast
    private var timer: Timer?

    init() {
        if let p = UserDefaults.standard.string(forKey: "showPath") { open(p, keepPosition: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    var current: Entry? { entries.indices.contains(pos) ? entries[pos] : nil }
    var next: Entry? { entries.indices.contains(pos + 1) ? entries[pos + 1] : nil }

    // MARK: loading

    func open(_ p: String, keepPosition: Bool = false) {
        path = p
        stamp = nil
        reload(keepPosition: keepPosition)
        var recent = UserDefaults.standard.stringArray(forKey: "recent") ?? []
        recent.removeAll { $0 == p }
        recent.insert(p, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(10)), forKey: "recent")
        if !keepPosition { resetClock(); go(0, act: false) }
        loadLastRun()
    }

    func reload(keepPosition: Bool = true) {
        guard let path else { return }
        do {
            let s = try Loader.load(path)
            show = s
            entries = Loader.entries(s)
            loadError = nil
            if !keepPosition { pos = 0 }
            if keepPosition { pos = min(UserDefaults.standard.integer(forKey: posKey), max(0, entries.count - 1)) }
        } catch {
            loadError = "\(error)"
        }
        stamp = mtime()
    }

    private var posKey: String { "pos:" + (path ?? "") }

    private func mtime() -> Date? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath)[.modificationDate]) as? Date
    }

    // MARK: moving

    func go(_ k: Int, act: Bool = true) {
        guard entries.indices.contains(k) else { return }
        if running, let s = itemStart { spent[pos, default: 0] += Date().timeIntervalSince(s) }
        itemStart = Date()
        pos = k
        beat = 0
        UserDefaults.standard.set(k, forKey: posKey)
        lastGo = Date()
        let it = entries[k].item
        if act, show.autoGo, it.autoGo, !it.go.isEmpty { arrive() }
    }

    // run this item's actions again (the Go button)
    func arrive() {
        guard let it = current?.item else { return }
        Runner.runAll(it.go, base: show.base) { [weak self] l in self?.say(l) }
    }

    func fallback() {
        guard let it = current?.item else { return }
        Runner.runAll(it.fallback, base: show.base) { [weak self] l in self?.say(l) }
    }

    func shell(_ a: J) { Runner.shell(a, base: show.base) { [weak self] l in self?.say(l) } }

    func say(_ l: String) {
        log.insert("\(Self.clock.string(from: Date()))  \(l)", at: 0)
        if log.count > 60 { log.removeLast() }
    }

    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var isDemo: Bool { current?.item.handle == true }
    var demoLive: Bool {
        guard isDemo, let st = handle?.status else { return false }
        return ["playing", "ready", "paused"].contains(st) && onItemTab
    }
    var onItemTab: Bool {
        guard let f = current?.item.handleFlow else { return true }
        return handle?.tabs?.first { $0.active == true }?.flowIdx == f
    }

    // the one big button: start the clock, play or pause the demo, else move on
    func primary() {
        if !running { startClock(); if pos == 0 && !(current?.item.go.isEmpty ?? true) { arrive() }; return }
        if isDemo && onItemTab, let st = handle?.status {
            switch st {
            case "playing": Handle.send("pause"); return
            case "ready", "paused": Handle.send("play"); return
            default: break
            }
        }
        go(pos + 1)
    }

    func back() { go(pos - 1) }

    // ⌃⌥→ / ⌃⌥←: a demo step on a Handle tab, else the next beat
    func step(_ d: Int) {
        if isDemo { Handle.send(d > 0 ? "next" : "prev"); return }
        let n = current?.item.lines.count ?? 0
        if n > 0 { beat = max(0, min(n - 1, beat + d)) }
    }

    func toggle() {
        if isDemo { Handle.send("toggle") } else if running { pauseClock() } else { startClock() }
    }

    // MARK: clock and rehearsal timings

    var elapsed: TimeInterval { elapsedBefore + (running ? now.timeIntervalSince(runStart ?? now) : 0) }
    var itemElapsed: TimeInterval { (spent[pos] ?? 0) + (running ? now.timeIntervalSince(itemStart ?? now) : 0) }
    var plannedTotal: Double { entries.map { $0.planned }.reduce(0, +) * 60 }
    var plannedBefore: Double { entries.prefix(pos).map { $0.planned }.reduce(0, +) * 60 }

    func sectionElapsed(_ sec: Int) -> TimeInterval {
        entries.filter { $0.section == sec }.map { e in (spent[e.index] ?? 0) + (e.index == pos && running ? now.timeIntervalSince(itemStart ?? now) : 0) }.reduce(0, +)
    }
    func sectionPlanned(_ sec: Int) -> Double { entries.filter { $0.section == sec }.map { $0.planned }.reduce(0, +) * 60 }

    func startClock() {
        guard !running else { return }
        running = true
        runStart = Date()
        itemStart = Date()
    }

    func pauseClock() {
        guard running else { return }
        elapsedBefore += Date().timeIntervalSince(runStart ?? Date())
        if let s = itemStart { spent[pos, default: 0] += Date().timeIntervalSince(s) }
        running = false
    }

    func resetClock() {
        running = false
        elapsedBefore = 0
        spent = [:]
        runStart = nil
        itemStart = Date()
    }

    private var rehearsalPath: String? {
        guard let path else { return nil }
        let real = (path as NSString).resolvingSymlinksInPath
        let name = ((real as NSString).lastPathComponent as NSString).deletingPathExtension
        return ((real as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name + ".rehearsals.json")
    }

    // append this run to <show>.rehearsals.json: total, and planned vs actual per item
    func saveRun() {
        let wasRunning = running
        pauseClock()
        guard let rp = rehearsalPath else { return }
        var runs = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rp)))) as? [J] ?? []
        let items: [J] = entries.map { e in
            ["section": e.sectionTitle, "title": e.item.title, "planned": Int(e.planned * 60), "actual": Int(spent[e.index] ?? 0)]
        }
        runs.append(["at": ISO8601DateFormatter().string(from: Date()), "total": Int(elapsed), "planned": Int(plannedTotal), "items": items])
        if let d = try? JSONSerialization.data(withJSONObject: runs, options: [.prettyPrinted]) {
            do { try d.write(to: URL(fileURLWithPath: rp)); say("Saved rehearsal: \(fmt(elapsed)) of \(fmt(plannedTotal)) planned") } catch { say("Couldn't save timings: \(error.localizedDescription)") }
        }
        loadLastRun()
        if wasRunning { startClock() }
    }

    func loadLastRun() {
        lastRun = [:]
        guard let rp = rehearsalPath, let d = try? Data(contentsOf: URL(fileURLWithPath: rp)),
              let runs = try? JSONSerialization.jsonObject(with: d) as? [J], let last = runs.last else { return }
        for i in last.list("items") { lastRun[i.str("section") ?? "", default: 0] += i.num("actual") ?? 0 }
    }

    // MARK: polling

    private func tick() {
        now = Date()
        if let m = mtime(), m != stamp { reload(); say("Reloaded the show") }
        if show.usesHandle { pollHandle() }
    }

    private var polling = false
    private func pollHandle() {
        guard !polling else { return }
        polling = true
        Handle.call("panel_get", timeout: 3) { data in
            let s = data.flatMap { try? JSONDecoder().decode(PanelState.self, from: $0) }
            DispatchQueue.main.async {
                self.polling = false
                self.handleUp = s != nil
                if let s { self.handle = s }
                self.follow()
            }
        }
    }

    // when you switch to a demo tab yourself, move to its item (only when the tab in front changes)
    private var seenFlow: Int?
    private func follow() {
        let f = handle?.tabs?.first { $0.active == true }?.flowIdx
        defer { seenFlow = f }
        guard Date().timeIntervalSince(lastGo) > 2.5, seenFlow != nil, f != seenFlow, let f, f != current?.item.handleFlow else { return }
        let hits = entries.filter { $0.item.handleFlow == f }.map { $0.index }
        if let k = hits.min(by: { abs($0 - pos) < abs($1 - pos) }) { go(k, act: false) }
    }

    func runChecks() {
        checking = true
        let s = show
        DispatchQueue.global().async {
            let r = Preflight.run(s)
            DispatchQueue.main.async { self.checks = r; self.checking = false }
        }
    }

    // MARK: remote control (127.0.0.1:4977)

    func remote(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.first ?? "state" {
        case "next": go(pos + 1)
        case "prev", "back": back()
        case "go": if parts.count > 1, let k = Int(parts[1]) { go(k - 1) }
        case "primary": primary()
        case "toggle": toggle()
        case "beat": step(parts.count > 1 && parts[1] == "prev" ? -1 : 1)
        case "start": startClock()
        case "pause": pauseClock()
        case "reload": reload()
        case "open": if parts.count > 1 { open(parts.dropFirst().joined(separator: "/").removingPercentEncoding ?? "") }
        default: break
        }
        var j: J = ["show": show.title, "pos": pos + 1, "count": entries.count, "running": running,
                    "elapsed": Int(elapsed), "planned": Int(plannedTotal)]
        if let c = current {
            j["item"] = ["section": c.sectionTitle, "title": c.item.title, "kind": c.item.kind, "cue": c.item.cue, "say": c.item.say]
        }
        if let n = next { j["next"] = n.item.title }
        let d = (try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

func fmt(_ t: TimeInterval) -> String {
    let s = Int(abs(t).rounded())
    return (t < 0 ? "-" : "") + String(format: "%d:%02d", s / 60, s % 60)
}

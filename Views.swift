// Left pane (Presenter): where you are, what to do, what to say, and the one button.
// Right pane (Navigator): clock and pace, the slide, and tabs for the outline, Q&A, checks and the log.
import AppKit
import SwiftUI

extension Array {
    subscript(safe k: Int) -> Element? { k >= 0 && k < count ? self[k] : nil }
}

struct ContentView: View {
    @ObservedObject var m: Model
    var body: some View {
        HStack(spacing: 0) {
            Presenter(m: m).frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity)
            Divider()
            Navigator(m: m).frame(width: 400)
        }
    }
}

func icon(_ kind: String) -> String {
    switch kind {
    case "slide": return "▭"
    case "demo": return "▶"
    case "app": return "◳"
    case "video": return "◉"
    case "break": return "☕"
    default: return "✎"
    }
}

struct Presenter: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = m.loadError {
                Text("Can't load the show").font(.system(size: 18, weight: .bold))
                Text(e).font(.system(size: 13)).foregroundColor(.red).textSelection(.enabled)
                Spacer()
            } else if let c = m.current {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.sectionTitle.isEmpty ? m.show.title : c.sectionTitle).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    Text(c.item.title).font(.system(size: 15)).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    if let o = c.item.owner ?? m.show.sections[safe: c.section]?.owner {
                        Text(o).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2)).cornerRadius(4)
                    }
                    Text("\(m.pos + 1) / \(m.entries.count)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                if !c.item.cue.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text("DO").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Color.orange).cornerRadius(4)
                        Text(c.item.cue).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12)).cornerRadius(8)
                }
                ActionButtons(m: m, item: c.item)
                if c.item.handle {
                    if m.onItemTab { DemoLines(m: m) } else { Text("Switching to the demo tab…").foregroundColor(.secondary); Spacer() }
                } else {
                    TalkView(m: m, item: c.item)
                }
            } else {
                Text("No show open").font(.system(size: 18, weight: .bold))
                Text("Open a .show.json or .show.md from the SR menu, or drop one on the app.").foregroundColor(.secondary)
                Spacer()
            }
            BigButtons(m: m)
        }
        .padding(16)
    }
}

// Go again · shell commands · the fallback
struct ActionButtons: View {
    @ObservedObject var m: Model
    let item: Item
    var body: some View {
        let shells = item.go.filter { $0["shell"] != nil }
        let others = item.go.filter { $0["shell"] == nil }
        if !others.isEmpty || !shells.isEmpty || !item.fallback.isEmpty {
            HStack(spacing: 6) {
                if !others.isEmpty {
                    Button("↻ Bring it forward") { m.arrive() }.help(others.map(Runner.label).joined(separator: " · "))
                }
                ForEach(Array(shells.enumerated()), id: \.offset) { _, a in
                    Button(Runner.label(a)) { m.shell(a) }.help("Runs in Terminal")
                }
                if !item.fallback.isEmpty {
                    Button("⚠︎ Use fallback") { m.fallback() }.help(item.fallback.map(Runner.label).joined(separator: " · "))
                }
                Spacer()
            }.controlSize(.small)
        }
    }
}

// what to say: paragraphs, or beats you step through
struct TalkView: View {
    @ObservedObject var m: Model
    let item: Item
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !item.say.isEmpty {
                        Text(item.say).font(.system(size: m.fontSize)).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(item.lines.enumerated()), id: \.offset) { k, l in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.say).font(.system(size: k == m.beat ? m.fontSize : m.fontSize - 3, weight: k == m.beat ? .medium : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundColor(k < m.beat ? .secondary : .primary)
                            if !l.note.isEmpty {
                                Text(l.note).font(.system(size: 12)).italic().foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(k == m.beat ? Color.accentColor.opacity(0.16) : Color.clear)
                        .overlay(alignment: .leading) { if k == m.beat { Rectangle().fill(Color.accentColor).frame(width: 3) } }
                        .cornerRadius(6).id(k)
                        .contentShape(Rectangle())
                        .onTapGesture { m.beat = k }
                    }
                    if !item.note.isEmpty {
                        Text(item.note).font(.system(size: 12)).italic().foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if item.say.isEmpty && item.lines.isEmpty && item.note.isEmpty {
                        Text("Nothing to say here: let the screen show it.").foregroundColor(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: m.beat) { b in withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(b, anchor: .top) } }
        }
    }
}

// the talk track of the Handle demo tab in front, the current step's line highlighted; click a line to play from it
struct DemoLines: View {
    @ObservedObject var m: Model

    var lines: [(step: Int, text: String, note: String)] {
        guard let s = m.handle, s.flow == true else { return [] }
        var out: [(step: Int, text: String, note: String)] = []
        if let t = s.intro, !t.isEmpty { out.append((-1, t, "")) }
        let notes = s.notes ?? []
        for (k, t) in (s.says ?? []).enumerated() where !t.isEmpty { out.append((k, t, notes[safe: k] ?? "")) }
        return out
    }

    var body: some View {
        let s = m.handle
        let i = s?.i ?? 0, n = s?.n ?? 0
        let ls = lines
        let cur = s?.status == "done" || i >= n ? ls.count - 1 : (ls.lastIndex { $0.step <= i } ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            if let it = m.current?.item, !it.say.isEmpty {
                Text(it.say).font(.system(size: m.fontSize - 2)).fixedSize(horizontal: false, vertical: true)
            }
            if ls.isEmpty {
                Text(m.handleUp ? "No lines on this tab: let the screen show it." : "Handle isn't reachable, so the demo can't play.")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(ls.enumerated()), id: \.offset) { k, l in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(l.step < 0 ? "Before you press Play" : "Step \(l.step + 1) · \(s?.steps?[safe: l.step] ?? "")")
                                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).lineLimit(1)
                                    Text(l.text).font(.system(size: k == cur ? m.fontSize : m.fontSize - 3, weight: k == cur ? .medium : .regular))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .foregroundColor(k < cur ? .secondary : .primary)
                                    if !l.note.isEmpty {
                                        Text(l.note).font(.system(size: 12)).italic().foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(k == cur ? Color.accentColor.opacity(0.16) : Color.clear)
                                .overlay(alignment: .leading) { if k == cur { Rectangle().fill(Color.accentColor).frame(width: 3) } }
                                .cornerRadius(6).id(k)
                                .contentShape(Rectangle())
                                .onTapGesture { Handle.send("jumpplay", ["i": max(0, l.step)]) }
                                .help("Play from this step")
                            }
                        }
                    }
                    .onChange(of: cur) { c in withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(c, anchor: .top) } }
                }
            }
        }
    }
}

struct BigButtons: View {
    @ObservedObject var m: Model

    var body: some View {
        let c = m.current
        let st = m.handle?.status ?? ""
        let demo = m.isDemo && m.onItemTab
        let (label, tint): (String, Color) = {
            if !m.running && c != nil { return (m.pos == 0 && m.elapsed == 0 ? "▶  Start the show" : "▶  Resume the clock", .green) }
            if demo && st == "playing" { return ("⏸  Pause", .orange) }
            if demo && st == "ready" { return ("▶  Play the demo", .green) }
            if demo && st == "paused" { return ("▶  Resume", .green) }
            if let n = m.next {
                let name = n.section == c?.section ? n.item.title : "\(n.sectionTitle) · \(n.item.title)"
                return ("Next:  \(name)  ▶", .accentColor)
            }
            return ("End of the show", .gray)
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { m.back() } label: { Text("◀ Back").frame(width: 80, height: 34) }
                    .controlSize(.large).disabled(m.pos == 0)
                Button { m.primary() } label: {
                    Text(label).font(.system(size: 15, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
                .disabled(c == nil || (m.running && m.next == nil && !m.demoLive))
                if m.running, m.demoLive, m.next != nil {
                    Button { m.go(m.pos + 1) } label: { Text("Skip ▶").frame(width: 70, height: 34) }.controlSize(.large)
                        .help("Go to the next item without finishing this demo")
                }
            }
            HStack {
                Text("⌃⌥↓ next · ⌃⌥↑ back · ⌃⌥→ ⌃⌥← beat or step · ⌥Space pause").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("A−") { m.fontSize = max(12, m.fontSize - 2) }.buttonStyle(.borderless).font(.system(size: 11))
                Button("A+") { m.fontSize = min(40, m.fontSize + 2) }.buttonStyle(.borderless).font(.system(size: 11))
            }
            if let n = m.notice { Text(n).font(.system(size: 10)).foregroundColor(.orange) }
        }
    }
}

struct Navigator: View {
    @ObservedObject var m: Model
    @State private var tab = 0
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(m.show.title.isEmpty ? "SHOWRUNNER" : m.show.title.uppercased())
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                if m.show.usesHandle {
                    Circle().fill(m.handleUp ? Color.green : Color.red).frame(width: 8, height: 8)
                        .help(m.handleUp ? "Connected to Handle" : "Handle bridge not reachable")
                }
            }
            Clock(m: m)
            if m.isDemo && m.onItemTab { DemoStatus(m: m) }
            if let c = m.current, let p = c.item.image, let img = NSImage(contentsOfFile: p) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.item.slide.map { "Slide \($0) · \(c.item.title)" } ?? c.item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08)).cornerRadius(8)
            }
            Picker("", selection: $tab) {
                Text("Run of show").tag(0)
                Text("Q&A").tag(1)
                Text("Checks").tag(2)
                Text("Log").tag(3)
            }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case 1: QAView(m: m, query: $query)
            case 2: ChecksView(m: m)
            case 3: LogView(m: m)
            default: Outline(m: m)
            }
        }
        .padding(14)
    }
}

struct Clock: View {
    @ObservedObject var m: Model
    var body: some View {
        let pace = m.elapsed - m.plannedBefore - min(m.itemElapsed, (m.current?.planned ?? 0) * 60)
        let itemPlanned = (m.current?.planned ?? 0) * 60
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(fmt(m.elapsed)).font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(m.running ? .primary : .secondary)
                if m.plannedTotal > 0 { Text("of \(fmt(m.plannedTotal))").font(.system(size: 12)).foregroundColor(.secondary) }
                Spacer()
                if m.plannedTotal > 0 && m.elapsed > 0 {
                    Text(abs(pace) < 15 ? "on time" : pace > 0 ? "\(fmt(pace)) behind" : "\(fmt(-pace)) ahead")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(pace > 60 ? .red : pace > 15 ? .orange : .green)
                }
            }
            HStack(spacing: 8) {
                Text("This item \(fmt(m.itemElapsed))" + (itemPlanned > 0 ? " / \(fmt(itemPlanned))" : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(itemPlanned > 0 && m.itemElapsed > itemPlanned ? .orange : .secondary)
                Spacer()
                Button(m.running ? "⏸ Clock" : "▶ Clock") { m.running ? m.pauseClock() : m.startClock() }
                Button("Save run") { m.saveRun() }.help("Append this run's timings to <show>.rehearsals.json")
                Button("⟲") { m.resetClock() }.help("Reset the clock")
            }.controlSize(.small)
        }
        .padding(10).background(Color.secondary.opacity(0.08)).cornerRadius(8)
    }
}

func pill(_ s: String) -> (String, Color) {
    switch s {
    case "playing": return ("PLAYING", .green)
    case "paused": return ("PAUSED", .orange)
    case "ready": return ("READY", .orange)
    case "done": return ("DONE", .gray)
    case "error": return ("STOPPED", .red)
    default: return ("", .secondary)
    }
}

struct DemoStatus: View {
    @ObservedObject var m: Model
    var body: some View {
        let s = m.handle
        let (label, color) = pill(s?.status ?? "")
        let n = s?.n ?? 0, i = s?.i ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !label.isEmpty {
                    Text(label).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.9)).foregroundColor(.white).clipShape(Capsule())
                }
                Text(i >= n ? "All \(n) steps done" : "Step \(i + 1) of \(n) · \(s?.steps?[safe: i] ?? "")").font(.system(size: 12)).lineLimit(1)
            }
            if s?.status == "paused", let p = s?.pausedBy, !p.isEmpty {
                Text("Paused by your \(p).").font(.system(size: 11)).foregroundColor(.orange)
            }
            if let e = s?.error, !e.isEmpty {
                Text("Stopped: \(e). Do it by hand, then Step ⏭ or Resume.").font(.system(size: 11)).foregroundColor(.red)
            }
            HStack(spacing: 4) {
                Button("⏮ Step") { Handle.send("prev") }
                Button("Step ⏭") { Handle.send("next") }
                Button("⟲ Restart tab") { Handle.send("stop") }
                Button("⟲ Reset all tabs") { Handle.send("resetall") }
            }.controlSize(.small)
        }
        .padding(10).background(Color.secondary.opacity(0.08)).cornerRadius(8)
    }
}

struct Outline: View {
    @ObservedObject var m: Model
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(m.entries, id: \.index) { e in
                        if e.index == 0 || m.entries[e.index - 1].section != e.section {
                            SectionHeader(m: m, e: e).padding(.top, e.index == 0 ? 0 : 8).padding(.bottom, 2)
                        }
                        HStack(spacing: 8) {
                            Text(icon(e.item.kind)).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 14)
                            Text(e.item.title).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            if e.planned > 0 { Text(fmt(e.planned * 60)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(e.index == m.pos ? Color.accentColor.opacity(0.2) : Color.clear).cornerRadius(5)
                        .foregroundColor(e.index < m.pos ? .secondary : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture { m.go(e.index) }
                        .id(e.index)
                    }
                }
            }
            .onChange(of: m.pos) { p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
        }
    }
}

struct SectionHeader: View {
    @ObservedObject var m: Model
    let e: Entry
    var body: some View {
        let planned = m.sectionPlanned(e.section)
        let spent = m.sectionElapsed(e.section)
        let last = m.lastRun[e.sectionTitle]
        HStack {
            Text(e.sectionTitle.isEmpty ? "—" : e.sectionTitle).font(.system(size: 13, weight: .bold))
                .foregroundColor(e.section == m.current?.section ? .primary : .secondary)
            Spacer()
            if spent > 0 {
                Text(fmt(spent)).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(planned > 0 && spent > planned ? .red : planned > 0 && spent > planned * 0.85 ? .orange : .secondary)
            }
            if planned > 0 { Text("/ \(fmt(planned))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
            if let last, last > 0 { Text("last \(fmt(last))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }
        }
    }
}

// questions you may get: the show's Q&A plus every "if asked" note, searchable
struct QAView: View {
    @ObservedObject var m: Model
    @Binding var query: String
    var body: some View {
        var all: [(q: String, a: String, at: Int?)] = m.show.qa.map { ($0.q, $0.a, nil) }
        for e in m.entries {
            if !e.item.note.isEmpty { all.append((e.item.title, e.item.note, e.index)) }
            for l in e.item.lines where !l.note.isEmpty { all.append((e.item.title, l.note, e.index)) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? all : all.filter { $0.q.localizedCaseInsensitiveContains(q) || $0.a.localizedCaseInsensitiveContains(q) }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Find an answer", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(h.q).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                if let k = h.at { Button("Go") { m.go(k) }.controlSize(.mini) }
                            }
                            Text(h.a).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08)).cornerRadius(6)
                    }
                    if hits.isEmpty { Text(all.isEmpty ? "No Q&A in this show." : "Nothing matches.").foregroundColor(.secondary) }
                }
            }
        }
    }
}

struct ChecksView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(m.checking ? "Checking…" : "Run checks") { m.runChecks() }.disabled(m.checking || m.show.preflight.isEmpty)
                Spacer()
                if !m.checks.isEmpty {
                    let bad = m.checks.filter { $0.ok == false }.count
                    Text(bad == 0 ? "All clear" : "\(bad) to fix").font(.system(size: 11, weight: .semibold)).foregroundColor(bad == 0 ? .green : .red)
                }
            }.controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.checks) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Text(c.ok == nil ? "○" : c.ok! ? "✓" : "✗").foregroundColor(c.ok == nil ? .secondary : c.ok! ? .green : .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.label).font(.system(size: 12))
                                Text(c.detail).font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Spacer()
                            if let f = c.fix {
                                Button("Fix") { Runner.runAll([f], base: m.show.base) { l in m.say(l) } }.controlSize(.mini)
                            }
                        }
                    }
                    if m.show.preflight.isEmpty { Text("This show lists no checks. Add a preflight list to the show file.").font(.system(size: 11)).foregroundColor(.secondary) }
                }
            }
        }
    }
}

struct LogView: View {
    @ObservedObject var m: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(m.log.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if m.log.isEmpty { Text("What the show did shows up here.").font(.system(size: 11)).foregroundColor(.secondary) }
            }
        }
    }
}

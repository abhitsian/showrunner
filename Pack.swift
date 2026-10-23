// Shareable shows. A .showrunner file is a zip of one folder: the show file, a files/ folder with every local
// file the show refers to (slide images, videos, decks, attachments), and its rehearsal timings. Paths in the
// packed show point into files/, so it runs on another Mac. Opening one unpacks it into ~/Showrunner/<name>/.
import Foundation

enum Pack {
    static let root = ("~/Showrunner" as NSString).expandingTildeInPath
    static var sharedDir: String { (root as NSString).appendingPathComponent("Shared") }

    // Packs the show at `path` into `outDir`/<title>.showrunner and returns that path.
    static func pack(_ path: String, to outDir: String = sharedDir) throws -> String {
        let fm = FileManager.default
        let real = (path as NSString).resolvingSymlinksInPath
        let base = (real as NSString).deletingLastPathComponent
        let fileName = (real as NSString).lastPathComponent
        let show = try Loader.load(real)
        let name = safe(show.title.isEmpty ? (fileName as NSString).deletingPathExtension : show.title)
        let stage = (NSTemporaryDirectory() as NSString).appendingPathComponent("showrunner-pack-\(UUID().uuidString)")
        let dir = (stage as NSString).appendingPathComponent(name)
        let files = (dir as NSString).appendingPathComponent("files")
        try fm.createDirectory(atPath: files, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: stage) }

        var copied: [String: String] = [:]   // absolute source → path inside the pack
        func bundle(_ raw: String) -> String? {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.contains("://"), !t.contains("\n"), t.count < 400 else { return nil }
            let abs = (resolvePath(t, base) as NSString).resolvingSymlinksInPath
            if let done = copied[abs] { return done }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue, abs != real else { return nil }
            var leaf = (abs as NSString).lastPathComponent
            let stem = (leaf as NSString).deletingPathExtension, ext = (leaf as NSString).pathExtension
            var k = 2
            while copied.values.contains("files/" + leaf) { leaf = "\(stem) \(k)" + (ext.isEmpty ? "" : ".\(ext)"); k += 1 }
            guard (try? fm.copyItem(atPath: abs, toPath: (files as NSString).appendingPathComponent(leaf))) != nil else { return nil }
            copied[abs] = "files/" + leaf
            return "files/" + leaf
        }

        let text = try String(contentsOfFile: real, encoding: .utf8)
        let out: String
        if real.lowercased().hasSuffix(".md") {
            out = text.components(separatedBy: "\n").map { packLine($0, bundle) }.joined(separator: "\n")
        } else {
            let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
            let d = try JSONSerialization.data(withJSONObject: walk(obj, bundle), options: [.prettyPrinted, .withoutEscapingSlashes])
            out = String(decoding: d, as: UTF8.self)
        }
        try out.write(toFile: (dir as NSString).appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        let stemName = ((fileName as NSString).deletingPathExtension as NSString).deletingPathExtension
        for cand in [stemName, (fileName as NSString).deletingPathExtension] {
            let rp = (base as NSString).appendingPathComponent(cand + ".rehearsals.json")
            if fm.fileExists(atPath: rp) {
                try? fm.copyItem(atPath: rp, toPath: (dir as NSString).appendingPathComponent(((fileName as NSString).deletingPathExtension) + ".rehearsals.json"))
                break
            }
        }

        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let dest = (outDir as NSString).appendingPathComponent(name + ".showrunner")
        try? fm.removeItem(atPath: dest)
        try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", dir, dest])
        return dest
    }

    // Unpacks a .showrunner file into ~/Showrunner/<name>/ (or "<name> 2" if that exists) and returns the show inside.
    static func unpack(_ file: String) throws -> String {
        let fm = FileManager.default
        let stage = (NSTemporaryDirectory() as NSString).appendingPathComponent("showrunner-unpack-\(UUID().uuidString)")
        try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: stage) }
        try ditto(["-x", "-k", file, stage])
        let top = (try fm.contentsOfDirectory(atPath: stage)).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard let folder = top.first else { throw LoadError(description: "\(file) is empty") }
        let src = (stage as NSString).appendingPathComponent(folder)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        var dest = (root as NSString).appendingPathComponent(folder)
        var k = 2
        while fm.fileExists(atPath: dest) { dest = (root as NSString).appendingPathComponent("\(folder) \(k)"); k += 1 }
        try fm.moveItem(atPath: src, toPath: dest)
        let shows = (try fm.contentsOfDirectory(atPath: dest)).filter { isShowFile($0) }.sorted()
        guard let s = shows.first else { throw LoadError(description: "no show file inside \(file)") }
        return (dest as NSString).appendingPathComponent(s)
    }

    static func isShowFile(_ name: String) -> Bool {
        let l = name.lowercased()
        return (l.hasSuffix(".show.md") || l.hasSuffix(".show.json")) && !l.hasPrefix(".")
    }

    // a Markdown directive or `attach:` line: bundle any argument that is a local file
    private static func packLine(_ line: String, _ bundle: (String) -> String?) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if t.hasPrefix("@") { rest = t.dropFirst().drop { $0 != " " } }
        else if t.lowercased().hasPrefix("attach:") { rest = t.dropFirst(7) }
        else { return line }
        rest = rest.drop { $0 == " " }
        var out = line
        for part in rest.components(separatedBy: " | ") {
            let p = part.trimmingCharacters(in: .whitespaces)
            // `@fallback video ~/x.mp4`: the path follows a verb
            let afterVerb = p.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
            for cand in [p, afterVerb].compactMap({ $0 }) {
                if let r = bundle(cand) { out = out.replacingOccurrences(of: cand, with: r); break }
            }
        }
        return out
    }

    // JSON: any string value that names a local file is bundled
    private static func walk(_ v: Any, _ bundle: (String) -> String?) -> Any {
        if let d = v as? [String: Any] { return d.mapValues { walk($0, bundle) } }
        if let a = v as? [Any] { return a.map { walk($0, bundle) } }
        if let s = v as? String, let r = bundle(s) { return r }
        return v
    }

    private static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw LoadError(description: "ditto \(args.first ?? "") failed (\(p.terminationStatus))") }
    }
}

// A show found on disk, for the Shows library: what it is and its saved rehearsal runs.
struct ShowInfo: Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let items: Int
    let planned: Double     // seconds
    let modified: Date
    let runs: [RunInfo]
}

struct RunInfo: Identifiable {
    let id: Int
    let at: Date?
    let total: Double
    let planned: Double
    let sections: [String: Double]
}

enum Library {
    static func rehearsalPath(_ show: String) -> String {
        let real = (show as NSString).resolvingSymlinksInPath
        let name = ((real as NSString).lastPathComponent as NSString).deletingPathExtension
        return ((real as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name + ".rehearsals.json")
    }

    static func runs(_ show: String) -> [RunInfo] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: rehearsalPath(show))),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [J] else { return [] }
        let iso = ISO8601DateFormatter()
        return arr.enumerated().map { k, r in
            var secs: [String: Double] = [:]
            for i in r.list("items") { secs[i.str("section") ?? "", default: 0] += i.num("actual") ?? 0 }
            return RunInfo(id: k, at: r.str("at").flatMap { iso.date(from: $0) }, total: r.num("total") ?? 0,
                           planned: r.num("planned") ?? 0, sections: secs)
        }
    }

    // every show in ~/Showrunner (any depth, skipping Shared/) plus the recent list, newest first
    static func scan(recent: [String]) -> [ShowInfo] {
        let fm = FileManager.default
        var paths: [String] = []
        if let en = fm.enumerator(atPath: Pack.root) {
            while let rel = en.nextObject() as? String {
                if rel.hasPrefix("Shared") || en.level > 3 { en.skipDescendants(); continue }
                if Pack.isShowFile((rel as NSString).lastPathComponent) { paths.append((Pack.root as NSString).appendingPathComponent(rel)) }
            }
        }
        paths += recent.filter { fm.fileExists(atPath: $0) }
        var seen = Set<String>()
        var out: [ShowInfo] = []
        for p in paths {
            let real = (p as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted, let s = try? Loader.load(p) else { continue }
            let es = Loader.entries(s)
            let mod = (try? fm.attributesOfItem(atPath: real)[.modificationDate] as? Date) ?? .distantPast
            out.append(ShowInfo(path: p, title: s.title, items: es.count, planned: es.map { $0.planned }.reduce(0, +) * 60,
                                modified: mod, runs: runs(p)))
        }
        let order = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return out.sorted { (order[$0.path] ?? 999, -$0.modified.timeIntervalSince1970) < (order[$1.path] ?? 999, -$1.modified.timeIntervalSince1970) }
    }
}

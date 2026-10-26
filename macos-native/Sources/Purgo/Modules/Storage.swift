import SwiftUI
import AppKit

// MARK: - iCloud Drive

struct CloudFolder: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    var local: Int64
    var total: Int64
    var pending: Int
    var selected = false
}

enum CloudScanner {
    static let root = path("~/Library/Mobile Documents/com~apple~CloudDocs")
    static let archiveRoot = root.appendingPathComponent("Archives Purgo")

    static func tops() -> [URL] {
        FS.children(root).filter { !$0.lastPathComponent.hasPrefix(".") }.map { $0.resolvingSymlinksInPath() }
    }

    static func measure(_ u: URL) -> (local: Int64, total: Int64, pending: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .ubiquitousItemIsUploadedKey]
        func one(_ v: URLResourceValues?) -> (Int64, Int64, Int) {
            (Int64(v?.totalFileAllocatedSize ?? 0), Int64(v?.fileSize ?? 0), v?.ubiquitousItemIsUploaded == false ? 1 : 0)
        }
        if !FS.isDir(u) { return one(try? u.resourceValues(forKeys: keys)) }
        var l: Int64 = 0, t: Int64 = 0, p = 0
        guard let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [],
                                                      errorHandler: { _, _ in true }) else { return (0, 0, 0) }
        for case let f as URL in en {
            guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            let m = one(v)
            l += m.0; t += m.1; p += m.2
        }
        return (l, t, p)
    }
}

@MainActor
final class CloudModel: ObservableObject {
    @Published var folders: [CloudFolder] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = ""
    @Published var busy: String?
    @Published var message: String?

    var local: Int64 { folders.reduce(0) { $0 + $1.local } }
    var total: Int64 { folders.reduce(0) { $0 + $1.total } }
    var pending: Int { folders.reduce(0) { $0 + $1.pending } }

    func scan() async {
        scanning = true
        var list: [CloudFolder] = []
        for u in CloudScanner.tops() {
            progress = u.lastPathComponent
            let m = await Task.detached { CloudScanner.measure(u) }.value
            list.append(CloudFolder(url: u, name: u.lastPathComponent, local: m.local, total: m.total, pending: m.pending,
                                    selected: m.local > 50_000_000 && m.pending == 0))
        }
        folders = list.sorted { $0.local > $1.local }
        scanning = false
        scanned = true
    }

    func evictSelected() async {
        let sel = folders.filter(\.selected)
        busy = "Libération des copies locales…"
        let before = sel.reduce(0) { $0 + $1.local }
        for f in sel {
            busy = "Libération de \(f.name)…"
            let m = await Task.detached { () -> (local: Int64, total: Int64, pending: Int) in
                Shell.run("/usr/bin/brctl", ["evict", f.url.path])
                Thread.sleep(forTimeInterval: 1)
                return CloudScanner.measure(f.url)
            }.value
            if let i = folders.firstIndex(where: { $0.id == f.id }) {
                folders[i].local = m.local
                folders[i].pending = m.pending
                folders[i].selected = false
            }
        }
        let after = sel.reduce(0) { acc, f in acc + (folders.first { $0.id == f.id }?.local ?? 0) }
        busy = nil
        message = "\(Fmt.bytes(before - after)) libérés sur ton Mac. Les fichiers restent dans iCloud et se retéléchargent quand tu les ouvres."
        Prefs.addFreed(before - after)
    }

    func sendFolderToCloud() async {
        guard let src = pickFolder(start: home) else { return }
        busy = "Envoi de \(src.lastPathComponent) vers iCloud…"
        let r = await Task.detached { () -> Bool in
            try? FileManager.default.createDirectory(at: CloudScanner.archiveRoot, withIntermediateDirectories: true)
            let dest = Organizer.unique(CloudScanner.archiveRoot.appendingPathComponent(src.lastPathComponent))
            return (try? FileManager.default.moveItem(at: src, to: dest)) != nil
        }.value
        busy = nil
        message = r ? "\(src.lastPathComponent) déplacé dans iCloud Drive › Archives Purgo. Une fois envoyé, libère sa copie locale ici."
                    : "Impossible de déplacer \(src.lastPathComponent)."
        await scan()
    }
}

struct CloudView: View {
    @ObservedObject var model: CloudModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .icloud, subtitle: "Ce qui est dans iCloud mais occupe encore de la place sur ton Mac.") {
                HStack {
                    Button("Envoyer un dossier vers iCloud…") { Task { await model.sendFolderToCloud() } }
                    if model.scanned { Button("Actualiser") { Task { await model.scan() } }.disabled(model.scanning) }
                }
            }
            if let m = model.message { Notice(text: m) }
            if let b = model.busy {
                HStack { ProgressView().controlSize(.small); Text(b); Spacer() }.padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.scanning {
                ScanningView(text: "Lecture d'iCloud Drive…", detail: model.progress)
            } else if !model.scanned {
                EmptyState(icon: Module.icloud.icon, title: "Garde tout, sans rien stocker",
                           message: "Les fichiers d'iCloud Drive peuvent rester uniquement dans le cloud : ils restent visibles dans le Finder et se téléchargent quand tu les ouvres. Purgo te montre ce qui occupe encore ton disque.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else {
                HStack(spacing: 24) {
                    ZStack {
                        Ring(value: model.total > 0 ? Double(model.local) / Double(model.total) : 0, tint: Module.icloud.tint, lineWidth: 10)
                        VStack(spacing: 0) {
                            Text(Fmt.bytes(model.local)).font(.headline)
                            Text("en local").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Fmt.bytes(model.total)) dans iCloud Drive, dont \(Fmt.bytes(model.local)) aussi stockés sur ce Mac.").font(.headline)
                        if model.pending > 0 {
                            Label("\(model.pending) fichier(s) pas encore envoyés : ils ne peuvent pas être libérés tant que l'envoi n'est pas fini.",
                                  systemImage: "icloud.and.arrow.up").font(.callout).foregroundStyle(.orange)
                        }
                        Button("Activer « Optimiser le stockage du Mac »…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")!)
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 10)

                List {
                    ForEach($model.folders) { $f in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $f.selected).labelsHidden().toggleStyle(.checkbox).disabled(f.local == 0)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name)
                                Text(f.pending > 0 ? "\(f.pending) fichier(s) en cours d'envoi" : "Entièrement dans iCloud")
                                    .font(.caption).foregroundStyle(f.pending > 0 ? .orange : .secondary)
                            }
                            Spacer()
                            SizeBar(fraction: f.total > 0 ? Double(f.local) / Double(f.total) : 0, tint: Module.icloud.tint, width: 100)
                            Text("\(Fmt.bytes(f.local)) / \(Fmt.bytes(f.total))").monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .trailing)
                            RevealButton(url: f.url)
                        }
                    }
                }
                let sel = model.folders.filter(\.selected)
                ActionBar(text: "\(Fmt.bytes(sel.reduce(0) { $0 + $1.local })) libérables", buttonTitle: "Libérer les copies locales",
                          tint: Module.icloud.tint, disabled: sel.isEmpty || model.busy != nil) {
                    Task { await model.evictSelected() }
                }
            }
        }
    }
}

// MARK: - Organizer (Downloads / Desktop)

struct MovePlan: Identifiable {
    let id = UUID()
    let src: URL
    let dest: URL
    let category: String
    let size: Int64
    var selected = true
}

enum Organizer {
    static let categories: [(name: String, exts: Set<String>)] = [
        ("Documents", ["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "odt", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key", "epub"]),
        ("Images", ["jpg", "jpeg", "png", "gif", "heic", "webp", "svg", "psd", "ai", "tif", "tiff", "bmp"]),
        ("Audio", ["wav", "aif", "aiff", "mp3", "flac", "m4a", "ogg", "als", "alp", "mid", "midi", "adg", "adv"]),
        ("Vidéos", ["mov", "mp4", "mkv", "avi", "m4v", "webm"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2"]),
        ("Installeurs", ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "app"]),
        ("Code", ["py", "ipynb", "js", "ts", "json", "html", "css", "swift", "sh", "sql", "java", "c", "cpp", "rb", "go", "rs", "yaml", "yml", "toml"]),
        ("Polices", ["ttf", "otf", "woff", "woff2"]),
    ]
    static let folderNames: Set<String> = Set(categories.map(\.name) + ["Captures d'écran", "Autres", "Dossiers"])
    static let logURL = path("~/Library/Application Support/Purgo/last-organize.json")

    static func category(_ u: URL) -> String {
        let n = u.lastPathComponent.lowercased()
        if n.hasPrefix("capture d") || n.hasPrefix("screenshot") || n.hasPrefix("enregistrement de l") { return "Captures d'écran" }
        let e = u.pathExtension.lowercased()
        if FS.isDir(u) && e != "app" { return "Dossiers" }
        return categories.first { $0.exts.contains(e) }?.name ?? "Autres"
    }

    static func sortPlan(_ folder: URL, includeFolders: Bool) -> [MovePlan] {
        FS.children(folder)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !folderNames.contains($0.lastPathComponent) }
            .compactMap { u in
                let c = category(u)
                if c == "Dossiers" && !includeFolders { return nil }
                return MovePlan(src: u, dest: folder.appendingPathComponent(c).appendingPathComponent(u.lastPathComponent),
                                category: c, size: FS.size(of: u))
            }
    }

    static func archivePlan(_ folder: URL, olderThan days: Int, to root: URL) -> [MovePlan] {
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return FS.children(folder).filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey, .contentAccessDateKey])
            let d = [v?.contentModificationDate, v?.addedToDirectoryDate, v?.contentAccessDate].compactMap { $0 }.max() ?? Date()
            guard d < limit else { return nil }
            let month = df.string(from: d)
            return MovePlan(src: u, dest: root.appendingPathComponent(month).appendingPathComponent(u.lastPathComponent),
                            category: month, size: FS.size(of: u))
        }
    }

    static func unique(_ u: URL) -> URL {
        var c = u
        var i = 2
        while FS.exists(c) {
            let base = u.deletingPathExtension().lastPathComponent
            let ext = u.pathExtension
            c = u.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return c
    }

    static func apply(_ plans: [MovePlan]) -> (moved: Int, errors: Int) {
        var log: [[String: String]] = []
        var errors = 0
        for p in plans {
            do {
                try FileManager.default.createDirectory(at: p.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let d = unique(p.dest)
                try FileManager.default.moveItem(at: p.src, to: d)
                log.append(["from": p.src.path, "to": d.path])
            } catch { errors += 1 }
        }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: log) { try? d.write(to: logURL) }
        return (log.count, errors)
    }

    static var canUndo: Bool { FS.exists(logURL) }

    static func undo() -> Int {
        guard let d = try? Data(contentsOf: logURL),
              let log = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return 0 }
        var n = 0
        for m in log.reversed() {
            if let f = m["from"], let t = m["to"], (try? FileManager.default.moveItem(atPath: t, toPath: f)) != nil { n += 1 }
        }
        try? FileManager.default.removeItem(at: logURL)
        return n
    }
}

@MainActor
final class OrganizerModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case sort = "Trier par type", archive = "Archiver l'ancien dans iCloud"
        var id: String { rawValue }
    }
    @Published var folder: URL = path("~/Downloads")
    @Published var mode: Mode = .sort
    @Published var days = 60
    @Published var includeFolders = false
    @Published var plans: [MovePlan] = []
    @Published var planned = false
    @Published var message: String?
    @Published var canUndo = Organizer.canUndo

    var groups: [String] { Array(Set(plans.map(\.category))).sorted() }

    func plan() async {
        let f = folder, m = mode, d = days, inc = includeFolders
        plans = await Task.detached {
            m == .sort ? Organizer.sortPlan(f, includeFolders: inc)
                       : Organizer.archivePlan(f, olderThan: d, to: CloudScanner.root.appendingPathComponent("Archives \(f.lastPathComponent)"))
        }.value
        planned = true
    }

    func apply() async {
        let sel = plans.filter(\.selected)
        let r = await Task.detached { Organizer.apply(sel) }.value
        message = "\(r.moved) élément(s) rangé(s)" + (r.errors > 0 ? " · \(r.errors) échec(s)" : "")
            + (mode == .archive ? " dans iCloud Drive. Libère leurs copies locales dans le module iCloud une fois envoyés." : ".")
        canUndo = Organizer.canUndo
        await plan()
    }

    func undo() async {
        let n = await Task.detached { Organizer.undo() }.value
        message = "\(n) élément(s) remis à leur place"
        canUndo = false
        await plan()
    }
}

struct OrganizerView: View {
    @ObservedObject var model: OrganizerModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .organizer, subtitle: "Range Téléchargements et Bureau en un clic, ou archive l'ancien dans iCloud.") {
                if model.canUndo {
                    Button("Annuler le dernier rangement") { Task { await model.undo() } }
                }
            }
            if let m = model.message { Notice(text: m) }

            HStack(spacing: 14) {
                Picker("Dossier", selection: Binding(get: { model.folder.path }, set: { model.folder = URL(fileURLWithPath: $0) })) {
                    Text("Téléchargements").tag(path("~/Downloads").path)
                    Text("Bureau").tag(path("~/Desktop").path)
                    if ![path("~/Downloads").path, path("~/Desktop").path].contains(model.folder.path) {
                        Text(model.folder.lastPathComponent).tag(model.folder.path)
                    }
                }
                .frame(width: 230)
                Button("Autre…") { if let u = pickFolder(start: model.folder) { model.folder = u } }
                Picker("", selection: $model.mode) { ForEach(OrganizerModel.Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                if model.mode == .archive {
                    Stepper("Plus de \(model.days) jours", value: $model.days, in: 7...720, step: 30)
                } else {
                    Toggle("Inclure les dossiers", isOn: $model.includeFolders)
                }
                Spacer()
                Button("Prévisualiser") { Task { await model.plan() } }.buttonStyle(.borderedProminent).tint(Module.organizer.tint)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if !model.planned {
                EmptyState(icon: Module.organizer.icon, title: "Un dossier enfin rangé",
                           message: "Trier par type : chaque fichier va dans un sous-dossier (Documents, Images, Audio, Installeurs…). Archiver : ce que tu n'as pas touché depuis longtemps part dans iCloud Drive, classé par mois. Tout est réversible.",
                           actionTitle: "Prévisualiser") { Task { await model.plan() } }
            } else if model.plans.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Déjà rangé", message: "Rien à déplacer dans ce dossier.")
            } else {
                List {
                    ForEach(model.groups, id: \.self) { g in
                        Section("\(g) (\(model.plans.filter { $0.category == g }.count))") {
                            ForEach($model.plans) { $p in
                                if p.category == g {
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: $p.selected).labelsHidden().toggleStyle(.checkbox)
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: p.src.path)).resizable().frame(width: 20, height: 20)
                                        Text(p.src.lastPathComponent).lineLimit(1)
                                        Spacer()
                                        Text("→ \(p.dest.deletingLastPathComponent().path.tilde)").font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.head).frame(maxWidth: 300, alignment: .trailing)
                                        Text(Fmt.bytes(p.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                }
                let sel = model.plans.filter(\.selected)
                ActionBar(text: "\(sel.count) élément(s) · \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))",
                          buttonTitle: model.mode == .sort ? "Ranger" : "Archiver dans iCloud",
                          tint: Module.organizer.tint, disabled: sel.isEmpty) {
                    Task { await model.apply() }
                }
            }
        }
    }
}

// MARK: - Music (Ableton Live)

struct LiveProject: Identifiable {
    var id: String { url.path }
    let url: URL
    let sets: Int
    var size: Int64
    var backup: Int64
    let modified: Date?
    var selected = false
}

@MainActor
final class MusicModel: ObservableObject {
    @Published var projects: [LiveProject] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = ""
    @Published var foundBytes: Int64 = 0
    @Published var busy: String?
    @Published var message: String?

    var backups: Int64 { projects.reduce(0) { $0 + $1.backup } }
    var total: Int64 { projects.reduce(0) { $0 + $1.size } }

    func scan() async {
        scanning = true
        foundBytes = 0
        let dirs = await Task.detached {
            HomeWalker.find(roots: [home, path("~/Music")], progress: { p in Task { @MainActor in self.progress = p } }) {
                FS.exists($0.appendingPathComponent("Ableton Project Info"))
            }
        }.value
        var list: [LiveProject] = []
        for d in dirs {
            progress = d.path.tilde
            let p = await Task.detached { () -> LiveProject in
                let sets = FS.children(d).filter { $0.pathExtension == "als" }
                let mod = sets.compactMap { HomeWalker.modified($0) }.max()
                return LiveProject(url: d, sets: sets.count, size: FS.size(of: d),
                                   backup: FS.size(of: d.appendingPathComponent("Backup")), modified: mod)
            }.value
            list.append(p)
            foundBytes += p.size
        }
        projects = list.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        scanning = false
        scanned = true
    }

    func trashBackups() async {
        let targets = projects.filter { $0.backup > 0 }.map { ($0.url.appendingPathComponent("Backup"), $0.backup) }
        let r = await Task.detached { Cleaner.trash(targets, allowAdmin: false) }.value
        message = "Sauvegardes automatiques d'Ableton : " + Cleaner.summary(r.freed, r.errors)
        for i in projects.indices {
            projects[i].size -= projects[i].backup
            projects[i].backup = 0
        }
    }

    func archiveSelected() async {
        let sel = projects.filter(\.selected)
        busy = "Archivage de \(sel.count) projet(s) dans iCloud…"
        let dest = CloudScanner.root.appendingPathComponent("Archives Musique")
        let moved = await Task.detached { () -> Int in
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var n = 0
            for p in sel {
                if (try? FileManager.default.moveItem(at: p.url, to: Organizer.unique(dest.appendingPathComponent(p.url.lastPathComponent)))) != nil { n += 1 }
            }
            return n
        }.value
        busy = nil
        projects.removeAll { !FS.exists($0.url) }
        message = "\(moved) projet(s) déplacé(s) dans iCloud Drive › Archives Musique. Libère leur copie locale dans le module iCloud une fois envoyés."
    }
}

struct MusicView: View {
    @ObservedObject var model: MusicModel
    let findDuplicateSamples: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .music, subtitle: "Tes projets Ableton Live, leurs sauvegardes automatiques et les vieux projets à archiver.") {
                HStack {
                    Button("Chercher les samples en double") { findDuplicateSamples() }
                    if model.scanned { Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning) }
                }
            }
            if let m = model.message { Notice(text: m) }
            if let b = model.busy {
                HStack { ProgressView().controlSize(.small); Text(b); Spacer() }.padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.scanning {
                ScanningView(text: "Recherche des projets Ableton…", detail: model.progress, bytes: model.foundBytes)
            } else if !model.scanned {
                EmptyState(icon: Module.music.icon, title: "Range ton studio",
                           message: "Purgo retrouve tes projets Live, mesure leurs dossiers Backup (des copies automatiques de chaque sauvegarde) et t'aide à archiver les vieux projets dans iCloud.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else if model.projects.isEmpty {
                EmptyState(icon: "music.note", title: "Aucun projet Ableton", message: "Aucun dossier de projet Live trouvé.")
            } else {
                HStack(spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Sauvegardes automatiques (Backup)", systemImage: "clock.arrow.circlepath").font(.headline)
                            Text(Fmt.bytes(model.backups)).font(.title2.bold())
                            Text("Live garde une copie de chaque version de tes sets. Tes .als actuels ne sont pas touchés.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Mettre les Backup à la Corbeille") { Task { await model.trashBackups() } }
                                .disabled(model.backups == 0)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Astuce Live", systemImage: "lightbulb").font(.headline)
                            Text("Avant d'archiver, fais Fichier › Rassembler et enregistrer : tous les samples utilisés sont copiés dans le projet, il restera complet même déplacé.")
                                .font(.caption)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)

                List {
                    ForEach($model.projects) { $p in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $p.selected).labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: "waveform").foregroundStyle(Module.music.tint).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.url.lastPathComponent).lineLimit(1)
                                Text("\(p.sets) set(s) · modifié \(Fmt.relative(p.modified))" + (p.backup > 0 ? " · Backup \(Fmt.bytes(p.backup))" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.bytes(p.size)).monospacedDigit().foregroundStyle(.secondary)
                            RevealButton(url: p.url)
                        }
                    }
                }
                let sel = model.projects.filter(\.selected)
                ActionBar(text: "\(sel.count) projet(s) · \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))", buttonTitle: "Archiver dans iCloud",
                          tint: Module.music.tint, disabled: sel.isEmpty || model.busy != nil) {
                    Task { await model.archiveSelected() }
                }
            }
        }
    }
}

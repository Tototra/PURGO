import SwiftUI
import AppKit

struct GitRepo: Identifiable {
    var id: String { url.path }
    let url: URL
    let branch: String
    let lastCommit: Date?
    let ahead: Int
    let dirty: Int
    let upstream: Bool
    let remote: String?
    var size: Int64 = -1
    var gitSize: Int64 = -1
    var selected = false

    var saved: Bool { remote != nil && upstream && ahead == 0 && dirty == 0 }
    var stale: Bool { lastCommit.map { Date().timeIntervalSince($0) > 365 * 86400 } ?? true }
    var webURL: URL? {
        guard var r = remote else { return nil }
        if r.hasPrefix("git@") {
            r = r.replacingOccurrences(of: ":", with: "/").replacingOccurrences(of: "git@", with: "https://")
        }
        if r.hasSuffix(".git") { r = String(r.dropLast(4)) }
        return r.hasPrefix("http") ? URL(string: r) : nil
    }
}

enum GitScanner {
    static let git = "/usr/bin/git"

    static func inspect(_ u: URL) -> GitRepo {
        let log = Shell.run(git, ["-C", u.path, "log", "-1", "--format=%ct"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Double(log).map { Date(timeIntervalSince1970: $0) }
        let st = Shell.run(git, ["-C", u.path, "status", "--porcelain=v2", "--branch"]).out
        var branch = "?", ahead = 0, dirty = 0, upstream = false
        for line in st.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst(14))
            } else if line.hasPrefix("# branch.ab ") {
                upstream = true
                let p = line.split(separator: " ")
                if p.count >= 4 { ahead = Int(p[2].dropFirst()) ?? 0 }
            } else if !line.hasPrefix("#") && !line.hasPrefix("!") {
                dirty += 1
            }
        }
        let rem = Shell.run(git, ["-C", u.path, "remote", "get-url", "origin"])
        let remote = rem.code == 0 ? rem.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var r = GitRepo(url: u, branch: branch, lastCommit: date, ahead: ahead, dirty: dirty, upstream: upstream,
                        remote: remote.isEmpty ? nil : remote)
        r.size = FS.size(of: u)
        r.gitSize = FS.size(of: u.appendingPathComponent(".git"))
        return r
    }
}

@MainActor
final class GitModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tous", stale = "Abandonnés (+1 an)", unsaved = "Non sauvegardés", saved = "Sauvegardés sur un serveur"
        var id: String { rawValue }
    }
    @Published var repos: [GitRepo] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = ""
    @Published var foundBytes: Int64 = 0
    @Published var filter: Filter = .all
    @Published var busy: String?
    @Published var message: String?

    var visible: [GitRepo] {
        repos.filter { r in
            switch filter {
            case .all: return true
            case .stale: return r.stale
            case .unsaved: return !r.saved
            case .saved: return r.saved
            }
        }
        .sorted { $0.size > $1.size }
    }
    var selected: [GitRepo] { repos.filter(\.selected) }

    func scan() async {
        scanning = true
        progress = ""
        foundBytes = 0
        let dirs = await Task.detached {
            HomeWalker.find(progress: { p in Task { @MainActor in self.progress = p } }) { u in
                let rel = u.path.replacingOccurrences(of: home.path + "/", with: "")
                return !rel.hasPrefix(".") && FS.exists(u.appendingPathComponent(".git"))
            }
        }.value
        var list: [GitRepo] = []
        for d in dirs {
            progress = d.path.tilde
            let r = await Task.detached { GitScanner.inspect(d) }.value
            list.append(r)
            foundBytes += max(r.size, 0)
        }
        repos = list
        scanning = false
        scanned = true
    }

    func toggle(_ r: GitRepo) {
        if let i = repos.firstIndex(where: { $0.id == r.id }) { repos[i].selected.toggle() }
    }

    func trashSelected() async {
        let sel = selected
        let r = await Task.detached { Cleaner.trash(sel.map { ($0.url, max($0.size, 0)) }, allowAdmin: false) }.value
        message = "\(sel.count) dépôt(s) mis à la Corbeille · " + Cleaner.summary(r.freed, r.errors)
        repos.removeAll { !FS.exists($0.url) }
    }

    func compactSelected() async {
        let sel = selected
        var saved: Int64 = 0
        for repo in sel {
            busy = "Compactage de \(repo.url.lastPathComponent)…"
            let after = await Task.detached { () -> Int64 in
                Shell.run(GitScanner.git, ["-C", repo.url.path, "gc", "--prune=now", "--quiet"])
                return FS.size(of: repo.url.appendingPathComponent(".git"))
            }.value
            saved += max(repo.gitSize - after, 0)
            if let i = repos.firstIndex(where: { $0.id == repo.id }) {
                repos[i].size -= max(repo.gitSize - after, 0)
                repos[i].gitSize = after
                repos[i].selected = false
            }
        }
        busy = nil
        message = "Historique Git compacté · \(Fmt.bytes(saved)) gagnés, sans rien perdre"
    }
}

struct GitView: View {
    @ObservedObject var model: GitModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .git, subtitle: "Tes dépôts Git : ceux que tu as abandonnés, et surtout ceux qui ne sont sauvegardés nulle part.") {
                if model.scanned { Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning) }
            }
            if let m = model.message { Notice(text: m) }
            if let b = model.busy {
                HStack { ProgressView().controlSize(.small); Text(b); Spacer() }.padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.scanning {
                ScanningView(text: "Inspection des dépôts Git…", detail: model.progress, bytes: model.foundBytes)
            } else if !model.scanned {
                EmptyState(icon: Module.git.icon, title: "Où sont tes projets ?",
                           message: "Purgo retrouve chaque dépôt Git, sa date de dernier commit et vérifie s'il est bien poussé sur GitHub. Un dépôt jamais poussé n'existe que sur ce Mac : c'est le premier à protéger, pas à supprimer.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else {
                HStack {
                    Picker("", selection: $model.filter) { ForEach(GitModel.Filter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
                List {
                    ForEach(model.visible) { r in
                        GitRow(repo: r) { model.toggle(r) }
                    }
                }
                let sel = model.selected
                HStack {
                    Text(sel.isEmpty ? "\(model.repos.count) dépôts · \(model.repos.filter { !$0.saved }.count) non sauvegardés"
                                     : "\(sel.count) sélectionné(s) · \(Fmt.bytes(sel.reduce(0) { $0 + max($1.size, 0) }))")
                        .font(.headline)
                    Spacer()
                    Button("Compacter l'historique") { Task { await model.compactSelected() } }
                        .help("git gc : réduit la taille du dossier .git sans rien perdre")
                        .disabled(sel.isEmpty || model.busy != nil)
                    Button("Mettre à la Corbeille") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(sel.isEmpty || model.busy != nil)
                }
                .controlSize(.large)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
        }
        .confirmationDialog("Mettre \(model.selected.count) dépôt(s) à la Corbeille ?", isPresented: $confirm) {
            Button("Mettre à la Corbeille", role: .destructive) { Task { await model.trashSelected() } }
        } message: {
            let unsaved = model.selected.filter { !$0.saved }.count
            Text(unsaved > 0
                 ? "⚠️ \(unsaved) d'entre eux ont du travail qui n'existe que sur ce Mac (pas de serveur, commits non poussés ou modifications en cours)."
                 : "Tous sont sauvegardés sur un serveur : tu pourras les récupérer avec git clone.")
        }
    }
}

struct GitRow: View {
    let repo: GitRepo
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { repo.selected }, set: { _ in toggle() })).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: repo.saved ? "checkmark.icloud" : "exclamationmark.icloud")
                .foregroundStyle(repo.saved ? .green : .orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.url.lastPathComponent).font(.headline).lineLimit(1)
                    Badge(text: repo.branch, color: .secondary)
                    if repo.remote == nil { Badge(text: "Aucun serveur", color: .red) }
                    else if !repo.upstream { Badge(text: "Branche jamais poussée", color: .orange) }
                    if repo.ahead > 0 { Badge(text: "\(repo.ahead) commit(s) non poussé(s)", color: .orange) }
                    if repo.dirty > 0 { Badge(text: "\(repo.dirty) modif. en cours", color: .yellow) }
                    if repo.stale { Badge(text: "Abandonné", color: .gray) }
                }
                Text("\(repo.url.deletingLastPathComponent().path.tilde) · dernier commit \(Fmt.relative(repo.lastCommit)) · .git \(Fmt.bytes(max(repo.gitSize, 0)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Fmt.bytes(max(repo.size, 0))).monospacedDigit().foregroundStyle(.secondary)
            if let w = repo.webURL {
                Button { NSWorkspace.shared.open(w) } label: { Image(systemName: "globe") }
                    .buttonStyle(.borderless).help("Ouvrir sur le serveur")
            }
            Button { Shell.run("/usr/bin/open", ["-a", "Terminal", repo.url.path]) } label: { Image(systemName: "terminal") }
                .buttonStyle(.borderless).help("Ouvrir dans le Terminal")
            RevealButton(url: repo.url)
        }
        .padding(.vertical, 3)
    }
}

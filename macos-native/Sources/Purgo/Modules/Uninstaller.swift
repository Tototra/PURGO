import SwiftUI
import AppKit
import CoreServices

struct AppEntry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let build: String
    let feedURL: String?
    var size: Int64 = -1
    var lastUsed: Date?
}

enum AppScanner {
    static func listApps(includeApple: Bool = false) -> [AppEntry] {
        var urls: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), path("~/Applications")] {
            for c in FS.children(root) {
                if c.pathExtension == "app" {
                    urls.append(c)
                } else if FS.isDir(c) {
                    urls += FS.children(c).filter { $0.pathExtension == "app" }
                }
            }
        }
        return urls.compactMap { u -> AppEntry? in
            guard let b = Bundle(url: u) else { return nil }
            let id = b.bundleIdentifier ?? ""
            if !includeApple && id.hasPrefix("com.apple.") { return nil }
            let info = b.infoDictionary ?? [:]
            return AppEntry(url: u,
                            name: u.deletingPathExtension().lastPathComponent,
                            bundleID: id,
                            version: info["CFBundleShortVersionString"] as? String ?? "",
                            build: info["CFBundleVersion"] as? String ?? "",
                            feedURL: info["SUFeedURL"] as? String,
                            lastUsed: lastUsed(u))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func lastUsed(_ u: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, u as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Every bundle id installed anywhere (Spotlight), used to detect orphans.
    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let out = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"]).out
        for line in out.split(separator: "\n") {
            if let id = Bundle(path: String(line))?.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        for a in listApps(includeApple: true) where !a.bundleID.isEmpty { ids.insert(a.bundleID.lowercased()) }
        return ids
    }
}

enum LeftoverFinder {
    static let userRoots = [
        "~/Library/Application Support", "~/Library/Caches", "~/Library/Preferences", "~/Library/Preferences/ByHost",
        "~/Library/Containers", "~/Library/Group Containers", "~/Library/Logs", "~/Library/Saved Application State",
        "~/Library/HTTPStorages", "~/Library/WebKit", "~/Library/Cookies", "~/Library/LaunchAgents",
        "~/Library/Application Scripts",
    ]
    static let systemRoots = [
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/LaunchAgents",
        "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Logs",
    ]

    static func find(bundleID: String, name: String) -> [CleanItem] {
        let bid = bundleID.lowercased()
        let nm = name.lowercased()
        let compact = nm.replacingOccurrences(of: " ", with: "")
        var urls: [URL] = []
        for root in userRoots + systemRoots {
            for c in FS.children(path(root)) {
                let n = c.lastPathComponent.lowercased()
                let matchID = !bid.isEmpty && n.contains(bid)
                let matchName = nm.count >= 4 && (n == nm || n == compact || n.hasPrefix(nm + ".") || n == nm + ".plist")
                if matchID || matchName { urls.append(c) }
            }
        }
        let sizes = FS.sizes(urls)
        return zip(urls, sizes).map { u, s in
            CleanItem(url: u, name: u.lastPathComponent,
                      detail: u.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"),
                      size: s)
        }
        .sorted { $0.size > $1.size }
    }

    static func orphans() -> [CleanItem] {
        let installed = AppScanner.installedBundleIDs()
        let roots = ["~/Library/Application Support", "~/Library/Caches", "~/Library/Containers", "~/Library/Preferences",
                     "~/Library/Saved Application State", "~/Library/HTTPStorages", "~/Library/WebKit", "~/Library/Logs"]
        let pattern = try! NSRegularExpression(pattern: #"^[a-z0-9-]+\.[a-z0-9-]+\.[a-z0-9._-]+$"#)
        var urls: [URL] = []
        for r in roots {
            for c in FS.children(path(r)) {
                var n = c.lastPathComponent.lowercased()
                for suffix in [".plist", ".savedstate", ".binarycookies"] where n.hasSuffix(suffix) {
                    n = String(n.dropLast(suffix.count))
                }
                guard pattern.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil else { continue }
                if n.hasPrefix("com.apple.") || n.hasPrefix("group.") || n.hasPrefix("systemgroup.") || n.hasPrefix("com.purgo") { continue }
                let known = installed.contains { id in n == id || n.hasPrefix(id + ".") || id.hasPrefix(n + ".") }
                if !known { urls.append(c) }
            }
        }
        let sizes = FS.sizes(urls)
        return zip(urls, sizes).map { u, s in
            CleanItem(url: u, name: u.lastPathComponent,
                      detail: u.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"),
                      size: s, selected: false)
        }
        .sorted { $0.size > $1.size }
    }
}

@MainActor
final class UninstallerModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable { case apps = "Applications", orphans = "Restes d'apps supprimées"; var id: String { rawValue } }
    enum Sort: String, CaseIterable, Identifiable { case name = "Nom", size = "Taille", used = "Dernière utilisation"; var id: String { rawValue } }

    @Published var mode: Mode = .apps
    @Published var sort: Sort = .size
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var search = ""
    @Published var selectedID: String?
    @Published var leftovers: [CleanItem] = []
    @Published var finding = false
    @Published var orphans: [CleanItem] = []
    @Published var orphansLoading = false
    @Published var orphansLoaded = false
    @Published var message: String?

    var visibleApps: [AppEntry] {
        let f = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .name: return f
        case .size: return f.sorted { $0.size > $1.size }
        case .used: return f.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var selectedApp: AppEntry? { apps.first { $0.id == selectedID } }

    func load() async {
        loading = true
        let list = await Task.detached { AppScanner.listApps() }.value
        apps = list
        loading = false
        loaded = true
        let urls = list.map(\.url)
        let sizes = await Task.detached { FS.sizes(urls) }.value
        for (i, s) in sizes.enumerated() where i < apps.count && apps[i].url == urls[i] { apps[i].size = s }
    }

    func select(_ app: AppEntry) async {
        selectedID = app.id
        leftovers = []
        finding = true
        let l = await Task.detached { LeftoverFinder.find(bundleID: app.bundleID, name: app.name) }.value
        if selectedID == app.id { leftovers = l }
        finding = false
    }

    private func bootoutAgents(_ items: [CleanItem]) {
        for l in items where l.selected && l.url.path.contains("/LaunchAgents/") {
            Shell.sh("launchctl bootout gui/\(getuid()) \(Shell.quote(l.url.path))")
        }
    }

    func uninstall(_ app: AppEntry) async {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
        try? await Task.sleep(nanoseconds: 800_000_000)
        bootoutAgents(leftovers)
        let targets = [(app.url, max(app.size, 0))] + leftovers.selectedTargets
        let r = await Task.detached { Cleaner.trash(targets) }.value
        message = r.errors.isEmpty
            ? "\(app.name) désinstallé · \(Fmt.bytes(r.freed)) libérés"
            : "\(app.name) : \(r.errors.count) élément(s) n'ont pas pu être supprimés"
        if !FS.exists(app.url) { apps.removeAll { $0.id == app.id } }
        selectedID = nil
        leftovers = []
    }

    /// Keeps the app but removes its data (like a fresh install).
    func reset(_ app: AppEntry) async {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
        try? await Task.sleep(nanoseconds: 800_000_000)
        bootoutAgents(leftovers)
        let targets = leftovers.selectedTargets
        let r = await Task.detached { Cleaner.trash(targets) }.value
        message = "\(app.name) réinitialisé · " + Cleaner.summary(r.freed, r.errors)
        await select(app)
    }

    func loadOrphans() async {
        orphansLoading = true
        orphans = await Task.detached { LeftoverFinder.orphans() }.value
        orphansLoading = false
        orphansLoaded = true
    }

    func trashOrphans() async {
        let targets = orphans.selectedTargets
        let r = await Task.detached { Cleaner.trash(targets) }.value
        message = Cleaner.summary(r.freed, r.errors)
        await loadOrphans()
    }
}

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @State private var confirmUninstall = false
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .uninstaller, subtitle: "Supprime les apps et tous leurs fichiers cachés, ou nettoie les restes d'apps déjà effacées.") {
                Picker("", selection: $model.mode) {
                    ForEach(UninstallerModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 360)
            }
            if let m = model.message { Notice(text: m) }

            switch model.mode {
            case .apps: appsPane
            case .orphans: orphansPane
            }
        }
        .task { if !model.loaded { await model.load() } }
    }

    var appsPane: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Rechercher", text: $model.search).textFieldStyle(.roundedBorder)
                    Picker("", selection: $model.sort) {
                        ForEach(UninstallerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 170)
                }
                .padding(10)
                if model.loading {
                    ScanningView(text: "Inventaire des applications…")
                } else {
                    List(model.visibleApps, selection: Binding(get: { model.selectedID }, set: { id in
                        if let id, let a = model.apps.first(where: { $0.id == id }) { Task { await model.select(a) } }
                    })) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text("Utilisée \(Fmt.relative(app.lastUsed))").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(app.size < 0 ? "…" : Fmt.bytes(app.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(app.id)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380)

            Group {
                if let app = model.selectedApp {
                    detail(app)
                } else {
                    EmptyState(icon: "hand.point.left", title: "Choisis une application",
                               message: "Purgo trouvera ses préférences, caches, conteneurs, agents de lancement et autres fichiers éparpillés.")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func detail(_ app: AppEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title3.bold())
                    Text("\(app.version.isEmpty ? "" : "Version \(app.version) · ")\(app.bundleID)").font(.caption).foregroundStyle(.secondary)
                    Text("Dernière utilisation : \(Fmt.relative(app.lastUsed))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RevealButton(url: app.url)
            }
            .padding(16)
            Divider()
            if model.finding {
                ScanningView(text: "Recherche des fichiers associés…")
            } else if model.leftovers.isEmpty {
                EmptyState(icon: "checkmark.circle", title: "Aucun fichier associé", message: "Seule l'application elle-même sera supprimée.")
            } else {
                List { ForEach($model.leftovers) { $i in ItemRow(item: $i) } }
            }
            let total = max(app.size, 0) + model.leftovers.selectedSize
            HStack {
                Text("Total : \(Fmt.bytes(total))").font(.headline)
                Spacer()
                Button("Réinitialiser") { confirmReset = true }
                    .disabled(model.leftovers.selectedSize == 0)
                    .help("Garde l'app mais efface ses données, comme une nouvelle installation")
                Button("Désinstaller") { confirmUninstall = true }
                    .buttonStyle(.borderedProminent).tint(Module.uninstaller.tint)
            }
            .padding(14)
            .background(.bar)
            .confirmationDialog("Désinstaller \(app.name) ?", isPresented: $confirmUninstall) {
                Button("Désinstaller", role: .destructive) { Task { await model.uninstall(app) } }
            } message: { Text("L'app et les fichiers sélectionnés vont dans la Corbeille.") }
            .confirmationDialog("Réinitialiser \(app.name) ?", isPresented: $confirmReset) {
                Button("Réinitialiser", role: .destructive) { Task { await model.reset(app) } }
            } message: { Text("L'app est conservée, ses réglages et données sélectionnés vont dans la Corbeille.") }
        }
    }

    var orphansPane: some View {
        VStack(spacing: 0) {
            if model.orphansLoading {
                ScanningView(text: "Recherche des restes d'apps supprimées…")
            } else if !model.orphansLoaded {
                EmptyState(icon: "puzzlepiece.extension", title: "Restes d'apps supprimées",
                           message: "Quand on glisse une app à la Corbeille, ses fichiers restent. Purgo les retrouve en comparant avec les apps installées. Vérifie la liste avant de supprimer.",
                           actionTitle: "Rechercher") { Task { await model.loadOrphans() } }
            } else if model.orphans.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Rien à signaler", message: "Aucun reste d'application trouvé.")
            } else {
                List { ForEach($model.orphans) { $i in ItemRow(item: $i) } }
                ActionBar(text: "\(Fmt.bytes(model.orphans.selectedSize)) sélectionnés sur \(Fmt.bytes(model.orphans.totalSize))",
                          buttonTitle: "Supprimer", tint: Module.uninstaller.tint, disabled: model.orphans.selectedSize == 0) {
                    Task { await model.trashOrphans() }
                }
            }
        }
    }
}

import SwiftUI
import AppKit

// MARK: - Models

struct PyPackage: Identifiable, Hashable {
    var id: String { name.lowercased().replacingOccurrences(of: "_", with: "-") }
    let name: String
    let version: String
    let size: Int64
}

struct PyEnv: Identifiable {
    enum Kind: String {
        case venv = "venv", conda = "Conda", poetry = "Poetry", pipx = "pipx", pipenv = "Pipenv",
             wrapper = "virtualenvwrapper", pyenv = "pyenv-virtualenv", uvTool = "uv tool", tox = "tox/nox"
    }
    var id: String { url.path }
    let url: URL
    let kind: Kind
    let project: URL?
    let pythonVersion: String
    let baseHome: String?
    let broken: Bool
    let toolOwned: Bool
    let lastUsed: Date?
    var size: Int64 = -1
    var packages: [PyPackage] = []
    var selected = false

    var name: String {
        if let p = project { return "\(p.lastPathComponent) › \(url.lastPathComponent)" }
        return url.lastPathComponent
    }
    var inactiveDays: Int { lastUsed.map { Int(Date().timeIntervalSince($0) / 86400) } ?? 9999 }
    var python: URL { url.appendingPathComponent("bin/python") }
    var activateCommand: String {
        kind == .conda ? "conda activate \(Shell.quote(url.path))"
                       : "source \(Shell.quote(url.appendingPathComponent("bin/activate").path))"
    }
    var hasProjectFiles: Bool {
        guard let p = project else { return false }
        return ["requirements.txt", "pyproject.toml", "setup.py", "Pipfile", "uv.lock", "poetry.lock"]
            .contains { FS.exists(p.appendingPathComponent($0)) }
    }
}

struct PyInterpreter: Identifiable {
    var id: String { root.path }
    let root: URL
    let matchRoot: String
    let binary: String
    let version: String
    let source: String
    let removable: Bool
    var size: Int64 = -1
    var usedBy: [String] = []
}

struct DupPackage: Identifiable {
    struct Entry: Identifiable { var id: String { envID }; let envID: String; let envName: String; let version: String; let size: Int64 }
    var id: String { key }
    let key: String
    let name: String
    let entries: [Entry]
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }
}

extension String {
    var tilde: String { replacingOccurrences(of: home.path, with: "~") }
}

// MARK: - Scanner

enum PyScanner {
    static let projectCacheNames: Set<String> = ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".ipynb_checkpoints", ".hypothesis"]
    static let skipNames: Set<String> = ["node_modules", ".git", "site-packages", ".npm", ".rustup", ".cargo", ".ollama",
                                         ".docker", ".gradle", ".m2", "DerivedData", ".Trash"]
    static let homeSkip: Set<String> = Set(["Library", ".Trash", "Music", "Pictures", "Movies", "Applications"]
        .map { home.appendingPathComponent($0).path })
    /// Hidden home folders that are meant to hold the user's own envs.
    static let userEnvDirs: Set<String> = [".venvs", ".virtualenvs", ".pyenv", ".local", ".conda", ".tox"]

    static var uvPath: String? {
        ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", path("~/.local/bin/uv").path, path("~/.cargo/bin/uv").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var condaBases: [URL] {
        ["~/miniconda3", "~/anaconda3", "~/miniforge3", "~/mambaforge", "~/opt/anaconda3", "~/opt/miniconda3",
         "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base", "/opt/miniconda3", "/opt/anaconda3"]
            .map { path($0) }
            .filter { FS.exists($0.appendingPathComponent("conda-meta")) }
    }

    static func isSymlink(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    struct WalkResult {
        var envs: [URL: PyEnv.Kind] = [:]
        var projectCaches: [URL] = []
    }

    /// One pass over the home folder finds every env and every project cache.
    static func walk(progress: @escaping (String) -> Void) -> WalkResult {
        var r = WalkResult()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let en = fm.enumerator(at: home, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                     errorHandler: { _, _ in true }) else { return r }
        var n = 0
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true else { continue }
            let name = u.lastPathComponent
            if homeSkip.contains(u.path) || skipNames.contains(name) { en.skipDescendants(); continue }
            if projectCacheNames.contains(name) { r.projectCaches.append(u); en.skipDescendants(); continue }
            n += 1
            if n % 250 == 0 { progress(u.path.tilde) }
            if fm.fileExists(atPath: u.appendingPathComponent("pyvenv.cfg").path) {
                r.envs[u] = .venv
                en.skipDescendants()
            } else if fm.fileExists(atPath: u.appendingPathComponent("conda-meta").path) {
                r.envs[u] = .conda
                en.skipDescendants()
            }
        }
        for c in FS.children(path("~/Library/Caches/pypoetry/virtualenvs")) where FS.exists(c.appendingPathComponent("pyvenv.cfg")) {
            r.envs[c] = .poetry
        }
        for b in condaBases {
            r.envs[b] = .conda
            for e in FS.children(b.appendingPathComponent("envs")) where FS.exists(e.appendingPathComponent("conda-meta")) {
                r.envs[e] = .conda
            }
        }
        return r
    }

    static func refine(_ u: URL, _ k: PyEnv.Kind) -> PyEnv.Kind {
        let p = u.path
        if k == .conda { return .conda }
        if p.contains("/pypoetry/virtualenvs/") { return .poetry }
        if p.contains("/pipx/venvs/") { return .pipx }
        if p.contains("/.local/share/virtualenvs/") { return .pipenv }
        if p.contains("/.virtualenvs/") { return .wrapper }
        if p.contains("/.pyenv/versions/") { return .pyenv }
        if p.contains("/uv/tools/") { return .uvTool }
        if p.contains("/.tox/") || p.contains("/.nox/") { return .tox }
        return .venv
    }

    static func sitePackages(_ env: URL) -> [URL] {
        FS.children(env.appendingPathComponent("lib"))
            .filter { $0.lastPathComponent.hasPrefix("python") }
            .map { $0.appendingPathComponent("site-packages") }
            .filter { FS.exists($0) }
    }

    static func parseCfg(_ u: URL) -> [String: String] {
        guard let s = try? String(contentsOf: u.appendingPathComponent("pyvenv.cfg"), encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                d[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return d
    }

    static func makeEnv(_ u: URL, _ k: PyEnv.Kind) -> PyEnv {
        let kind = refine(u, k)
        let cfg = parseCfg(u)
        let sp = sitePackages(u)
        var version = cfg["version"] ?? cfg["version_info"] ?? ""
        if version.isEmpty, let lib = sp.first?.deletingLastPathComponent().lastPathComponent {
            version = lib.replacingOccurrences(of: "python", with: "")
        }
        if kind == .conda,
           let py = FS.children(u.appendingPathComponent("conda-meta")).map(\.lastPathComponent).first(where: { $0.hasPrefix("python-") && $0.hasSuffix(".json") }) {
            version = py.split(separator: "-").dropFirst().first.map(String.init) ?? version
        }
        let parent = u.deletingLastPathComponent()
        var project: URL?
        if kind == .venv, parent != home { project = parent }
        if kind == .tox { project = parent.deletingLastPathComponent() }

        // Inside a hidden folder of the home that belongs to some tool (e.g. ~/.claude, ~/.vscode)?
        let rel = u.path.replacingOccurrences(of: home.path + "/", with: "")
        let top = rel.split(separator: "/").first.map(String.init) ?? ""
        let toolOwned = top.hasPrefix(".") && !userEnvDirs.contains(top)
        if toolOwned { project = nil }

        var dates: [Date] = []
        if let d = try? u.appendingPathComponent("pyvenv.cfg").resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate { dates.append(d) }
        for s in sp {
            if let d = try? s.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { dates.append(d) }
        }
        if let d = try? u.appendingPathComponent("bin").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { dates.append(d) }

        let pyOK = FileManager.default.fileExists(atPath: u.appendingPathComponent("bin/python").path)
        return PyEnv(url: u, kind: kind, project: project, pythonVersion: version, baseHome: cfg["home"],
                     broken: !pyOK, toolOwned: toolOwned, lastUsed: dates.max())
    }

    static func packages(_ env: URL) -> [PyPackage] {
        var out: [PyPackage] = []
        for sp in sitePackages(env) {
            for d in FS.children(sp) where d.pathExtension == "dist-info" {
                var name = "", version = ""
                if let meta = try? String(contentsOf: d.appendingPathComponent("METADATA"), encoding: .utf8) {
                    for line in meta.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
                        if line.hasPrefix("Name: ") { name = String(line.dropFirst(6)) }
                        else if line.hasPrefix("Version: ") { version = String(line.dropFirst(9)) }
                        if !name.isEmpty && !version.isEmpty { break }
                    }
                }
                if name.isEmpty {
                    let parts = d.deletingPathExtension().lastPathComponent.split(separator: "-")
                    name = String(parts.first ?? "")
                    version = parts.count > 1 ? String(parts[1]) : ""
                }
                var size: Int64 = 0
                if let rec = try? String(contentsOf: d.appendingPathComponent("RECORD"), encoding: .utf8) {
                    for line in rec.split(separator: "\n") {
                        if let last = line.split(separator: ",", omittingEmptySubsequences: false).last, let v = Int64(last) { size += v }
                    }
                }
                out.append(PyPackage(name: name, version: version, size: size))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func pyVersion(_ bin: String) -> String {
        Shell.run(bin, ["--version"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Python ", with: "")
    }

    static func interpreters(envs: [PyEnv]) -> [PyInterpreter] {
        var list: [PyInterpreter] = []
        func add(_ root: URL, _ bin: URL, _ source: String, _ removable: Bool, match: URL? = nil) {
            guard FileManager.default.isExecutableFile(atPath: bin.path) else { return }
            list.append(PyInterpreter(root: root, matchRoot: (match ?? root).resolvingSymlinksInPath().path,
                                      binary: bin.path, version: pyVersion(bin.path), source: source, removable: removable))
        }
        let clt = URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        add(clt.appendingPathComponent("Library/Frameworks/Python3.framework"), clt.appendingPathComponent("usr/bin/python3"),
            "macOS (outils de ligne de commande)", false, match: clt)
        for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            for c in FS.children(URL(fileURLWithPath: cellar)) where c.lastPathComponent.hasPrefix("python@") {
                let minor = c.lastPathComponent.replacingOccurrences(of: "python@", with: "")
                for v in FS.children(c) where FS.isDir(v) {
                    add(v, v.appendingPathComponent("bin/python\(minor)"), "Homebrew (\(c.lastPathComponent))", true)
                }
            }
        }
        for v in FS.children(URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions")) where v.lastPathComponent != "Current" {
            add(v, v.appendingPathComponent("bin/python3"), "python.org", true)
        }
        for v in FS.children(path("~/.pyenv/versions")) where !isSymlink(v) {
            add(v, v.appendingPathComponent("bin/python"), "pyenv", true)
        }
        for v in FS.children(path("~/.local/share/uv/python")) where FS.isDir(v) && !isSymlink(v) && !v.lastPathComponent.hasPrefix(".") {
            add(v, v.appendingPathComponent("bin/python3"), "uv", true)
        }
        for b in condaBases {
            add(b, b.appendingPathComponent("bin/python"), "Conda (installation de base)", true)
        }

        for i in list.indices {
            let root = list[i].matchRoot
            list[i].usedBy = envs.filter { e in
                if list[i].source.hasPrefix("Conda") && e.url.path.hasPrefix(list[i].root.path) && e.url != list[i].root { return true }
                let target = e.python.resolvingSymlinksInPath().path
                let base = e.baseHome.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
                return target.hasPrefix(root + "/") || (!base.isEmpty && base.hasPrefix(root))
            }.map(\.name)
        }
        let sizes = FS.sizes(list.map(\.root))
        for i in list.indices { list[i].size = sizes[i] }
        return list
    }

    static func brokenKernels() -> [CleanItem] {
        var out: [CleanItem] = []
        for root in [path("~/Library/Jupyter/kernels"), URL(fileURLWithPath: "/usr/local/share/jupyter/kernels"),
                     URL(fileURLWithPath: "/opt/homebrew/share/jupyter/kernels")] {
            for k in FS.children(root) {
                guard let d = try? Data(contentsOf: k.appendingPathComponent("kernel.json")),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let argv = j["argv"] as? [String], let exe = argv.first else { continue }
                if exe.hasPrefix("/") && !FileManager.default.fileExists(atPath: exe) {
                    out.append(CleanItem(url: k, name: (j["display_name"] as? String) ?? k.lastPathComponent,
                                         detail: "Pointe vers \(exe.tilde), qui n'existe plus", size: FS.size(of: k)))
                }
            }
        }
        return out
    }

    static func cacheCategories(projectCaches: [URL]) -> [JunkCategory] {
        func items(_ paths: [URL], selected: Bool = true) -> [CleanItem] {
            let ex = paths.filter { FS.exists($0) }
            return zip(ex, FS.sizes(ex)).filter { $0.1 > 0 }.map {
                CleanItem(url: $0.0, name: $0.0.lastPathComponent, detail: $0.0.deletingLastPathComponent().path.tilde,
                          size: $0.1, selected: selected)
            }
            .sorted { $0.size > $1.size }
        }
        var cats: [JunkCategory] = []
        let pkg = items([path("~/Library/Caches/pip"), path("~/.cache/pip"), path("~/.cache/uv"),
                         path("~/Library/Caches/pypoetry/cache"), path("~/Library/Caches/pypoetry/artifacts"),
                         path("~/Library/Caches/pipenv"), path("~/Library/Caches/pdm"), path("~/.cache/pre-commit")]
                        + condaBases.map { $0.appendingPathComponent("pkgs") })
        if !pkg.isEmpty {
            cats.append(JunkCategory(id: "pkg", name: "Caches de téléchargement de paquets", icon: "shippingbox",
                                     info: "pip, uv, Poetry, Pipenv, Conda… Les paquets seront retéléchargés si besoin.", items: pkg))
        }
        let proj = items(projectCaches)
        if !proj.isEmpty {
            cats.append(JunkCategory(id: "proj", name: "Caches dans tes projets", icon: "folder.badge.gearshape",
                                     info: "__pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .ipynb_checkpoints. Recréés automatiquement.",
                                     items: proj))
        }
        let ml = items([path("~/.cache/huggingface"), path("~/.cache/torch"), path("~/.keras"), path("~/.cache/whisper")], selected: false)
        if !ml.isEmpty {
            cats.append(JunkCategory(id: "ml", name: "Modèles de machine learning téléchargés", icon: "brain",
                                     info: "Hugging Face, PyTorch Hub, Keras, Whisper. Lourds, mais à retélécharger si tu les supprimes.", items: ml))
        }
        let k = brokenKernels()
        if !k.isEmpty {
            cats.append(JunkCategory(id: "kernels", name: "Noyaux Jupyter cassés", icon: "exclamationmark.triangle",
                                     info: "Ils apparaissent dans Jupyter mais pointent vers un environnement supprimé.", items: k))
        }
        return cats
    }

    // MARK: Actions

    static func uninstall(_ pkg: String, in env: PyEnv) -> (ok: Bool, out: String) {
        let py = env.python.path
        let r = Shell.run(py, ["-m", "pip", "uninstall", "-y", pkg])
        if r.code == 0 { return (true, r.out) }
        if let uv = uvPath {
            let r2 = Shell.run(uv, ["pip", "uninstall", "--python", py, pkg])
            return (r2.code == 0, r2.out)
        }
        return (false, r.out)
    }

    /// Writes name==version for every package so the env can be rebuilt later.
    static func saveRequirements(_ env: PyEnv) -> URL? {
        let pkgs = env.packages.isEmpty ? packages(env.url) : env.packages
        guard !pkgs.isEmpty else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let header = """
        # Sauvegardé par Purgo le \(df.string(from: Date()))
        # Environnement : \(env.url.path.tilde) · Python \(env.pythonVersion)
        # Pour le recréer : uv venv --python \(env.pythonVersion.split(separator: ".").prefix(2).joined(separator: ".")) && uv pip install -r <ce fichier>

        """
        let body = pkgs.map { "\($0.name)==\($0.version)" }.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: "\n")
        let dir = env.project ?? path("~/Documents/Purgo/requirements")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = env.url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let f = dir.appendingPathComponent("requirements-\(base.isEmpty ? "venv" : base)-purgo.txt")
        do {
            try (header + body + "\n").write(to: f, atomically: true, encoding: .utf8)
            return f
        } catch { return nil }
    }

    static func recreate(_ env: PyEnv) -> (ok: Bool, out: String) {
        guard let proj = env.project else { return (false, "Aucun projet associé à cet environnement.") }
        let q = Shell.quote
        let minor = env.pythonVersion.split(separator: ".").prefix(2).joined(separator: ".")
        var req = ""
        if FS.exists(proj.appendingPathComponent("requirements.txt")) { req = proj.appendingPathComponent("requirements.txt").path }
        else if let saved = saveRequirements(env) { req = saved.path }

        let moved = Cleaner.trash([(env.url, 0)], allowAdmin: false)
        guard moved.errors.isEmpty else { return (false, "Impossible de déplacer l'ancien environnement.") }

        let newPy = env.url.appendingPathComponent("bin/python").path
        var cmd: String
        if let uv = uvPath {
            if FS.exists(proj.appendingPathComponent("uv.lock")) && env.url.lastPathComponent == ".venv" {
                cmd = "cd \(q(proj.path)) && \(q(uv)) sync"
            } else {
                cmd = "\(q(uv)) venv \(minor.isEmpty ? "" : "--python \(minor) ")\(q(env.url.path))"
                if !req.isEmpty { cmd += " && \(q(uv)) pip install --python \(q(newPy)) -r \(q(req))" }
                else if FS.exists(proj.appendingPathComponent("pyproject.toml")) { cmd += " && \(q(uv)) pip install --python \(q(newPy)) -e \(q(proj.path))" }
            }
        } else {
            let candidates = ["/opt/homebrew/bin/python\(minor)", "/usr/local/bin/python\(minor)",
                              "/Library/Frameworks/Python.framework/Versions/\(minor)/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
            let py = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
            cmd = "\(q(py)) -m venv \(q(env.url.path))"
            if !req.isEmpty { cmd += " && \(q(env.url.path + "/bin/python")) -m pip install -r \(q(req))" }
        }
        let r = Shell.sh(cmd)
        return (r.code == 0, r.out)
    }
}

// MARK: - Model

@MainActor
final class PythonModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case envs = "Environnements", packages = "Paquets en double", interpreters = "Interpréteurs", caches = "Caches"
        var id: String { rawValue }
    }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tous", broken = "Cassés", inactive = "Inactifs (+3 mois)", multiple = "Plusieurs par projet", tools = "Outils"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Taille", used = "Dernière utilisation", name = "Nom"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .envs
    @Published var filter: Filter = .all
    @Published var sort: Sort = .size
    @Published var search = ""
    @Published var envs: [PyEnv] = []
    @Published var interpreters: [PyInterpreter] = []
    @Published var caches: [JunkCategory] = []
    @Published var dupPackages: [DupPackage] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = ""
    @Published var foundBytes: Int64 = 0
    @Published var selectedID: String?
    @Published var message: String?
    @Published var busy: String?

    var totalSize: Int64 { envs.reduce(0) { $0 + max($1.size, 0) } }
    var brokenCount: Int { envs.filter(\.broken).count }
    var inactive: [PyEnv] { envs.filter { $0.inactiveDays > 90 && !$0.toolOwned } }
    var unusedInterpreters: [PyInterpreter] { interpreters.filter { $0.removable && $0.usedBy.isEmpty } }
    var cachesSize: Int64 { caches.reduce(0) { $0 + $1.total } }
    var selectedEnvs: [PyEnv] { envs.filter(\.selected) }
    var selectedEnv: PyEnv? { envs.first { $0.id == selectedID } }

    var multiProjects: Set<String> {
        Set(Dictionary(grouping: envs.compactMap { $0.project?.path }, by: { $0 }).filter { $0.value.count > 1 }.keys)
    }

    var visibleEnvs: [PyEnv] {
        let multi = multiProjects
        var list = envs.filter { e in
            switch filter {
            case .all: return true
            case .broken: return e.broken
            case .inactive: return e.inactiveDays > 90 && !e.toolOwned
            case .multiple: return e.project.map { multi.contains($0.path) } ?? false
            case .tools: return e.toolOwned
            }
        }
        if !search.isEmpty { list = list.filter { $0.url.path.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .used: list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    func scan() async {
        scanning = true
        progress = ""
        foundBytes = 0
        message = nil
        let walk = await Task.detached(priority: .userInitiated) {
            PyScanner.walk { p in Task { @MainActor in self.progress = p } }
        }.value
        envs = await Task.detached { walk.envs.map { PyScanner.makeEnv($0.key, $0.value) } }.value
            .sorted { $0.url.path < $1.url.path }
        for i in envs.indices {
            let e = envs[i]
            progress = e.url.path.tilde
            let (s, pk) = await Task.detached { (FS.size(of: e.url), PyScanner.packages(e.url)) }.value
            if i < envs.count, envs[i].id == e.id {
                envs[i].size = s
                envs[i].packages = pk
            }
            foundBytes += s
        }
        progress = "Interpréteurs Python…"
        let snapshot = envs
        interpreters = await Task.detached { PyScanner.interpreters(envs: snapshot) }.value
        progress = "Caches Python…"
        let pc = walk.projectCaches
        caches = await Task.detached { PyScanner.cacheCategories(projectCaches: pc) }.value
        computeDuplicates()
        scanning = false
        scanned = true
    }

    func computeDuplicates() {
        var map: [String: [DupPackage.Entry]] = [:]
        var names: [String: String] = [:]
        for e in envs {
            for p in e.packages {
                map[p.id, default: []].append(.init(envID: e.id, envName: e.name, version: p.version, size: p.size))
                names[p.id] = p.name
            }
        }
        dupPackages = map.filter { $0.value.count > 1 && $0.value.reduce(0) { $0 + $1.size } > 5_000_000 }
            .map { DupPackage(key: $0.key, name: names[$0.key] ?? $0.key, entries: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.total > $1.total }
    }

    func refresh(_ envID: String) async {
        guard let i = envs.firstIndex(where: { $0.id == envID }) else { return }
        let u = envs[i].url
        let kind = envs[i].kind
        guard FS.exists(u) else { envs.remove(at: i); return }
        var e = await Task.detached { PyScanner.makeEnv(u, kind) }.value
        let (s, pk) = await Task.detached { (FS.size(of: u), PyScanner.packages(u)) }.value
        e.size = s
        e.packages = pk
        if let j = envs.firstIndex(where: { $0.id == envID }) { envs[j] = e }
        computeDuplicates()
    }

    func trash(_ list: [PyEnv], saveRequirements: Bool) async {
        busy = "Suppression de \(list.count) environnement(s)…"
        var saved = 0
        if saveRequirements {
            for e in list where !e.toolOwned {
                let f = await Task.detached { PyScanner.saveRequirements(e) }.value
                if f != nil { saved += 1 }
            }
        }
        let targets = list.map { ($0.url, max($0.size, 0)) }
        let r = await Task.detached { Cleaner.trash(targets) }.value
        envs.removeAll { !FS.exists($0.url) }
        if let s = selectedID, !envs.contains(where: { $0.id == s }) { selectedID = nil }
        var msg = "\(list.count - r.errors.count) environnement(s) supprimé(s) · \(Fmt.bytes(r.freed)) dans la Corbeille"
        if saved > 0 { msg += " · \(saved) fichier(s) requirements sauvegardé(s) dans les projets" }
        message = msg
        computeDuplicates()
        busy = nil
    }

    func uninstall(_ pkgName: String, pkgSize: Int64, from envID: String) async {
        guard let env = envs.first(where: { $0.id == envID }) else { return }
        busy = "Désinstallation de \(pkgName) dans \(env.name)…"
        let r = await Task.detached { PyScanner.uninstall(pkgName, in: env) }.value
        if r.ok {
            message = "\(pkgName) désinstallé de \(env.name) · \(Fmt.bytes(pkgSize)) libérés"
            await refresh(envID)
        } else {
            message = "Échec : " + (r.out.split(separator: "\n").last.map(String.init) ?? "erreur inconnue")
        }
        busy = nil
    }

    func uninstallEverywhere(_ dup: DupPackage, except keep: String?) async {
        for e in dup.entries where e.envID != keep {
            await uninstall(dup.name, pkgSize: e.size, from: e.envID)
        }
    }

    func saveRequirements(_ env: PyEnv) async {
        let saved: URL? = await Task.detached { () -> URL? in PyScanner.saveRequirements(env) }.value
        if let f = saved {
            message = "Requirements sauvegardés : \(f.path.tilde)"
            FS.reveal(f)
        } else {
            message = "Aucun paquet à sauvegarder"
        }
    }

    func recreate(_ env: PyEnv) async {
        busy = "Recréation de \(env.name)… (ça peut prendre quelques minutes)"
        let r = await Task.detached { PyScanner.recreate(env) }.value
        busy = nil
        message = r.ok ? "\(env.name) recréé à neuf ✓" : "Échec de la recréation : " + String(r.out.suffix(240))
        await refresh(env.id)
    }

    func removeInterpreter(_ i: PyInterpreter) async {
        busy = "Suppression de Python \(i.version)…"
        let r = await Task.detached { () -> (Bool, String) in
            if i.source.hasPrefix("Homebrew"), let b = UpdateChecker.brewPath {
                let formula = i.root.deletingLastPathComponent().lastPathComponent
                let x = Shell.run(b, ["uninstall", "--ignore-dependencies", formula])
                return (x.code == 0, x.out)
            }
            let t = Cleaner.trash([(i.root, max(i.size, 0))])
            return (t.errors.isEmpty, t.errors.joined(separator: ", "))
        }.value
        message = r.0 ? "Python \(i.version) (\(i.source)) supprimé" : "Échec : " + String(r.1.suffix(240))
        interpreters.removeAll { $0.id == i.id && !FS.exists(i.root) }
        busy = nil
    }

    func cleanCaches() async {
        busy = "Nettoyage des caches…"
        let targets = caches.flatMap { $0.items.selectedTargets }
        let r = await Task.detached { Cleaner.trash(targets, allowAdmin: false) }.value
        message = Cleaner.summary(r.freed, r.errors)
        for c in caches.indices { caches[c].items.removeAll { !FS.exists($0.url) } }
        caches.removeAll { $0.items.isEmpty }
        busy = nil
    }

    func openTerminal(_ env: PyEnv) {
        Shell.run("/usr/bin/open", ["-a", "Terminal", (env.project ?? env.url).path])
    }

    func copyActivate(_ env: PyEnv) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(env.activateCommand, forType: .string)
        message = "Commande copiée : \(env.activateCommand)"
    }
}

// MARK: - Views

struct PythonView: View {
    @ObservedObject var model: PythonModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .python, subtitle: "Tous tes venv, interpréteurs, paquets et caches Python au même endroit.") {
                if model.scanned { Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning) }
            }
            if let m = model.message { Notice(text: m, icon: "info.circle.fill", color: .blue) }
            if let b = model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(b).font(.callout); Spacer() }
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.scanning {
                ScanningView(text: "Recherche des environnements Python…", detail: model.progress, bytes: model.foundBytes)
            } else if !model.scanned {
                EmptyState(icon: Module.python.icon, title: "Fini le chaos des venv",
                           message: "Purgo retrouve chaque venv, environnement Conda, Poetry, pipx, pyenv ou tox de ton Mac, les interpréteurs installés, les paquets en double et tous les caches Python.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else {
                PyInsights(model: model)
                Picker("", selection: $model.tab) {
                    ForEach(PythonModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 20).padding(.bottom, 10)

                switch model.tab {
                case .envs: PyEnvsPane(model: model)
                case .packages: PyDupPane(model: model)
                case .interpreters: PyInterpPane(model: model)
                case .caches: PyCachePane(model: model)
                }
            }
        }
    }
}

struct PyInsights: View {
    @ObservedObject var model: PythonModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip("shippingbox", "\(model.envs.count) environnements · \(Fmt.bytes(model.totalSize))", Module.python.tint) {
                    model.tab = .envs; model.filter = .all
                }
                if model.brokenCount > 0 {
                    chip("bandage", "\(model.brokenCount) cassé(s)", .red) { model.tab = .envs; model.filter = .broken }
                }
                if !model.inactive.isEmpty {
                    chip("moon.zzz", "\(model.inactive.count) inactif(s) · \(Fmt.bytes(model.inactive.reduce(0) { $0 + max($1.size, 0) }))", .orange) {
                        model.tab = .envs; model.filter = .inactive
                    }
                }
                if let top = model.dupPackages.first {
                    chip("square.on.square", "\(top.name) ×\(top.entries.count) · \(Fmt.bytes(top.total))", .purple) { model.tab = .packages }
                }
                if !model.unusedInterpreters.isEmpty {
                    chip("terminal", "\(model.unusedInterpreters.count) Python inutilisé(s)", .teal) { model.tab = .interpreters }
                }
                if model.cachesSize > 0 {
                    chip("archivebox", "Caches · \(Fmt.bytes(model.cachesSize))", .gray) { model.tab = .caches }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 10)
    }

    func chip(_ icon: String, _ text: String, _ c: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(c.opacity(0.15)))
                .foregroundStyle(c)
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}

struct PyEnvsPane: View {
    @ObservedObject var model: PythonModel
    @State private var confirm = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Rechercher un chemin", text: $model.search).textFieldStyle(.roundedBorder)
                    Picker("", selection: $model.filter) { ForEach(PythonModel.Filter.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().frame(width: 170)
                    Picker("", selection: $model.sort) { ForEach(PythonModel.Sort.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().frame(width: 150)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)

                List(selection: $model.selectedID) {
                    ForEach(model.visibleEnvs) { e in
                        PyEnvRow(env: e, multi: e.project.map { model.multiProjects.contains($0.path) } ?? false) {
                            if let i = model.envs.firstIndex(where: { $0.id == e.id }) { model.envs[i].selected.toggle() }
                        }
                        .tag(e.id)
                    }
                }

                let sel = model.selectedEnvs
                ActionBar(text: sel.isEmpty ? "Coche des environnements pour les supprimer"
                                            : "\(sel.count) sélectionné(s) · \(Fmt.bytes(sel.reduce(0) { $0 + max($1.size, 0) }))",
                          buttonTitle: "Supprimer", tint: .red, disabled: sel.isEmpty) { confirm = true }
            }
            .frame(minWidth: 430, idealWidth: 520)

            Group {
                if let e = model.selectedEnv {
                    PyEnvDetail(model: model, env: e)
                } else {
                    EmptyState(icon: "hand.point.left", title: "Choisis un environnement",
                               message: "Tu verras ses paquets, l'interpréteur utilisé, et tu pourras le sauvegarder, le recréer ou le supprimer.")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Supprimer \(model.selectedEnvs.count) environnement(s) ?", isPresented: $confirm) {
            Button("Sauvegarder les requirements puis supprimer") {
                Task { await model.trash(model.selectedEnvs, saveRequirements: true) }
            }
            Button("Supprimer sans sauvegarder", role: .destructive) {
                Task { await model.trash(model.selectedEnvs, saveRequirements: false) }
            }
        } message: {
            Text("Ils partent dans la Corbeille. Avec la sauvegarde, un fichier requirements-…-purgo.txt est écrit dans chaque projet pour pouvoir tout réinstaller.")
        }
    }
}

struct PyEnvRow: View {
    let env: PyEnv
    let multi: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { env.selected }, set: { _ in toggle() })).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: env.broken ? "bandage.fill" : (env.kind == .conda ? "circle.hexagongrid.fill" : "shippingbox.fill"))
                .foregroundStyle(env.broken ? .red : Module.python.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(env.name).lineLimit(1)
                    Badge(text: env.kind.rawValue, color: Module.python.tint)
                    if !env.pythonVersion.isEmpty { Badge(text: "py \(env.pythonVersion)", color: .secondary) }
                    if env.broken { Badge(text: "Cassé", color: .red) }
                    if env.toolOwned { Badge(text: "Outil", color: .gray) }
                    if multi { Badge(text: "Doublon projet", color: .purple) }
                }
                Text("\(env.url.deletingLastPathComponent().path.tilde) · utilisé \(Fmt.relative(env.lastUsed))")
                    .font(.caption).foregroundStyle(env.inactiveDays > 90 ? .orange : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(env.size < 0 ? "…" : Fmt.bytes(env.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct PyEnvDetail: View {
    @ObservedObject var model: PythonModel
    let env: PyEnv
    @State private var pkgSearch = ""
    @State private var pendingPkg: PyPackage?
    @State private var confirmDelete = false

    var maxPkg: Int64 { env.packages.first?.size ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(env.name).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(max(env.size, 0))).font(.title3.bold()).monospacedDigit()
                }
                Text(env.url.path.tilde).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 14) {
                    Label("Python \(env.pythonVersion.isEmpty ? "?" : env.pythonVersion)", systemImage: "terminal")
                    Label("\(env.packages.count) paquets", systemImage: "shippingbox")
                    Label("Utilisé \(Fmt.relative(env.lastUsed))", systemImage: "clock")
                }
                .font(.callout).foregroundStyle(.secondary)
                if let h = env.baseHome {
                    Text("Créé avec : \(h.tilde)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if env.broken {
                    Notice(text: "Cet environnement est cassé : l'interpréteur Python qui a servi à le créer n'existe plus. Recrée-le ou supprime-le.",
                           icon: "bandage.fill", color: .red)
                        .padding(.horizontal, -20)
                }
                if env.toolOwned {
                    Text("Cet environnement appartient à une application (dossier caché). Le supprimer peut la casser.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button { model.openTerminal(env) } label: { Label("Terminal", systemImage: "terminal") }
                    Button { model.copyActivate(env) } label: { Label("Copier l'activation", systemImage: "doc.on.clipboard") }
                    Button { Task { await model.saveRequirements(env) } } label: { Label("Sauvegarder", systemImage: "square.and.arrow.down") }
                        .help("Écrit un requirements.txt avec les versions exactes")
                    if env.project != nil && env.kind == .venv {
                        Button { Task { await model.recreate(env) } } label: { Label("Recréer", systemImage: "arrow.triangle.2.circlepath") }
                            .help("Sauvegarde les paquets, remplace l'environnement par un neuf et réinstalle tout")
                    }
                    RevealButton(url: env.url)
                    Spacer()
                    Button("Supprimer", role: .destructive) { confirmDelete = true }
                }
                .controlSize(.small)
                .disabled(model.busy != nil)
            }
            .padding(16)

            Divider()
            TextField("Filtrer les paquets", text: $pkgSearch).textFieldStyle(.roundedBorder).padding(10)
            List {
                ForEach(env.packages.filter { pkgSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(pkgSearch) }) { p in
                    HStack(spacing: 10) {
                        Text(p.name).lineLimit(1)
                        Text(p.version).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        SizeBar(fraction: Double(p.size) / Double(max(maxPkg, 1)), tint: Module.python.tint, width: 90)
                        Text(Fmt.bytes(p.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                        Button { pendingPkg = p } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Désinstaller")
                            .disabled(env.broken || model.busy != nil)
                    }
                }
            }
        }
        .confirmationDialog("Désinstaller \(pendingPkg?.name ?? "") de \(env.name) ?",
                            isPresented: Binding(get: { pendingPkg != nil }, set: { if !$0 { pendingPkg = nil } })) {
            Button("Désinstaller", role: .destructive) {
                if let p = pendingPkg { Task { await model.uninstall(p.name, pkgSize: p.size, from: env.id) } }
                pendingPkg = nil
            }
        } message: { Text("Purgo utilise pip (ou uv) de cet environnement, comme dans le Terminal.") }
        .confirmationDialog("Supprimer \(env.name) ?", isPresented: $confirmDelete) {
            Button("Sauvegarder les requirements puis supprimer") { Task { await model.trash([env], saveRequirements: true) } }
            Button("Supprimer sans sauvegarder", role: .destructive) { Task { await model.trash([env], saveRequirements: false) } }
        }
    }
}

struct PyDupPane: View {
    @ObservedObject var model: PythonModel

    var body: some View {
        VStack(spacing: 0) {
            if model.dupPackages.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Aucun gros paquet en double", message: "Chaque gros paquet n'est installé qu'une fois.")
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    Text("Les mêmes paquets sont copiés dans chaque venv. Avec **uv**, les environnements partagent les fichiers via son cache (liens physiques) : un seul exemplaire de torch sur le disque, même pour 10 projets.")
                        .font(.callout)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
                List {
                    ForEach(model.dupPackages) { d in
                        Section {
                            ForEach(d.entries) { e in
                                HStack {
                                    Text(e.envName).lineLimit(1)
                                    Text(e.version).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Fmt.bytes(e.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button("Désinstaller ici") {
                                        Task { await model.uninstall(d.name, pkgSize: e.size, from: e.envID) }
                                    }
                                    .controlSize(.small).disabled(model.busy != nil)
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(d.name) — \(d.entries.count) environnements · \(Fmt.bytes(d.total))").font(.headline)
                                Spacer()
                                Menu("Garder un seul…") {
                                    ForEach(d.entries) { e in
                                        Button("Garder dans \(e.envName)") { Task { await model.uninstallEverywhere(d, except: e.envID) } }
                                    }
                                }
                                .controlSize(.small).fixedSize()
                            }
                        }
                    }
                }
            }
        }
    }
}

struct PyInterpPane: View {
    @ObservedObject var model: PythonModel
    @State private var pending: PyInterpreter?

    var body: some View {
        List {
            ForEach(model.interpreters) { i in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "terminal.fill").font(.title3).foregroundStyle(Module.python.tint).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Python \(i.version)").font(.headline)
                            Badge(text: i.source, color: Module.python.tint)
                            if !i.removable { Badge(text: "Système", color: .gray) }
                            else if i.usedBy.isEmpty { Badge(text: "Utilisé par aucun venv", color: .teal) }
                        }
                        Text(i.binary.tilde).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !i.usedBy.isEmpty {
                            Text("Utilisé par : " + i.usedBy.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(Fmt.bytes(max(i.size, 0))).monospacedDigit().foregroundStyle(.secondary)
                    Button("Supprimer") { pending = i }
                        .controlSize(.small)
                        .disabled(!i.removable || model.busy != nil)
                }
                .padding(.vertical, 4)
            }
        }
        .confirmationDialog("Supprimer Python \(pending?.version ?? "") (\(pending?.source ?? "")) ?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Supprimer", role: .destructive) {
                if let p = pending { Task { await model.removeInterpreter(p) } }
                pending = nil
            }
        } message: {
            if let p = pending, !p.usedBy.isEmpty {
                Text("⚠️ \(p.usedBy.count) environnement(s) l'utilisent et seront cassés : \(p.usedBy.joined(separator: ", ")).")
            } else {
                Text("Aucun environnement ne l'utilise.")
            }
        }
    }
}

struct PyCachePane: View {
    @ObservedObject var model: PythonModel

    var body: some View {
        VStack(spacing: 0) {
            if model.caches.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Aucun cache Python", message: "Rien à nettoyer de ce côté.")
            } else {
                List { ForEach($model.caches) { $c in JunkCategoryRow(cat: $c) } }
                let sel = model.caches.reduce(0) { $0 + $1.selectedTotal }
                ActionBar(text: "\(Fmt.bytes(sel)) sélectionnés sur \(Fmt.bytes(model.cachesSize))", buttonTitle: "Nettoyer",
                          tint: Module.python.tint, disabled: sel == 0 || model.busy != nil) {
                    Task { await model.cleanCaches() }
                }
            }
        }
    }
}

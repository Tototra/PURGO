import SwiftUI
import AppKit

// MARK: - Docker

enum DockerCLI {
    static var bin: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
         path("~/.docker/bin/docker").path, path("~/.orbstack/bin/docker").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, out: String) {
        guard let b = bin else { return (-1, "Docker n'est pas installé") }
        return Shell.run(b, args)
    }

    static func rows(_ args: [String]) -> [[String: String]] {
        run(args).out.split(separator: "\n").compactMap { l in
            guard let d = String(l).data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return j.mapValues { "\($0)" }
        }
    }
}

struct DockerItem: Identifiable {
    enum Kind { case image, container, volume }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let size: String
    var selected = false
}

@MainActor
final class DockerModel: ObservableObject {
    @Published var installed = DockerCLI.bin != nil
    @Published var running = false
    @Published var loading = false
    @Published var loaded = false
    @Published var usage: [[String: String]] = []
    @Published var items: [DockerItem] = []
    @Published var rawSize: Int64 = 0
    @Published var busy: String?
    @Published var message: String?

    func load() async {
        installed = DockerCLI.bin != nil
        guard installed else { loaded = true; return }
        loading = true
        let r = await Task.detached { () -> (Bool, [[String: String]], [DockerItem], Int64) in
            let raw = FS.size(of: path("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"))
            guard DockerCLI.run(["info", "--format", "{{.ServerVersion}}"]).code == 0 else { return (false, [], [], raw) }
            let usage = DockerCLI.rows(["system", "df", "--format", "{{json .}}"])
            var items: [DockerItem] = []
            items += DockerCLI.rows(["ps", "-a", "--filter", "status=exited", "--filter", "status=created", "--format", "{{json .}}"]).map {
                DockerItem(id: $0["ID"] ?? "", kind: .container, title: $0["Names"] ?? "?",
                           detail: "Conteneur arrêté · \($0["Image"] ?? "") · \($0["Status"] ?? "")", size: $0["Size"] ?? "", selected: true)
            }
            items += DockerCLI.rows(["images", "--format", "{{json .}}"]).map {
                let dangling = ($0["Repository"] ?? "") == "<none>"
                return DockerItem(id: $0["ID"] ?? "", kind: .image, title: "\($0["Repository"] ?? "?"):\($0["Tag"] ?? "")",
                                  detail: "Image · créée \($0["CreatedSince"] ?? "")" + (dangling ? " · orpheline" : ""),
                                  size: $0["Size"] ?? "", selected: dangling)
            }
            items += DockerCLI.rows(["volume", "ls", "-f", "dangling=true", "--format", "{{json .}}"]).map {
                DockerItem(id: $0["Name"] ?? "", kind: .volume, title: $0["Name"] ?? "?",
                           detail: "Volume utilisé par aucun conteneur", size: "")
            }
            return (true, usage, items, raw)
        }.value
        running = r.0
        usage = r.1
        items = r.2
        rawSize = r.3
        loading = false
        loaded = true
    }

    func run(_ label: String, _ commands: [[String]]) async {
        busy = label
        let outs = await Task.detached { commands.map { DockerCLI.run($0) } }.value
        busy = nil
        let reclaimed = outs.compactMap { o in
            o.out.split(separator: "\n").first { $0.contains("reclaimed space") }.map(String.init)
        }
        message = reclaimed.isEmpty ? "\(label) terminé" : reclaimed.joined(separator: " · ")
        await load()
    }

    func removeSelected() async {
        let sel = items.filter(\.selected)
        var cmds: [[String]] = []
        let c = sel.filter { $0.kind == .container }.map(\.id)
        let i = sel.filter { $0.kind == .image }.map(\.id)
        let v = sel.filter { $0.kind == .volume }.map(\.id)
        if !c.isEmpty { cmds.append(["rm"] + c) }
        if !i.isEmpty { cmds.append(["rmi", "-f"] + i) }
        if !v.isEmpty { cmds.append(["volume", "rm"] + v) }
        await run("Suppression", cmds)
    }

    func startDocker() {
        Shell.run("/usr/bin/open", ["-a", "Docker"])
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await load()
        }
    }
}

struct DockerView: View {
    @ObservedObject var model: DockerModel
    @State private var confirmAll = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .docker, subtitle: "Images, conteneurs arrêtés, volumes et cache de build qui s'accumulent.") {
                if model.running { Button("Actualiser") { Task { await model.load() } } }
            }
            if let m = model.message { Notice(text: m) }
            if let b = model.busy {
                HStack { ProgressView().controlSize(.small); Text(b); Spacer() }.padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.loading && !model.loaded {
                ScanningView(text: "Interrogation de Docker…")
            } else if !model.installed {
                EmptyState(icon: Module.docker.icon, title: "Docker n'est pas installé",
                           message: "Rien à nettoyer de ce côté. Si tu l'installes un jour, Purgo surveillera ses images et ses volumes, qui grossissent vite.")
            } else if !model.running {
                EmptyState(icon: Module.docker.icon, title: "Docker est arrêté",
                           message: "Lance Docker Desktop pour que Purgo puisse analyser les images et les volumes." +
                           (model.rawSize > 0 ? " Son disque virtuel occupe déjà \(Fmt.bytes(model.rawSize)) sur ton Mac." : ""),
                           actionTitle: "Lancer Docker") { model.startDocker() }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.usage.indices, id: \.self) { i in usageCard(model.usage[i]) }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 10)
                if model.rawSize > 0 {
                    Text("Le disque virtuel de Docker Desktop occupe \(Fmt.bytes(model.rawSize)). Il ne rétrécit pas tout seul après un nettoyage : réduis sa taille dans Docker Desktop › Settings › Resources.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 8)
                }
                List {
                    ForEach($model.items) { $it in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $it.selected).labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: it.kind == .image ? "square.stack.3d.up" : (it.kind == .container ? "shippingbox" : "externaldrive"))
                                .foregroundStyle(Module.docker.tint).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.title).lineLimit(1)
                                Text(it.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(it.size).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Tout nettoyer (system prune)") { confirmAll = true }
                    Spacer()
                    Button("Supprimer la sélection") { Task { await model.removeSelected() } }
                        .buttonStyle(.borderedProminent).tint(Module.docker.tint)
                        .disabled(!model.items.contains(where: \.selected) || model.busy != nil)
                }
                .controlSize(.large).padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
        }
        .task { if !model.loaded { await model.load() } }
        .confirmationDialog("Tout nettoyer dans Docker ?", isPresented: $confirmAll) {
            Button("Nettoyer", role: .destructive) {
                Task { await model.run("Nettoyage complet", [["system", "prune", "-a", "-f", "--volumes"]]) }
            }
        } message: {
            Text("Supprime les conteneurs arrêtés, toutes les images inutilisées, les volumes orphelins et le cache de build. Les images se retéléchargent avec docker pull.")
        }
    }

    func usageCard(_ row: [String: String]) -> some View {
        let type = row["Type"] ?? ""
        let cmd: [String]? = switch type {
        case "Images": ["image", "prune", "-a", "-f"]
        case "Containers": ["container", "prune", "-f"]
        case "Local Volumes": ["volume", "prune", "-a", "-f"]
        case "Build Cache": ["builder", "prune", "-a", "-f"]
        default: nil
        }
        let label = ["Images": "Images", "Containers": "Conteneurs", "Local Volumes": "Volumes", "Build Cache": "Cache de build"][type] ?? type
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.headline)
                Text(row["Size"] ?? "").font(.title2.bold())
                Text("Récupérable : \(row["Reclaimable"] ?? "?")").font(.caption).foregroundStyle(.secondary)
                if let cmd {
                    Button("Nettoyer") { Task { await model.run("Nettoyage \(label.lowercased())", [cmd]) } }
                        .controlSize(.small).disabled(model.busy != nil)
                }
            }
        }
        .frame(width: 190)
    }
}

// MARK: - Homebrew

enum BrewCLI {
    @discardableResult
    static func run(_ args: String) -> (code: Int32, out: String) {
        guard let b = UpdateChecker.brewPath else { return (-1, "Homebrew n'est pas installé") }
        return Shell.sh("HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \(Shell.quote(b)) \(args) 2>&1")
    }
}

struct BrewPkg: Identifiable {
    var id: String { (cask ? "cask:" : "") + name }
    let name: String
    let cask: Bool
    let size: Int64
    let installed: Date?
    let leaf: Bool
    var selected = false
}

@MainActor
final class BrewModel: ObservableObject {
    @Published var installed = UpdateChecker.brewPath != nil
    @Published var loading = false
    @Published var loaded = false
    @Published var pkgs: [BrewPkg] = []
    @Published var cleanupEstimate: String?
    @Published var orphans: [String] = []
    @Published var showDeps = false
    @Published var busy: String?
    @Published var message: String?

    var visible: [BrewPkg] { pkgs.filter { showDeps || $0.leaf }.sorted { $0.size > $1.size } }

    func load() async {
        guard installed else { loaded = true; return }
        loading = true
        let r = await Task.detached { () -> ([BrewPkg], String?, [String]) in
            let prefix = BrewCLI.run("--prefix").out.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines: (String) -> [String] = { BrewCLI.run($0).out.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("Warning") } }
            let leaves = Set(lines("leaves"))
            var list: [BrewPkg] = []
            for f in lines("list --formula -1") {
                let u = URL(fileURLWithPath: prefix).appendingPathComponent("Cellar/\(f)")
                list.append(BrewPkg(name: f, cask: false, size: FS.size(of: u), installed: HomeWalker.modified(u), leaf: leaves.contains(f)))
            }
            for c in lines("list --cask -1") {
                let u = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/\(c)")
                list.append(BrewPkg(name: c, cask: true, size: FS.size(of: u), installed: HomeWalker.modified(u), leaf: true))
            }
            let cl = BrewCLI.run("cleanup --prune=all -n").out
            let est = UpdateChecker.captures(cl, #"approximately ([0-9.,]+\s?[KMGT]?B)"#).first
            let orphans = lines("autoremove -n").filter { !$0.hasPrefix("==>") }
            return (list, est, orphans)
        }.value
        pkgs = r.0
        cleanupEstimate = r.1
        orphans = r.2
        loading = false
        loaded = true
    }

    func run(_ label: String, _ args: [String]) async {
        busy = label
        let outs = await Task.detached { args.map { BrewCLI.run($0) } }.value
        busy = nil
        let failed = outs.filter { $0.code != 0 }
        message = failed.isEmpty ? "\(label) terminé ✓"
                                 : "\(label) : " + String(failed.first!.out.split(separator: "\n").last ?? "erreur")
        await load()
    }

    func uninstallSelected() async {
        let sel = pkgs.filter(\.selected)
        await run("Désinstallation de \(sel.count) paquet(s)",
                  sel.map { "uninstall \($0.cask ? "--cask " : "")\(Shell.quote($0.name))" })
    }
}

struct BrewView: View {
    @ObservedObject var model: BrewModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .homebrew, subtitle: "Vieilles versions, téléchargements en cache et dépendances devenues inutiles.") {
                if model.loaded && model.installed { Button("Actualiser") { Task { await model.load() } } }
            }
            if let m = model.message { Notice(text: m) }
            if let b = model.busy {
                HStack { ProgressView().controlSize(.small); Text(b); Spacer() }.padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.loading && !model.loaded {
                ScanningView(text: "Inventaire de Homebrew…")
            } else if !model.installed {
                EmptyState(icon: Module.homebrew.icon, title: "Homebrew n'est pas installé", message: "Rien à faire ici.")
            } else {
                HStack(spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Anciennes versions et cache", systemImage: "clock.arrow.circlepath").font(.headline)
                            Text(model.cleanupEstimate ?? "Rien").font(.title2.bold())
                            Button("brew cleanup") { Task { await model.run("Nettoyage Homebrew", ["cleanup --prune=all"]) } }
                                .disabled(model.cleanupEstimate == nil || model.busy != nil)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Dépendances orphelines", systemImage: "link.badge.plus").font(.headline)
                            Text(model.orphans.isEmpty ? "Aucune" : "\(model.orphans.count) : " + model.orphans.prefix(4).joined(separator: ", "))
                                .font(.callout).lineLimit(2)
                            Button("brew autoremove") { Task { await model.run("Suppression des dépendances orphelines", ["autoremove"]) } }
                                .disabled(model.orphans.isEmpty || model.busy != nil)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)

                HStack {
                    Text("Paquets installés").font(.headline)
                    Spacer()
                    Toggle("Afficher aussi les dépendances", isOn: $model.showDeps)
                }
                .padding(.horizontal, 20).padding(.bottom, 4)

                List {
                    ForEach(model.visible) { p in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { p.selected }, set: { v in
                                if let i = model.pkgs.firstIndex(where: { $0.id == p.id }) { model.pkgs[i].selected = v }
                            })).labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: p.cask ? "macwindow" : "terminal").foregroundStyle(Module.homebrew.tint).frame(width: 20)
                            Text(p.name)
                            if p.cask { Badge(text: "App", color: .blue) }
                            if !p.leaf { Badge(text: "Dépendance", color: .gray) }
                            Spacer()
                            Text("installé \(Fmt.relative(p.installed))").font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.bytes(p.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                ActionBar(text: "\(model.pkgs.filter(\.selected).count) paquet(s) sélectionné(s)", buttonTitle: "Désinstaller",
                          tint: Module.homebrew.tint, disabled: !model.pkgs.contains(where: \.selected) || model.busy != nil) {
                    confirm = true
                }
            }
        }
        .task { if !model.loaded { await model.load() } }
        .confirmationDialog("Désinstaller \(model.pkgs.filter(\.selected).count) paquet(s) Homebrew ?", isPresented: $confirm) {
            Button("Désinstaller", role: .destructive) { Task { await model.uninstallSelected() } }
        } message: {
            Text("Utilise brew uninstall. Tu peux les réinstaller à tout moment avec brew install.")
        }
    }
}

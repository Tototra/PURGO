import SwiftUI
import AppKit

struct StartupItem: Identifiable {
    enum Kind: String {
        case loginItem = "Ouverture à la connexion"
        case userAgent = "Agent utilisateur"
        case globalAgent = "Agent global"
        case daemon = "Démon système"
    }
    var id: String { kind.rawValue + label }
    let kind: Kind
    let name: String
    let label: String
    let url: URL?
    let program: String
    var enabled: Bool
}

enum StartupScanner {
    static func disabledSet(domain: String) -> Set<String> {
        let out = Shell.run("/bin/launchctl", ["print-disabled", domain]).out
        var s = Set<String>()
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let r = t.range(of: "\" => ") else { continue }
            let label = String(t[t.index(after: t.startIndex)..<r.lowerBound])
            let v = t[r.upperBound...]
            if v.hasPrefix("disabled") || v.hasPrefix("true") { s.insert(label) }
        }
        return s
    }

    static func loginItems() -> [String]? {
        let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the name of every login item"])
        guard r.code == 0 else { return nil }
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? [] : s.components(separatedBy: ", ")
    }

    static func scan() -> (items: [StartupItem], loginItemsAvailable: Bool) {
        var out: [StartupItem] = []
        let li = loginItems()
        for n in li ?? [] {
            out.append(StartupItem(kind: .loginItem, name: n, label: n, url: nil, program: "", enabled: true))
        }
        let uid = getuid()
        let guiDisabled = disabledSet(domain: "gui/\(uid)")
        let sysDisabled = disabledSet(domain: "system")
        let dirs: [(String, StartupItem.Kind, Set<String>)] = [
            ("~/Library/LaunchAgents", .userAgent, guiDisabled),
            ("/Library/LaunchAgents", .globalAgent, guiDisabled),
            ("/Library/LaunchDaemons", .daemon, sysDisabled),
        ]
        for (dir, kind, disabled) in dirs {
            for f in FS.children(path(dir)) where f.pathExtension == "plist" {
                let p = LaunchPlist(url: f)
                let label = p.label ?? f.deletingPathExtension().lastPathComponent
                let prog = p.program ?? ""
                let name = prog.isEmpty ? label : appName(from: prog) ?? label
                out.append(StartupItem(kind: kind, name: name, label: label, url: f, program: prog,
                                       enabled: !p.disabledKey && !disabled.contains(label)))
            }
        }
        return (out, li != nil)
    }

    /// "/Applications/Foo.app/Contents/MacOS/foo" -> "Foo"
    static func appName(from program: String) -> String? {
        guard let r = program.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(program[..<r.lowerBound]) + ".app").deletingPathExtension().lastPathComponent
    }
}

@MainActor
final class StartupModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var loginItemsAvailable = true
    @Published var message: String?

    var enabledCount: Int { items.filter(\.enabled).count }

    func load() async {
        loading = true
        let r = await Task.detached { StartupScanner.scan() }.value
        items = r.items
        loginItemsAvailable = r.loginItemsAvailable
        loading = false
        loaded = true
    }

    func setEnabled(_ item: StartupItem, _ on: Bool) async {
        guard let url = item.url else { return }
        let domain = item.kind == .daemon ? "system" : "gui/\(getuid())"
        let q = Shell.quote(url.path)
        let cmd = on
            ? "launchctl enable \(domain)/\(item.label); launchctl bootstrap \(domain) \(q) 2>/dev/null; true"
            : "launchctl disable \(domain)/\(item.label); launchctl bootout \(domain) \(q) 2>/dev/null; true"
        let r = await Task.detached { item.kind == .daemon ? Shell.admin(cmd) : Shell.sh(cmd) }.value
        if r.code != 0 { message = "Impossible de modifier \(item.name)" }
        await load()
    }

    func remove(_ item: StartupItem) async {
        if item.kind == .loginItem {
            let name = item.name.replacingOccurrences(of: "\"", with: "\\\"")
            _ = await Task.detached {
                Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(name)\""])
            }.value
            message = "\(item.name) ne s'ouvrira plus à la connexion"
        } else if let url = item.url {
            let domain = item.kind == .daemon ? "system" : "gui/\(getuid())"
            let r = await Task.detached { () -> (freed: Int64, errors: [String]) in
                let cmd = "launchctl bootout \(domain) \(Shell.quote(url.path)) 2>/dev/null; true"
                if item.kind == .daemon { Shell.admin(cmd) } else { Shell.sh(cmd) }
                return Cleaner.trash([(url, 0)])
            }.value
            message = r.errors.isEmpty ? "\(item.name) supprimé du démarrage" : "Impossible de supprimer \(item.name)"
        }
        await load()
    }
}

struct StartupView: View {
    @ObservedObject var model: StartupModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .startup, subtitle: "Ce qui se lance tout seul au démarrage et ralentit ton Mac.") {
                HStack {
                    Button("Réglages d'ouverture…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    Button("Actualiser") { Task { await model.load() } }
                }
            }
            if let m = model.message { Notice(text: m, icon: "info.circle.fill", color: .blue) }
            if !model.loginItemsAvailable {
                Notice(text: "Autorise Purgo à contrôler « Événements Système » (Réglages › Confidentialité › Automatisation) pour voir les apps ouvertes à la connexion.",
                       icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if model.loading && !model.loaded {
                ScanningView(text: "Inventaire des éléments de démarrage…")
            } else {
                List {
                    ForEach([StartupItem.Kind.loginItem, .userAgent, .globalAgent, .daemon], id: \.self) { kind in
                        let group = model.items.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Section("\(kind.rawValue) (\(group.count))") {
                                ForEach(group) { item in row(item) }
                            }
                        }
                    }
                }
            }
        }
        .task { if !model.loaded { await model.load() } }
    }

    func row(_ item: StartupItem) -> some View {
        HStack(spacing: 10) {
            if let u = item.url, item.kind != .loginItem {
                Image(systemName: "gearshape.2").frame(width: 24).foregroundStyle(.secondary)
                    .help(u.path)
            } else {
                Image(systemName: "app.badge").frame(width: 24).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(item.kind == .loginItem ? "S'ouvre quand tu te connectes" : item.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.kind != .loginItem {
                Toggle("", isOn: Binding(get: { item.enabled }, set: { v in Task { await model.setEnabled(item, v) } }))
                    .toggleStyle(.switch).labelsHidden()
                    .help(item.enabled ? "Activé" : "Désactivé")
            }
            if let u = item.url { RevealButton(url: u) }
            Button { Task { await model.remove(item) } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Retirer du démarrage")
        }
        .padding(.vertical, 3)
    }
}

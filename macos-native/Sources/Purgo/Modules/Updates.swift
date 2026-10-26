import SwiftUI
import AppKit

struct UpdateItem: Identifiable {
    enum Source: String { case sparkle = "App", brew = "Homebrew", macOS = "macOS" }
    var id: String { source.rawValue + name }
    let name: String
    let current: String
    let latest: String
    let source: Source
    var appURL: URL? = nil
    var updating = false
}

enum UpdateChecker {
    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    static func captures(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// Reads the Sparkle appcast declared by an app and compares versions.
    static func sparkle(_ app: AppEntry) async -> UpdateItem? {
        guard let f = app.feedURL, let url = URL(string: f) else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 10)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let shorts = captures(xml, #"sparkle:shortVersionString\s*=\s*"([^"]+)""#)
            + captures(xml, #"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"#)
        let builds = captures(xml, #"sparkle:version\s*=\s*"([^"]+)""#)
            + captures(xml, #"<sparkle:version>([^<]+)</sparkle:version>"#)
        if let latest = shorts.max(by: { newer($1, than: $0) }), !app.version.isEmpty {
            return newer(latest, than: app.version)
                ? UpdateItem(name: app.name, current: app.version, latest: latest, source: .sparkle, appURL: app.url) : nil
        }
        if let latest = builds.max(by: { newer($1, than: $0) }), !app.build.isEmpty, newer(latest, than: app.build) {
            return UpdateItem(name: app.name, current: app.version.isEmpty ? app.build : app.version, latest: latest,
                              source: .sparkle, appURL: app.url)
        }
        return nil
    }

    static func brew() -> [UpdateItem] {
        guard let b = brewPath else { return [] }
        let out = Shell.run(b, ["outdated", "--verbose"]).out
        return out.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let r = s.range(of: #"^(\S+) \(([^)]+)\) [<!]=? (.+)$"#, options: .regularExpression) else { return nil }
            let m = String(s[r])
            let name = String(m.split(separator: " ").first ?? "")
            let cur = captures(m, #"\(([^)]+)\)"#).first ?? ""
            let latest = String(m.split(separator: " ").last ?? "")
            return UpdateItem(name: name, current: cur, latest: latest, source: .brew)
        }
    }

    static func macOS() -> [UpdateItem] {
        let out = Shell.run("/usr/sbin/softwareupdate", ["-l"]).out
        return out.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("Title:") else { return nil }
            let title = captures(s, #"Title: ([^,]+)"#).first ?? s
            let version = captures(s, #"Version: ([^,]+)"#).first ?? ""
            return UpdateItem(name: title, current: ProcessInfo.processInfo.operatingSystemVersionString, latest: version, source: .macOS)
        }
    }
}

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var items: [UpdateItem] = []
    @Published var checking = false
    @Published var checked = false
    @Published var status = ""
    @Published var checkedApps = 0

    var hasBrew: Bool { UpdateChecker.brewPath != nil }

    func check() async {
        checking = true
        items = []
        status = "Lecture des applications…"
        let apps = await Task.detached { AppScanner.listApps() }.value.filter { $0.feedURL != nil }
        checkedApps = apps.count
        status = "Vérification de \(apps.count) apps compatibles…"
        var found: [UpdateItem] = []
        await withTaskGroup(of: UpdateItem?.self) { group in
            for a in apps { group.addTask { await UpdateChecker.sparkle(a) } }
            for await r in group { if let r { found.append(r) } }
        }
        items = found.sorted { $0.name < $1.name }
        if hasBrew {
            status = "Homebrew…"
            items += await Task.detached { UpdateChecker.brew() }.value
        }
        status = "macOS…"
        items += await Task.detached { UpdateChecker.macOS() }.value
        checking = false
        checked = true
    }

    func upgradeBrew(_ item: UpdateItem) async {
        guard let b = UpdateChecker.brewPath, let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].updating = true
        let r = await Task.detached { Shell.run(b, ["upgrade", item.name]) }.value
        if r.code == 0 { items.removeAll { $0.id == item.id } } else if let j = items.firstIndex(where: { $0.id == item.id }) { items[j].updating = false }
    }

    func upgradeAllBrew() async {
        for item in items where item.source == .brew { await upgradeBrew(item) }
    }
}

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .updates, subtitle: "Les mises à jour de tes apps, de Homebrew et de macOS au même endroit.") {
                HStack {
                    Button("App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
                    Button("Mise à jour de macOS") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                    }
                    if model.checked { Button("Revérifier") { Task { await model.check() } }.disabled(model.checking) }
                }
            }
            if model.checking {
                ScanningView(text: "Recherche de mises à jour…", detail: model.status)
            } else if !model.checked {
                EmptyState(icon: Module.updates.icon, title: "Garde tes apps à jour",
                           message: "Purgo interroge directement les serveurs de mise à jour des apps (Sparkle), Homebrew et macOS. Les apps de l'App Store se mettent à jour depuis l'App Store.",
                           actionTitle: "Vérifier") { Task { await model.check() } }
            } else if model.items.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Tout est à jour",
                           message: "\(model.checkedApps) apps vérifiées, aucune mise à jour disponible.")
            } else {
                List {
                    ForEach(model.items) { item in
                        HStack(spacing: 12) {
                            if let u = item.appURL {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 28, height: 28)
                            } else {
                                Image(systemName: item.source == .brew ? "mug" : "apple.logo").frame(width: 28)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(item.name).font(.headline); Badge(text: item.source.rawValue, color: .blue) }
                                Text("\(item.current) → \(item.latest)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            switch item.source {
                            case .sparkle:
                                Button("Ouvrir pour mettre à jour") { if let u = item.appURL { NSWorkspace.shared.open(u) } }
                            case .brew:
                                if item.updating { ProgressView().controlSize(.small) }
                                else { Button("Mettre à jour") { Task { await model.upgradeBrew(item) } } }
                            case .macOS:
                                Button("Réglages") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                if model.items.contains(where: { $0.source == .brew }) {
                    ActionBar(text: "\(model.items.count) mise(s) à jour disponible(s)", buttonTitle: "Tout mettre à jour (Homebrew)",
                              tint: Module.updates.tint) { Task { await model.upgradeAllBrew() } }
                }
            }
        }
    }
}

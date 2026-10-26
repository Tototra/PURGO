import SwiftUI
import AppKit

struct PrivacyEntry: Identifiable {
    let id = UUID()
    let kind: String
    let icon: String
    let paths: [URL]
    let size: Int64
    var selected: Bool
}

struct BrowserData: Identifiable {
    let id: String
    let name: String
    let bundleIDs: [String]
    var entries: [PrivacyEntry]
    var running = false
    var note: String? = nil
}

enum PrivacyScanner {
    struct Chromium { let name, bundleID, support, cache: String }

    static let chromium: [Chromium] = [
        .init(name: "Google Chrome", bundleID: "com.google.Chrome",
              support: "~/Library/Application Support/Google/Chrome", cache: "~/Library/Caches/Google/Chrome"),
        .init(name: "Brave", bundleID: "com.brave.Browser",
              support: "~/Library/Application Support/BraveSoftware/Brave-Browser", cache: "~/Library/Caches/BraveSoftware/Brave-Browser"),
        .init(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
              support: "~/Library/Application Support/Microsoft Edge", cache: "~/Library/Caches/Microsoft Edge"),
        .init(name: "Arc", bundleID: "company.thebrowser.Browser",
              support: "~/Library/Application Support/Arc/User Data", cache: "~/Library/Caches/Arc"),
        .init(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
              support: "~/Library/Application Support/Vivaldi", cache: "~/Library/Caches/Vivaldi"),
    ]

    static func entry(_ kind: String, _ icon: String, _ urls: [URL], selected: Bool = true) -> PrivacyEntry? {
        let ex = urls.filter { FS.exists($0) }
        guard !ex.isEmpty else { return nil }
        return PrivacyEntry(kind: kind, icon: icon, paths: ex, size: ex.reduce(0) { $0 + FS.size(of: $1) }, selected: selected)
    }

    static func scan() -> [BrowserData] {
        var out: [BrowserData] = []

        // Safari
        let safari = path("~/Library/Safari")
        let s = [
            entry("Historique", "clock.arrow.circlepath",
                  ["History.db", "History.db-wal", "History.db-shm", "History.db-lock"].map { safari.appendingPathComponent($0) }),
            entry("Cookies", "birthday.cake",
                  [path("~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                   path("~/Library/Cookies/Cookies.binarycookies")]),
            entry("Cache", "internaldrive",
                  [path("~/Library/Caches/com.apple.Safari"), path("~/Library/Containers/com.apple.Safari/Data/Library/Caches")]),
            entry("Dernière session", "rectangle.stack", [safari.appendingPathComponent("LastSession.plist")], selected: false),
        ].compactMap { $0 }
        out.append(BrowserData(id: "safari", name: "Safari", bundleIDs: ["com.apple.Safari"], entries: s,
                               note: s.isEmpty ? "Active l'accès complet au disque pour analyser Safari." : nil))

        // Chromium family
        for c in chromium {
            let sup = path(c.support)
            guard FS.exists(sup) else { continue }
            let profiles = FS.children(sup).filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            func files(_ names: [String]) -> [URL] { profiles.flatMap { p in names.map { p.appendingPathComponent($0) } } }
            let e = [
                entry("Historique", "clock.arrow.circlepath",
                      files(["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"])),
                entry("Cookies", "birthday.cake",
                      files(["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"])),
                entry("Cache", "internaldrive",
                      [path(c.cache)] + files(["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"])),
                entry("Sessions et onglets", "rectangle.stack",
                      files(["Sessions", "Current Session", "Last Session", "Current Tabs", "Last Tabs"]), selected: false),
            ].compactMap { $0 }
            if !e.isEmpty { out.append(BrowserData(id: c.bundleID, name: c.name, bundleIDs: [c.bundleID], entries: e)) }
        }

        // Firefox (history is not touched: Firefox stores bookmarks in the same file)
        let ff = FS.children(path("~/Library/Application Support/Firefox/Profiles")).filter { FS.isDir($0) }
        if !ff.isEmpty {
            func files(_ names: [String]) -> [URL] { ff.flatMap { p in names.map { p.appendingPathComponent($0) } } }
            let e = [
                entry("Cookies", "birthday.cake", files(["cookies.sqlite", "cookies.sqlite-wal"])),
                entry("Cache", "internaldrive", [path("~/Library/Caches/Firefox")]),
                entry("Historique des formulaires", "character.cursor.ibeam", files(["formhistory.sqlite"])),
                entry("Sessions et onglets", "rectangle.stack", files(["sessionstore.jsonlz4", "sessionstore-backups"]), selected: false),
            ].compactMap { $0 }
            if !e.isEmpty {
                out.append(BrowserData(id: "firefox", name: "Firefox", bundleIDs: ["org.mozilla.firefox"], entries: e,
                                       note: "L'historique Firefox n'est pas proposé : il est stocké avec tes favoris."))
            }
        }

        // System traces
        let sfl = path("~/Library/Application Support/com.apple.sharedfilelist")
        let recents = FS.children(sfl).filter { $0.lastPathComponent.contains("Recent") }
        let sys = [
            entry("Éléments récents", "clock", recents),
            entry("Historique des téléchargements", "arrow.down.circle",
                  [path("~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")]),
            entry("Historique du Terminal", "terminal",
                  [path("~/.zsh_history"), path("~/.bash_history"), path("~/.zsh_sessions"), path("~/.python_history")], selected: false),
        ].compactMap { $0 }
        if !sys.isEmpty { out.append(BrowserData(id: "system", name: "Traces système", bundleIDs: [], entries: sys)) }

        return out
    }
}

@MainActor
final class PrivacyModel: ObservableObject {
    @Published var browsers: [BrowserData] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var result: String?

    var selectedCount: Int {
        browsers.filter { !$0.running }.reduce(0) { $0 + $1.entries.filter(\.selected).count }
    }

    func scan() async {
        scanning = true
        var b = await Task.detached { PrivacyScanner.scan() }.value
        for i in b.indices {
            b[i].running = b[i].bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        }
        browsers = b
        scanning = false
        scanned = true
    }

    func clean() async {
        var targets: [(URL, Int64)] = []
        for b in browsers where !b.running {
            for e in b.entries where e.selected {
                for (i, p) in e.paths.enumerated() { targets.append((p, i == 0 ? e.size : 0)) }
            }
        }
        let r = await Task.detached { Cleaner.trash(targets, allowAdmin: false) }.value
        result = "Traces effacées · " + Cleaner.summary(r.freed, r.errors)
        await scan()
    }

    func quit(_ b: BrowserData) {
        for id in b.bundleIDs {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await scan()
        }
    }
}

struct PrivacyView: View {
    @ObservedObject var model: PrivacyModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .privacy, subtitle: "Historique, cookies et traces de navigation de tes navigateurs.") {
                if model.scanned { Button("Réanalyser") { Task { await model.scan() } } }
            }
            if let r = model.result { Notice(text: r) }

            if model.scanning {
                ScanningView(text: "Recherche des traces de navigation…")
            } else if !model.scanned {
                EmptyState(icon: Module.privacy.icon, title: "Protège ta vie privée",
                           message: "Efface l'historique, les cookies et les caches de Safari, Chrome, Brave, Edge, Arc, Firefox et les traces de macOS.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach($model.browsers) { $b in BrowserCard(browser: $b) { model.quit(b) } }
                    }
                    .padding(20)
                }
                ActionBar(text: "\(model.selectedCount) catégories sélectionnées", buttonTitle: "Effacer",
                          tint: Module.privacy.tint, disabled: model.selectedCount == 0) {
                    Task { await model.clean() }
                }
            }
        }
    }
}

struct BrowserCard: View {
    @Binding var browser: BrowserData
    let quit: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(browser.name).font(.headline)
                    if browser.running { Badge(text: "Ouvert", color: .orange) }
                    Spacer()
                    if browser.running {
                        Text("Ferme-le pour pouvoir effacer").font(.caption).foregroundStyle(.secondary)
                        Button("Quitter \(browser.name)", action: quit).controlSize(.small)
                    }
                }
                if let n = browser.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                ForEach($browser.entries) { $e in
                    HStack {
                        Toggle("", isOn: $e.selected).labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: e.icon).frame(width: 20).foregroundStyle(Module.privacy.tint)
                        Text(e.kind)
                        Spacer()
                        Text(Fmt.bytes(e.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .disabled(browser.running)
                }
            }
        }
    }
}

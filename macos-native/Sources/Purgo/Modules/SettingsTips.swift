import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - Preferences & stats

enum Prefs {
    static let d = UserDefaults.standard

    static func addFreed(_ b: Int64) {
        guard b > 0 else { return }
        d.set(d.double(forKey: "lifetimeFreed") + Double(b), forKey: "lifetimeFreed")
    }
    static var lifetimeFreed: Int64 { Int64(d.double(forKey: "lifetimeFreed")) }
    static var alertsEnabled: Bool { d.object(forKey: "alertsEnabled") as? Bool ?? true }
    static var alertGB: Double { d.object(forKey: "alertGB") as? Double ?? 10 }
    static var autoClean: Bool { d.bool(forKey: "autoClean") }
}

// MARK: - Notifications

enum Notifier {
    static func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Background watchdog (runs while Purgo is open, even only in the menu bar)

@MainActor
final class Watchdog {
    private var timer: Timer?
    private var alertedLow = false

    func start() {
        Notifier.setup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        if Prefs.alertsEnabled {
            let free = Double(SysInfo.disk().free)
            let threshold = Prefs.alertGB * 1e9
            if free < threshold && !alertedLow {
                alertedLow = true
                Notifier.post("Espace disque faible", "Il ne reste que \(Fmt.bytes(Int64(free))). Ouvre Purgo pour faire de la place.")
            } else if free > threshold * 1.2 {
                alertedLow = false
            }
            checkPythons()
        }
        if Prefs.autoClean {
            let last = Prefs.d.double(forKey: "lastAutoClean")
            if Date().timeIntervalSince1970 - last > 7 * 86400 {
                Prefs.d.set(Date().timeIntervalSince1970, forKey: "lastAutoClean")
                Task.detached(priority: .background) {
                    let cats = JunkScanner.scanAll().filter { ["caches", "logs"].contains($0.id) }
                    let r = Cleaner.trash(cats.flatMap { $0.items.selectedTargets }, allowAdmin: false)
                    if r.freed > 0 {
                        Notifier.post("Nettoyage automatique", "\(Fmt.bytes(r.freed)) de caches et journaux mis à la Corbeille.")
                    }
                }
            }
        }
    }

    /// Warns when a Python install disappears (e.g. after `brew upgrade`): venvs built on it break.
    private func checkPythons() {
        var now: [String] = []
        for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            for c in FS.children(URL(fileURLWithPath: cellar)) where c.lastPathComponent.hasPrefix("python@") {
                now += FS.children(c).map(\.path)
            }
        }
        now += FS.children(path("~/.pyenv/versions")).map(\.path)
        now += FS.children(path("~/.local/share/uv/python")).filter { !$0.lastPathComponent.hasPrefix(".") }.map(\.path)
        if let prev = Prefs.d.array(forKey: "knownPythons") as? [String] {
            let gone = Set(prev).subtracting(now)
            if !gone.isEmpty {
                let names = gone.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                Notifier.post("Une version de Python a disparu",
                              "\(names) n'existe plus : des venv sont peut-être cassés. Vérifie dans Purgo › Python.")
            }
        }
        Prefs.d.set(now, forKey: "knownPythons")
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @AppStorage("alertsEnabled") private var alerts = true
    @AppStorage("alertGB") private var alertGB = 10.0
    @AppStorage("autoClean") private var autoClean = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Alertes") {
                Toggle("Me prévenir quand l'espace disque est faible", isOn: $alerts)
                Slider(value: $alertGB, in: 5...50, step: 5) { Text("Seuil : \(Int(alertGB)) Go") }
                    .disabled(!alerts)
                Text("Purgo te prévient aussi quand une version de Python disparaît après une mise à jour : tes venv peuvent casser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatisation") {
                Toggle("Nettoyer les caches et journaux chaque semaine", isOn: $autoClean)
                Toggle("Ouvrir Purgo au démarrage du Mac (dans la barre des menus)", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        do {
                            if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Text("Les alertes et le nettoyage automatique fonctionnent tant que Purgo tourne, même fenêtre fermée.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Statistiques") {
                LabeledContent("Espace récupéré grâce à Purgo", value: Fmt.bytes(Prefs.lifetimeFreed))
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 440)
    }
}

// MARK: - Tips (macOS settings that save space for you)

struct Tip: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let check: (() -> Bool)?
    let action: () -> Void
}

enum Tips {
    static func defaultsRead(_ domain: String, _ key: String) -> String? {
        let r = Shell.run("/usr/bin/defaults", ["read", domain, key])
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    static func settings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }

    static let captures = path("~/Pictures/Captures d'écran")

    static let all: [Tip] = [
        Tip(id: "trash30", icon: "trash.slash", title: "Vider la Corbeille automatiquement après 30 jours",
            detail: "Le Finder supprime tout seul ce qui traîne dans la Corbeille depuis plus d'un mois.",
            actionTitle: "Activer",
            check: { defaultsRead("com.apple.finder", "FXRemoveOldTrashItems") == "1" },
            action: { Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "FXRemoveOldTrashItems", "-bool", "true"]) }),
        Tip(id: "screens", icon: "camera.viewfinder", title: "Ranger les captures d'écran dans leur propre dossier",
            detail: "Fini le Bureau couvert de captures : elles iront dans Images › Captures d'écran.",
            actionTitle: "Configurer",
            check: { (defaultsRead("com.apple.screencapture", "location") ?? "").contains("Captures") },
            action: {
                try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
                Shell.run("/usr/bin/defaults", ["write", "com.apple.screencapture", "location", captures.path])
                Shell.run("/usr/bin/killall", ["SystemUIServer"])
            }),
        Tip(id: "icloud", icon: "icloud", title: "Optimiser le stockage du Mac (iCloud Drive)",
            detail: "Quand le disque se remplit, macOS ne garde en local que les fichiers iCloud récents. Réglages › [ton nom] › iCloud › iCloud Drive.",
            actionTitle: "Ouvrir les réglages", check: nil,
            action: { settings("com.apple.preferences.AppleIDPrefPane") }),
        Tip(id: "photos", icon: "photo.on.rectangle", title: "Photos : optimiser le stockage",
            detail: "Les originaux restent dans iCloud, le Mac garde des versions légères. Dans Photos › Réglages › iCloud.",
            actionTitle: "Ouvrir Photos", check: nil,
            action: { Shell.run("/usr/bin/open", ["-a", "Photos"]) }),
        Tip(id: "messages", icon: "message", title: "Messages : ne garder que la dernière année",
            detail: "Les pièces jointes des conversations peuvent peser des Go. Messages › Réglages › Général › Conserver les messages : 1 an.",
            actionTitle: "Ouvrir Messages", check: nil,
            action: { Shell.run("/usr/bin/open", ["-a", "Messages"]) }),
        Tip(id: "uv", icon: "bolt", title: "Utiliser uv pour tes environnements Python",
            detail: "uv crée un venv en une seconde et partage les paquets entre projets au lieu de les recopier : un seul torch sur le disque pour tous tes projets.",
            actionTitle: "Installer uv",
            check: { PyScanner.uvPath != nil },
            action: { BrewCLI.run("install uv") }),
        Tip(id: "ableton", icon: "waveform", title: "Ableton Live : limiter le cache de décodage",
            detail: "Live décompresse les MP3/FLAC dans un cache qui grossit sans fin. Live › Réglages › Fichier/Dossier › Cache de décodage : taille maximale 2 Go.",
            actionTitle: "Ouvrir Live", check: nil,
            action: { Shell.run("/usr/bin/open", ["-b", "com.ableton.live"]) }),
        Tip(id: "storage", icon: "internaldrive", title: "Voir le résumé de stockage de macOS",
            detail: "Pour comparer avec Purgo et retrouver les recommandations d'Apple.",
            actionTitle: "Ouvrir", check: nil,
            action: { settings("com.apple.settings.Storage") }),
    ]
}

@MainActor
final class TipsModel: ObservableObject {
    @Published var done: Set<String> = []

    func refresh() async {
        let r = await Task.detached { Set(Tips.all.filter { $0.check?() == true }.map(\.id)) }.value
        done = r
    }

    func run(_ t: Tip) async {
        await Task.detached { t.action() }.value
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refresh()
    }
}

struct TipsView: View {
    @ObservedObject var model: TipsModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .tips, subtitle: "Des réglages de macOS qui font de la place à ta place, pour de bon.") {
                SettingsLink { Label("Alertes et automatisation…", systemImage: "gearshape") }
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Tips.all) { t in
                        Card {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: t.icon).font(.title2).foregroundStyle(Module.tips.tint).frame(width: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(t.title).font(.headline)
                                        if model.done.contains(t.id) { Badge(text: "Déjà fait", color: .green) }
                                    }
                                    Text(t.detail).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !model.done.contains(t.id) {
                                    Button(t.actionTitle) { Task { await model.run(t) } }
                                } else {
                                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                                }
                            }
                        }
                        .hoverLift()
                    }
                }
                .padding(20)
            }
        }
        .task { await model.refresh() }
    }
}

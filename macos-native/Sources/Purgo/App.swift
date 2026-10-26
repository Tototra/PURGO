import SwiftUI
import AppKit

@main
struct PurgoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Purgo", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Modules

enum Module: String, CaseIterable, Identifiable, Hashable {
    case smartScan, junk, privacy, malware, monitor, maintenance, startup, uninstaller, updates, spaceLens, largeFiles, duplicates, python
    case node, docker, homebrew, git, aiModels, icloud, organizer, music, tips

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Analyse intelligente"
        case .junk: "Nettoyage système"
        case .privacy: "Confidentialité"
        case .malware: "Logiciels malveillants"
        case .monitor: "Moniteur"
        case .maintenance: "Maintenance"
        case .startup: "Démarrage"
        case .uninstaller: "Désinstallateur"
        case .updates: "Mises à jour"
        case .spaceLens: "Explorateur d'espace"
        case .largeFiles: "Gros et anciens fichiers"
        case .duplicates: "Doublons"
        case .python: "Python"
        case .node: "Node.js"
        case .docker: "Docker"
        case .homebrew: "Homebrew"
        case .git: "Dépôts Git"
        case .aiModels: "Modèles d'IA"
        case .icloud: "iCloud Drive"
        case .organizer: "Rangement"
        case .music: "Musique"
        case .tips: "Conseils"
        }
    }

    var icon: String {
        switch self {
        case .smartScan: "sparkles"
        case .junk: "trash.circle"
        case .privacy: "hand.raised"
        case .malware: "shield.lefthalf.filled"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .maintenance: "wrench.and.screwdriver"
        case .startup: "power"
        case .uninstaller: "xmark.app"
        case .updates: "arrow.down.app"
        case .spaceLens: "circle.hexagongrid"
        case .largeFiles: "doc.zipper"
        case .duplicates: "doc.on.doc"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .node: "hexagon"
        case .docker: "shippingbox.circle"
        case .homebrew: "mug"
        case .git: "arrow.triangle.branch"
        case .aiModels: "brain"
        case .icloud: "icloud"
        case .organizer: "tray.full"
        case .music: "music.note"
        case .tips: "lightbulb"
        }
    }

    var tint: Color {
        switch self {
        case .smartScan: .indigo
        case .junk, .privacy: .teal
        case .malware: .green
        case .monitor, .maintenance, .startup: .orange
        case .uninstaller, .updates: .blue
        case .spaceLens, .largeFiles, .duplicates: .purple
        case .python: Color(red: 0.22, green: 0.47, blue: 0.82)
        case .node: Color(red: 0.30, green: 0.62, blue: 0.29)
        case .docker: Color(red: 0.11, green: 0.53, blue: 0.93)
        case .homebrew: Color(red: 0.85, green: 0.52, blue: 0.18)
        case .git: Color(red: 0.94, green: 0.33, blue: 0.20)
        case .aiModels: Color(red: 0.58, green: 0.36, blue: 0.92)
        case .icloud, .organizer: .cyan
        case .music: .pink
        case .tips: Color(red: 0.95, green: 0.70, blue: 0.10)
        }
    }
}

struct ModuleGroup: Identifiable {
    let title: String
    let modules: [Module]
    var id: String { title }

    static let all: [ModuleGroup] = [
        .init(title: "", modules: [.smartScan]),
        .init(title: "Nettoyage", modules: [.junk, .privacy]),
        .init(title: "Protection", modules: [.malware]),
        .init(title: "Vitesse", modules: [.monitor, .maintenance, .startup]),
        .init(title: "Applications", modules: [.uninstaller, .updates]),
        .init(title: "Fichiers", modules: [.spaceLens, .largeFiles, .duplicates]),
        .init(title: "Stockage", modules: [.icloud, .organizer, .music, .tips]),
        .init(title: "Développeurs", modules: [.python, .node, .docker, .homebrew, .git, .aiModels]),
    ]
}

// MARK: - State

@MainActor
final class AppState: ObservableObject {
    @Published var module: Module = .smartScan
    @Published var hasFDA = Permissions.hasFullDiskAccess

    let junk = JunkModel()
    let privacy = PrivacyModel()
    let malware = MalwareModel()
    let monitor = MonitorModel()
    let maintenance = MaintenanceModel()
    let startup = StartupModel()
    let uninstaller = UninstallerModel()
    let updates = UpdatesModel()
    let lens = SpaceLensModel()
    let large = LargeFilesModel()
    let dups = DuplicatesModel()
    let python = PythonModel()
    let node = NodeModel()
    let docker = DockerModel()
    let brew = BrewModel()
    let git = GitModel()
    let ai = AIModelsModel()
    let cloud = CloudModel()
    let organizer = OrganizerModel()
    let music = MusicModel()
    let tips = TipsModel()
    let watchdog = Watchdog()

    init() {
        monitor.start()
        watchdog.start()
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            ZStack {
                AnimatedBackground(tint: state.module.tint)
                    .animation(.easeInOut(duration: 0.6), value: state.module)
                detail
                    .id(state.module)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)),
                                            removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .environment(\.moduleTint, state.module.tint)
            .animation(.easeInOut(duration: 0.3), value: state.module)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.hasFDA = Permissions.hasFullDiskAccess
        }
    }

    @ViewBuilder var detail: some View {
        switch state.module {
        case .smartScan: SmartScanView()
        case .junk: JunkView(model: state.junk)
        case .privacy: PrivacyView(model: state.privacy)
        case .malware: MalwareView(model: state.malware)
        case .monitor: MonitorView(model: state.monitor)
        case .maintenance: MaintenanceView(model: state.maintenance)
        case .startup: StartupView(model: state.startup)
        case .uninstaller: UninstallerView(model: state.uninstaller)
        case .updates: UpdatesView(model: state.updates)
        case .spaceLens: SpaceLensView(model: state.lens)
        case .largeFiles: LargeFilesView(model: state.large)
        case .duplicates: DuplicatesView(model: state.dups)
        case .python: PythonView(model: state.python)
        case .node: NodeView(model: state.node)
        case .docker: DockerView(model: state.docker)
        case .homebrew: BrewView(model: state.brew)
        case .git: GitView(model: state.git)
        case .aiModels: AIModelsView(model: state.ai)
        case .icloud: CloudView(model: state.cloud)
        case .organizer: OrganizerView(model: state.organizer)
        case .music: MusicView(model: state.music) {
            state.dups.root = path("~/Music")
            state.module = .duplicates
            Task { await state.dups.scan() }
        }
        case .tips: TipsView(model: state.tips)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Module?>(get: { state.module }, set: { if let m = $0 { state.module = m } })) {
                ForEach(ModuleGroup.all) { group in
                    if group.title.isEmpty {
                        ForEach(group.modules) { row($0) }
                    } else {
                        Section(group.title) {
                            ForEach(group.modules) { row($0) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if !state.hasFDA {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accès complet au disque", systemImage: "lock.shield").font(.caption.bold())
                    Text("Nécessaire pour analyser Safari, Mail et certains caches.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Autoriser…") { Permissions.openFullDiskAccess() }
                        .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                .padding(10)
            }
        }
    }

    func row(_ m: Module) -> some View {
        Label {
            Text(m.title)
        } icon: {
            Image(systemName: m.icon).foregroundStyle(m.tint)
        }
        .tag(m)
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContent(monitor: state.monitor) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var monitor: MonitorModel
    let open: () -> Void
    @State private var freeing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.indigo)
                Text("Purgo").font(.headline)
                Spacer()
            }
            HStack(spacing: 18) {
                mini("CPU", monitor.cpu, .orange, Fmt.percent(monitor.cpu))
                mini("RAM", monitor.mem.pressure, .blue, Fmt.percent(monitor.mem.pressure))
                mini("Disque", monitor.diskUsedFraction, .purple, Fmt.bytes(monitor.diskFree) + " libres")
            }
            if let b = monitor.battery {
                Label("\(b.percent) % · \(b.charging ? "en charge" : (b.plugged ? "branché" : "sur batterie"))",
                      systemImage: b.charging ? "battery.100.bolt" : "battery.75")
                    .font(.caption)
            }
            Divider()
            Button {
                freeing = true
                Task {
                    _ = await Task.detached { Shell.admin("/usr/sbin/purge") }.value
                    freeing = false
                }
            } label: { Label(freeing ? "Libération…" : "Libérer la mémoire", systemImage: "memorychip") }
                .disabled(freeing)
            Button { open() } label: { Label("Ouvrir Purgo", systemImage: "macwindow") }
            SettingsLink { Label("Réglages…", systemImage: "gearshape") }
            Button { NSApp.terminate(nil) } label: { Label("Quitter", systemImage: "power") }
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 300)
    }

    func mini(_ title: String, _ v: Double, _ c: Color, _ caption: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Ring(value: v, tint: c, lineWidth: 6).frame(width: 52, height: 52)
                Text(Fmt.percent(v)).font(.caption2.bold()).monospacedDigit()
            }
            Text(title).font(.caption.bold())
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

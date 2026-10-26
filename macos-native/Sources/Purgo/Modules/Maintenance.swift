import SwiftUI

struct MaintTask: Identifiable {
    enum Status { case idle, running, done, failed }
    let id: String
    let name: String
    let info: String
    let icon: String
    let admin: Bool
    let command: String
    var selected = false
    var status: Status = .idle
    var output = ""
}

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published var tasks: [MaintTask] = [
        .init(id: "ram", name: "Libérer la mémoire vive",
              info: "Vide les caches disque gardés en mémoire pour récupérer de la RAM inactive.",
              icon: "memorychip", admin: true, command: "/usr/sbin/purge"),
        .init(id: "dns", name: "Vider le cache DNS",
              info: "Corrige les sites qui ne chargent plus ou pointent vers une ancienne adresse.",
              icon: "network", admin: true, command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        .init(id: "snapshots", name: "Supprimer les instantanés Time Machine locaux",
              info: "Libère l'espace « purgeable » réservé par les instantanés locaux.",
              icon: "clock.arrow.circlepath", admin: true, command: "tmutil thinlocalsnapshots / 999999999999 4"),
        .init(id: "spotlight", name: "Réindexer Spotlight",
              info: "Répare une recherche lente ou des résultats manquants. La réindexation prend un moment.",
              icon: "magnifyingglass", admin: true, command: "mdutil -E /"),
        .init(id: "launchservices", name: "Reconstruire la base Launch Services",
              info: "Supprime les doublons du menu « Ouvrir avec » et répare les associations de fichiers.",
              icon: "square.stack.3d.up", admin: false,
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"),
        .init(id: "quicklook", name: "Réinitialiser Quick Look",
              info: "Régénère les aperçus et miniatures des fichiers.",
              icon: "eye", admin: false, command: "qlmanage -r cache; qlmanage -r"),
        .init(id: "fonts", name: "Nettoyer le cache des polices",
              info: "Répare les polices qui s'affichent mal ou en double.",
              icon: "textformat", admin: false, command: "atsutil databases -removeUser"),
        .init(id: "verify", name: "Vérifier le disque de démarrage",
              info: "Contrôle l'intégrité du système de fichiers, sans rien modifier.",
              icon: "stethoscope", admin: false, command: "diskutil verifyVolume /"),
        .init(id: "ui", name: "Relancer le Finder et le Dock",
              info: "Utile quand l'interface rame ou se fige.",
              icon: "arrow.clockwise", admin: false, command: "killall Finder; killall Dock"),
    ]
    @Published var running = false

    var selectedCount: Int { tasks.filter(\.selected).count }

    func runSelected() async {
        running = true
        for i in tasks.indices where tasks[i].selected {
            tasks[i].status = .running
            tasks[i].output = ""
            let t = tasks[i]
            let r = await Task.detached { t.admin ? Shell.admin(t.command) : Shell.sh(t.command) }.value
            tasks[i].status = r.code == 0 ? .done : .failed
            tasks[i].output = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        running = false
    }
}

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .maintenance, subtitle: "Les petites réparations qui gardent macOS rapide et stable.")
            List {
                ForEach($model.tasks) { $t in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("", isOn: $t.selected).labelsHidden().toggleStyle(.checkbox).disabled(model.running)
                        Image(systemName: t.icon).font(.title3).frame(width: 28).foregroundStyle(Module.maintenance.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(t.name).font(.headline)
                                if t.admin { Badge(text: "Mot de passe requis", color: .secondary) }
                            }
                            Text(t.info).font(.callout).foregroundStyle(.secondary)
                            if !t.output.isEmpty {
                                Text(t.output).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(4).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        status(t.status)
                    }
                    .padding(.vertical, 6)
                }
            }
            ActionBar(text: "\(model.selectedCount) tâche(s) sélectionnée(s)",
                      buttonTitle: model.running ? "En cours…" : "Exécuter",
                      tint: Module.maintenance.tint, disabled: model.selectedCount == 0 || model.running) {
                Task { await model.runSelected() }
            }
        }
    }

    @ViewBuilder func status(_ s: MaintTask.Status) -> some View {
        switch s {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

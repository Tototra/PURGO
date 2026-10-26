import AppKit
import SwiftUI

struct JunkCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let info: String
    var items: [CleanItem]
    var expanded = false
    var total: Int64 { items.totalSize }
    var selectedTotal: Int64 { items.selectedSize }
}

enum JunkScanner {
    struct Def {
        let id: String
        let name: String
        let icon: String
        let info: String
        let roots: [String]
        var selected = true
        var excludePrefixes: [String] = []
        var extensions: [String]? = nil
        var filter: ((URL) -> Bool)? = nil
    }

    static let defs: [Def] = [
        Def(id: "caches", name: "Caches des applications", icon: "internaldrive",
            info: "Fichiers temporaires recréés automatiquement par les apps.",
            roots: ["~/Library/Caches"],
            excludePrefixes: ["com.apple.", "CloudKit", "com.purgo", "Purgo", "FamilyCircle", "GeoServices"]),
        Def(id: "logs", name: "Journaux et rapports de plantage", icon: "doc.text",
            info: "Historique technique des apps, inutile au quotidien.",
            roots: ["~/Library/Logs"]),
        Def(id: "installers", name: "Installeurs téléchargés", icon: "shippingbox",
            info: "Fichiers .dmg, .pkg et .iso restés dans Téléchargements et sur le Bureau.",
            roots: ["~/Downloads", "~/Desktop"],
            extensions: ["dmg", "pkg", "mpkg", "iso", "exe", "msi"]),
        Def(id: "macos", name: "Installeurs de macOS", icon: "apple.logo",
            info: "Les apps « Installer macOS » restées dans Applications après une mise à jour (12 Go chacune).",
            roots: ["/Applications"],
            filter: { $0.lastPathComponent.hasPrefix("Install macOS") || $0.lastPathComponent.hasPrefix("Installer macOS") }),
        Def(id: "screens", name: "Vieilles captures d'écran", icon: "camera.viewfinder",
            info: "Captures et enregistrements d'écran de plus de 30 jours sur le Bureau.",
            roots: ["~/Desktop", "~/Pictures/Captures d'écran"],
            selected: false,
            filter: { u in
                let n = u.lastPathComponent.lowercased()
                guard n.hasPrefix("capture d") || n.hasPrefix("screenshot") || n.hasPrefix("enregistrement de l") else { return false }
                let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                return Date().timeIntervalSince(d) > 30 * 86400
            }),
        Def(id: "messages", name: "Pièces jointes de Messages", icon: "message",
            info: "Photos, vidéos et fichiers reçus dans Messages. Ils disparaîtront aussi des conversations.",
            roots: ["~/Library/Messages/Attachments"],
            selected: false),
        Def(id: "dev", name: "Caches de développement", icon: "hammer",
            info: "npm, pip, uv, Hugging Face, Gradle, Cargo, Xcode DerivedData… Retéléchargés si besoin.",
            roots: ["~/.npm/_cacache", "~/.cache", "~/.gradle/caches", "~/Library/Developer/Xcode/DerivedData",
                    "~/Library/Developer/CoreSimulator/Caches", "~/.cargo/registry/cache", "~/go/pkg/mod/cache",
                    "~/.bun/install/cache", "~/Library/pnpm/store", "~/.yarn/berry/cache"],
            selected: false),
        Def(id: "mail", name: "Pièces jointes Mail", icon: "paperclip",
            info: "Copies locales des pièces jointes ouvertes depuis Mail (elles restent dans les e-mails).",
            roots: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"]),
        Def(id: "xcode", name: "Supports d'appareils Xcode", icon: "iphone.gen3",
            info: "Symboles de débogage des anciennes versions d'iOS.",
            roots: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport"],
            selected: false),
        Def(id: "ios", name: "Sauvegardes iPhone / iPad", icon: "externaldrive.badge.timemachine",
            info: "Sauvegardes locales d'appareils. À garder si tu n'utilises pas la sauvegarde iCloud.",
            roots: ["~/Library/Application Support/MobileSync/Backup"],
            selected: false),
    ]

    static func scanAll(progress: @escaping (String, Int64) -> Void = { _, _ in }) -> [JunkCategory] {
        var running: Int64 = 0
        return defs.compactMap { def in
            var urls: [URL] = []
            for r in def.roots {
                for c in FS.children(path(r)) {
                    let n = c.lastPathComponent
                    if n == ".DS_Store" || n == ".localized" { continue }
                    if def.excludePrefixes.contains(where: { n.hasPrefix($0) }) { continue }
                    if let ext = def.extensions, !ext.contains(c.pathExtension.lowercased()) { continue }
                    if let f = def.filter, !f(c) { continue }
                    urls.append(c)
                }
            }
            // Size in small parallel chunks so the UI can follow along.
            var sizes: [Int64] = []
            var i = 0
            while i < urls.count {
                let chunk = Array(urls[i..<min(i + 6, urls.count)])
                let s = FS.sizes(chunk)
                sizes += s
                running += s.reduce(0, +)
                progress(chunk.last!.path.replacingOccurrences(of: home.path, with: "~"), running)
                i += 6
            }
            var items: [CleanItem] = []
            for (u, s) in zip(urls, sizes) where s > 0 {
                items.append(CleanItem(url: u, name: u.lastPathComponent,
                                       detail: u.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"),
                                       size: s, selected: def.selected))
            }
            guard !items.isEmpty else { return nil }
            items.sort { $0.size > $1.size }
            return JunkCategory(id: def.id, name: def.name, icon: def.icon, info: def.info, items: items)
        }
    }
}

@MainActor
final class JunkModel: ObservableObject {
    @Published var categories: [JunkCategory] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var lastResult: String?
    @Published var currentPath = ""
    @Published var foundBytes: Int64 = 0
    @Published var cleaning = false
    @Published var lastFreed: Int64 = 0

    var total: Int64 { categories.reduce(0) { $0 + $1.total } }
    var selectedTotal: Int64 { categories.reduce(0) { $0 + $1.selectedTotal } }

    func scan() async {
        scanning = true
        currentPath = ""
        foundBytes = 0
        let cats = await Task.detached(priority: .userInitiated) {
            JunkScanner.scanAll { p, b in
                Task { @MainActor in self.currentPath = p; self.foundBytes = b }
            }
        }.value
        categories = cats
        scanning = false
        scanned = true
    }

    func clean() async {
        let targets = categories.flatMap { $0.items.selectedTargets }
        cleaning = true
        foundBytes = 0
        var freed: Int64 = 0
        var errors: [String] = []
        // Clean in batches so the counter and the ticker animate.
        for chunk in stride(from: 0, to: targets.count, by: 8).map({ Array(targets[$0..<min($0 + 8, targets.count)]) }) {
            currentPath = chunk.last!.0.path.replacingOccurrences(of: home.path, with: "~")
            let r = await Task.detached { Cleaner.trash(chunk) }.value
            freed += r.freed
            errors += r.errors
            foundBytes = freed
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        cleaning = false
        lastFreed = freed
        let r = (freed: freed, errors: errors)
        lastResult = Cleaner.summary(r.freed, r.errors)
        await scan()
    }
}

struct JunkView: View {
    @ObservedObject var model: JunkModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .junk, subtitle: "Caches, journaux, installeurs et fichiers de développement inutiles.") {
                HStack {
                    TrashButton()
                    if model.scanned {
                        Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning)
                    }
                }
            }
            if let r = model.lastResult { Notice(text: r) }

            if model.cleaning {
                ScanningView(text: "Nettoyage en cours…", detail: model.currentPath, bytes: model.foundBytes, cleaning: true)
            } else if model.scanning {
                ScanningView(text: "Recherche des fichiers inutiles…", detail: model.currentPath, bytes: model.foundBytes)
            } else if !model.scanned {
                EmptyState(icon: Module.junk.icon, title: "Fais de la place",
                           message: "Purgo repère les fichiers temporaires que macOS et tes apps accumulent. Tout part dans la Corbeille, donc rien n'est perdu tant que tu ne la vides pas.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else if model.categories.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Tout est propre", message: "Aucun fichier inutile trouvé.")
            } else {
                List {
                    ForEach($model.categories) { $cat in
                        JunkCategoryRow(cat: $cat)
                    }
                }
                ActionBar(text: "\(Fmt.bytes(model.selectedTotal)) sélectionnés sur \(Fmt.bytes(model.total))",
                          buttonTitle: "Nettoyer", tint: Module.junk.tint, disabled: model.selectedTotal == 0) {
                    confirm = true
                }
            }
        }
        .confirmationDialog("Déplacer \(Fmt.bytes(model.selectedTotal)) dans la Corbeille ?", isPresented: $confirm) {
            Button("Nettoyer") { Task { await model.clean() } }
        } message: {
            Text("Les fichiers restent récupérables dans la Corbeille. Ferme les apps concernées pour un meilleur résultat.")
        }
    }
}

struct JunkCategoryRow: View {
    @Binding var cat: JunkCategory

    var body: some View {
        DisclosureGroup(isExpanded: $cat.expanded) {
            ForEach($cat.items) { $item in ItemRow(item: $item) }
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { !cat.items.isEmpty && cat.items.allSatisfy(\.selected) },
                    set: { v in for i in cat.items.indices { cat.items[i].selected = v } }
                )).labelsHidden().toggleStyle(.checkbox)
                Image(systemName: cat.icon).frame(width: 22).foregroundStyle(Module.junk.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.name).font(.headline)
                    Text(cat.info).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.bytes(cat.total)).monospacedDigit().font(.headline)
                    Text("\(cat.items.count) éléments").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

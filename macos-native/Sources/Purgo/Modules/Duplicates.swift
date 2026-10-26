import SwiftUI
import AppKit
import CryptoKit

struct DupGroup: Identifiable {
    let id = UUID()
    let size: Int64
    var files: [CleanItem]
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

enum DupScanner {
    static func hash(_ url: URL, partial: Bool) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        if partial {
            if let d = try? h.read(upToCount: 65536) { hasher.update(data: d) }
            if let end = try? h.seekToEnd(), end > 131072 {
                try? h.seek(toOffset: end - 65536)
                if let d = try? h.read(upToCount: 65536) { hasher.update(data: d) }
            }
        } else {
            while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func scan(root: URL, minSize: Int64, progress: @escaping (String) -> Void) -> [DupGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else { return [] }
        let skip: Set<String> = [home.appendingPathComponent("Library").path, home.appendingPathComponent(".Trash").path]
        var bySize: [Int64: [(URL, Date)]] = [:]
        var n = 0
        for case let u as URL in en {
            if skip.contains(u.path) { en.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let s = v.fileSize, Int64(s) >= minSize else { continue }
            bySize[Int64(s), default: []].append((u, v.creationDate ?? .distantPast))
            n += 1
            if n % 1000 == 0 { progress("\(n) fichiers indexés") }
        }

        var groups: [DupGroup] = []
        let candidates = bySize.filter { $0.value.count > 1 }
        var done = 0
        for (size, files) in candidates {
            done += 1
            if done % 20 == 0 { progress("Comparaison \(done)/\(candidates.count)") }
            var byPartial: [String: [(URL, Date)]] = [:]
            for f in files { if let h = hash(f.0, partial: true) { byPartial[h, default: []].append(f) } }
            for (_, p) in byPartial where p.count > 1 {
                var byFull: [String: [(URL, Date)]] = [:]
                for f in p { if let h = hash(f.0, partial: false) { byFull[h, default: []].append(f) } }
                for (_, same) in byFull where same.count > 1 {
                    let sorted = same.sorted { $0.1 < $1.1 }
                    let items = sorted.enumerated().map { i, f in
                        CleanItem(url: f.0, name: f.0.lastPathComponent,
                                  detail: f.0.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
                                    + (i == 0 ? " · original (le plus ancien)" : ""),
                                  size: size, selected: i != 0)
                    }
                    groups.append(DupGroup(size: size, files: items))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var root: URL = home
    @Published var minSizeKB: Double = 500
    @Published var groups: [DupGroup] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = ""
    @Published var result: String?

    var selectedSize: Int64 { groups.reduce(0) { $0 + $1.files.selectedSize } }
    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func scan() async {
        scanning = true
        progress = ""
        let r = root
        let min = Int64(minSizeKB * 1000)
        groups = await Task.detached {
            DupScanner.scan(root: r, minSize: min) { p in Task { @MainActor in self.progress = p } }
        }.value
        scanning = false
        scanned = true
    }

    func trashSelected() async {
        // Safety: never trash every copy of a group.
        var targets: [(URL, Int64)] = []
        for g in groups {
            let sel = g.files.filter(\.selected)
            if sel.count < g.files.count { targets += sel.map { ($0.url, $0.size) } }
        }
        let r = await Task.detached { Cleaner.trash(targets, allowAdmin: false) }.value
        result = Cleaner.summary(r.freed, r.errors)
        for i in groups.indices { groups[i].files.removeAll { !FS.exists($0.url) } }
        groups.removeAll { $0.files.count < 2 }
    }
}

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .duplicates, subtitle: "Fichiers identiques au bit près, même s'ils portent des noms différents.") {
                HStack {
                    Button("Dossier : \(model.root == home ? "Accueil" : model.root.lastPathComponent)") {
                        if let u = pickFolder(start: model.root) { model.root = u }
                    }
                    if model.scanned { Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning) }
                }
            }
            if let r = model.result { Notice(text: r) }

            if model.scanning {
                ScanningView(text: "Recherche des doublons…", detail: model.progress)
            } else if !model.scanned {
                VStack(spacing: 0) {
                    EmptyState(icon: Module.duplicates.icon, title: "Débusque les doublons",
                               message: "Purgo compare le contenu exact des fichiers (empreinte SHA-256). Dans chaque groupe, la copie la plus ancienne est gardée par défaut.",
                               actionTitle: "Analyser") { Task { await model.scan() } }
                    HStack {
                        Text("Ignorer les fichiers de moins de \(Fmt.bytes(Int64(model.minSizeKB * 1000)))").font(.caption)
                        Slider(value: $model.minSizeKB, in: 1...50000).frame(width: 220)
                    }
                    .padding(.bottom, 30)
                }
            } else if model.groups.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Aucun doublon", message: "Chaque fichier est unique dans ce dossier.")
            } else {
                List {
                    ForEach($model.groups) { $g in
                        Section {
                            ForEach($g.files) { $f in ItemRow(item: $f) }
                        } header: {
                            Text("\(g.files.count) copies · \(Fmt.bytes(g.size)) chacune · \(Fmt.bytes(g.wasted)) récupérables")
                        }
                    }
                }
                ActionBar(text: "\(Fmt.bytes(model.selectedSize)) sélectionnés · \(Fmt.bytes(model.wasted)) en double au total",
                          buttonTitle: "Supprimer les copies", tint: Module.duplicates.tint, disabled: model.selectedSize == 0) {
                    Task { await model.trashSelected() }
                }
            }
        }
    }
}

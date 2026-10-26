import AppKit
import SwiftUI

enum FileKind: String, CaseIterable, Identifiable {
    case all = "Tous les types", video = "Vidéos", audio = "Audio", archive = "Archives et images disque",
         image = "Images", document = "Documents", other = "Autres"
    var id: String { rawValue }

    static func of(_ ext: String) -> FileKind {
        switch ext.lowercased() {
        case "mov", "mp4", "mkv", "avi", "m4v", "webm": return .video
        case "wav", "aif", "aiff", "mp3", "flac", "m4a", "ogg", "alac": return .audio
        case "zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2", "dmg", "iso", "pkg", "img": return .archive
        case "jpg", "jpeg", "png", "heic", "psd", "tif", "tiff", "raw", "cr2", "nef", "dng": return .image
        case "pdf", "doc", "docx", "ppt", "pptx", "key", "pages", "xls", "xlsx", "numbers": return .document
        default: return .other
        }
    }
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Peu importe", month = "Pas ouverts depuis 1 mois", halfYear = "Depuis 6 mois", year = "Depuis 1 an"
    var id: String { rawValue }
    var days: Double? {
        switch self {
        case .any: nil
        case .month: 30
        case .halfYear: 182
        case .year: 365
        }
    }
}

struct BigFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let kind: FileKind
    let accessed: Date?
    var selected = false
}

enum LargeFileScanner {
    static func scan(root: URL, progress: @escaping (Int) -> Void) -> [BigFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .contentAccessDateKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else { return [] }
        let skip: Set<String> = [home.appendingPathComponent("Library").path, home.appendingPathComponent(".Trash").path]
        var out: [BigFile] = []
        var n = 0
        for case let u as URL in en {
            if skip.contains(u.path) { en.skipDescendants(); continue }
            n += 1
            if n % 2000 == 0 { progress(n) }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if s >= 10_000_000 {
                out.append(BigFile(url: u, size: s, kind: .of(u.pathExtension), accessed: v.contentAccessDate ?? v.contentModificationDate))
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor
final class LargeFilesModel: ObservableObject {
    @Published var all: [BigFile] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var scannedCount = 0
    @Published var minSizeMB: Double = 100
    @Published var age: AgeFilter = .any
    @Published var kind: FileKind = .all
    @Published var root: URL = home
    @Published var result: String?

    var visible: [BigFile] {
        let minBytes = Int64(minSizeMB * 1_000_000)
        let limit = age.days.map { Date().addingTimeInterval(-$0 * 86400) }
        return all.filter { f in
            f.size >= minBytes
                && (kind == .all || f.kind == kind)
                && (limit == nil || (f.accessed ?? .distantPast) < limit!)
        }
    }

    var selected: [BigFile] { all.filter(\.selected) }

    func scan() async {
        scanning = true
        scannedCount = 0
        let r = root
        all = await Task.detached {
            LargeFileScanner.scan(root: r) { n in Task { @MainActor in self.scannedCount = n } }
        }.value
        scanning = false
        scanned = true
    }

    func toggle(_ f: BigFile) {
        if let i = all.firstIndex(where: { $0.id == f.id }) { all[i].selected.toggle() }
    }

    func trashSelected() async {
        let targets = selected.map { ($0.url, $0.size) }
        let r = await Task.detached { Cleaner.trash(targets, allowAdmin: false) }.value
        result = Cleaner.summary(r.freed, r.errors)
        all.removeAll { f in f.selected && !FS.exists(f.url) }
    }
}

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .largeFiles, subtitle: "Les fichiers volumineux et ceux que tu n'as pas ouverts depuis longtemps.") {
                HStack {
                    Button("Dossier : \(model.root == home ? "Accueil" : model.root.lastPathComponent)") {
                        if let u = pickFolder(start: model.root) { model.root = u; Task { await model.scan() } }
                    }
                    if model.scanned { Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning) }
                }
            }
            if let r = model.result { Notice(text: r) }

            if model.scanning {
                ScanningView(text: "Exploration des fichiers…", detail: "\(model.scannedCount) fichiers parcourus")
            } else if !model.scanned {
                EmptyState(icon: Module.largeFiles.icon, title: "Trouve ce qui prend de la place",
                           message: "Purgo liste tous tes fichiers de plus de 10 Mo. Filtre ensuite par taille, type et date de dernière ouverture.",
                           actionTitle: "Analyser") { Task { await model.scan() } }
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Taille minimale : \(Fmt.bytes(Int64(model.minSizeMB * 1_000_000)))").font(.caption)
                        Slider(value: $model.minSizeMB, in: 10...5000).frame(width: 220)
                    }
                    Picker("Type", selection: $model.kind) { ForEach(FileKind.allCases) { Text($0.rawValue).tag($0) } }
                        .frame(width: 260)
                    Picker("Ancienneté", selection: $model.age) { ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) } }
                        .frame(width: 280)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 8)

                let files = model.visible
                if files.isEmpty {
                    EmptyState(icon: "line.3.horizontal.decrease.circle", title: "Aucun fichier", message: "Assouplis les filtres.")
                } else {
                    List(files) { f in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { f.selected }, set: { _ in model.toggle(f) }))
                                .labelsHidden().toggleStyle(.checkbox)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.url.lastPathComponent).lineLimit(1)
                                Text("\(f.url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")) · ouvert \(Fmt.relative(f.accessed))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Fmt.bytes(f.size)).monospacedDigit()
                            RevealButton(url: f.url)
                        }
                    }
                }
                ActionBar(text: "\(model.selected.count) fichier(s) · \(Fmt.bytes(model.selected.reduce(0) { $0 + $1.size }))",
                          buttonTitle: "Mettre à la Corbeille", tint: Module.largeFiles.tint, disabled: model.selected.isEmpty) {
                    confirm = true
                }
            }
        }
        .confirmationDialog("Mettre \(model.selected.count) fichier(s) à la Corbeille ?", isPresented: $confirm) {
            Button("Mettre à la Corbeille", role: .destructive) { Task { await model.trashSelected() } }
        }
    }
}

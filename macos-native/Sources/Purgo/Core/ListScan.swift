import SwiftUI
import AppKit

// MARK: - Home folder walker shared by the developer modules

enum HomeWalker {
    static let defaultSkipNames: Set<String> = ["node_modules", ".git", "site-packages", ".npm", ".rustup", ".cargo", ".ollama",
                                                ".docker", ".gradle", ".m2", "DerivedData", ".Trash", "__pycache__"]
    static let defaultHomeSkip: Set<String> = Set(["Library", ".Trash", "Music", "Pictures", "Movies", "Applications"]
        .map { home.appendingPathComponent($0).path })

    /// Returns every folder matching `match` (without descending into it).
    static func find(roots: [URL] = [home],
                     skipNames: Set<String> = defaultSkipNames,
                     homeSkip: Set<String> = defaultHomeSkip,
                     progress: (String) -> Void = { _ in },
                     match: (URL) -> Bool) -> [URL] {
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var n = 0
        for root in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsPackageDescendants],
                                                          errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in en {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isSymbolicLink != true else { continue }
                if match(u) { out.append(u); en.skipDescendants(); continue }
                if homeSkip.contains(u.path) || skipNames.contains(u.lastPathComponent) { en.skipDescendants(); continue }
                n += 1
                if n % 300 == 0 { progress(u.path.tilde) }
            }
        }
        return out
    }

    static func modified(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - Generic "scan a list of items, trash the selected ones" module

@MainActor
class ListScanModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress = ""
    @Published var foundBytes: Int64 = 0
    @Published var result: String?

    /// Builds the list (runs off the main thread). `report(path, bytesSoFar)`.
    nonisolated func produce(report: @escaping (String, Int64) -> Void) -> [CleanItem] { [] }

    /// Files to actually move to the Trash for the selected items.
    nonisolated func expand(_ selected: [CleanItem]) -> [(URL, Int64)] { selected.map { ($0.url, $0.size) } }

    func scan() async {
        scanning = true
        progress = ""
        foundBytes = 0
        result = nil
        let found = await Task.detached(priority: .userInitiated) {
            self.produce { p, b in
                Task { @MainActor in
                    self.progress = p
                    if b > 0 { self.foundBytes = b }
                }
            }
        }.value
        items = found
        scanning = false
        scanned = true
    }

    func trashSelected() async {
        let sel = items.filter(\.selected)
        let r = await Task.detached { Cleaner.trash(self.expand(sel), allowAdmin: false) }.value
        result = Cleaner.summary(r.freed, r.errors)
        items.removeAll { !FS.exists($0.url) }
    }
}

struct ListScanView<Extra: View>: View {
    @ObservedObject var model: ListScanModel
    let module: Module
    let subtitle: String
    let scanningText: String
    let emptyTitle: String
    let emptyMessage: String
    var actionTitle = "Mettre à la Corbeille"
    var note: String? = nil
    @ViewBuilder var extra: () -> Extra
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: module, subtitle: subtitle) {
                if model.scanned { Button("Réanalyser") { Task { await model.scan() } }.disabled(model.scanning) }
            }
            if let r = model.result { Notice(text: r) }

            if model.scanning {
                ScanningView(text: scanningText, detail: model.progress, bytes: model.foundBytes > 0 ? model.foundBytes : nil)
            } else if !model.scanned {
                EmptyState(icon: module.icon, title: emptyTitle, message: emptyMessage, actionTitle: "Analyser") {
                    Task { await model.scan() }
                }
            } else if model.items.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Rien à signaler", message: "Rien trouvé ici, tout est propre.")
            } else {
                if let note {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb").foregroundStyle(.yellow)
                        Text(.init(note)).font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.bottom, 8)
                }
                extra()
                List { ForEach($model.items) { $i in ItemRow(item: $i) } }
                ActionBar(text: "\(Fmt.bytes(model.items.selectedSize)) sélectionnés sur \(Fmt.bytes(model.items.totalSize))",
                          buttonTitle: actionTitle, tint: module.tint, disabled: model.items.selectedSize == 0) {
                    confirm = true
                }
            }
        }
        .confirmationDialog("\(actionTitle) : \(Fmt.bytes(model.items.selectedSize)) ?", isPresented: $confirm) {
            Button(actionTitle, role: .destructive) { Task { await model.trashSelected() } }
        } message: {
            Text("Tout part dans la Corbeille : rien n'est perdu tant que tu ne la vides pas.")
        }
    }
}

extension ListScanView where Extra == EmptyView {
    init(model: ListScanModel, module: Module, subtitle: String, scanningText: String,
         emptyTitle: String, emptyMessage: String, actionTitle: String = "Mettre à la Corbeille", note: String? = nil) {
        self.init(model: model, module: module, subtitle: subtitle, scanningText: scanningText,
                  emptyTitle: emptyTitle, emptyMessage: emptyMessage, actionTitle: actionTitle, note: note) { EmptyView() }
    }
}

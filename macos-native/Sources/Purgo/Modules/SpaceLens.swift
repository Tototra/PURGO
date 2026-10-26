import SwiftUI
import AppKit

struct LensNode: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDir: Bool
    var size: Int64
}

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var stack: [URL] = [home]
    @Published var nodes: [LensNode] = []
    @Published var pending = 0
    @Published var message: String?
    private var generation = 0

    var current: URL { stack.last ?? home }
    var total: Int64 { nodes.reduce(0) { $0 + max($1.size, 0) } }
    var maxSize: Int64 { nodes.map(\.size).max() ?? 1 }
    var sorted: [LensNode] { nodes.sorted { $0.size > $1.size } }

    func load() {
        generation += 1
        let g = generation
        let kids = FS.children(current).filter { $0.lastPathComponent != ".DS_Store" }
        nodes = kids.map { LensNode(url: $0, name: $0.lastPathComponent, isDir: FS.isDir($0) && !FS.isPackage($0), size: -1) }
        pending = nodes.count
        for n in nodes {
            let u = n.url
            Task.detached(priority: .utility) {
                let s = FS.size(of: u)
                await MainActor.run {
                    guard self.generation == g, let i = self.nodes.firstIndex(where: { $0.url == u }) else { return }
                    self.nodes[i].size = s
                    self.pending -= 1
                }
            }
        }
    }

    func open(_ n: LensNode) {
        guard n.isDir else { FS.reveal(n.url); return }
        stack.append(n.url)
        load()
    }

    func go(to index: Int) {
        stack = Array(stack.prefix(index + 1))
        load()
    }

    func setRoot(_ url: URL) {
        stack = [url]
        load()
    }

    func trash(_ n: LensNode) {
        if FS.trash(n.url) == nil {
            nodes.removeAll { $0.id == n.id }
            message = "\(n.name) déplacé dans la Corbeille (\(Fmt.bytes(max(n.size, 0))))"
        } else {
            message = "Impossible de déplacer \(n.name)"
        }
    }
}

struct SpaceLensView: View {
    @ObservedObject var model: SpaceLensModel
    @State private var pendingTrash: LensNode?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .spaceLens, subtitle: "Visualise ce qui occupe ton disque, dossier par dossier.") {
                HStack {
                    Button("Dossier personnel") { model.setRoot(home) }
                    Button("Disque entier") { model.setRoot(URL(fileURLWithPath: "/")) }
                    Button("Choisir…") { if let u = pickFolder(start: model.current) { model.setRoot(u) } }
                }
            }
            if let m = model.message { Notice(text: m) }

            HStack(spacing: 4) {
                ForEach(Array(model.stack.enumerated()), id: \.offset) { i, u in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button(i == 0 && u == home ? "Accueil" : (u.path == "/" ? "Macintosh HD" : u.lastPathComponent)) { model.go(to: i) }
                        .buttonStyle(.borderless)
                        .fontWeight(i == model.stack.count - 1 ? .semibold : .regular)
                }
                Spacer()
                if model.pending > 0 {
                    ProgressView().controlSize(.small)
                    Text("Calcul… \(model.pending) restant(s)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Total : \(Fmt.bytes(model.total))").font(.callout.bold())
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            List(model.sorted) { n in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path)).resizable().frame(width: 22, height: 22)
                    Text(n.name).lineLimit(1)
                    Spacer()
                    if n.size < 0 {
                        ProgressView().controlSize(.mini)
                    } else {
                        SizeBar(fraction: Double(n.size) / Double(max(model.maxSize, 1)), tint: Module.spaceLens.tint)
                        Text(Fmt.bytes(n.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    if n.isDir {
                        Button { model.open(n) } label: { Image(systemName: "chevron.right.circle") }.buttonStyle(.borderless)
                    } else {
                        RevealButton(url: n.url)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.open(n) }
                .contextMenu {
                    Button("Afficher dans le Finder") { FS.reveal(n.url) }
                    Button("Mettre à la Corbeille", role: .destructive) { pendingTrash = n }
                }
            }
        }
        .task { if model.nodes.isEmpty { model.load() } }
        .confirmationDialog("Mettre « \(pendingTrash?.name ?? "") » à la Corbeille ?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Mettre à la Corbeille", role: .destructive) {
                if let n = pendingTrash { model.trash(n) }
                pendingTrash = nil
            }
        }
    }
}

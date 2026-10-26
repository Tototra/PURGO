import SwiftUI
import AppKit

// MARK: - Node.js

final class NodeModel: ListScanModel {
    override nonisolated func produce(report: @escaping (String, Int64) -> Void) -> [CleanItem] {
        var out: [CleanItem] = []
        var total: Int64 = 0

        let dirs = HomeWalker.find(progress: { report($0, 0) }) { u in
            u.lastPathComponent == "node_modules" && FS.exists(u.deletingLastPathComponent().appendingPathComponent("package.json"))
        }
        for d in dirs {
            let proj = d.deletingLastPathComponent()
            let s = FS.size(of: d)
            total += s
            report(d.path.tilde, total)
            let touched = [HomeWalker.modified(proj.appendingPathComponent("package.json")), HomeWalker.modified(proj)].compactMap { $0 }.max()
            let days = touched.map { Date().timeIntervalSince($0) / 86400 } ?? 9999
            out.append(CleanItem(url: d, name: "\(proj.lastPathComponent) › node_modules",
                                 detail: "\(proj.path.tilde) · projet modifié \(Fmt.relative(touched)) · npm install pour le recréer",
                                 size: s, selected: days > 90))
        }

        let def = (try? String(contentsOf: path("~/.nvm/alias/default"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for v in FS.children(path("~/.nvm/versions/node")) where FS.isDir(v) {
            let isDefault = !def.isEmpty && v.lastPathComponent.hasPrefix(def.hasPrefix("v") ? def : "v" + def)
            let s = FS.size(of: v)
            total += s
            out.append(CleanItem(url: v, name: "Node \(v.lastPathComponent) (nvm)",
                                 detail: isDefault ? "Version par défaut, à garder" : "Version installée avec nvm",
                                 size: s, selected: false))
        }

        let caches: [(String, String)] = [
            ("~/.npm/_cacache", "Cache npm"), ("~/Library/Caches/Yarn", "Cache Yarn"), ("~/.yarn/berry/cache", "Cache Yarn Berry"),
            ("~/Library/pnpm/store", "Store pnpm"), ("~/Library/Caches/pnpm", "Cache pnpm"), ("~/.bun/install/cache", "Cache Bun"),
            ("~/Library/Caches/ms-playwright", "Navigateurs Playwright"), ("~/.cache/puppeteer", "Chrome de Puppeteer"),
            ("~/Library/Caches/node-gyp", "En-têtes node-gyp"),
        ]
        for (p, n) in caches {
            let u = path(p)
            guard FS.exists(u) else { continue }
            let s = FS.size(of: u)
            guard s > 0 else { continue }
            total += s
            out.append(CleanItem(url: u, name: n, detail: "Cache global, retéléchargé à la demande", size: s, selected: true))
        }
        return out.sorted { $0.size > $1.size }
    }
}

struct NodeView: View {
    @ObservedObject var model: NodeModel
    var body: some View {
        ListScanView(model: model, module: .node,
                     subtitle: "Les dossiers node_modules de tes projets, les versions de Node et les caches npm, Yarn, pnpm.",
                     scanningText: "Recherche des node_modules…",
                     emptyTitle: "Le trou noir des node_modules",
                     emptyMessage: "Chaque projet JavaScript embarque des centaines de Mo de dépendances. Purgo les retrouve tous ; ceux des projets inactifs depuis 3 mois sont présélectionnés.",
                     note: "Un `npm install` (ou `pnpm install`) dans le projet recrée son dossier node_modules en quelques secondes. Astuce : **pnpm** partage les paquets entre projets au lieu de les copier.")
    }
}

// MARK: - Local AI models

enum Ollama {
    static let root = path("~/.ollama/models")

    struct Manifest { let name: String; let url: URL; let digests: [String]; let size: Int64 }

    static func manifests() -> [Manifest] {
        let mroot = root.appendingPathComponent("manifests")
        guard let en = FileManager.default.enumerator(at: mroot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [Manifest] = []
        for case let f as URL in en {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let d = try? Data(contentsOf: f),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var layers = (j["layers"] as? [[String: Any]]) ?? []
            if let c = j["config"] as? [String: Any] { layers.append(c) }
            var digests: [String] = []
            var size: Int64 = 0
            for l in layers {
                if let dg = l["digest"] as? String { digests.append(dg) }
                size += (l["size"] as? NSNumber)?.int64Value ?? 0
            }
            var comps = f.path.replacingOccurrences(of: mroot.path + "/", with: "").split(separator: "/").map(String.init)
            if comps.first == "registry.ollama.ai" { comps.removeFirst() }
            if comps.first == "library" { comps.removeFirst() }
            let tag = comps.popLast() ?? "latest"
            out.append(Manifest(name: comps.joined(separator: "/") + ":" + tag, url: f, digests: digests, size: size))
        }
        return out
    }

    static func blob(_ digest: String) -> URL {
        root.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
    }
}

final class AIModelsModel: ListScanModel {
    override nonisolated func produce(report: @escaping (String, Int64) -> Void) -> [CleanItem] {
        var out: [CleanItem] = []
        func used(_ u: URL) -> Date? {
            let v = try? u.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            return v?.contentAccessDate ?? v?.contentModificationDate
        }
        func add(_ u: URL, _ name: String, _ source: String, size: Int64? = nil) {
            let s = size ?? FS.size(of: u)
            guard s > 0 else { return }
            out.append(CleanItem(url: u, name: name, detail: "\(source) · utilisé \(Fmt.relative(used(u)))", size: s, selected: false))
            report(u.path.tilde, out.reduce(0) { $0 + $1.size })
        }

        for m in Ollama.manifests() { add(m.url, m.name, "Ollama", size: m.size) }

        for c in FS.children(path("~/.cache/huggingface/hub")) {
            let n = c.lastPathComponent
            for prefix in ["models--", "datasets--", "spaces--"] where n.hasPrefix(prefix) {
                add(c, String(n.dropFirst(prefix.count)).replacingOccurrences(of: "--", with: "/"),
                    prefix == "datasets--" ? "Hugging Face (dataset)" : "Hugging Face")
            }
        }
        for r in ["~/.lmstudio/models", "~/.cache/lm-studio/models"] {
            for pub in FS.children(path(r)) where FS.isDir(pub) {
                for m in FS.children(pub) where FS.isDir(m) { add(m, "\(pub.lastPathComponent)/\(m.lastPathComponent)", "LM Studio") }
            }
        }
        for f in FS.children(path("~/.cache/whisper")) { add(f, f.lastPathComponent, "Whisper") }
        for f in FS.children(path("~/Library/Application Support/nomic.ai/GPT4All")) where ["gguf", "bin"].contains(f.pathExtension) {
            add(f, f.lastPathComponent, "GPT4All")
        }
        for f in FS.children(path("~/.cache/torch/hub/checkpoints")) { add(f, f.lastPathComponent, "PyTorch Hub") }
        for f in FS.children(path("~/.cache/torch/sentence_transformers")) { add(f, f.lastPathComponent, "Sentence Transformers") }
        return out.sorted { $0.size > $1.size }
    }

    /// Deleting an Ollama model = its manifest + the blobs no other model uses.
    override nonisolated func expand(_ selected: [CleanItem]) -> [(URL, Int64)] {
        var res = selected.map { ($0.url, $0.size) }
        let ollamaSel = Set(selected.filter { $0.url.path.contains("/.ollama/models/manifests/") }.map(\.url.path))
        guard !ollamaSel.isEmpty else { return res }
        let all = Ollama.manifests()
        let keep = Set(all.filter { !ollamaSel.contains($0.url.path) }.flatMap(\.digests))
        let drop = Set(all.filter { ollamaSel.contains($0.url.path) }.flatMap(\.digests)).subtracting(keep)
        res += drop.map { (Ollama.blob($0), Int64(0)) }
        return res
    }
}

struct AIModelsView: View {
    @ObservedObject var model: AIModelsModel
    var body: some View {
        ListScanView(model: model, module: .aiModels,
                     subtitle: "Les modèles d'IA téléchargés : Ollama, Hugging Face, LM Studio, Whisper, GPT4All, PyTorch.",
                     scanningText: "Recherche des modèles d'IA…",
                     emptyTitle: "Des Go de poids neuronaux",
                     emptyMessage: "Un seul modèle local pèse souvent 2 à 40 Go. Purgo les liste tous avec leur date de dernière utilisation. Rien n'est présélectionné.",
                     note: "Supprimer un modèle Ollama retire aussi ses fichiers de poids, sauf ceux partagés avec un autre modèle. Il se retélécharge avec `ollama pull`.")
    }
}

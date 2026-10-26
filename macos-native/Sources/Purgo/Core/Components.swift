import SwiftUI
import AppKit

// MARK: - Shared item model

struct CleanItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String
    var detail: String = ""
    var size: Int64
    var selected: Bool = true
}

extension Array where Element == CleanItem {
    var selectedSize: Int64 { filter(\.selected).reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { reduce(0) { $0 + $1.size } }
    var selectedTargets: [(URL, Int64)] { filter(\.selected).map { ($0.url, $0.size) } }
}

// MARK: - Header

struct ModuleHeader<Trailing: View>: View {
    let module: Module
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: module.icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(module.tint.gradient))
            VStack(alignment: .leading, spacing: 4) {
                Text(module.title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(20)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(module: Module, subtitle: String) {
        self.init(module: module, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Rows

struct ItemRow: View {
    @Binding var item: CleanItem

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            RevealButton(url: item.url)
        }
        .padding(.vertical, 2)
    }
}

struct RevealButton: View {
    let url: URL
    var body: some View {
        Button { FS.reveal(url) } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Afficher dans le Finder")
    }
}

// MARK: - States

struct ScanningView: View {
    let text: String
    var detail: String = ""
    var bytes: Int64? = nil
    var cleaning = false
    @Environment(\.moduleTint) private var tint

    var body: some View {
        VStack(spacing: 22) {
            ScanOrb(phase: cleaning ? .cleaning : .scanning, tint: tint) {
                VStack(spacing: 4) {
                    if let bytes {
                        CountingBytes(value: Double(bytes))
                            .animation(.easeOut(duration: 0.6), value: bytes)
                        Text(cleaning ? "nettoyés" : "trouvés").font(.callout).opacity(0.85)
                    } else {
                        Image(systemName: cleaning ? "wind" : "magnifyingglass")
                            .font(.system(size: 40, weight: .semibold))
                            .symbolEffect(.pulse)
                    }
                }
            }
            Text(text).font(.title3.bold())
            LiveTicker(text: detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.moduleTint) private var tint
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            if let actionTitle, let action {
                ScanOrb(phase: .idle, tint: tint, action: action) {
                    VStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 38, weight: .semibold))
                        Text(actionTitle).font(.title3.bold())
                    }
                }
            } else if icon.contains("checkmark") {
                ScanOrb(phase: .done, tint: tint, size: 180) {
                    Image(systemName: "checkmark").font(.system(size: 50, weight: .heavy))
                        .scaleEffect(appeared ? 1 : 0.3)
                        .animation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.15), value: appeared)
                }
            } else {
                Image(systemName: icon).font(.system(size: 46)).foregroundStyle(tint.opacity(0.6))
            }
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { appeared = true } }
    }
}

struct Notice: View {
    let text: String
    var icon = "checkmark.circle.fill"
    var color: Color = .green
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(text)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

// MARK: - Bottom action bar

struct ActionBar: View {
    let text: String
    let buttonTitle: String
    let tint: Color
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.headline)
            Spacer()
            Button(action: action) { Text(buttonTitle).frame(minWidth: 120) }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.large)
                .disabled(disabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Visuals

struct Ring: View {
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: value)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }
}

struct SizeBar: View {
    let fraction: Double
    let tint: Color
    var width: CGFloat = 140
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08)).frame(width: width, height: 6)
            Capsule().fill(tint.gradient).frame(width: max(2, width * min(max(fraction, 0), 1)), height: 6)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

// MARK: - Trash

struct TrashButton: View {
    @State private var size: Int64 = -1
    @State private var confirm = false

    var body: some View {
        Button { confirm = true } label: {
            Label(size >= 0 ? "Corbeille · \(Fmt.bytes(size))" : "Corbeille", systemImage: "trash")
        }
        .task { await refresh() }
        .confirmationDialog("Vider définitivement la Corbeille ?", isPresented: $confirm) {
            Button("Vider la Corbeille", role: .destructive) {
                Task {
                    _ = await Task.detached {
                        Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
                    }.value
                    await refresh()
                }
            }
        } message: {
            Text("C'est la seule action irréversible de Purgo : les fichiers seront supprimés pour de bon.")
        }
    }

    func refresh() async {
        size = await Task.detached { FS.size(of: home.appendingPathComponent(".Trash")) }.value
    }
}

// MARK: - Folder picker

func pickFolder(start: URL? = nil) -> URL? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.allowsMultipleSelection = false
    p.directoryURL = start
    p.prompt = "Choisir"
    return p.runModal() == .OK ? p.url : nil
}

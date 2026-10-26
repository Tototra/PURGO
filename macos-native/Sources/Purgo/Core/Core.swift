import Foundation
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser

/// Expands "~" and builds a file URL.
func path(_ s: String) -> URL {
    URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(b, 0), countStyle: .file)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "jamais" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func percent(_ v: Double) -> String {
        String(format: "%.0f %%", v * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }
}

// MARK: - File system

enum FS {
    static let fm = FileManager.default

    static func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    static func isPackage(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    private static let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

    /// Space actually used on disk by a file or a folder (recursive).
    static func size(of url: URL) -> Int64 {
        if !isDir(url) {
            let v = try? url.resourceValues(forKeys: sizeKeys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: sizeKeys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Sizes of many items, computed in parallel.
    static func sizes(_ urls: [URL]) -> [Int64] {
        var out = [Int64](repeating: 0, count: urls.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                buf[i] = size(of: urls[i])
            }
        }
        return out
    }

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// Moves an item to the Trash (reversible). Returns an error message on failure.
    @discardableResult
    static func trash(_ url: URL) -> String? {
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            return "\(url.lastPathComponent) : \(error.localizedDescription)"
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    static func sh(_ cmd: String) -> (code: Int32, out: String) {
        run("/bin/zsh", ["-c", cmd])
    }

    /// Runs a command as administrator (macOS shows its password prompt).
    @discardableResult
    static func admin(_ cmd: String) -> (code: Int32, out: String) {
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Cleaner (everything goes to the Trash, never deleted directly)

enum Cleaner {
    /// Moves items to the Trash. Items outside the home folder that need
    /// root rights are moved with a single administrator prompt.
    static func trash(_ items: [(URL, Int64)], allowAdmin: Bool = true) -> (freed: Int64, errors: [String]) {
        var freed: Int64 = 0
        var errors: [String] = []
        var needAdmin: [(URL, Int64)] = []
        for (u, s) in items where FS.exists(u) {
            if FS.trash(u) == nil {
                freed += s
            } else if allowAdmin && !u.path.hasPrefix(home.path) {
                needAdmin.append((u, s))
            } else {
                errors.append(u.lastPathComponent)
            }
        }
        if !needAdmin.isEmpty {
            let trashDir = home.appendingPathComponent(".Trash").path
            let stamp = Int(Date().timeIntervalSince1970)
            let cmd = needAdmin.map { item in
                "mv -f \(Shell.quote(item.0.path)) \(Shell.quote(trashDir + "/" + item.0.lastPathComponent + "-\(stamp)"))"
            }.joined(separator: "; ")
            let r = Shell.admin(cmd)
            if r.code == 0 {
                freed += needAdmin.reduce(0) { $0 + $1.1 }
            } else {
                errors += needAdmin.map { $0.0.lastPathComponent }
            }
        }
        Prefs.addFreed(freed)
        return (freed, errors)
    }

    static func summary(_ freed: Int64, _ errors: [String]) -> String {
        var s = "\(Fmt.bytes(freed)) déplacés dans la Corbeille"
        if !errors.isEmpty { s += " · \(errors.count) élément(s) ignoré(s) (protégés ou en cours d'utilisation)" }
        return s
    }
}

// MARK: - Permissions

enum Permissions {
    /// Full Disk Access is needed to read Safari, Mail and some caches.
    static var hasFullDiskAccess: Bool {
        let probe = home.appendingPathComponent("Library/Application Support/com.apple.TCC")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

// MARK: - launchd plists (shared by Startup and Malware)

struct LaunchPlist {
    let label: String?
    let program: String?
    let arguments: [String]
    let disabledKey: Bool
    let runAtLoad: Bool

    init(url: URL) {
        let d = (try? Data(contentsOf: url))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        label = d["Label"] as? String
        arguments = d["ProgramArguments"] as? [String] ?? []
        program = (d["Program"] as? String) ?? arguments.first
        disabledKey = d["Disabled"] as? Bool ?? false
        runAtLoad = d["RunAtLoad"] as? Bool ?? false
    }
}

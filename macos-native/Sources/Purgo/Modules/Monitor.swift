import AppKit
import SwiftUI
import Charts
import Darwin

struct MemInfo {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swap: UInt64 = 0
    var used: UInt64 { app + wired + compressed }
    var pressure: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct BatteryInfo {
    let percent: Int
    let charging: Bool
    let plugged: Bool
    let cycles: Int
    let health: Double?
}

struct ProcInfo: Identifiable {
    let id: Int32
    let name: String
    let cpu: Double
    let mem: Int64
}

struct CPUTicks { let user, system, idle, nice: UInt32 }

enum SysInfo {
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: t.0, system: t.1, idle: t.2, nice: t.3)
    }

    static func memory() -> MemInfo {
        var m = MemInfo()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            var ps: vm_size_t = 0
            host_page_size(mach_host_self(), &ps)
            let page = UInt64(ps)
            let intPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (intPages > purgeable ? intPages - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swap = swap.xsu_used }
        return m
    }

    static func disk() -> (free: Int64, total: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }

    static func battery() -> BatteryInfo? {
        let out = Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]).out
        guard out.contains("CycleCount") else { return nil }
        func num(_ k: String) -> Int? {
            guard let r = out.range(of: "\"\(k)\" = (\\d+)", options: .regularExpression) else { return nil }
            return Int(out[r].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        func yes(_ k: String) -> Bool { out.contains("\"\(k)\" = Yes") }
        let cur = num("CurrentCapacity") ?? 0
        let maxC = num("MaxCapacity") ?? 100
        let percent = maxC == 100 ? cur : (maxC > 0 ? cur * 100 / maxC : 0)
        let raw = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity")
        let design = num("DesignCapacity")
        var health: Double?
        if let raw, let design, design > 0 { health = min(Double(raw) / Double(design), 1) }
        return BatteryInfo(percent: percent, charging: yes("IsCharging"), plugged: yes("ExternalConnected"),
                           cycles: num("CycleCount") ?? 0, health: health)
    }

    static func topProcesses(byMemory: Bool) -> [ProcInfo] {
        let r = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm=", byMemory ? "-m" : "-r"])
        return r.out.split(separator: "\n").prefix(14).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int64(parts[2]) else { return nil }
            return ProcInfo(id: pid, name: String(parts[3]), cpu: cpu, mem: rss * 1024)
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var mem = MemInfo()
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var battery: BatteryInfo?
    @Published var processes: [ProcInfo] = []
    @Published var sortByMemory = false
    @Published var freeingRAM = false
    @Published var lastFreed: String?

    var diskUsedFraction: Double { diskTotal > 0 ? 1 - Double(diskFree) / Double(diskTotal) : 0 }

    private var timer: Timer?
    private var prev: CPUTicks?
    private var tick = 0

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if let t = SysInfo.cpuTicks() {
            if let p = prev {
                let busy = Double(t.user &- p.user) + Double(t.system &- p.system) + Double(t.nice &- p.nice)
                let total = busy + Double(t.idle &- p.idle)
                if total > 0 { cpu = busy / total }
            }
            prev = t
        }
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        mem = SysInfo.memory()
        let d = SysInfo.disk()
        diskFree = d.free
        diskTotal = d.total
        tick += 1
        let byMem = sortByMemory
        if tick % 15 == 1 {
            Task.detached { let b = SysInfo.battery(); await MainActor.run { self.battery = b } }
        }
        Task.detached { let p = SysInfo.topProcesses(byMemory: byMem); await MainActor.run { self.processes = p } }
    }

    func freeRAM() async {
        freeingRAM = true
        let before = mem.used
        let r = await Task.detached { Shell.admin("/usr/sbin/purge") }.value
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        refresh()
        freeingRAM = false
        if r.code == 0 {
            lastFreed = "Mémoire libérée : \(Fmt.bytes(Int64(before) - Int64(mem.used)))"
        }
    }

    func quit(_ p: ProcInfo) {
        if let app = NSRunningApplication(processIdentifier: p.id) { app.terminate() } else { kill(p.id, SIGTERM) }
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .monitor, subtitle: "Processeur, mémoire, disque, batterie et apps gourmandes en temps réel.") {
                Text("Allumé depuis \(Fmt.duration(ProcessInfo.processInfo.systemUptime))").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        cpuCard
                        memCard
                    }
                    HStack(spacing: 14) {
                        diskCard
                        batteryCard
                    }
                    processCard
                }
                .padding(20)
            }
        }
    }

    var cpuCard: some View {
        Card {
            HStack(spacing: 16) {
                gauge(model.cpu, .orange, "CPU")
                Chart {
                    ForEach(Array(model.cpuHistory.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("t", i), y: .value("CPU", v * 100))
                            .foregroundStyle(.orange.opacity(0.2))
                        LineMark(x: .value("t", i), y: .value("CPU", v * 100))
                            .foregroundStyle(.orange)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .frame(height: 100)
            }
        }
    }

    var memCard: some View {
        Card {
            HStack(spacing: 16) {
                gauge(model.mem.pressure, .blue, "RAM")
                VStack(alignment: .leading, spacing: 4) {
                    row("Utilisée", Int64(model.mem.used))
                    row("Apps", Int64(model.mem.app))
                    row("Réservée (wired)", Int64(model.mem.wired))
                    row("Compressée", Int64(model.mem.compressed))
                    row("Fichiers en cache", Int64(model.mem.cached))
                    row("Swap", Int64(model.mem.swap))
                    HStack {
                        Button(model.freeingRAM ? "Libération…" : "Libérer la mémoire") { Task { await model.freeRAM() } }
                            .disabled(model.freeingRAM).controlSize(.small)
                        if let l = model.lastFreed { Text(l).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    var diskCard: some View {
        Card {
            HStack(spacing: 16) {
                gauge(model.diskUsedFraction, .purple, "Disque")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Macintosh HD").font(.headline)
                    row("Disponible", model.diskFree)
                    row("Capacité", model.diskTotal)
                    row("Utilisé", model.diskTotal - model.diskFree)
                }
            }
        }
    }

    var batteryCard: some View {
        Card {
            if let b = model.battery {
                HStack(spacing: 16) {
                    gauge(Double(b.percent) / 100, .green, "Batterie")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(b.charging ? "En charge" : (b.plugged ? "Branché" : "Sur batterie")).font(.headline)
                        if let h = b.health { Text("Santé : \(Fmt.percent(h)) de la capacité d'origine").font(.callout) }
                        Text("Cycles de charge : \(b.cycles)").font(.callout)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "powerplug").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Pas de batterie (Mac de bureau)").foregroundStyle(.secondary)
                }
                .frame(height: 100)
            }
        }
    }

    var processCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Apps les plus gourmandes").font(.headline)
                    Spacer()
                    Picker("", selection: $model.sortByMemory) {
                        Text("CPU").tag(false)
                        Text("Mémoire").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 180)
                }
                ForEach(model.processes) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f %%", p.cpu)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(Fmt.bytes(p.mem)).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        Button { model.quit(p) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Quitter")
                    }
                    .font(.callout)
                    Divider()
                }
            }
        }
    }

    func gauge(_ v: Double, _ c: Color, _ title: String) -> some View {
        ZStack {
            Ring(value: v, tint: c, lineWidth: 10)
            VStack(spacing: 0) {
                Text(Fmt.percent(v)).font(.title3.bold()).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 100, height: 100)
    }

    func row(_ label: String, _ v: Int64) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(Fmt.bytes(v)).monospacedDigit()
        }
        .font(.callout)
        .frame(maxWidth: 260)
    }
}

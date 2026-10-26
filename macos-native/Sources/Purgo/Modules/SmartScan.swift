import SwiftUI
import AppKit

struct SmartScanView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        SmartScanBody(junk: state.junk, malware: state.malware, startup: state.startup, monitor: state.monitor) { state.module = $0 }
    }
}

struct SmartScanBody: View {
    @ObservedObject var junk: JunkModel
    @ObservedObject var malware: MalwareModel
    @ObservedObject var startup: StartupModel
    @ObservedObject var monitor: MonitorModel
    let go: (Module) -> Void

    @State private var phase: OrbPhase = .idle
    @State private var steps: [Int: StepRow.Phase] = [0: .waiting, 1: .waiting, 2: .waiting]
    @State private var cardsShown = 0
    @State private var freed: Int64 = 0
    @State private var cleanedOnce = false
    @State private var resultLine: String?

    private let tint = Module.smartScan.tint

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 10)

            ScanOrb(phase: phase, tint: tint, size: 260, action: phase == .idle ? { run() } : nil) {
                orbContent
            }

            VStack(spacing: 8) {
                Text(headline).font(.title2.bold())
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: phase)
                if phase == .scanning || phase == .cleaning {
                    LiveTicker(text: tickerText)
                } else if let r = resultLine {
                    Text(r).foregroundStyle(.secondary).transition(.opacity)
                } else if phase == .idle {
                    Text("Nettoyage, protection et vitesse en une seule analyse.").foregroundStyle(.secondary)
                    if Prefs.lifetimeFreed > 0 {
                        Label("Purgo t'a déjà fait gagner \(Fmt.bytes(Prefs.lifetimeFreed))", systemImage: "trophy")
                            .font(.callout.weight(.medium)).foregroundStyle(tint)
                    }
                }
            }

            if phase == .scanning {
                HStack(spacing: 28) {
                    StepRow(title: "Fichiers inutiles", icon: Module.junk.icon, state: steps[0] ?? .waiting, tint: Module.junk.tint)
                    StepRow(title: "Menaces", icon: Module.malware.icon, state: steps[1] ?? .waiting, tint: Module.malware.tint)
                    StepRow(title: "Démarrage", icon: Module.startup.icon, state: steps[2] ?? .waiting, tint: Module.startup.tint)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if phase == .done {
                HStack(alignment: .top, spacing: 14) {
                    if cardsShown > 0 {
                        SummaryCard(module: .junk, value: Fmt.bytes(junk.selectedTotal),
                                    caption: "à nettoyer sur \(Fmt.bytes(junk.total)) trouvés") { go(.junk) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if cardsShown > 1 {
                        let n = malware.knownCount + malware.suspiciousCount
                        SummaryCard(module: .malware, value: n == 0 ? "Aucune" : "\(n)",
                                    caption: n == 0 ? "menace détectée" : "menace(s) ou élément(s) suspect(s)") { go(.malware) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if cardsShown > 2 {
                        SummaryCard(module: .startup, value: "\(startup.enabledCount)",
                                    caption: "éléments lancés automatiquement") { go(.startup) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 900)

                HStack(spacing: 12) {
                    Button("Nouvelle analyse") { run() }.controlSize(.large)
                    if !cleanedOnce {
                        Button { clean() } label: {
                            Label("Nettoyer et protéger", systemImage: "sparkles").font(.headline).frame(width: 220, height: 26)
                        }
                        .buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
                        .disabled(junk.selectedTotal == 0 && malware.selectedCount == 0)
                    }
                }
                .opacity(cardsShown > 2 ? 1 : 0)
            }

            if phase == .idle {
                SystemStrip(monitor: monitor).transition(.opacity)
            }

            Spacer(minLength: 10)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: phase)
    }

    // MARK: Orb content

    @ViewBuilder var orbContent: some View {
        switch phase {
        case .idle:
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 40, weight: .semibold))
                    .symbolEffect(.pulse)
                Text("Analyser").font(.title2.bold())
            }
        case .scanning:
            VStack(spacing: 2) {
                CountingBytes(value: Double(junk.foundBytes)).animation(.easeOut(duration: 0.6), value: junk.foundBytes)
                Text("à libérer").font(.callout).opacity(0.85)
            }
        case .cleaning:
            VStack(spacing: 2) {
                CountingBytes(value: Double(junk.foundBytes)).animation(.easeOut(duration: 0.5), value: junk.foundBytes)
                Text("nettoyés").font(.callout).opacity(0.85)
            }
        case .done:
            VStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 42, weight: .heavy))
                    .transition(.scale.combined(with: .opacity))
                CountingBytes(value: Double(cleanedOnce ? freed : junk.selectedTotal), font: .title3.bold())
                    .animation(.easeOut(duration: 1.2), value: cleanedOnce ? freed : junk.selectedTotal)
            }
        }
    }

    var headline: String {
        switch phase {
        case .idle: "Prêt pour une analyse intelligente"
        case .scanning: "Analyse de ton Mac…"
        case .cleaning: "Nettoyage et protection…"
        case .done: cleanedOnce ? "Ton Mac est tout propre ✨" : "Analyse terminée"
        }
    }

    var tickerText: String {
        if phase == .cleaning { return junk.currentPath }
        if steps[0] != .done { return junk.currentPath }
        if steps[1] != .done { return malware.progress }
        return "Éléments de démarrage…"
    }

    // MARK: Actions

    func run() {
        cleanedOnce = false
        resultLine = nil
        cardsShown = 0
        steps = [0: .running, 1: .running, 2: .running]
        withAnimation { phase = .scanning }
        Task { @MainActor in
            await withTaskGroup(of: Int.self) { g in
                g.addTask { await junk.scan(); return 0 }
                g.addTask { await malware.scan(); return 1 }
                g.addTask { await startup.load(); return 2 }
                for await i in g {
                    withAnimation(.spring) { steps[i] = .done }
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation { phase = .done }
            revealCards()
        }
    }

    func clean() {
        withAnimation { phase = .cleaning }
        Task { @MainActor in
            let before = monitor.diskFree
            await junk.clean()
            if malware.selectedCount > 0 { await malware.removeSelected() }
            monitor.refresh()
            freed = max(junk.lastFreed, monitor.diskFree - before)
            cleanedOnce = true
            resultLine = junk.lastResult
            cardsShown = 0
            withAnimation { phase = .done }
            revealCards()
        }
    }

    func revealCards() {
        for i in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.18) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { cardsShown = i }
            }
        }
    }
}

struct SystemStrip: View {
    @ObservedObject var monitor: MonitorModel
    var body: some View {
        HStack(spacing: 14) {
            pill("internaldrive", "\(Fmt.bytes(monitor.diskFree)) libres", monitor.diskUsedFraction, .purple)
            pill("memorychip", "RAM \(Fmt.percent(monitor.mem.pressure))", monitor.mem.pressure, .blue)
            pill("cpu", "CPU \(Fmt.percent(monitor.cpu))", monitor.cpu, .orange)
            if let b = monitor.battery {
                pill("battery.75", "Batterie \(b.percent) %", Double(b.percent) / 100, .green)
            }
        }
    }

    func pill(_ icon: String, _ text: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Ring(value: v, tint: c, lineWidth: 4).frame(width: 22, height: 22)
            Image(systemName: icon).foregroundStyle(c)
            Text(text).font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .hoverLift()
    }
}

struct SummaryCard: View {
    let module: Module
    let value: String
    let caption: String
    let open: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(module.title, systemImage: module.icon).font(.headline).foregroundStyle(module.tint)
                Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text(caption).font(.callout).foregroundStyle(.secondary)
                Button("Voir le détail", action: open).buttonStyle(.link)
            }
        }
        .hoverLift()
    }
}

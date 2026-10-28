import AppKit
import SwiftUI

// A child process that exits while we write to its stdin must give an error, not end the app.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
// Debug commands (benchmarks, tests) keep the detailed log: they work on test pages, not on the user's data.
if arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { Log.forceDetail = true }
// Commands that drive the real mouse and keyboard: Esc on the keyboard stops them at once.
if TestKillSwitch.needed(for: arguments) { TestKillSwitch.install() }

func argument(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

if arguments.contains("--selftest") {
    Task { @MainActor in
        let ok = await DebugCLI.selfTest()
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if arguments.contains("--agent-bench") {
    let path = argument(after: "--agent-bench").flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "Tests/bench/agente.tsv"
    let engine = argument(after: "--engine").flatMap(EngineID.init(rawValue:)) ?? .local
    let only = Set((argument(after: "--only") ?? "").split(separator: ",").map(String.init))
    let server = argument(after: "--model").map { (argument(after: "--server") ?? AppSettings.Defaults.localServerURL, $0) }
    let mode = argument(after: "--local-mode").flatMap(LocalEngine.Mode.init(rawValue:))
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        await DebugCLI.agentBench(path: path, engine: engine, only: only, server: server, mode: mode,
                                  cold: arguments.contains("--cold"), prepare: arguments.contains("--prepare"))
        exit(0)
    }
    dispatchMain()
}

if let dir = argument(after: "--hud-shot") {
    // Debug: the floating message in its styles, drawn off screen into PNG files.
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let cases: [(String, HUDModel.Phase, String, String, Bool, Bool)] = [
            ("1-ascolto-compatto", .listening, "Apri la mail di Marco", "", false, true),
            ("2-risposta-compatta", .success, "Questa cartella è un progetto Swift: Sources contiene il codice, Tests le prove, build i file compilati. Le cartelle _bmad e _bmad-output contengono i documenti di progetto.", "", false, true),
            ("3-ti-ascolto-mini", .listening, "Ti ascolto", "", true, true),
            ("4-ascolto-normale", .listening, "Apri la mail di Marco", "✍️ Dettatura · di' «fine» per chiudere", false, false),
        ]
        for (name, phase, title, detail, mini, compact) in cases {
            let model = HUDModel()
            model.phase = phase; model.title = title; model.detail = detail; model.mini = mini; model.compact = compact
            model.alignment = .bottom
            let host = NSHostingView(rootView: HUDView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 660, height: 300)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        print("Immagini in \(dir)")
        exit(0)
    }
}

if arguments.contains("--hands-test") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        let ok = await DebugCLI.handsTest()
        print(ok ? "Tutto ok." : "Prova fallita.")
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if arguments.contains("--bench-cleanup") {
    // Debug: closes the Bench pages left open in Safari.
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        await DebugCLI.closeBenchPages(Executor())
        exit(0)
    }
    dispatchMain()
}

if let text = argument(after: "--clean") {
    // Debug: dictation cleanup with Apple's model (FR-33).
    Task { @MainActor in
        let started = Date()
        let out = await LocalText.cleanDictation(text, timeout: .seconds(5))
        print(String(format: "%.2fs → %@", Date().timeIntervalSince(started), out ?? "(nessuna ripulitura)"))
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--fallback-test") {
    Task { @MainActor in
        let ok = await DebugCLI.fallbackTest()
        print(ok ? "Tutto ok." : "Prova fallita.")
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if arguments.contains("--risk-classifier-test") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        let ok = await DebugCLI.riskClassifierTest(budget: argument(after: "--budget").flatMap(Double.init) ?? 0.9)
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if arguments.contains("--security-coverage") {
    let ok = MainActor.assumeIsolated { DebugCLI.securityCoverage() }
    exit(ok ? 0 : 1)
}

if arguments.contains("--security-suite") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    // A typo («lokal») must not fall back to a cloud engine in silence.
    guard let engine = EngineID(rawValue: argument(after: "--engine") ?? "claude") else {
        print("Motore sconosciuto: \(argument(after: "--engine") ?? ""). Valori: \(EngineID.allCases.map(\.rawValue).joined(separator: ", "))")
        exit(2)
    }
    Task { @MainActor in
        let ok = await DebugCLI.securitySuite(engine: engine, strict: arguments.contains("--strict"), classifier: !arguments.contains("--no-risk-classifier"))
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if arguments.contains("--apple-events-spike") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        await AppleEventsSpike.run(launch: arguments.contains("--avvia"))
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--ocr-debug") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        let t = Date()
        TextReader.shared.warmUp()
        while !TextReader.shared.isWarm, Date().timeIntervalSince(t) < 90 { try? await Task.sleep(for: .milliseconds(200)) }
        print(String(format: "riscaldamento: %@ in %.1f s", TextReader.shared.isWarm ? "finito" : "NON finito", Date().timeIntervalSince(t)))
        if let shot = try? await ScreenCapture.frontWindow(maxSide: 1400, scaleFactor: 2) {
            let r0 = Date()
            let lines = await TextReader.shared.read(shot.image)
            print(String(format: "lettura: %d righe in %.2f s", lines?.count ?? -1, Date().timeIntervalSince(r0)))
        }
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--local-vision-test") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        await DebugCLI.localVisionTest()
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--session-test") {
    // Claude's Long session for real: two messages on one process, the second reads the cache.
    Task { @MainActor in
        let ok = await DebugCLI.sessionTest()
        print(ok ? "Tutto ok." : "Prova fallita.")
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if arguments.contains("--route-test") {
    let path = argument(after: "--route-test").flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "Tests/corpus/instradamento.tsv"
    let rules = arguments.contains("--rules")
    Task { @MainActor in
        let ok = await DebugCLI.routeTest(path: path, rulesOnly: rules)
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if let dir = argument(after: "--settings-shot") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await DebugCLI.settingsShot(dir: dir)
            exit(0)
        }
        app.run()
    }
}

if let page = argument(after: "--converse-test") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        await DebugCLI.converseTest(page: page)
        exit(0)
    }
    dispatchMain()
}

if let page = argument(after: "--tools-test") {
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        await DebugCLI.toolsTest(page: page)
        exit(0)
    }
    dispatchMain()
}

if let path = argument(after: "--transcribe") {
    Task { @MainActor in
        await DebugCLI.transcribe(path)
        exit(0)
    }
    dispatchMain()
}

if let path = argument(after: "--ptt-restart-test") {
    // Debug: push-to-talk right after the microphone restarted, without and with the fix.
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        for clear in [false, true] {
            let engine = SpeechEngine()
            do {
                let text = try await engine.debugRestartTest(URL(fileURLWithPath: path), clear: clear)
                print("\(clear ? "con correzione" : "senza correzione"): «\(text)»")
            } catch { print("Errore: \(error.localizedDescription)") }
        }
        exit(0)
    }
    dispatchMain()
}

if let path = argument(after: "--listen-file") {
    // Debug: an audio file through the whole listening chain of the app (detector + recognizer),
    // in real time: which sentences come out and when.
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        let engine = SpeechEngine()
        let t0 = Date()
        engine.onUtterance = { text in print(String(format: "%6.2fs  frase: «%@»", Date().timeIntervalSince(t0), text)) }
        do { try await engine.feedFile(URL(fileURLWithPath: path)) } catch { print("Errore: \(error.localizedDescription)") }
        try? await Task.sleep(for: .seconds(3))
        exit(0)
    }
    dispatchMain()
}

if let path = argument(after: "--vad-test") {
    MainActor.assumeIsolated { DebugCLI.vadTest(path) }
    exit(0)
}

if let path = argument(after: "--stream-test") {
    Task { @MainActor in
        await DebugCLI.streamTest(path)
        exit(0)
    }
    dispatchMain()
}

if let seconds = argument(after: "--mic-test") {
    Task { @MainActor in
        await DebugCLI.micTest(Double(seconds) ?? 10)
        exit(0)
    }
    dispatchMain()
}

if let seconds = argument(after: "--wake-test") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hud = HUDController()
        let coordinator = Coordinator(hud: hud, settings: AppSettings.shared)
        coordinator.dryRun = true
        coordinator.onDryRun = { print($0) }
        Task { @MainActor in
            await coordinator.prepare()
            coordinator.setMode(.wakeWord)
            print("Ascolto continuo attivo per \(seconds) s")
            try? await Task.sleep(for: .seconds(Double(seconds) ?? 20))
            exit(0)
        }
        withExtendedLifetime(coordinator) { app.run() }
    }
}

if let request = argument(after: "--agent-test") {
    Task { @MainActor in
        let agent = AgentRunner(executor: Executor(), settings: AppSettings.shared)
        if let e = argument(after: "--engine").flatMap(EngineID.init(rawValue:)) { agent.forcedEngine = e }
        let deep = arguments.contains("--deep")
        agent.tools.onProgress = { print("  · \($0)") }
        agent.tools.askUser = { q, _ in print("  ? \(q) → (test: nessuna risposta)"); return nil }
        do {
            try await agent.start()
            agent.prewarm()
            try await Task.sleep(for: .seconds(4))
            let started = Date()
            agent.refreshAvailability()
            try await Task.sleep(for: .seconds(1))
            let answer = try await agent.run(request, context: ScreenContext.capture(includeLabels: false), deep: deep)
            print(String(format: "Risposta (%@/%@, %.1fs, %d chiamate, %d con effetti): %@", agent.lastEngine?.rawValue ?? "?", agent.lastModel,
                         Date().timeIntervalSince(started), agent.tools.callCount, agent.tools.effectfulCalls, answer))
        } catch {
            print("Errore: \(error.localizedDescription)")
        }
        agent.shutdown()
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--mcp-serve") {
    // Debug: only the agent tool server, to try other MCP clients (e.g. `codex exec`) by hand.
    // Prints the URL and the token, then serves until killed.
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        let tools = AgentTools(executor: Executor())
        tools.onProgress = { print("  · \($0)") }
        tools.askUser = { q, _ in print("  ? \(q) → (test: nessuna risposta)"); return nil }
        let server = MCPServer(tools: AgentTools.definitions) { name, args in
            await tools.call(name, args)
        }
        do {
            try await server.start()
            print("URL=\(server.url)")
            print("TOKEN=\(server.token)")
            fflush(stdout)
        } catch {
            print("Errore: \(error.localizedDescription)")
            exit(1)
        }
        withExtendedLifetime(server) {}
        while true { try? await Task.sleep(for: .seconds(3600)); _ = server }
    }
    dispatchMain()
}

if arguments.contains("--observe-stats") {
    // Debug: how much of the frontmost window the agent can see (no content printed).
    Task { @MainActor in
        AX.debugTargetBundle = argument(after: "--observe-stats").flatMap { $0.hasPrefix("-") ? nil : $0 }
        let tools = AgentTools(executor: Executor())
        let customQuery = ProcessInfo.processInfo.environment["MTA_QUERY"]
        for query in (customQuery.map { [$0] } ?? [nil, "a"]) as [String?] {
            let started = Date()
            let r = await tools.call("observe", query.map { ["query": $0] } ?? [:])
            let text = (r.content.first?["text"] as? String) ?? ""
            if ProcessInfo.processInfo.environment["MTA_DUMP"] != nil { print(text) }
            let items = text.split(separator: "\n").filter { $0.hasPrefix("[") }
            var roles: [String: Int] = [:]
            for line in items {
                let role = line.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                roles[role, default: 0] += 1
            }
            print(String(format: "observe%@: %d elementi in %.2fs, cliccabili %d", query == nil ? "" : "(query)",
                         items.count, Date().timeIntervalSince(started), items.filter { $0.contains("]*") }.count))
            print("  ruoli: \(roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
            print("  " + (text.split(separator: "\n").last.map(String.init) ?? ""))
        }
        exit(0)
    }
    dispatchMain()
}

if let name = argument(after: "--activate-test") {
    // Debug: only brings an app to the front (no typing, no clicks), then goes back.
    Task { @MainActor in
        let before = AX.frontmostApplication()
        let ex = Executor()
        let started = Date()
        let opened = (try? await ex.openApp(name)) ?? "?"
        let now = AX.frontmostApplication()?.localizedName ?? "?"
        print(String(format: "Richiesto %@ → in primo piano: %@ (%.1fs)", opened, now, Date().timeIntervalSince(started)))
        if let before { await ex.bringToFront(before) }
        print("Tornato a: \(AX.frontmostApplication()?.localizedName ?? "?")")
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--phase3-test") {
    // Debug: memory/macro round-trip (temporary macro, removed at the end), profiles, numbers.
    Task { @MainActor in
        let mem = Memory.shared
        mem.saveMacro(name: "prova selftest", steps: ["apri Safari", "giù"])
        let m = mem.macro(for: "Esegui la macro prova selftest")
        print("macro salvata e trovata: \(m?.steps == ["apri Safari", "giù"])")
        print("macro per nome diretto: \(mem.macro(for: "Prova selftest.") != nil)")
        print("macro eliminata: \(mem.deleteMacro("prova selftest"))")
        print("file memoria: \(mem.fileURL.path)")
        for b in ["Microsoft Edge", "Google Chrome", "Brave"] {
            Log.info("TEST profili \(b): \(BrowserProfiles.list(browser: b).count)")
        }
        AX.debugTargetBundle = "com.microsoft.edgemac"
        let overlay = NumberOverlay()
        let started = Date()
        let n = overlay.show(timeout: 1)
        overlay.hide()
        print(String(format: "numeri su Edge: %d (%.2fs)", n, Date().timeIntervalSince(started)))
        exit(0)
    }
    dispatchMain()
}

if let out = argument(after: "--shot-test") {
    // Debug: numbered screenshot of a given app's window (env MTA_TARGET), saved to a file.
    MainActor.assumeIsolated { _ = NSApplication.shared }
    Task { @MainActor in
        AX.debugTargetBundle = ProcessInfo.processInfo.environment["MTA_TARGET"] ?? "com.apple.calculator"
        let tools = AgentTools(executor: Executor())
        let r = await tools.call("screenshot", [:])
        if let b64 = r.content.first?["data"] as? String, let data = Data(base64Encoded: b64) {
            try? data.write(to: URL(fileURLWithPath: out))
            Log.info("TEST screenshot salvato: \(out) (\(data.count) byte)")
        }
        Log.info("TEST screenshot nota: \((r.content.last?["text"] as? String)?.prefix(300) ?? "-")")
        exit(0)
    }
    dispatchMain()
}

if let utterance = argument(after: "--plan") {
    Task { @MainActor in
        await DebugCLI.plan(utterance)
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--context") {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        print(ScreenContext.capture(includeLabels: true).promptDescription)
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

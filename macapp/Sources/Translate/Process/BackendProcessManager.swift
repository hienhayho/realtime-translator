import Foundation

/// Spawns and supervises the two subprocesses this app depends on: the
/// Python backend (`uv run uvicorn app.main:app ...`) and llama-server
/// (translation model). Neither is launched by the other — see BACKEND.md
/// "Model Setup". Replaces the old "assume both are already running in a
/// terminal" assumption with active process ownership: launch, poll
/// `/health` until ready, detect crashes, clean up on quit.
@MainActor
@Observable
final class BackendProcessManager {
    private(set) var pythonStatus: ProcessStatus = .notStarted
    private(set) var llamaStatus: ProcessStatus = .notStarted

    /// Both subprocesses have reported healthy at least once. Gates the
    /// "Listen" button / initial WS connect attempt in the UI, replacing
    /// today's optimistic "assume backend already running" behavior.
    var isReady: Bool {
        pythonStatus == .healthy && llamaStatus == .healthy
    }

    private let backendDir: URL
    private var pythonProcess: Process?
    private var llamaProcess: Process?
    private var pythonIntentionalStop = false
    private var llamaIntentionalStop = false

    private let pythonPort = 8000
    private let llamaPort = 8081

    /// The repo's `backend/` directory. Installed app: fixed
    /// `~/.translate-app/backend`, matching install.sh's clone target — see
    /// PLAN.md step 0/6. Dev builds run from this checkout instead, so fall
    /// back to a `#filePath`-relative path when `~/.translate-app` doesn't
    /// exist, avoiding a hard dependency on install.sh having been run.
    static func resolveBackendDir() -> URL {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".translate-app/backend")
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }
        // .../macapp/Sources/Translate/Process/BackendProcessManager.swift -> repo root/backend
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // Process/
            .deletingLastPathComponent() // Translate/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // macapp/
            .deletingLastPathComponent() // repo root/
            .appendingPathComponent("backend")
    }

    /// backendDir: the repo's `backend/` directory — see resolveBackendDir().
    init(backendDir: URL) {
        self.backendDir = backendDir
    }

    // MARK: - Launch

    func start(whisperTier: ModelSelection.WhisperTier, translationModel: ModelSelection.TranslationModel) {
        startLlama(model: translationModel)
        startPython(tier: whisperTier)
    }

    private func startPython(tier: ModelSelection.WhisperTier) {
        guard let uvPath = Self.resolveExecutable(
            "uv",
            knownPaths: ["\(NSHomeDirectory())/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        ) else {
            pythonStatus = .crashed("uv not found — install: https://docs.astral.sh/uv/")
            return
        }

        let process = Process()
        process.executableURL = uvPath
        process.arguments = ["run", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", String(pythonPort)]
        process.currentDirectoryURL = backendDir

        var env = ProcessInfo.processInfo.environment
        env["WHISPER_TIER"] = tier.rawValue
        process.environment = env

        attachLogging(process, name: "backend")

        pythonIntentionalStop = false
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(process: proc, wasIntentional: self?.pythonIntentionalStop ?? false, isPython: true)
            }
        }

        do {
            try process.run()
            pythonProcess = process
            pythonStatus = .starting
            pollHealth(port: pythonPort, isPython: true)
        } catch {
            pythonStatus = .crashed("Failed to launch backend: \(error.localizedDescription)")
        }
    }

    private func startLlama(model: ModelSelection.TranslationModel) {
        guard let llamaPath = Self.resolveExecutable(
            "llama-server",
            knownPaths: ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        ) else {
            llamaStatus = .crashed("llama-server not found — install via 'brew install llama.cpp'")
            return
        }

        let process = Process()
        process.executableURL = llamaPath
        process.arguments = [
            "-hf", model.rawValue,
            "--no-mmproj", "--port", String(llamaPort),
            "--chat-template-kwargs", "{\"enable_thinking\":false}",
            "--slot-prompt-similarity", "1.0",
            "--no-cache-prompt",
            "--ctx-size", "2048",
        ]

        var env = ProcessInfo.processInfo.environment
        env["LLAMA_CACHE"] = backendDir.appendingPathComponent("models/llm").path
        process.environment = env

        attachLogging(process, name: "llama-server")

        llamaIntentionalStop = false
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(process: proc, wasIntentional: self?.llamaIntentionalStop ?? false, isPython: false)
            }
        }

        do {
            try process.run()
            llamaProcess = process
            llamaStatus = .starting
            pollHealth(port: llamaPort, isPython: false)
        } catch {
            llamaStatus = .crashed("Failed to launch llama-server: \(error.localizedDescription)")
        }
    }

    // MARK: - Restart (model switch)

    /// Restarts the Python backend with a new Whisper tier, waiting until
    /// it's healthy again (or has crashed) before returning — so a caller
    /// (e.g. ModelsView) can sequence a WS reconnect afterward via
    /// SessionCoordinator's planned-relaunch path. llama-server is
    /// untouched, matching the confirmed asymmetric switch design.
    func restartPython(withTier tier: ModelSelection.WhisperTier) async {
        pythonIntentionalStop = true
        pythonProcess?.terminate()
        pythonProcess = nil
        startPython(tier: tier)
        await waitUntilSettled(isPython: true)
    }

    /// Same as restartPython, but for llama-server / translation model.
    /// Python backend is untouched.
    func restartLlama(withModel model: ModelSelection.TranslationModel) async {
        llamaIntentionalStop = true
        llamaProcess?.terminate()
        llamaProcess = nil
        startLlama(model: model)
        await waitUntilSettled(isPython: false)
    }

    /// Polls this manager's own published status until it leaves the
    /// starting/downloadingModel transient states (i.e. reaches .healthy or
    /// .crashed) — lets an async restart caller know when it's safe to
    /// proceed instead of guessing a fixed delay.
    private func waitUntilSettled(isPython: Bool) async {
        while true {
            let status = isPython ? pythonStatus : llamaStatus
            switch status {
            case .healthy, .crashed:
                return
            default:
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Readiness polling

    /// No short timeout — first launch (or a switch to a never-used model)
    /// can incur a real multi-GB download via llama-server's/huggingface_hub's
    /// own `-hf`/snapshot_download machinery, neither of which exposes
    /// structured progress over HTTP. `.starting` -> `.downloadingModel` is
    /// inferred purely from elapsed time; the only real failure signal is
    /// the process exiting on its own (handled by terminationHandler).
    private func pollHealth(port: Int, isPython: Bool) {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let startedAt = Date()

        Task {
            while true {
                guard !Task.isCancelled else { return }

                if let (_, response) = try? await URLSession.shared.data(from: url),
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run {
                        if isPython { self.pythonStatus = .healthy } else { self.llamaStatus = .healthy }
                    }
                    return
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                await MainActor.run {
                    let stillStarting = isPython ? self.pythonStatus == .starting : self.llamaStatus == .starting
                    guard stillStarting || (isPython ? self.pythonStatus == .downloadingModel : self.llamaStatus == .downloadingModel) else {
                        return // process may have crashed/stopped since — don't clobber that state
                    }
                    let next: ProcessStatus = elapsed > 5 ? .downloadingModel : .starting
                    if isPython { self.pythonStatus = next } else { self.llamaStatus = next }
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Termination handling

    private func handleTermination(process: Process, wasIntentional: Bool, isPython: Bool) {
        let status: ProcessStatus = wasIntentional
            ? .stopped
            : .crashed("\(isPython ? "Backend" : "llama-server") exited unexpectedly (code \(process.terminationStatus))")
        if isPython {
            pythonStatus = status
            pythonProcess = nil
        } else {
            llamaStatus = status
            llamaProcess = nil
        }
    }

    // MARK: - Shutdown

    /// Called on app quit (see AppDelegate). SIGTERM both, give them a
    /// moment to exit gracefully, SIGKILL anything still alive so quitting
    /// never leaves an orphaned llama-server/uvicorn eating RAM/VRAM.
    func stopAll() {
        pythonIntentionalStop = true
        llamaIntentionalStop = true

        let pids = [pythonProcess?.processIdentifier, llamaProcess?.processIdentifier].compactMap { $0 }
        pythonProcess?.terminate()
        llamaProcess?.terminate()

        Thread.sleep(forTimeInterval: 2.0)

        for pid in pids {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/kill")
            check.arguments = ["-9", String(pid)]
            try? check.run()
            check.waitUntilExit()
        }

        pythonProcess = nil
        llamaProcess = nil
        pythonStatus = .stopped
        llamaStatus = .stopped
    }

    // MARK: - Path resolution

    /// GUI apps on macOS don't inherit the interactive shell's PATH, so
    /// `uv`/`llama-server` aren't reliably found via plain `Process` PATH
    /// lookup. Check known install locations first, fall back to a login
    /// shell's `command -v` (which DOES source rc files) as a last resort.
    private static func resolveExecutable(_ name: String, knownPaths: [String]) -> URL? {
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = Pipe()

        guard (try? probe.run()) != nil else { return nil }
        probe.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Log capture

    private func attachLogging(_ process: Process, name: String) {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Translate")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("\(name).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        process.standardOutput = handle
        process.standardError = handle
    }
}

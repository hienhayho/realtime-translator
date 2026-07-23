import Foundation

/// Wires an AudioSource (mic or video file) -> BackendClient -> SessionStore.
/// Owns the listen/stop lifecycle triggered from the UI.
///
/// Reconnect has two distinct paths, since they have different readiness
/// signals available:
/// - Unexpected drop (crash, network blip): exponential backoff, blind
///   retry — no signal for when the backend will be back.
/// - Planned relaunch (model switch, see BackendProcessManager): exact
///   readiness is known (the new process's /health going green), so this
///   reconnects once, deterministically, no backoff guessing needed.
@MainActor
final class SessionCoordinator {
    private let store: SessionStore
    private let client: BackendClient
    private let host: String
    private let port: Int

    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var activeSource: AudioSource?
    private var reconnectTask: Task<Void, Never>?

    /// Set by stop()/a planned relaunch just before tearing down the
    /// connection, so the receive loop's termination can tell "we did this
    /// on purpose" apart from "the connection dropped out from under us".
    private var isIntentionalDisconnect = false

    private let maxReconnectAttempts = 6

    init(store: SessionStore, host: String, port: Int) {
        self.store = store
        self.host = host
        self.port = port
        self.client = BackendClient(host: host, port: port)
    }

    func start(source: AudioSource) async {
        guard !store.isListening else { return }
        reconnectTask?.cancel()

        store.connectionState = .connecting
        let messages = client.connect()
        store.connectionState = .connected

        receiveTask = Task {
            for await message in messages {
                store.apply(message)
            }
            self.handleDisconnect()
        }

        do {
            let audioStream = try source.start()
            activeSource = source
            sendTask = Task {
                for await chunk in audioStream {
                    await client.sendAudio(chunk)
                }
            }
        } catch {
            store.apply(.error(message: "Audio source failed: \(error.localizedDescription)"))
            store.connectionState = .failed(error.localizedDescription)
            return
        }

        await client.sendControl(.start)
        store.isListening = true
    }

    func stop() async {
        guard store.isListening else { return }
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        await client.sendControl(.stop)
        teardown()
        activeSource = nil // explicit user stop — no reconnect will ever resume this source
        store.connectionState = .disconnected
    }

    /// Clears displayed results (keeps any active video playing). If a
    /// session is active, also tells the backend to reset its rolling
    /// translation context so future translations aren't influenced by
    /// cleared segments.
    func clear() async {
        if store.isListening {
            await client.sendControl(.reset)
        }
        store.clearResults()
    }

    // MARK: - Planned relaunch (model switch)

    /// Called by whatever drives a model switch once it's about to kill the
    /// backend process — disconnects cleanly first so the receive loop's
    /// termination isn't mistaken for an unexpected drop.
    func disconnectForPlannedRelaunch() {
        guard store.isListening || store.connectionState == .connected else { return }
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        teardown()
        store.connectionState = .connecting
    }

    /// Called once the relaunched process's /health is confirmed green —
    /// reconnects deterministically, no backoff needed since readiness is
    /// already known.
    func reconnectAfterPlannedRelaunch() async {
        guard let source = activeSource else {
            // No source was active (e.g. switched models before ever
            // pressing Listen) — nothing to reconnect, just clear the
            // "connecting" state a caller may have set.
            store.connectionState = .disconnected
            return
        }
        await start(source: source)
    }

    // MARK: - Unexpected drop

    private func handleDisconnect() {
        let wasIntentional = isIntentionalDisconnect
        isIntentionalDisconnect = false
        teardown()

        if wasIntentional {
            store.connectionState = .disconnected
            return
        }

        store.connectionState = .connecting
        reconnectTask = Task {
            await attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        var delayMs: UInt64 = 500
        for _ in 1...maxReconnectAttempts {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }

            if await probeHealthy() {
                if let source = activeSource {
                    await start(source: source)
                } else {
                    store.connectionState = .disconnected
                }
                return
            }
            delayMs = min(delayMs * 2, 5000)
        }
        store.connectionState = .failed("Lost connection to backend — gave up reconnecting")
    }

    private func probeHealthy() async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/health") else { return false }
        guard let (_, response) = try? await URLSession.shared.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func teardown() {
        activeSourceStop()
        sendTask?.cancel()
        receiveTask?.cancel()
        client.disconnect()
        store.isListening = false
    }

    private func activeSourceStop() {
        activeSource?.stop()
        // Keep activeSource itself around (not nilled) so a reconnect can
        // resume the same source without the caller re-picking a file/mic.
    }
}

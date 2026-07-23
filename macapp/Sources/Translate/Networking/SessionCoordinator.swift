import Foundation

/// Wires an AudioSource (mic or video file) -> BackendClient -> SessionStore.
/// Owns the listen/stop lifecycle triggered from the UI.
@MainActor
final class SessionCoordinator {
    private let store: SessionStore
    private let client: BackendClient

    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var activeSource: AudioSource?

    init(store: SessionStore, host: String, port: Int) {
        self.store = store
        self.client = BackendClient(host: host, port: port)
    }

    func start(source: AudioSource) async {
        guard !store.isListening else { return }

        store.connectionState = .connecting
        let messages = client.connect()
        store.connectionState = .connected

        receiveTask = Task {
            for await message in messages {
                store.apply(message)
            }
            store.connectionState = .disconnected
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
        await client.sendControl(.stop)
        activeSource?.stop()
        activeSource = nil
        sendTask?.cancel()
        receiveTask?.cancel()
        client.disconnect()
        store.isListening = false
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
}

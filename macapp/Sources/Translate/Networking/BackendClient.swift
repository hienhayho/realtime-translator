import Foundation

/// WS client to the local Python backend. See BACKEND.md for wire format:
/// binary frames = raw PCM16 mono @16kHz, JSON text frames = control/server messages.
final class BackendClient: NSObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let url: URL

    init(host: String, port: Int) {
        self.url = URL(string: "ws://\(host):\(port)/ws")!
        super.init()
    }

    func connect() -> AsyncStream<ServerMessage> {
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        return AsyncStream { continuation in
            Task {
                await self.receiveLoop(continuation: continuation)
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    func sendAudio(_ data: Data) async {
        try? await task?.send(.data(data))
    }

    func sendControl(_ action: ControlAction) async {
        guard let payload = try? JSONEncoder().encode(ControlMessage(action)),
              let text = String(data: payload, encoding: .utf8)
        else { return }
        try? await task?.send(.string(text))
    }

    private func receiveLoop(continuation: AsyncStream<ServerMessage>.Continuation) async {
        guard let task else {
            continuation.finish()
            return
        }

        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    if let decoded = try? ServerMessage.decode(from: data) {
                        continuation.yield(decoded)
                    }
                case .string(let text):
                    if let data = text.data(using: .utf8), let decoded = try? ServerMessage.decode(from: data) {
                        continuation.yield(decoded)
                    }
                @unknown default:
                    break
                }
            } catch {
                continuation.yield(.error(message: error.localizedDescription))
                continuation.finish()
                return
            }
        }
    }
}

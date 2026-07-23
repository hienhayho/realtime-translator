import Foundation
import Observation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@Observable
final class SessionStore {
    var segments: [Segment] = []
    var connectionState: ConnectionState = .disconnected
    var isListening: Bool = false
    var lastError: String?
    var activeVideoURL: URL?

    /// Segments awaiting translation — drives VideoPlayerView's auto-pause,
    /// see UI.md "Backlog-Aware Auto-Pause".
    var pendingTranslationCount: Int {
        segments.filter { $0.translatedText == nil }.count
    }

    func apply(_ message: ServerMessage) {
        switch message {
        case .asrFinal(let text, let sourceLanguage, let segmentId):
            segments.append(Segment(id: segmentId, sourceLanguage: sourceLanguage, sourceText: text, translatedText: nil))

        case .translationUpdate(let text, _, _, let segmentId):
            guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
            segments[index].translatedText = text

        case .error(let message):
            lastError = message
        }
    }

    /// Clears displayed transcript/translation only — keeps an active video
    /// playing (used by the "Clear" button, distinct from a full session
    /// teardown).
    func clearResults() {
        segments.removeAll()
        lastError = nil
    }

    func reset() {
        clearResults()
        activeVideoURL = nil
    }
}

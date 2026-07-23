// Mirrors backend/app/ws/protocol.py — keep in sync with that file.
import Foundation

enum ServerMessage {
    case asrFinal(text: String, sourceLanguage: SourceLanguage, segmentId: Int)
    case translationUpdate(text: String, sourceLanguage: SourceLanguage, isFinal: Bool, segmentId: Int)
    case error(message: String)
}

enum ServerMessageDecodeError: Error {
    case unknownType(String)
    case malformed
}

extension ServerMessage {
    static func decode(from data: Data) throws -> ServerMessage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            throw ServerMessageDecodeError.malformed
        }

        switch type {
        case "asr_final":
            guard let text = json["text"] as? String,
                  let sourceLanguageRaw = json["source_language"] as? String,
                  let sourceLanguage = SourceLanguage(rawValue: sourceLanguageRaw),
                  let segmentId = json["segment_id"] as? Int
            else {
                throw ServerMessageDecodeError.malformed
            }
            return .asrFinal(text: text, sourceLanguage: sourceLanguage, segmentId: segmentId)

        case "translation_update":
            guard let text = json["text"] as? String,
                  let sourceLanguageRaw = json["source_language"] as? String,
                  let sourceLanguage = SourceLanguage(rawValue: sourceLanguageRaw),
                  let isFinal = json["is_final"] as? Bool,
                  let segmentId = json["segment_id"] as? Int
            else {
                throw ServerMessageDecodeError.malformed
            }
            return .translationUpdate(text: text, sourceLanguage: sourceLanguage, isFinal: isFinal, segmentId: segmentId)

        case "error":
            guard let message = json["message"] as? String else {
                throw ServerMessageDecodeError.malformed
            }
            return .error(message: message)

        default:
            throw ServerMessageDecodeError.unknownType(type)
        }
    }
}

enum ControlAction: String {
    case start, stop, reset
}

struct ControlMessage: Encodable {
    let type = "control"
    let action: String

    init(_ action: ControlAction) {
        self.action = action.rawValue
    }
}

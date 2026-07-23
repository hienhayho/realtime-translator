import Foundation

enum SourceLanguage: String {
    case vi, en

    var label: String {
        switch self {
        case .vi: return "Vietnamese"
        case .en: return "English"
        }
    }

    var opposite: SourceLanguage {
        switch self {
        case .vi: return .en
        case .en: return .vi
        }
    }
}

struct Segment: Identifiable, Equatable {
    let id: Int
    var sourceLanguage: SourceLanguage
    var sourceText: String
    var translatedText: String?
}

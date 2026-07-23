import Foundation

/// Persisted user choice of which STT/translation models to run. Vietnamese
/// (Gipformer) is intentionally absent — never user-configurable, see
/// BACKEND.md "Bilingual Transcription".
@Observable
final class ModelSelection {
    enum WhisperTier: String, CaseIterable, Identifiable {
        case tinyEn = "tiny.en"
        case baseEn = "base.en"
        case mediumEn = "medium.en"

        var id: String { rawValue }
        var label: String { rawValue }
    }

    enum TranslationModel: String, CaseIterable, Identifiable {
        case qwen4B = "unsloth/Qwen3.5-4B-GGUF:UD-Q4_K_XL"
        case qwen9B = "unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .qwen4B: return "Qwen3.5 4B"
            case .qwen9B: return "Qwen3.5 9B"
            }
        }
    }

    var whisperTier: WhisperTier {
        didSet {
            UserDefaults.standard.set(whisperTier.rawValue, forKey: Self.whisperTierKey)
        }
    }

    var translationModel: TranslationModel {
        didSet {
            UserDefaults.standard.set(translationModel.rawValue, forKey: Self.translationModelKey)
        }
    }

    private static let whisperTierKey = "modelSelection.whisperTier"
    private static let translationModelKey = "modelSelection.translationModel"

    init() {
        let storedTier = UserDefaults.standard.string(forKey: Self.whisperTierKey)
        whisperTier = storedTier.flatMap(WhisperTier.init(rawValue:)) ?? .tinyEn

        let storedModel = UserDefaults.standard.string(forKey: Self.translationModelKey)
        translationModel = storedModel.flatMap(TranslationModel.init(rawValue:)) ?? .qwen4B
    }
}

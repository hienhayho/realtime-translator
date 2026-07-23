import Foundation

/// Lifecycle state of one supervised subprocess (Python backend or
/// llama-server), as tracked by BackendProcessManager.
enum ProcessStatus: Equatable {
    case notStarted
    case starting
    /// Distinct from `.starting` — inferred when `/health` hasn't responded
    /// within a few seconds of launch, since a never-before-used model
    /// (Whisper tier or LLM variant) downloads on first use and that wait
    /// can be multi-minute. See BACKEND.md "Bilingual Transcription" /
    /// macapp README for the fully-lazy download design.
    case downloadingModel
    case healthy
    case crashed(String)
    case stopped
}

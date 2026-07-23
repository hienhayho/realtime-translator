import Foundation

/// Common interface for anything that can feed the translation pipeline —
/// live mic capture or a decoded video/audio file. Both yield PCM16 mono
/// @16kHz chunks (backend's expected format, see backend/app/config.py).
protocol AudioSource {
    func start() throws -> AsyncStream<Data>
    func stop()
}

extension AudioCaptureEngine: AudioSource {}
extension VideoFileAudioSource: AudioSource {}

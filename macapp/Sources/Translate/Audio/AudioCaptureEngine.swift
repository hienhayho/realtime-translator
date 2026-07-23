import AVFoundation

/// Taps the mic, converts to mono 16-bit PCM @16kHz (backend's expected format,
/// see backend/app/config.py SAMPLE_RATE), and yields raw frame bytes.
final class AudioCaptureEngine {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Data>.Continuation?

    func start() throws -> AsyncStream<Data> {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

        let stream = AsyncStream<Data> { continuation in
            self.continuation = continuation

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                guard let self, let data = self.convert(buffer) else { return }
                continuation.yield(data)
            }
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }

        let outputCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * Self.targetFormat.sampleRate / buffer.format.sampleRate
        ) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, let channelData = outputBuffer.int16ChannelData else { return nil }
        let frameCount = Int(outputBuffer.frameLength)
        return Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)
    }

    enum CaptureError: Error {
        case converterCreationFailed
    }
}

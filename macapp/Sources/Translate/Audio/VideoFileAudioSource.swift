import AVFoundation

/// Decodes a video/audio file's audio track and yields PCM16 mono @16kHz
/// chunks, paced to match real playback speed (so backend VAD segments it
/// the same way it would a live mic feed — see UI.md "Video File Input").
final class VideoFileAudioSource {
    private let url: URL
    private var reader: AVAssetReader?
    private var continuation: AsyncStream<Data>.Continuation?
    private var isCancelled = false

    init(url: URL) {
        self.url = url
    }

    func start() throws -> AsyncStream<Data> {
        let asset = AVURLAsset(url: url)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCaptureEngine.targetFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let semaphore = DispatchSemaphore(value: 0)
        var loadedTrack: AVAssetTrack?
        var loadError: Error?
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                loadedTrack = tracks.first
            } catch {
                loadError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let loadError { throw loadError }
        guard let track = loadedTrack else { throw FileSourceError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileSourceError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else { throw FileSourceError.readerSetupFailed }
        self.reader = reader
        isCancelled = false

        let sampleRate = AudioCaptureEngine.targetFormat.sampleRate
        let stream = AsyncStream<Data> { continuation in
            self.continuation = continuation

            Task.detached { [weak self] in
                while let self, !self.isCancelled, reader.status == .reading {
                    guard let sampleBuffer = output.copyNextSampleBuffer(),
                          let data = Self.pcmData(from: sampleBuffer)
                    else { break }

                    let frameCount = data.count / MemoryLayout<Int16>.size
                    let chunkDuration = Double(frameCount) / sampleRate
                    continuation.yield(data)
                    try? await Task.sleep(nanoseconds: UInt64(chunkDuration * 1_000_000_000))
                }
                continuation.finish()
            }
        }

        return stream
    }

    func stop() {
        isCancelled = true
        reader?.cancelReading()
        reader = nil
        continuation?.finish()
        continuation = nil
    }

    private static func pcmData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer else { return nil }
        return Data(bytes: dataPointer, count: length)
    }

    enum FileSourceError: Error {
        case noAudioTrack
        case readerSetupFailed
    }
}

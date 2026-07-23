import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    var onToggleMic: () -> Void
    var onChooseFile: () -> Void
    var onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if case .failed(let reason) = store.connectionState {
                statusBanner("Backend not connected: \(reason)")
            } else if store.connectionState == .disconnected {
                statusBanner("Backend not connected — start the service")
            }

            if let videoURL = store.activeVideoURL {
                VideoPlayerView(url: videoURL)
                    .frame(minHeight: 200, idealHeight: 280)

                Divider()
            }

            HStack(spacing: 0) {
                TranscriptColumn(
                    title: "Transcription",
                    segments: store.segments,
                    languageTagForSegment: { $0.sourceLanguage.label },
                    textForSegment: { $0.sourceText }
                )

                Divider()

                TranscriptColumn(
                    title: "Translation",
                    segments: store.segments,
                    languageTagForSegment: { $0.sourceLanguage.opposite.label },
                    textForSegment: { $0.translatedText }
                )
            }
        }
        .frame(minWidth: 640, idealWidth: 880, minHeight: 420, idealHeight: 600)
    }

    private var header: some View {
        HStack {
            Text("VI ⇄ EN")
                .font(.headline)
            Spacer()
            if !store.isListening {
                Button("Choose File…") {
                    onChooseFile()
                }
            }
            Button("Clear") {
                onClear()
            }
            .disabled(store.segments.isEmpty)
            Button(store.isListening ? "Stop" : "Listen") {
                onToggleMic()
            }
        }
        .padding(12)
    }

    private func statusBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
    }
}

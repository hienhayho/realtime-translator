# UI Plan — macOS Client

## Goal

Native SwiftUI app: capture audio (mic, or a video file's audio track), stream to backend over WebSocket, render a bilingual transcript + translation per completed utterance — either speaker language (Vietnamese or English) is detected per segment and translated into the other, see BACKEND.md "Bilingual Transcription".

**Note:** backend ASR (Gipformer + Whisper base.en) runs offline/whole-segment only, no partial transcripts — see BACKEND.md "ASR Mode Decision". Backend emits `asr_final` + `translation_update` (always `is_final: true`, both carrying `source_language`) per VAD-detected utterance, nothing mid-utterance. UI below reflects this: no partial/revision rendering, segments simply appear once done.

## Tech Stack

| Layer | Choice | Why |
|---|---|---|
| UI framework | SwiftUI | Native, fast to build for a standard desktop window |
| Audio capture | AVAudioEngine | Low-latency tap on mic input, native PCM access |
| Networking | `URLSessionWebSocketTask` | Built-in, no extra dep, sufficient for localhost WS |
| Concurrency | Swift Concurrency (async/await, `AsyncStream`) | Clean handling of WS message stream + audio buffer stream |
| App shell | Standard `WindowGroup` | Regular desktop app — Dock icon, resizable window, Cmd+Tab visible (switched from menubar popover per user preference) |
| Min target | macOS 14+ (Sonoma) | Swift Concurrency baseline |

## App Shape

Standard resizable window (`WindowGroup`), title bar, Dock icon — normal macOS app, not menubar-only. Min size 480×360, opens at 640×520.

## Project Structure

Swift Package Manager executable target (no xcodegen/hand-written .xcodeproj — opens directly in Xcode via `open Package.swift`, also buildable via `swift build` from CLI):

```
macapp/
├── Package.swift
├── Sources/
│   └── Translate/
│       ├── TranslateApp.swift          # @main, WindowGroup scene
│       ├── Audio/
│       │   ├── AudioSource.swift         # protocol: AsyncStream<Data> of PCM16/16kHz chunks, common to mic + file
│       │   ├── AudioCaptureEngine.swift  # AVAudioEngine setup, mic tap, PCM16 conversion (implements AudioSource)
│       │   ├── AudioPermission.swift     # mic permission request/check
│       │   └── VideoFileAudioSource.swift  # AVAssetReader, decodes a video/audio file's audio track, real-time-paced (implements AudioSource)
│       ├── Networking/
│       │   ├── BackendClient.swift       # WS connect/reconnect, send audio, receive messages
│       │   ├── SessionCoordinator.swift  # glues audio capture + WS + store, owns listen/stop lifecycle
│       │   └── Protocol.swift            # Codable structs matching backend WS schema
│       ├── State/
│       │   ├── SessionStore.swift        # @Observable — current segments, connection state, active video URL
│       │   └── Segment.swift             # id, sourceLanguage, sourceText, translatedText
│       ├── Views/
│       │   ├── ContentView.swift         # main window: two-column layout (Transcription/Translation) + optional video player
│       │   ├── TranscriptColumn.swift    # one column's scrolling segment list (source text, or translated text — both tag each row with sourceLanguage)
│       │   ├── SegmentRow.swift          # single segment's language tag + text
│       │   ├── VideoPlayerView.swift     # AVPlayer wrapper (AVKit VideoPlayer), shown when a file is loaded
│       │   └── SettingsView.swift        # backend host/port, mic device picker, toggle VI text visibility
│       └── Resources/
│           └── Info.plist                # NSMicrophoneUsageDescription
└── README.md
```

## Data Flow

```
AVAudioEngine tap (PCM16 buffers, 16kHz mono)
   │
   ▼
AudioCaptureEngine ──(AsyncStream<Data>)──► BackendClient.send(audioChunk)
                                                  │  binary WS frame
                                                  ▼
                                            [backend service]
                                                  │  JSON WS messages
                                                  ▼
BackendClient.receive() ──(AsyncStream<ServerMessage>)──► SessionStore.apply(message)
                                                                  │
                                                                  ▼
                                                          @Observable state
                                                                  │
                                                                  ▼
                                                          ContentView (auto-updates)
```

## State Model

```swift
enum SourceLanguage: String { case vi, en }

struct Segment: Identifiable {
    let id: Int                        // segment_id from backend
    var sourceLanguage: SourceLanguage // which ASR model's transcript the LLM picked as real
    var sourceText: String             // that ASR model's transcript
    var translatedText: String?        // nil until translation_update arrives; always the OTHER language
}

@Observable
final class SessionStore {
    var segments: [Segment] = []
    var connectionState: ConnectionState = .disconnected
    var isListening: Bool = false
    var activeVideoURL: URL?  // set when a video file source is running, drives VideoPlayerView

    func apply(_ message: ServerMessage) {
        switch message {
        case .asrFinal(let text, let lang, let id): segments.append(Segment(id: id, sourceLanguage: lang, sourceText: text, translatedText: nil))
        case .translationUpdate(let text, _, _, let id): /* find segment by id, set translatedText */
        case .error(let msg): /* surface to UI */
        }
    }
}
```

## Rendering Behavior

- **Layout: two columns, side by side** (same split as before the bilingual rework, labels just changed). Left column = "Transcription" (`sourceText`, whichever ASR transcript the LLM picked as real for that segment), right column = "Translation" (`translatedText`, that segment translated into the other language). Both columns scroll together, row `N` in each corresponds to the same `segment_id` — same vertical position, so a row's source and its translation sit at the same height across the split.
- Every row shows a small language tag above its text: left column tags with `sourceLanguage` (`[Vietnamese]`/`[English]`), right column tags with the *opposite* of `sourceLanguage` (translation target is always the other language — no separate field needed, `SourceLanguage.opposite` computes it client-side).
- A segment's row appears in the left (Transcription) column immediately on `asr_final`. The corresponding right (Translation) row shows a brief loading state (e.g. "…") until `translation_update` arrives for that `segment_id`, then fades in.
- No partial/word-by-word revision — backend doesn't emit that (offline ASR). Once the translation arrives, the row is locked — no further changes.
- New rows append at the bottom, both columns auto-scroll together to keep the latest row visible.
- Connection lost / backend not running: clear inline state ("Backend not connected — start service"), not a silent freeze.
- Expect a natural pause-then-appear rhythm (utterance boundary → both rows show up together, not continuously) — this is an inherent latency characteristic of offline ASR, not a bug. Don't design UI that implies continuous live captioning.
- The "show/hide Vietnamese source text" setting no longer applies (left column is always meaningful, source language now varies per segment) — drop that toggle from Settings.
- **Clear button**: in the header, next to Choose File/Listen. Wipes displayed segments (`SessionStore.clearResults()`) without stopping an active video or mic session. If a session is active, also sends `{"type":"control","action":"reset"}` so the backend drops its rolling translation context — otherwise cleared segments would still silently influence future translations via the context window. Disabled when there's nothing to clear.

## Audio Capture Details

- Tap `AVAudioEngine.inputNode` at native format, convert to 16kHz mono Int16 via `AVAudioConverter` before sending (backend expects this format — must match `BACKEND.md` config).
- Chunk size: send buffers as captured (e.g. every ~100-200ms) — let backend-side VAD handle segmentation, don't segment client-side.
- Request mic permission via `NSMicrophoneUsageDescription` in Info.plist; handle denial gracefully (disable listen button, show settings link).

## Video File Input

Alternative to mic: pick a video (or audio) file, decode its audio track, feed the same downstream pipeline (VAD/ASR/translation on the backend is unchanged — it only sees a PCM16 byte stream, doesn't know or care about the source).

```swift
protocol AudioSource {
    func start() throws -> AsyncStream<Data>   // yields PCM16 mono 16kHz chunks
    func stop()
}
```

`AudioCaptureEngine` (mic) and `VideoFileAudioSource` (file) both conform. `SessionCoordinator` takes an `AudioSource` instead of being hardcoded to mic — same WS/session logic either way.

- **Decode**: `AVAssetReader` + `AVAssetReaderTrackOutput` on the file's audio track, output settings requesting linear PCM directly (skip a separate `AVAudioConverter` pass if the reader can emit the target format natively; fall back to converter if not).
- **Pacing**: real-time — throttle chunk delivery to match the audio's actual duration (e.g. sleep between chunks proportional to chunk duration), so it behaves like a live mic feed and backend VAD segments it the same way. Don't dump the whole file's audio at once.
- **Source picker**: `NSOpenPanel` restricted to video/audio UTTypes (`.movie`, `.audio`, `.mpeg4Movie`, etc.), triggered from a "Choose File…" control alongside the existing mic "Listen" button in `ContentView`.
- Reuses `asr_final` / `translation_update` messages and `SessionStore` unchanged — a file "session" looks identical to a mic session from the backend's point of view.

### Video Playback (visible, alongside captions)

When the source is a video file, show it playing above (or beside) the two-column transcript, so captions can be read while watching.

- **Two independent reads of the same file, not a shared pipeline**: `AVPlayer` is created separately from `VideoFileAudioSource` and plays the file directly (its own decode, its own audio output through speakers). `VideoFileAudioSource` keeps decoding the same file *silently* in parallel purely to feed the backend PCM stream. Chosen over tapping `AVPlayer`'s own audio output (e.g. `MTAudioProcessingTap`) for simplicity — accepted tradeoff: playback position and caption timing aren't hard-locked, minor drift possible over a long file, not corrected for in v1.
- **`VideoPlayerView`**: thin AVKit `VideoPlayer(player:)` wrapper, shown only when `SessionStore.activeVideoURL` is set (i.e., a file session is active). Hidden entirely during mic sessions.
- `chooseFile()` in `TranslateApp` creates both the `AVPlayer(url:)` (assigned to `store.activeVideoURL`'s player, starts playback) and the `VideoFileAudioSource(url:)` (feeds the backend) from the same picked URL, starts both roughly together.
- Stopping the session (`Stop` button) pauses/tears down both the player and the audio source.

### Backlog-Aware Auto-Pause

Problem observed in testing: ASR + local LLM translation take real wall-clock time per segment (seconds), but both the video (`AVPlayer`) and the silent audio feed (`VideoFileAudioSource`) run at real playback speed regardless — neither waits for the backend to catch up. Captions fall further behind the longer the video plays.

Fix: pause the *visible* video player when the backend falls behind, resume once it catches up. The silent audio feed keeps running at real-time pace throughout (unchanged) — only visible playback is throttled, so the viewer never sees video ahead of its captions.

- **Backlog signal**: count of segments with `enText == nil` (VI shown, translation not back yet) in `SessionStore.segments`. Simple, already-available client-side state — no new backend signal needed.
- **Threshold**: pause `AVPlayer` when pending count exceeds e.g. 2; resume when it drops to 0 (or 1, avoid rapid pause/resume flicker — needs a small hysteresis gap between pause and resume thresholds).
- **Where it lives**: `SessionStore` gains a computed `pendingCount: Int { segments.filter { $0.enText == nil }.count }`. `VideoPlayerView` observes this (via `@Environment(SessionStore.self)`) and calls `player.pause()` / `player.play()` accordingly — done in the view via `.onChange(of:)`, not pushed into `AVPlayer` construction.
- This only applies to file sessions — mic sessions have no "video to pause," `isListening` mic audio just keeps flowing regardless of translation backlog (acceptable: live mic can't be paused anyway).
- Net effect: video effectively plays at "however fast the pipeline can keep up," bounded below by real-time — matches the earlier discussion's rejected "slow down playback rate" option, but adaptive instead of a fixed guessed rate.

## Networking Details

- Connect to `ws://127.0.0.1:<port>` (port from Settings, default matches backend's default).
- Reconnect with backoff if backend restarts mid-session.
- Send `{"type":"control","action":"start"}` on listen toggle-on, `"stop"` on toggle-off, `"reset"` when clearing transcript.

## Settings (v1 minimal)

- Backend host/port (default `127.0.0.1:8000`)
- Mic input device picker (if multiple available)
- Launch at login

## Open Items / To Validate

- Confirm `URLSessionWebSocketTask` binary+text frame interleaving works cleanly, or split audio/control onto separate connections if not.
- Confirm `AVAssetReaderTrackOutput` can emit PCM16/16kHz mono directly via `outputSettings`, or whether an extra `AVAudioConverter` pass is needed (mirrors the mic path either way — check before assuming zero-conversion).
- Decide whether video source needs its own segment-boundary handling if the file has long silences (e.g. auto-fast-forward through silence) — v1 can just let VAD skip silent stretches naturally, same as mic.
- Watch for audible double-audio: `AVPlayer` plays the file's real audio through speakers while `VideoFileAudioSource` also decodes it (silently, for the backend only) — confirm the silent path truly produces no audible output.
- Measure actual drift between video playback position and caption arrival over a 10+ minute file — if unacceptably large, revisit the "tap AVPlayer's own output" alternative from the original design discussion.

## Non-goals (v1)

- No multi-window / multi-session support.
- No export/save transcript (add later if needed).
- No iOS/iPadOS port — macOS only per current scope.
- No visible video playback/scrubbing UI — audio-only extraction for v1, add a player view later if wanted.

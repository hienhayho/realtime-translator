# macapp — VI→EN Realtime Translation Client

See `../UI.md` for full design. SwiftUI desktop app (standard window), macOS 14+.

## Build & Run

```bash
swift build
```

Open `Package.swift` in Xcode and run from there (Cmd+R) — needed for the mic
permission prompt to register correctly (`swift run` launches an unsigned
binary outside a real app bundle).

Requires the backend running first (`../backend/README.md`) — default expects
`ws://127.0.0.1:8000/ws`, configurable in the app's Settings.

## Status

Mic capture → backend → translation pipeline verified working end-to-end via
Xcode debug run. `NSApplication.setActivationPolicy(.regular)` is set
explicitly in `TranslateApp.init()` since SPM executable targets don't
reliably wire `Resources/Info.plist` into the build product — don't rely on
Info.plist alone for activation policy or Dock visibility in this setup.

Video file audio source (`VideoFileAudioSource.swift`, "Choose File…" button)
added but **not yet tested end-to-end** — builds clean, not run against a real
video file. Before relying on it:

- Confirm `AVAssetReaderTrackOutput`'s PCM16/16kHz `outputSettings` actually
  produces the requested format directly (no separate `AVAudioConverter` pass
  currently wired in for the file path — only the mic path has one).
- Confirm real-time pacing (`Task.sleep` between chunks, sized to each
  chunk's audio duration) doesn't drift/accumulate lag over a long file.
- Confirm `NSOpenPanel`'s `.movie`/`.audio`/`.mpeg4Movie` content types cover
  the file formats you actually want to test with.

UI reworked to a two-column split (`TranscriptColumn.swift`, VI left / EN
right, `ContentView.swift`) plus optional video playback (`VideoPlayerView.swift`,
AVKit `VideoPlayer`) shown above the columns when a file session is active.
Verified working visually — two columns render and stay row-aligned in
practice, video plays alongside captions, no audible double-audio observed
from the parallel silent decode.

**Known real issue, fixed by auto-pause (see below):** video played at real
speed while ASR+translation take real wall-clock time per segment, so
captions fell further behind the longer a video played (confirmed in
testing — only one caption line appeared while the video kept going).

Fix: `VideoPlayerView` now tracks `SessionStore.pendingTranslationCount`
(segments with VI text but no EN yet) and pauses the player once backlog
exceeds 2 pending segments, resumes once it drains to 0 — see UI.md
"Backlog-Aware Auto-Pause". **Not yet tested against a real video** — builds
clean, logic not run end-to-end since this change. Before relying on it:

- Confirm the pause/resume thresholds (2 / 0) feel right in practice — too
  aggressive pausing is annoying, too loose defeats the purpose. Tune based
  on actual pipeline throughput once observed.
- Confirm `.onChange(of: store.pendingTranslationCount)` actually fires
  reliably as segments complete (SwiftUI Observation framework + AVPlayer
  interaction not yet exercised together).
- The silent `VideoFileAudioSource` audio feed keeps running at real-time
  pace even while the *visible* player is paused (unchanged, intentional —
  only playback is throttled) — confirm this doesn't cause the audio feed to
  run ahead of what's been shown, creating a *different* kind of desync.

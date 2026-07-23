import AVKit
import SwiftUI

/// Plays the chosen video file for visible playback. Independent of
/// VideoFileAudioSource, which decodes the same file silently in parallel
/// to feed the backend — see UI.md "Video Playback (visible, alongside captions)".
///
/// Auto-pauses when the translation backlog grows (backend can't keep up
/// with real-time playback) and resumes once it drains, so captions never
/// fall far behind what's on screen — see UI.md "Backlog-Aware Auto-Pause".
struct VideoPlayerView: View {
    @Environment(SessionStore.self) private var store
    let url: URL
    @State private var player: AVPlayer
    @State private var pausedForBacklog = false

    private static let pauseThreshold = 2
    private static let resumeThreshold = 0

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .onChange(of: store.pendingTranslationCount) { _, pendingCount in
                if !pausedForBacklog, pendingCount > Self.pauseThreshold {
                    pausedForBacklog = true
                    player.pause()
                } else if pausedForBacklog, pendingCount <= Self.resumeThreshold {
                    pausedForBacklog = false
                    player.play()
                }
            }
    }
}

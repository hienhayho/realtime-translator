import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranslateApp: App {
    @State private var store = SessionStore()
    @State private var coordinator: SessionCoordinator?

    init() {
        // Force a regular app (Dock icon, window, Cmd+Tab). SPM executable
        // targets don't reliably wire Resources/Info.plist into the build
        // product, so LSUIElement there can't be trusted — set explicitly.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(onToggleMic: toggleMic, onChooseFile: chooseFile, onClear: clear)
                .environment(store)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }

    private func makeCoordinatorIfNeeded() -> SessionCoordinator {
        if let coordinator { return coordinator }
        let host = UserDefaults.standard.string(forKey: "backendHost") ?? "127.0.0.1"
        let port = UserDefaults.standard.integer(forKey: "backendPort")
        let newCoordinator = SessionCoordinator(store: store, host: host, port: port == 0 ? 8000 : port)
        coordinator = newCoordinator
        return newCoordinator
    }

    private func toggleMic() {
        let coordinator = makeCoordinatorIfNeeded()

        Task {
            if store.isListening {
                await coordinator.stop()
                store.activeVideoURL = nil
                return
            }

            if AudioPermission.status() != .authorized {
                let granted = await AudioPermission.request()
                guard granted else {
                    store.apply(.error(message: "Microphone permission denied"))
                    return
                }
            }

            await coordinator.start(source: AudioCaptureEngine())
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let coordinator = makeCoordinatorIfNeeded()
        Task {
            if store.isListening {
                await coordinator.stop()
            }
            store.activeVideoURL = url
            await coordinator.start(source: VideoFileAudioSource(url: url))
        }
    }

    private func clear() {
        let coordinator = makeCoordinatorIfNeeded()
        Task {
            await coordinator.clear()
        }
    }
}

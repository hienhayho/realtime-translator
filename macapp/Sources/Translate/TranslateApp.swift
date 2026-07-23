import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SessionStore()
    @State private var coordinator: SessionCoordinator?
    @State private var modelSelection = ModelSelection()
    @State private var processManager = BackendProcessManager(backendDir: BackendProcessManager.resolveBackendDir())
    @State private var sidebarSelection: SidebarDestination? = .translate

    init() {
        // Force a regular app (Dock icon, window, Cmd+Tab). SPM executable
        // targets don't reliably wire Resources/Info.plist into the build
        // product, so LSUIElement there can't be trusted — set explicitly.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                Sidebar(selection: $sidebarSelection)
            } detail: {
                switch sidebarSelection {
                case .models:
                    ModelsView(
                        onBeforeModelSwitch: disconnectBeforeModelSwitch,
                        onAfterModelSwitch: reconnectAfterModelSwitch
                    )
                case .translate, .none:
                    ContentView(onToggleMic: toggleMic, onChooseFile: chooseFile, onClear: clear)
                }
            }
            .environment(store)
            .environment(processManager)
            .environment(modelSelection)
            .task {
                appDelegate.processManager = processManager
                _ = makeCoordinatorIfNeeded()
                processManager.start(whisperTier: modelSelection.whisperTier, translationModel: modelSelection.translationModel)
            }
        }
        .windowResizability(.contentSize)
    }

    private func makeCoordinatorIfNeeded() -> SessionCoordinator {
        if let coordinator { return coordinator }
        let host = UserDefaults.standard.string(forKey: "backendHost") ?? "127.0.0.1"
        let port = UserDefaults.standard.integer(forKey: "backendPort")
        let newCoordinator = SessionCoordinator(store: store, host: host, port: port == 0 ? 8000 : port)
        coordinator = newCoordinator
        return newCoordinator
    }

    /// Passed into ModelsView, called just before a model-switch restart —
    /// disconnects the WS session cleanly so the receive loop's termination
    /// isn't mistaken for an unexpected drop.
    private func disconnectBeforeModelSwitch() {
        makeCoordinatorIfNeeded().disconnectForPlannedRelaunch()
    }

    /// Passed into ModelsView, called after BackendProcessManager confirms
    /// the relaunched process is healthy again — reconnects the WS session
    /// deterministically (see SessionCoordinator's planned-relaunch path).
    private func reconnectAfterModelSwitch() async {
        await makeCoordinatorIfNeeded().reconnectAfterPlannedRelaunch()
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

import SwiftUI

struct ModelsView: View {
    @Environment(ModelSelection.self) private var modelSelection
    @Environment(BackendProcessManager.self) private var processManager
    /// Called BEFORE the process restart, to disconnect the WS session
    /// cleanly first (avoids racing the old dying process) — and AFTER, to
    /// reconnect once the manager confirms the new process is healthy. See
    /// SessionCoordinator's planned-relaunch path.
    var onBeforeModelSwitch: () -> Void
    var onAfterModelSwitch: () async -> Void

    @AppStorage("backendHost") private var backendHost: String = "127.0.0.1"
    @AppStorage("backendPort") private var backendPort: Int = 8000

    var body: some View {
        @Bindable var modelSelection = modelSelection

        Form {
            Section("Translation Model") {
                Picker("Model", selection: $modelSelection.translationModel) {
                    ForEach(ModelSelection.TranslationModel.allCases) { model in
                        Text(model.label).tag(model)
                    }
                }
                .onChange(of: modelSelection.translationModel) { _, newValue in
                    onBeforeModelSwitch()
                    Task {
                        await processManager.restartLlama(withModel: newValue)
                        await onAfterModelSwitch()
                    }
                }
            }

            Section("English Speech Recognition") {
                Picker("Model", selection: $modelSelection.whisperTier) {
                    ForEach(ModelSelection.WhisperTier.allCases) { tier in
                        Text(tier.label).tag(tier)
                    }
                }
                .onChange(of: modelSelection.whisperTier) { _, newValue in
                    onBeforeModelSwitch()
                    Task {
                        await processManager.restartPython(withTier: newValue)
                        await onAfterModelSwitch()
                    }
                }
            }

            Section("Status") {
                statusRow("Translation server", status: processManager.llamaStatus)
                statusRow("Backend", status: processManager.pythonStatus)
            }

            Section("Advanced") {
                TextField("Host", text: $backendHost)
                TextField("Port", value: $backendPort, format: .number)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 420)
    }

    private func statusRow(_ label: String, status: ProcessStatus) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(statusText(status))
                .foregroundStyle(statusColor(status))
                .font(.caption)
        }
    }

    private func statusText(_ status: ProcessStatus) -> String {
        switch status {
        case .notStarted: return "Not started"
        case .starting: return "Starting…"
        case .downloadingModel: return "Downloading…"
        case .healthy: return "Healthy"
        case .crashed(let reason): return "Crashed: \(reason)"
        case .stopped: return "Stopped"
        }
    }

    private func statusColor(_ status: ProcessStatus) -> Color {
        switch status {
        case .healthy: return .green
        case .crashed: return .red
        case .starting, .downloadingModel: return .orange
        case .notStarted, .stopped: return .secondary
        }
    }
}

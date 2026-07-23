import SwiftUI

struct SettingsView: View {
    @AppStorage("backendHost") private var backendHost: String = "127.0.0.1"
    @AppStorage("backendPort") private var backendPort: Int = 8000

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Host", text: $backendHost)
                TextField("Port", value: $backendPort, format: .number)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case translate = "Translate"
    case models = "Models"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .translate: return "waveform"
        case .models: return "cpu"
        }
    }
}

struct Sidebar: View {
    @Binding var selection: SidebarDestination?

    var body: some View {
        List(SidebarDestination.allCases, selection: $selection) { destination in
            Label(destination.rawValue, systemImage: destination.systemImage)
                .tag(destination)
        }
        .listStyle(.sidebar)
        .navigationTitle("Translate")
    }
}

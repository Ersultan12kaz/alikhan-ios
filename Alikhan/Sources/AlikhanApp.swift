import SwiftUI

@main
struct AlikhanApp: App {
    @StateObject private var assistant = Assistant.shared
    @StateObject private var settings = Settings.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(assistant)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .onOpenURL { assistant.handle(url: $0) }
                .onAppear { assistant.boot() }
        }
        .onChange(of: phase) { _, new in assistant.scenePhaseChanged(new) }
    }
}

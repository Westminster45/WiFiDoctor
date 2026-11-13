import SwiftUI

@main
struct WiFiDoctorApp: App {
    @StateObject private var model = AppModel()

    init() {
        CLI.handle(CommandLine.arguments)
    }

    var body: some Scene {
        Window("WiFi Doctor", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 920, height: 600)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Save Report…") { model.saveReport() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.diagnosis == nil)
            }
        }
    }
}

import SwiftUI

@main
struct PolarmacApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup("Polar") {
            RootView()
                .environmentObject(session)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Polar") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
            }
        }

        Settings {
            SettingsView().environmentObject(session)
        }
    }
}

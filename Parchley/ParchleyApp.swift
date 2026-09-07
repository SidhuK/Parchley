import SwiftUI
import AppKit

@main
struct ParchleyApp: App {
    @State private var model = ParchleyAppModel()
    @NSApplicationDelegateAdaptor(ParchleyAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("Parchley") { ContentView(model: model).frame(minWidth: 850, minHeight: 560).onAppear { appDelegate.model = model }.onOpenURL { url in model.importFiles([url]) }.focusedSceneValue(\.parchleyModel, model) }
            .defaultSize(width: 1180, height: 780)
            .windowToolbarStyle(.unifiedCompact)
            .windowResizability(.contentMinSize)
            .commands {
                SidebarCommands()
                ParchleyCommands()
            }
        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        Window("About Parchley", id: "about") { AboutView() }
            .defaultSize(width: 420, height: 480)
            .windowResizability(.contentSize)
    }
}

@MainActor
final class ParchleyAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ParchleyAppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.flushDrafts(); sender.reply(toApplicationShouldTerminate: !model.hasPendingDrafts) }
        return .terminateLater
    }
}

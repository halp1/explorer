import AppIntents
import Foundation
import ExplorerKit

@available(macOS 13.0, *)
struct OpenNewWindowIntent: AppIntent {
    static var title: LocalizedStringResource = "Open New Window"
    static var description = IntentDescription("Opens a new Explorer window.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.shared.openWindow(.directory(Preferences.shared.defaultURL))
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenInExplorerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open in Explorer"
    static var description = IntentDescription("Opens a folder or archive in the Explorer app.")
    static var openAppWhenRun = true
    @Parameter(title: "Folder or Archive") var file: IntentFile
    @MainActor func perform() async throws -> some IntentResult {
        if let u = file.fileURL { AppDelegate.shared.openFolderOrArchive(u) }
        return .result()
    }
}

@available(macOS 13.0, *)
struct RevealInExplorerIntent: AppIntent {
    static var title: LocalizedStringResource = "Reveal in Explorer"
    static var description = IntentDescription("Reveals an item in the Explorer app.")
    static var openAppWhenRun = true
    @Parameter(title: "File or Folder") var file: IntentFile
    @MainActor func perform() async throws -> some IntentResult {
        if let u = file.fileURL { AppDelegate.shared.reveal(u) }
        return .result()
    }
}

@available(macOS 13.0, *)
struct ExplorerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenNewWindowIntent(), phrases: ["Open a new \(.applicationName) window"])
    }
}

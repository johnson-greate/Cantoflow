import SwiftUI

/// SwiftUI application entry point.
/// Replaces the manual main.swift / NSApplication.run() approach that
/// conflicted with SwiftUI's own run-loop management.
@main
struct CantoFlowApp: App {
    /// Bridges to our existing AppKit delegate for pipeline / menu bar setup.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Placeholder only — SwiftUI requires at least one scene, but the real
        // settings window is created by SettingsWindowController using a manual
        // NSHostingController.  Keeping SettingsView() here would cause SwiftUI
        // to maintain a hidden background window with ObservableObject subscribers
        // (VocabularyViewModel, SettingsStore) that conflict with AppKit CA
        // transactions on macOS 26 beta, producing NSConcretePointerArray crashes.
        Settings {
            EmptyView()
        }
    }
}

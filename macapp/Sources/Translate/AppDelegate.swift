import AppKit

/// Real NSApplicationDelegate for quit-time cleanup — SwiftUI's own
/// lifecycle hooks aren't a reliable enough "about to quit" signal for
/// making sure subprocesses actually get terminated before the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var processManager: BackendProcessManager?

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.stopAll()
    }
}

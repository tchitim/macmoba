// In-app updates. Sparkle does the work — fetch the appcast, verify the EdDSA
// signature and the Developer ID signature, swap the bundle, relaunch — so this
// is only the controller's lifetime and the menu item that drives it.
//
// A running MacMoba usually holds live SSH sessions, so nothing installs
// silently: SUAutomaticallyUpdate is false in Info.plist, and the user decides
// when to restart.

import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    /// nil when Sparkle cannot run — a bare `swift run` binary has no bundle
    /// and no feed, and starting the updater there logs errors for nothing.
    private let updater: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            updater = nil
            return
        }
        updater = SPUStandardUpdaterController(startingUpdater: true,
                                               updaterDelegate: nil,
                                               userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { updater != nil }

    func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }
}

/// The menu item, kept next to the controller so both move together.
struct CheckForUpdatesCommand: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        Button("Check for Updates…") { controller.checkForUpdates() }
            .disabled(!controller.canCheckForUpdates)
    }
}

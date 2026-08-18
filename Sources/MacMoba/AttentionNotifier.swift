// System notifications for panes that need attention while MacMoba is in the
// background — the cmux behaviour: the bell in a hidden terminal reaches you,
// and clicking the notification lands you on that pane.

import AppKit
import Foundation
import UserNotifications

@MainActor
enum AttentionNotifier {
    /// Set at startup: takes a pane id to the window and tab that hold it.
    static var openPane: ((UUID) -> Void)?

    private static var authorizationRequested = false

    static func post(title: String, body: String, paneID: UUID) {
        // UNUserNotificationCenter needs a real bundle; a bare `swift run`
        // binary has none and the call would throw an Objective-C exception.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["paneID": paneID.uuidString]
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
    }
}

/// Routes a clicked notification back to its pane.
final class AttentionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["paneID"] as? String, let paneID = UUID(uuidString: raw) {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                AttentionNotifier.openPane?(paneID)
            }
        }
        completion()
    }
}

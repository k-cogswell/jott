import Foundation
import UserNotifications

// ======================================================================
// CONFIRMATION TOASTS
// ======================================================================
// The only permission this app ever asks for. Requested lazily on the
// first logged task rather than at launch, so a first run that just
// shows the menubar stays prompt-free.
enum Notifier {
    private static var requested = false

    static func post(_ body: String) {
        guard !body.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = "Jott"
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            center.add(request)
        }

        if requested {
            deliver()
        } else {
            requested = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                if granted { DispatchQueue.main.async { deliver() } }
            }
        }
    }
}

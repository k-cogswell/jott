import Foundation
import UserNotifications

// ======================================================================
// BACKGROUND NUDGES
// ======================================================================
// Reserved for messages that have to reach the user when they are NOT
// looking at the app -- the long-task nudge. Confirming a write is
// ToastController's job instead: it is instant and needs no permission.
//
// This is the only permission the app ever asks for, and it is requested
// lazily on the first nudge rather than at launch, so a run that never
// trips one stays prompt-free.
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

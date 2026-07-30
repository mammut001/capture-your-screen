//
//  UserNotificationService.swift
//  capture-your-screen
//
//  Injectable wrapper around UNUserNotificationCenter so workflow code
//  can be unit tested without a notification-capable host process.
//

import Foundation
import UserNotifications

@MainActor
protocol UserNotifying: AnyObject {
    func postNotification(title: String, body: String)
}

@MainActor
final class SystemUserNotificationService: UserNotifying {
    init() {}

    func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("UserNotificationService: notification delivery failed: \(error.localizedDescription)")
            }
        }
    }
}

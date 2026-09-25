import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushCenter: ObservableObject {
    static let shared = PushCenter()
    @Published var token: String?
    @Published var log = ""
    @Published var received = 0
    private var cont: CheckedContinuation<ProbeResult, Never>?

    func append(_ s: String) { log += s + "\n" }

    func registerForProbe() async -> ProbeResult {
        await withCheckedContinuation { c in
            cont = c
            UIApplication.shared.registerForRemoteNotifications()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.resolve(ProbeResult(.needsConfig, "no APNs callback in 8s"))
            }
        }
    }
    private func resolve(_ r: ProbeResult) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: r)
    }
    func gotToken(_ hex: String) {
        token = hex
        append("✅ device token (\(hex.count) hex):\n\(hex)")
        resolve(ProbeResult(.functional, "token \(hex.prefix(16))… (\(hex.count/2) B) — open Push screen"))
    }
    func failed(_ msg: String) { append("❌ registration failed: \(msg)"); resolve(ProbeResult(.denied, msg)) }
    func gotPush(_ payload: String) { received += 1; append("📩 PUSH RECEIVED #\(received):\n\(payload)") }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        return true
    }
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushCenter.shared.gotToken(hex) }
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let e = error as NSError
        Task { @MainActor in PushCenter.shared.failed("\(e.localizedDescription) [\(e.domain) \(e.code)]") }
    }
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await MainActor.run { PushCenter.shared.gotPush("(background) \(userInfo)") }
        return .noData
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { PushCenter.shared.gotPush("\(notification.request.content.userInfo)") }
        return [.banner, .sound]
    }
}

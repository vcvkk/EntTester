import SwiftUI
import UIKit
import UserNotifications

struct PushView: View {
    @ObservedObject private var center = PushCenter.shared
    @AppStorage("ent.keyID") private var keyID = ""
    @AppStorage("ent.teamID") private var teamID = "WZ4E396K4F"
    @AppStorage("ent.topic") private var topic = "app.topaz5224.elephant1433"
    @AppStorage("ent.p8") private var p8 = ""
    @AppStorage("ent.sandbox") private var sandbox = true

    private var apsEnv: String {
        (SignatureReader.entitlements["aps-environment"] as? String) ?? "✖ not in signature"
    }

    var body: some View {
        Form {
            Section("Environment") {
                Text("aps-environment in signature: \(apsEnv)").font(.caption)
                Picker("APNs gateway", selection: $sandbox) {
                    Text("sandbox (development)").tag(true)
                    Text("prod (production)").tag(false)
                }.pickerStyle(.segmented)
            }
            Section("Provider key (.p8) — needed to SEND") {
                TextField("Key ID (10 chars)", text: $keyID).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Team ID (10 chars)", text: $teamID).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Topic (bundle id)", text: $topic).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextEditor(text: $p8).frame(height: 110).font(.system(size: 10, design: .monospaced))
                    .overlay(alignment: .topLeading) {
                        if p8.isEmpty { Text("paste -----BEGIN PRIVATE KEY----- …").font(.system(size: 10)).foregroundStyle(.tertiary).padding(6) }
                    }
            }
            Section {
                Button("① Register (get device token)") { register() }
                Button("② 📤 Send push to myself") { sendSelf() }
                Button("🔔 Fire local notification (no server)") { fireLocal() }
                if center.token != nil {
                    Button("Copy token") { UIPasteboard.general.string = center.token }
                }
                Button("Clear log", role: .destructive) { center.log = "" }
            }
            Section("Log") {
                Text(center.log.isEmpty ? "—" : center.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Push (APNs)")
    }

    private func register() {
        center.append("→ registering…")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                center.append("auth granted: \(granted ? "YES" : "NO")")
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func sendSelf() {
        guard let token = center.token else { center.append("❌ no token yet — tap Register"); return }
        guard !keyID.isEmpty, !teamID.isEmpty, !topic.isEmpty, !p8.isEmpty else { center.append("❌ fill Key ID, Team ID, Topic and paste the .p8"); return }
        center.append("→ sending self-push (\(sandbox ? "sandbox" : "prod"))…")
        Task {
            let r = await APNSSender.send(p8: p8, keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                                          teamID: teamID.trimmingCharacters(in: .whitespacesAndNewlines),
                                          topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
                                          token: token, sandbox: sandbox, title: "EntTester", message: "self-push 👋")
            await MainActor.run { center.append(r) }
        }
    }

    private func fireLocal() {
        let c = UNMutableNotificationContent()
        c.title = "EntTester (local)"; c.body = "local notification 🔔 — no server"; c.sound = .default
        c.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: "ent.local", content: c,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        UNUserNotificationCenter.current().add(req) { err in
            DispatchQueue.main.async { center.append(err == nil ? "→ local notification scheduled (2s)…" : "❌ \(err!.localizedDescription)") }
        }
    }
}

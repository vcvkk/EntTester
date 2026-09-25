import Foundation
import CryptoKit

enum APNSSender {
    static func send(p8: String, keyID: String, teamID: String, topic: String,
                     token: String, sandbox: Bool, title: String, message: String) async -> String {
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: p8) }
        catch { return "❌ can't parse .p8: \(error.localizedDescription)" }

        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        guard let header = try? JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID]),
              let payload = try? JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(Date().timeIntervalSince1970)]) else {
            return "❌ JWT encode failed"
        }
        let signingInput = "\(b64url(header)).\(b64url(payload))"
        guard let sig = try? key.signature(for: Data(signingInput.utf8)) else { return "❌ sign failed" }
        let jwt = "\(signingInput).\(b64url(sig.rawRepresentation))"

        let host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else { return "❌ bad token" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(topic, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.httpBody = try? JSONSerialization.data(withJSONObject:
            ["aps": ["alert": ["title": title, "body": message], "sound": "default"]])

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            let apnsId = http?.value(forHTTPHeaderField: "apns-id") ?? "-"
            if code == 200 { return "✅ HTTP 200 apns-id=\(apnsId) — watch for 📩" }
            var reason = String(data: data, encoding: .utf8) ?? ""
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = j["reason"] as? String { reason = r }
            return "❌ HTTP \(code) reason=\(reason)"
        } catch { return "❌ \(error.localizedDescription)" }
    }
}

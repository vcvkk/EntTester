import Foundation

enum ProbeStatus: String {
    case functional  = "✅"
    case present     = "🔵"
    case needsConfig = "⚙️"
    case denied      = "❌"
    case unavailable = "⛔️"
    case absent      = "✖️"
}

struct ProbeResult {
    var status: ProbeStatus
    var detail: String
    init(_ s: ProbeStatus, _ d: String = "") { status = s; detail = d }
}

enum Category: String, CaseIterable {
    case identity      = "Identity / signing"
    case icloud        = "iCloud & ubiquity"
    case networking    = "Networking & VPN"
    case notifications = "Notifications & Siri"
    case health        = "HealthKit"
    case media         = "Media & camera"
    case security      = "Security & attestation"
    case kernel        = "Kernel / memory"
    case commerce      = "Commerce & passes"
    case system        = "System / accessories"
}

struct EntitlementValues {
    let dict: [String: Any]
    func has(_ k: String) -> Bool { dict[k] != nil }
    func first(_ k: String) -> String? {
        if let a = dict[k] as? [String], let f = a.first { return f }
        if let s = dict[k] as? String { return s }
        return nil
    }
    func array(_ k: String) -> [String] { (dict[k] as? [String]) ?? [] }
}

struct Entitlement: Identifiable {
    let key: String
    let title: String
    let category: Category
    var interactive: Bool = false      // shows a blocking system sheet; skipped in Run All
    let probe: (EntitlementValues) async -> ProbeResult
    var id: String { key }
}

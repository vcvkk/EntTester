import Foundation
import CommonCrypto
import Security
import UIKit
import AVFoundation
import CoreText
import HealthKit
import NetworkExtension
import CoreNFC
import Intents
import GameKit
import UserNotifications
import PassKit
import CloudKit
import ClassKit
import ExternalAccessory
import SystemConfiguration.CaptiveNetwork
import DeviceCheck
import AuthenticationServices
import WeatherKit
import CoreLocation
import FamilyControls
#if canImport(WiFiAware)
import WiFiAware
#endif

// MARK: small async helpers for callback / handler APIs

@MainActor private func siriAuth() async -> ProbeResult {
    await withCheckedContinuation { c in
        INPreferences.requestSiriAuthorization { status in
            switch status {
            case .authorized: c.resume(returning: ProbeResult(.functional, "Siri authorized"))
            case .denied, .restricted: c.resume(returning: ProbeResult(.denied, "user/policy denied"))
            default: c.resume(returning: ProbeResult(.functional, "Siri API reachable (not determined)"))
            }
        }
    }
}

@MainActor private func gameCenter() async -> ProbeResult {
    await withCheckedContinuation { c in
        var done = false
        GKLocalPlayer.local.authenticateHandler = { _, error in
            if done { return }; done = true
            if GKLocalPlayer.local.isAuthenticated { c.resume(returning: ProbeResult(.functional, "authenticated")) }
            else if let error { c.resume(returning: ProbeResult(.denied, error.localizedDescription)) }
            else { c.resume(returning: ProbeResult(.functional, "GC reachable; needs sign-in UI")) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if done { return }; done = true
            c.resume(returning: ProbeResult(.functional, "GC reachable (auth pending)"))
        }
    }
}

private func vpnSaveRemove() async -> ProbeResult {
    let m = NEVPNManager.shared()
    return await withCheckedContinuation { c in
        m.loadFromPreferences { _ in
            let p = NEVPNProtocolIKEv2()
            p.serverAddress = "enttester.probe"; p.remoteIdentifier = "probe"; p.username = "probe"
            p.authenticationMethod = .none
            m.protocolConfiguration = p; m.localizedDescription = "EntTester probe (auto-removed)"; m.isEnabled = false
            m.saveToPreferences { err in
                if let err { c.resume(returning: ProbeResult(.denied, err.localizedDescription)); return }
                m.removeFromPreferences { _ in c.resume(returning: ProbeResult(.functional, "created + removed a real VPN configuration")) }
            }
        }
    }
}

private func neLoad() async -> ProbeResult {
    await withCheckedContinuation { c in
        NETunnelProviderManager.loadAllFromPreferences { mgrs, err in
            if let err { c.resume(returning: ProbeResult(.denied, err.localizedDescription)) }
            else { c.resume(returning: ProbeResult(.functional, "provider prefs reachable; \(mgrs?.count ?? 0) config(s)")) }
        }
    }
}

private func hotspotConfigured() async -> ProbeResult {
    await withCheckedContinuation { c in
        NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
            c.resume(returning: ProbeResult(.functional, "API reachable; \(ssids.count) configured SSID(s)"))
        }
    }
}

private func llhlsReady() async -> ProbeResult {
    let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    defer { withExtendedLifetime(player) {} }
    for _ in 0..<20 {
        _ = player.currentItem   // keep player retained across suspension points
        if item.status == .readyToPlay { return ProbeResult(.functional, "HLS pipeline ready (LL-HLS needs a low-latency source to measure)") }
        if item.status == .failed { return ProbeResult(.denied, item.error?.localizedDescription ?? "playback failed") }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return ProbeResult(.needsConfig, "stream didn't become ready (network?)")
}

@MainActor
enum Catalog {
    static func all() -> [Entitlement] {
        var a: [Entitlement] = []

        // ===== Identity / signing =====
        a.append(Entitlement(key: "application-identifier", title: "Application Identifier", category: .identity) { v in
            v.first("application-identifier").map { ProbeResult(.present, $0) } ?? ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.team-identifier", title: "Team Identifier", category: .identity) { v in
            v.first("com.apple.developer.team-identifier").map { ProbeResult(.present, $0) } ?? ProbeResult(.absent)
        })
        a.append(Entitlement(key: "get-task-allow", title: "get-task-allow (debuggable)", category: .identity) { v in
            guard v.has("get-task-allow") else { return ProbeResult(.absent) }
            let sig = (v.dict["get-task-allow"] as? Bool) ?? false
            return ProbeResult(.functional, "signature=\(sig), CS_GET_TASK_ALLOW(runtime)=\(SysInfo.csGetTaskAllow ? "YES" : "NO")")
        })
        a.append(Entitlement(key: "keychain-access-groups", title: "Keychain Access Groups", category: .identity) { v in
            guard v.has("keychain-access-groups") else { return ProbeResult(.absent) }
            guard let g = v.first("keychain-access-groups") else { return ProbeResult(.present, "no group value") }
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrAccount as String: "entTester.probe",
                                       kSecAttrAccessGroup as String: g]
            SecItemDelete(base as CFDictionary)
            var add = base; add[kSecValueData as String] = Data("x".utf8)
            let s = SecItemAdd(add as CFDictionary, nil)
            var q = base; q[kSecReturnData as String] = true
            let r = SecItemCopyMatching(q as CFDictionary, nil)
            SecItemDelete(base as CFDictionary)
            return (s == errSecSuccess && r == errSecSuccess)
                ? ProbeResult(.functional, "wrote+read a keychain item in \(g)")
                : ProbeResult(.denied, "add=\(s) copy=\(r)")
        })

        // ===== iCloud & ubiquity =====
        a.append(Entitlement(key: "com.apple.security.application-groups", title: "App Groups", category: .icloud) { v in
            guard v.has("com.apple.security.application-groups") else { return ProbeResult(.absent) }
            guard let g = v.first("com.apple.security.application-groups"),
                  let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else {
                return ProbeResult(.denied, "no container URL")
            }
            let f = u.appendingPathComponent("entTester.probe")
            do { try Data("x".utf8).write(to: f); _ = try Data(contentsOf: f); try? FileManager.default.removeItem(at: f)
                return ProbeResult(.functional, "wrote+read a file in \(g)")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.ubiquity-kvstore-identifier", title: "iCloud Key-Value Store", category: .icloud) { v in
            guard v.has("com.apple.developer.ubiquity-kvstore-identifier") else { return ProbeResult(.absent) }
            let kv = NSUbiquitousKeyValueStore.default
            kv.set("\(Date().timeIntervalSince1970)", forKey: "entTester.kv")
            return kv.synchronize() ? ProbeResult(.functional, "KVS write+synchronize ok")
                                    : ProbeResult(.needsConfig, "present; iCloud not signed in / sync off")
        })
        a.append(Entitlement(key: "com.apple.developer.ubiquity-container-identifiers", title: "iCloud Ubiquity Container", category: .icloud) { v in
            guard v.has("com.apple.developer.ubiquity-container-identifiers") else { return ProbeResult(.absent) }
            let id = v.first("com.apple.developer.ubiquity-container-identifiers")
            return await Task.detached { () -> ProbeResult in
                guard let u = FileManager.default.url(forUbiquityContainerIdentifier: id) else {
                    return ProbeResult(.needsConfig, "no container URL (iCloud off / not provisioned)")
                }
                let docs = u.appendingPathComponent("Documents")
                try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
                let f = docs.appendingPathComponent("entTester.probe")
                do { try Data("probe".utf8).write(to: f); _ = try Data(contentsOf: f); try? FileManager.default.removeItem(at: f)
                    return ProbeResult(.functional, "wrote+read a file in the iCloud container")
                } catch { return ProbeResult(.denied, error.localizedDescription) }
            }.value
        })
        a.append(Entitlement(key: "com.apple.developer.icloud-services", title: "iCloud Services (CloudKit)", category: .icloud) { v in
            guard v.has("com.apple.developer.icloud-services") else { return ProbeResult(.absent) }
            let cid = v.first("com.apple.developer.icloud-container-identifiers")
            let c = cid.map { CKContainer(identifier: $0) } ?? CKContainer.default()
            do {
                let st = try await c.accountStatus()
                switch st {
                case .available: return ProbeResult(.functional, "CloudKit reachable, account available")
                case .noAccount: return ProbeResult(.functional, "CloudKit reachable, no iCloud account")
                case .restricted: return ProbeResult(.functional, "CloudKit reachable, restricted")
                default: return ProbeResult(.needsConfig, "couldn't determine account status")
                }
            } catch { return ProbeResult(.needsConfig, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.icloud-container-identifiers", title: "iCloud Container Identifiers", category: .icloud) { v in
            v.has("com.apple.developer.icloud-container-identifiers") ? ProbeResult(.present, "config — exercised by CloudKit + ubiquity probes") : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.icloud-container-development-container-identifiers", title: "iCloud Dev Containers", category: .icloud) { v in
            v.has("com.apple.developer.icloud-container-development-container-identifiers") ? ProbeResult(.present, "development container config") : ProbeResult(.absent)
        })

        // ===== Networking & VPN =====
        a.append(Entitlement(key: "com.apple.developer.networking.wifi-info", title: "Wi-Fi Info (SSID)", category: .networking) { v in
            guard v.has("com.apple.developer.networking.wifi-info") else { return ProbeResult(.absent) }
            if let net = await NEHotspotNetwork.fetchCurrent() { return ProbeResult(.functional, "SSID: \(net.ssid)") }
            return ProbeResult(.needsConfig, "present; needs Location auth + active Wi-Fi")
        })
        a.append(Entitlement(key: "com.apple.developer.networking.HotspotConfiguration", title: "Hotspot Configuration", category: .networking) { v in
            v.has("com.apple.developer.networking.HotspotConfiguration") ? await hotspotConfigured() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.networking.multipath", title: "Multipath TCP", category: .networking) { v in
            guard v.has("com.apple.developer.networking.multipath") else { return ProbeResult(.absent) }
            let cfg = URLSessionConfiguration.default; cfg.multipathServiceType = .handover
            do { let (_, resp) = try await URLSession(configuration: cfg).data(from: URL(string: "https://www.apple.com")!)
                return ProbeResult(.functional, "MPTCP request ok (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.networking.networkextension", title: "Network Extension", category: .networking) { v in
            v.has("com.apple.developer.networking.networkextension") ? await neLoad() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.networking.vpn.api", title: "Personal VPN API", category: .networking, interactive: true) { v in
            v.has("com.apple.developer.networking.vpn.api") ? await vpnSaveRemove() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.associated-domains", title: "Associated Domains", category: .networking) { v in
            v.has("com.apple.developer.associated-domains")
                ? ProbeResult(.needsConfig, "no app-side API — needs apple-app-site-association on the domain")
                : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.coremedia.hls.low-latency", title: "Low-Latency HLS", category: .media) { v in
            v.has("com.apple.developer.coremedia.hls.low-latency") ? await llhlsReady() : ProbeResult(.absent)
        })

        // ===== Notifications & Siri =====
        a.append(Entitlement(key: "aps-environment", title: "Push (APNs)", category: .notifications) { v in
            v.has("aps-environment") ? await PushCenter.shared.registerForProbe() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.usernotifications.time-sensitive", title: "Time-Sensitive Notifications", category: .notifications) { v in
            guard v.has("com.apple.developer.usernotifications.time-sensitive") else { return ProbeResult(.absent) }
            let c = UNMutableNotificationContent(); c.title = "probe"; c.interruptionLevel = .timeSensitive
            let req = UNNotificationRequest(identifier: "ent.ts", content: c,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
            do { try await UNUserNotificationCenter.current().add(req)
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["ent.ts"])
                return ProbeResult(.functional, "scheduled a .timeSensitive request")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.usernotifications.communication", title: "Communication Notifications", category: .notifications) { v in
            guard v.has("com.apple.developer.usernotifications.communication") else { return ProbeResult(.absent) }
            let handle = INPersonHandle(value: "probe", type: .unknown)
            let me = INPerson(personHandle: handle, nameComponents: nil, displayName: "Probe", image: nil, contactIdentifier: nil, customIdentifier: nil)
            let intent = INSendMessageIntent(recipients: [me], outgoingMessageType: .outgoingMessageText,
                content: "probe", speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: me, attachments: nil)
            do { try await INInteraction(intent: intent, response: nil).donate()
                return ProbeResult(.functional, "donated INSendMessageIntent")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.siri", title: "SiriKit", category: .notifications) { v in
            v.has("com.apple.developer.siri") ? await siriAuth() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.applesignin", title: "Sign in with Apple", category: .notifications, interactive: true) { v in
            v.has("com.apple.developer.applesignin") ? await AppleSignIn.shared.run() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.game-center", title: "Game Center", category: .notifications) { v in
            v.has("com.apple.developer.game-center") ? await gameCenter() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.developer.authentication-services.autofill-credential-provider", title: "AutoFill Credential Provider", category: .security) { v in
            guard v.has("com.apple.developer.authentication-services.autofill-credential-provider") else { return ProbeResult(.absent) }
            let enabled = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                ASCredentialIdentityStore.shared.getState { c.resume(returning: $0.isEnabled) }
            }
            return ProbeResult(enabled ? .functional : .present,
                "credential store reachable; extension enabled in Settings: \(enabled ? "YES" : "NO")")
        })

        // ===== HealthKit =====
        a.append(Entitlement(key: "com.apple.developer.healthkit", title: "HealthKit (write+read)", category: .health) { v in
            guard v.has("com.apple.developer.healthkit") else { return ProbeResult(.absent) }
            guard HKHealthStore.isHealthDataAvailable() else { return ProbeResult(.unavailable, "HealthKit unavailable") }
            let store = HKHealthStore(); let bm = HKQuantityType(.bodyMass)
            do {
                try await store.requestAuthorization(toShare: [bm], read: [bm])
                let q = HKQuantity(unit: .gramUnit(with: .none), doubleValue: 70000)
                let s = HKQuantitySample(type: bm, quantity: q, start: Date(), end: Date())
                try await store.save(s)
                try await store.delete(s)
                return ProbeResult(.functional, "wrote + deleted a bodyMass sample")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.healthkit.access", title: "HealthKit Clinical Access", category: .health) { v in
            guard v.has("com.apple.developer.healthkit.access") else { return ProbeResult(.absent) }
            guard HKHealthStore.isHealthDataAvailable() else { return ProbeResult(.unavailable) }
            let store = HKHealthStore()
            guard let ct = HKObjectType.clinicalType(forIdentifier: .allergyRecord) else { return ProbeResult(.unavailable, "clinical types unavailable") }
            do { try await store.requestAuthorization(toShare: [], read: [ct])
                return ProbeResult(.functional, "clinical (health-records) authorization accepted")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.healthkit.background-delivery", title: "HealthKit Background Delivery", category: .health) { v in
            guard v.has("com.apple.developer.healthkit.background-delivery") else { return ProbeResult(.absent) }
            guard HKHealthStore.isHealthDataAvailable() else { return ProbeResult(.unavailable) }
            let store = HKHealthStore(); let t = HKQuantityType(.stepCount)
            do { try await store.enableBackgroundDelivery(for: t, frequency: .hourly)
                return ProbeResult(.functional, "background delivery enabled")
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.healthkit.recalibrate-estimates", title: "HealthKit Recalibrate Estimates", category: .health) { v in
            guard v.has("com.apple.developer.healthkit.recalibrate-estimates") else { return ProbeResult(.absent) }
            guard HKHealthStore.isHealthDataAvailable() else { return ProbeResult(.unavailable) }
            // recalibrateEstimates(...) exists (iOS15) but needs prior estimated samples;
            // reflect that it's a HealthKit sub-capability that activates once HK is authorized.
            let store = HKHealthStore()
            let canRecal = store.responds(to: NSSelectorFromString("recalibrateEstimatesForSampleType:atDate:completion:"))
            return ProbeResult(canRecal ? .present : .unavailable,
                canRecal ? "recalibrate API present; needs estimated samples to run" : "needs iOS 15+")
        })

        // ===== Media & camera =====
        a.append(Entitlement(key: "com.apple.developer.avfoundation.multitasking-camera-access", title: "Multitasking Camera Access", category: .media) { v in
            guard v.has("com.apple.developer.avfoundation.multitasking-camera-access") else { return ProbeResult(.absent) }
            let s = AVCaptureSession()
            let supported = s.isMultitaskingCameraAccessSupported
            return ProbeResult(supported ? .functional : .unavailable,
                "isMultitaskingCameraAccessSupported=\(supported) (entitlement gates this API)")
        })
        a.append(Entitlement(key: "com.apple.developer.user-fonts", title: "User Fonts", category: .media) { v in
            guard v.has("com.apple.developer.user-fonts") else { return ProbeResult(.absent) }
            let arr = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
            return ProbeResult(.functional, "CTFontManager reachable; \(arr.count) user font(s) registered")
        })
        a.append(Entitlement(key: "com.apple.developer.nfc.readersession.formats", title: "NFC Reader", category: .media, interactive: true) { v in
            v.has("com.apple.developer.nfc.readersession.formats") ? await NFCReaderProbe.shared.run() : ProbeResult(.absent)
        })

        // ===== Security & attestation =====
        a.append(Entitlement(key: "com.apple.developer.devicecheck.appattest-environment", title: "App Attest (full flow)", category: .security) { v in
            guard v.has("com.apple.developer.devicecheck.appattest-environment") else { return ProbeResult(.absent) }
            let svc = DCAppAttestService.shared
            guard svc.isSupported else { return ProbeResult(.unavailable, "not supported on this device") }
            do {
                let keyId = try await svc.generateKey()
                var rnd = Data(count: 32); _ = rnd.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                let hash = Data(SHA256hex(rnd))
                do { let att = try await svc.attestKey(keyId, clientDataHash: hash)
                    return ProbeResult(.functional, "key generated + attested (\(att.count)-byte attestation object)")
                } catch { return ProbeResult(.functional, "key generated; attest needs network: \(error.localizedDescription)") }
            } catch { return ProbeResult(.denied, error.localizedDescription) }
        })
        a.append(Entitlement(key: "com.apple.developer.family-controls", title: "Family Controls (Screen Time)", category: .security, interactive: true) { v in
            guard v.has("com.apple.developer.family-controls") else { return ProbeResult(.absent) }
            do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                return ProbeResult(.functional, "Screen Time authorization granted")
            } catch { return ProbeResult(.denied, "\(error)") }
        })

        // ===== Kernel / memory =====
        a.append(Entitlement(key: "com.apple.developer.kernel.increased-memory-limit", title: "Increased Memory Limit", category: .kernel) { v in
            guard v.has("com.apple.developer.kernel.increased-memory-limit") else { return ProbeResult(.absent) }
            let phys = SysInfo.physicalMemory, lim = SysInfo.effectiveLimit
            guard lim > 0 else { return ProbeResult(.present, "present; tap for detail") }
            let pct = 100.0 * Double(lim) / Double(phys)
            return ProbeResult(pct >= 55 ? .functional : .present,
                "limit ≈\(lim/1_048_576) MB / \(phys/1_048_576) MB (\(Int(pct))%) — tap for detail")
        })
        a.append(Entitlement(key: "com.apple.developer.kernel.increased-debugging-memory-limit", title: "Increased Debugging Memory Limit", category: .kernel) { v in
            guard v.has("com.apple.developer.kernel.increased-debugging-memory-limit") else { return ProbeResult(.absent) }
            if SysInfo.debuggerAttached { return ProbeResult(.functional, "debugger attached — raised limit active") }
            if SysInfo.csDebugged { return ProbeResult(.present, "CS_DEBUGGED set (JIT) but no active trace — tap for detail") }
            return ProbeResult(.present, "present; only under an attached debugger — tap for detail")
        })
        a.append(Entitlement(key: "com.apple.developer.kernel.extended-virtual-addressing", title: "Extended Virtual Addressing", category: .kernel) { v in
            guard v.has("com.apple.developer.kernel.extended-virtual-addressing") else { return ProbeResult(.absent) }
            let va = SysInfo.maxVirtualReservation(); let big = va > (UInt64(8) << 30)
            return ProbeResult(big ? .functional : .present, "max VA reservation \(va/1_048_576) MB \(big ? "(>8 GiB)" : "(near default)") — tap for detail")
        })

        // ===== Commerce & passes =====
        a.append(Entitlement(key: "com.apple.developer.in-app-payments", title: "Apple Pay", category: .commerce) { v in
            guard v.has("com.apple.developer.in-app-payments") else { return ProbeResult(.absent) }
            let can = PKPaymentAuthorizationController.canMakePayments()
            let canNet = PKPaymentAuthorizationController.canMakePayments(usingNetworks: [.visa, .masterCard, .amex])
            let m = v.array("com.apple.developer.in-app-payments")
            return ProbeResult(canNet ? .functional : .needsConfig,
                "canMakePayments=\(can), withNetworks=\(canNet), merchants: \(m.isEmpty ? "(none)" : m.joined(separator: ", "))")
        })
        a.append(Entitlement(key: "com.apple.developer.pass-type-identifiers", title: "Wallet Pass Types", category: .commerce) { v in
            guard v.has("com.apple.developer.pass-type-identifiers") else { return ProbeResult(.absent) }
            let avail = PKPassLibrary.isPassLibraryAvailable()
            let n = avail ? PKPassLibrary().passes().count : 0
            return ProbeResult(avail ? .needsConfig : .unavailable,
                "PassLibrary available=\(avail), \(n) pass(es); adding needs a signed .pkpass")
        })
        a.append(Entitlement(key: "com.apple.developer.weatherkit", title: "WeatherKit", category: .commerce) { v in
            guard v.has("com.apple.developer.weatherkit") else { return ProbeResult(.absent) }
            do {
                let w = try await WeatherService.shared.weather(for: CLLocation(latitude: 37.33, longitude: -122.03))
                return ProbeResult(.functional, "current temp: \(w.currentWeather.temperature.formatted())")
            } catch { return ProbeResult(.needsConfig, "call failed: \(error.localizedDescription)") }
        })

        // ===== System / accessories =====
        a.append(Entitlement(key: "com.apple.developer.homekit", title: "HomeKit", category: .system) { v in
            v.has("com.apple.developer.homekit") ? await HomeProbe.shared.run() : ProbeResult(.absent)
        })
        a.append(Entitlement(key: "com.apple.external-accessory.wireless-configuration", title: "External Accessory Wireless Config", category: .system) { v in
            guard v.has("com.apple.external-accessory.wireless-configuration") else { return ProbeResult(.absent) }
            let br = EAWiFiUnconfiguredAccessoryBrowser(delegate: nil, queue: .main)
            br.startSearchingForUnconfiguredAccessories(matching: nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            br.stopSearchingForUnconfiguredAccessories()
            return ProbeResult(.functional, "MFi accessory browser started (entitlement honored)")
        })
        a.append(Entitlement(key: "com.apple.developer.ClassKit-environment", title: "ClassKit", category: .system) { v in
            guard v.has("com.apple.developer.ClassKit-environment") else { return ProbeResult(.absent) }
            let ctx = CLSDataStore.shared.mainAppContext
            return ProbeResult(.functional, "CLSDataStore reachable; mainAppContext id=\(ctx.identifier)")
        })
        a.append(Entitlement(key: "com.apple.developer.wifi-aware", title: "Wi-Fi Aware", category: .system) { v in
            guard v.has("com.apple.developer.wifi-aware") else { return ProbeResult(.absent) }
            #if canImport(WiFiAware)
            return ProbeResult(.needsConfig, "WiFiAware framework available; pairing needs a second Wi-Fi Aware device")
            #else
            return ProbeResult(.present, "WiFiAware SDK not in this Xcode; entitlement present in signature")
            #endif
        })

        return a
    }
}

private func SHA256hex(_ d: Data) -> [UInt8] {
    var hash = [UInt8](repeating: 0, count: 32)
    d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &hash) }
    return hash
}

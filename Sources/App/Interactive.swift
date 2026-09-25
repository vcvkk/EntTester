import Foundation
import UIKit
import AuthenticationServices
import CoreNFC
import HomeKit

@MainActor func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
}

@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignIn()
    private var cont: CheckedContinuation<ProbeResult, Never>?
    private var ctrl: ASAuthorizationController?

    func run() async -> ProbeResult {
        await withCheckedContinuation { c in
            cont = c
            let req = ASAuthorizationAppleIDProvider().createRequest()
            req.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [req])
            controller.delegate = self
            controller.presentationContextProvider = self
            ctrl = controller
            controller.performRequests()
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        keyWindow() ?? ASPresentationAnchor()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(ProbeResult(.functional, "Sign in with Apple flow completed"))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let ae = error as? ASAuthorizationError, ae.code == .canceled {
            finish(ProbeResult(.functional, "sheet shown; canceled — entitlement works"))
        } else {
            finish(ProbeResult(.denied, error.localizedDescription))
        }
    }
    private func finish(_ r: ProbeResult) { cont?.resume(returning: r); cont = nil; ctrl = nil }
}

final class NFCReaderProbe: NSObject, NFCNDEFReaderSessionDelegate {
    static let shared = NFCReaderProbe()
    private var cont: CheckedContinuation<ProbeResult, Never>?
    private var session: NFCNDEFReaderSession?

    func run() async -> ProbeResult {
        guard NFCNDEFReaderSession.readingAvailable else { return ProbeResult(.unavailable, "NFC not available on this device") }
        return await withCheckedContinuation { c in
            cont = c
            let s = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: true)
            s.alertMessage = "EntTester: hold a tag near the top, or cancel"
            session = s
            s.begin()
        }
    }
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        finish(ProbeResult(.functional, "scanned \(messages.count) NDEF message(s)"))
    }
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        finish(ProbeResult(.functional, "reader session ran (\(error.localizedDescription))"))
    }
    private func finish(_ r: ProbeResult) { cont?.resume(returning: r); cont = nil; session = nil }
}

final class HomeProbe: NSObject, HMHomeManagerDelegate {
    static let shared = HomeProbe()
    private var cont: CheckedContinuation<ProbeResult, Never>?
    private var mgr: HMHomeManager?

    func run() async -> ProbeResult {
        await withCheckedContinuation { c in
            cont = c
            let m = HMHomeManager()
            m.delegate = self
            mgr = m
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.finish(ProbeResult(.functional, "HMHomeManager alive (no homes update yet)"))
            }
        }
    }
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        finish(ProbeResult(.functional, "\(manager.homes.count) home(s) accessible"))
    }
    private func finish(_ r: ProbeResult) { cont?.resume(returning: r); cont = nil; mgr?.delegate = nil; mgr = nil }
}

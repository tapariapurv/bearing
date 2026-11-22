import Foundation
import Network

/// Receives the browser's redirect after sign-in, on a random local port.
final class Loopback: @unchecked Sendable {
    private let listener: NWListener
    private let q = DispatchQueue(label: "bearing.oauth")
    private var done: CheckedContinuation<[String: String]?, Never>?
    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
    }
    func wait(ready: @escaping @Sendable (UInt16) -> Void) async -> [String: String]? {
        await withCheckedContinuation { c in
            q.async { [self] in
                done = c
                listener.stateUpdateHandler = { [self] s in
                    if case .ready = s, let p = listener.port?.rawValue { ready(p) }
                    if case .failed = s { finish(nil) }
                }
                listener.newConnectionHandler = { [self] conn in
                    conn.start(queue: q)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, _, _ in
                        let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                        let parts = line.split(separator: " ")
                        let items = parts.count > 1 ? URLComponents(string: "http://x" + parts[1])?.queryItems ?? [] : []
                        let got = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                        let html = "<html><body style='font:16px -apple-system;text-align:center;padding-top:80px'>You can close this tab and go back to Bearing.</body></html>"
                        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                        conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                        if got["code"] != nil || got["error"] != nil { finish(got) }
                    }
                }
                listener.start(queue: q)
                q.asyncAfter(deadline: .now() + 300) { [self] in finish(nil) }
            }
        }
    }
    private func finish(_ r: [String: String]?) { listener.cancel(); done?.resume(returning: r); done = nil }
}

#if os(macOS)
import AppKit
extension Loopback { @MainActor static func open(_ u: URL) { NSWorkspace.shared.open(u) }; @MainActor static func close() {} }
#else
import AuthenticationServices
import UIKit
/// iOS opens sign-in pages in an in-app browser sheet; the loopback still receives the code.
extension Loopback {
    @MainActor private static var sheet: ASWebAuthenticationSession?
    @MainActor static func open(_ u: URL) {
        sheet = ASWebAuthenticationSession(url: u, callback: .customScheme("bearing")) { _, _ in }
        sheet?.presentationContextProvider = Anchor.shared
        sheet?.start()
    }
    @MainActor static func close() { sheet?.cancel(); sheet = nil }
}
final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Anchor()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor() }
    }
}
#endif

import SwiftUI
import AuthenticationServices
import CryptoKit

/// The Mac app's data as raw JSON, so edits here never drop fields the phone doesn't know about.
/// Synced with Firestore at users/{email} using the person's own Google sign-in, last writer wins.
@Observable @MainActor final class Cloud {
    static let shared = Cloud()
    var email = UserDefaults.standard.string(forKey: "email") ?? ""
    var doc: [String: Any] = [:]
    var status = ""
    @ObservationIgnored private var access = ""
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var auth: ASWebAuthenticationSession?
    private var stamp: Double {
        get { UserDefaults.standard.double(forKey: "sync.stamp") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.stamp") }
    }
    private let file = URL.documentsDirectory.appendingPathComponent("data.json")
    private let base = "https://firestore.googleapis.com/v1/projects/bearing-514007/databases/(default)/documents/users/"
    private let tokenURL = "https://oauth2.googleapis.com/token"

    init() { if let d = try? Data(contentsOf: file) { doc = Self.obj(d) } }

    // MARK: Sign-in (Google, loopback redirect inside an in-app browser sheet)

    func signIn() async {
        guard let lb = try? Loopback() else { status = "Couldn't open a local port for sign-in."; return }
        let verifier = Self.random(), state = Self.random()
        final class Port: @unchecked Sendable { var value: UInt16 = 0 }
        let port = Port()
        let got = await lb.wait { p in
            port.value = p
            Task { @MainActor in
                var u = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                u.queryItems = [.init(name: "client_id", value: GoogleClient.id), .init(name: "redirect_uri", value: "http://127.0.0.1:\(p)"),
                                .init(name: "response_type", value: "code"), .init(name: "state", value: state),
                                .init(name: "scope", value: "openid email https://www.googleapis.com/auth/datastore"),
                                .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL), .init(name: "code_challenge_method", value: "S256"),
                                .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
                self.auth = ASWebAuthenticationSession(url: u.url!, callback: .customScheme("bearing")) { _, _ in }
                self.auth?.presentationContextProvider = Anchor.shared
                self.auth?.start()
            }
        }
        auth?.cancel(); auth = nil
        guard let got, got["state"] == state, let code = got["code"] else { status = "Sign-in didn't finish."; return }
        do {
            let j = try await form(["code": code, "code_verifier": verifier, "redirect_uri": "http://127.0.0.1:\(port.value)", "grant_type": "authorization_code"])
            guard let rt = j["refresh_token"] as? String, let id = j["id_token"] as? String,
                  let mail = Self.claims(id)["email"] as? String else { status = "Google didn't return an account."; return }
            Keychain.set("google.refresh", rt)
            email = mail; UserDefaults.standard.set(mail, forKey: "email")
            stamp = 0; await pull()
        } catch { status = error.localizedDescription }
    }
    func signOut() { Keychain.set("google.refresh", ""); email = ""; UserDefaults.standard.removeObject(forKey: "email"); doc = [:]; stamp = 0; try? FileManager.default.removeItem(at: file) }

    private func form(_ f: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: tokenURL)!); r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let all = f.merging(["client_id": GoogleClient.id, "client_secret": GoogleClient.secret]) { a, _ in a }
        r.httpBody = Data(all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").utf8)
        let j = Self.obj(try await URLSession.shared.data(for: r).0)
        if let t = j["access_token"] as? String { access = t; expiry = Date().addingTimeInterval((j["expires_in"] as? Double ?? 3600) - 60) }
        return j
    }
    private func token() async throws -> String {
        if !access.isEmpty, expiry > Date() { return access }
        _ = try await form(["refresh_token": Keychain.get("google.refresh"), "grant_type": "refresh_token"])
        guard !access.isEmpty else { throw URLError(.userAuthenticationRequired) }
        return access
    }

    // MARK: Sync

    func pull() async {
        guard !email.isEmpty else { return }
        guard let (d, code) = try? await request("GET") else { status = "Offline"; return }
        status = code == 200 || code == 404 ? "" : "Sync failed (\(code)). Sign in again if this continues."
        guard code == 200, let f = Self.obj(d)["fields"] as? [String: Any],
              let json = (f["data"] as? [String: Any])?["stringValue"] as? String,
              let mod = (f["modified"] as? [String: Any])?["doubleValue"] as? Double, mod > stamp else { return }
        doc = Self.obj(Data(json.utf8)); stamp = mod; save()
    }
    private func push() async {
        guard let d = try? JSONSerialization.data(withJSONObject: doc) else { return }
        let (_, code) = (try? await request("PATCH", ["fields": ["data": ["stringValue": String(decoding: d, as: UTF8.self)], "modified": ["doubleValue": stamp]]])) ?? (Data(), 0)
        status = code == 200 ? "" : "Not synced yet"
    }
    private func request(_ method: String, _ body: [String: Any]? = nil) async throws -> (Data, Int) {
        var r = URLRequest(url: URL(string: base + (email.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!)
        r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private func save() { if let d = try? JSONSerialization.data(withJSONObject: doc) { try? d.write(to: file, options: .atomic) } }

    /// Applies a local edit, then pushes two seconds after the last one.
    func edit(_ f: (inout [String: Any]) -> Void) {
        f(&doc); stamp = Date().timeIntervalSince1970; save()
        pending?.cancel(); pending = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { await push() } }
    }

    // MARK: Reading the Mac's model

    struct Item: Identifiable { var id: String, title: String, done: Bool, due: Date?, goal: String? }
    struct Goal: Identifiable { var id: String, title: String, why: String, hours: Double }
    struct Slot: Identifiable { var id: String, title: String, start: Date, end: Date }
    private static let iso = ISO8601DateFormatter()
    var compass: String { doc["compass"] as? String ?? "" }
    var goals: [Goal] {
        (doc["goals"] as? [[String: Any]] ?? []).filter { !($0["archived"] as? Bool ?? false) }.map {
            Goal(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", why: $0["why"] as? String ?? "", hours: $0["weeklyHours"] as? Double ?? 0)
        }
    }
    var tasks: [Item] {
        let names = Dictionary(goals.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return (doc["tasks"] as? [[String: Any]] ?? []).map {
            Item(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", done: $0["done"] as? Bool ?? false,
                 due: ($0["due"] as? String).flatMap(Self.iso.date), goal: ($0["goalID"] as? String).flatMap { names[$0] })
        }
    }
    func slots(on day: Date) -> [Slot] {
        (doc["blocks"] as? [[String: Any]] ?? []).compactMap { b in
            guard let s = (b["start"] as? String).flatMap(Self.iso.date), let e = (b["end"] as? String).flatMap(Self.iso.date),
                  Calendar.current.isDate(s, inSameDayAs: day) else { return nil }
            return Slot(id: b["id"] as? String ?? "", title: b["title"] as? String ?? "", start: s, end: e)
        }.sorted { $0.start < $1.start }
    }
    func toggle(_ id: String) { editTask(id) { $0["done"] = !($0["done"] as? Bool ?? false) } }
    func delete(_ id: String) { edit { d in d["tasks"] = (d["tasks"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != id } } }
    func add(_ title: String, goal: String? = nil) {
        // Every key the Mac's TaskItem needs to decode.
        var t: [String: Any] = ["id": UUID().uuidString, "title": title, "notes": "", "project": "", "priority": 1, "done": false]
        if let goal { t["goalID"] = goal }
        edit { d in d["tasks"] = [t] + (d["tasks"] as? [[String: Any]] ?? []) }
    }
    private func editTask(_ id: String, _ f: (inout [String: Any]) -> Void) {
        edit { d in
            var ts = d["tasks"] as? [[String: Any]] ?? []
            if let i = ts.firstIndex(where: { $0["id"] as? String == id }) { f(&ts[i]) }
            d["tasks"] = ts
        }
    }

    nonisolated static func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
    nonisolated static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: "."); guard parts.count > 1 else { return [:] }
        var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return obj(Data(base64Encoded: s) ?? Data())
    }
    private static func random() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "") }
}

extension Data { var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }

final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Anchor()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor() }
    }
}

enum Keychain {
    static func get(_ k: String) -> String {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Bearing", kSecAttrAccount as String: k, kSecReturnData as String: true]
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? String(decoding: out as? Data ?? Data(), as: UTF8.self) : ""
    }
    static func set(_ k: String, _ v: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Bearing", kSecAttrAccount as String: k]
        SecItemDelete(q as CFDictionary)
        if !v.isEmpty { SecItemAdd(q.merging([kSecValueData as String: Data(v.utf8)]) { a, _ in a } as CFDictionary, nil) }
    }
}

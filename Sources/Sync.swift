import Foundation

/// Keeps one copy of AppData in Firestore at users/{email}, signed in with the person's own Google token.
// ponytail: whole-document last-writer-wins and IAM access (works for the project owner);
// move to Firebase Auth + per-field merge if other people use it or edits collide.
@MainActor enum Sync {
    static var token: () async throws -> String = { try await GoogleCalendar.shared.bearer() }
    static var ready: () -> Bool = { GoogleCalendar.shared.connected }
    private static let base = "https://firestore.googleapis.com/v1/projects/bearing-514007/databases/(default)/documents/users/"
    private static var pending: Task<Void, Never>?
    private static var applying = false
    /// Time of the last local edit or the last copy taken from the cloud.
    private static var stamp: Double {
        get { UserDefaults.standard.double(forKey: "sync.stamp") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.stamp") }
    }
    private static var user: String { Store.shared.data.prefs.profile?.email ?? "" }

    /// Called on every local edit; pushes at most every 30 seconds.
    static func changed() {
        guard !applying, !Store.isTesting else { return }
        stamp = Date().timeIntervalSince1970
        guard pending == nil else { return }
        pending = Task { try? await Task.sleep(for: .seconds(30)); pending = nil; await push() }
    }
    /// Takes the cloud copy when it is newer than anything on this device.
    static func pull() async {
        guard !Store.isTesting, ready(), !user.isEmpty, let (d, code) = try? await request("GET") else { return }
        if code == 404 { await push(); return }
        guard code == 200, let (mod, json) = parse(d), mod > stamp,
              var remote = try? Store.decoder.decode(AppData.self, from: Data(json.utf8)) else { return }
        remote.prefs.profile = Store.shared.data.prefs.profile
        applying = true; Store.shared.data = remote; applying = false
        stamp = mod
    }
    static func push() async {
        guard ready(), !user.isEmpty, let d = try? Store.encoder.encode(Store.shared.data) else { return }
        _ = try? await request("PATCH", ["fields": ["data": ["stringValue": String(decoding: d, as: UTF8.self)], "modified": ["doubleValue": stamp]]])
    }
    nonisolated static func parse(_ d: Data) -> (Double, String)? {
        guard let f = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["fields"] as? [String: Any],
              let json = (f["data"] as? [String: Any])?["stringValue"] as? String,
              let m = f["modified"] as? [String: Any], let mod = m["doubleValue"] as? Double ?? (m["integerValue"] as? String).flatMap(Double.init) else { return nil }
        return (mod, json)
    }
    private static func request(_ method: String, _ body: [String: Any]? = nil) async throws -> (Data, Int) {
        var r = URLRequest(url: URL(string: base + (user.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!)
        r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

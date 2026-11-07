import SwiftUI
import Network
import CryptoKit

// Google Calendar over its REST API. build.sh generates GoogleClient from google-client.local,
// which stays out of the public repo. Google treats a desktop app's secret as non-confidential.

struct GEvent: Hashable {
    var id: String, cal: String, title: String, start: Date, end: Date, allDay: Bool
    var key: String { "g:\(cal):\(id)" }
}
struct GCal: Identifiable, Hashable { var id: String, title: String, color: Color, writable: Bool, primary: Bool, selected: Bool }

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

struct GoogleError: LocalizedError { var code: Int, text: String; var errorDescription: String? { text } }

@Observable @MainActor final class GoogleCalendar {
    static let shared = GoogleCalendar()
    var connected = !Store.isTesting && !Keychain.get("google.refresh").isEmpty
    var status = ""
    var calendars: [GCal] = []
    var events: [GEvent] = []
    var access = ""
    var expiry = Date.distantPast
    private var looping = false
    private var creating = Set<UUID>()
    private var dirty = Set<UUID>()   // local edits Google hasn't confirmed
    private var touched = Set<UUID>() // edited since this sync began, so its fetch may be stale
    private let api = "https://www.googleapis.com/calendar/v3/"
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    // MARK: Sign-in

    nonisolated static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func random() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "") }
    private func form(_ f: [String: String]) -> Data {
        var ok = CharacterSet.alphanumerics; ok.insert(charactersIn: "-._~")
        return Data(f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&").utf8)
    }

    func connect() async {
        let id = GoogleClient.id
        guard let server = try? Loopback() else { status = "Couldn't open a local port for sign-in."; return }
        status = "Finish signing in with Google in your browser…"
        let verifier = random(), state = random()
        final class Port: @unchecked Sendable { var value: UInt16 = 0 }
        let port = Port()
        let got = await server.wait { p in
            port.value = p
            var u = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            u.queryItems = [.init(name: "client_id", value: id), .init(name: "redirect_uri", value: "http://127.0.0.1:\(p)/"), .init(name: "response_type", value: "code"),
                            .init(name: "scope", value: "openid email profile https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly"),
                            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"), .init(name: "state", value: state),
                            .init(name: "code_challenge", value: GoogleCalendar.challenge(verifier)), .init(name: "code_challenge_method", value: "S256")]
            DispatchQueue.main.async { NSWorkspace.shared.open(u.url!) }
        }
        guard let got else { status = "Sign-in timed out. Try again."; return }
        guard got["state"] == state, let code = got["code"] else { status = "Google sign-in didn't finish: \(got["error"] ?? "state mismatch")."; return }
        do {
            let j = try await tokenCall(["code": code, "client_id": id, "client_secret": GoogleClient.secret, "code_verifier": verifier,
                                         "grant_type": "authorization_code", "redirect_uri": "http://127.0.0.1:\(port.value)/"])
            guard let refresh = j["refresh_token"] as? String else { status = "Google didn't return a refresh token. Try again."; return }
            Keychain.set("google.refresh", refresh)
            connected = true
            if let u = URL(string: "https://openidconnect.googleapis.com/v1/userinfo") {
                var r = URLRequest(url: u); r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                let me = ((try? JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: r).0)) as? [String: Any]) ?? [:]
                Store.shared.data.prefs.profile = Profile(name: me["name"] as? String ?? "", email: me["email"] as? String ?? "")
            }
            start()
        } catch { status = error.localizedDescription }
    }

    func signOut() { disconnect(); Store.shared.data.prefs.profile = nil }
    func disconnect() {
        let refresh = Keychain.get("google.refresh")
        if !refresh.isEmpty, let u = URL(string: "https://oauth2.googleapis.com/revoke") {
            var r = URLRequest(url: u); r.httpMethod = "POST"; r.httpBody = form(["token": refresh])
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            Task { _ = try? await URLSession.shared.data(for: r) }
        }
        Keychain.set("google.refresh", "")
        connected = false; access = ""; expiry = .distantPast; calendars = []; events = []; status = ""
        if Store.shared.data.prefs.calendarID?.hasPrefix("google:") == true { Store.shared.data.prefs.calendarID = nil }
    }

    private func tokenCall(_ f: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: tokenURL); r.httpMethod = "POST"; r.httpBody = form(f)
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let http = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(http) else { throw GoogleError(code: http, text: j["error_description"] as? String ?? j["error"] as? String ?? "Google returned \(http).") }
        if let t = j["access_token"] as? String { access = t; expiry = Date().addingTimeInterval((j["expires_in"] as? Double ?? 3600) - 60) }
        return j
    }

    private func token() async throws -> String {
        if !access.isEmpty, expiry > Date() { return access }
        do {
            _ = try await tokenCall(["refresh_token": Keychain.get("google.refresh"), "client_id": GoogleClient.id,
                                     "client_secret": GoogleClient.secret, "grant_type": "refresh_token"])
            return access
        } catch let e as GoogleError where e.code == 400 || e.code == 401 {
            connected = false
            status = "Google sign-in expired. Connect again."
            throw e
        }
    }

    private func call(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        var r = URLRequest(url: URL(string: api + path)!); r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let http = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(http) else {
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            throw GoogleError(code: http, text: (j?["error"] as? [String: Any])?["message"] as? String ?? "Google returned \(http).")
        }
        return d
    }
    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    // MARK: Parsing

    nonisolated static func parseCalendars(_ d: Data) -> [GCal] {
        let items = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let hex = UInt32((c["backgroundColor"] as? String ?? "#38BDF8").dropFirst(), radix: 16) ?? 0x38BDF8
            let role = c["accessRole"] as? String ?? ""
            return GCal(id: id, title: c["summaryOverride"] as? String ?? c["summary"] as? String ?? id, color: dyn(hex, hex),
                        writable: role == "owner" || role == "writer", primary: c["primary"] as? Bool ?? false, selected: c["selected"] as? Bool ?? false)
        }
    }
    nonisolated static func parseEvents(_ d: Data, cal: String) -> [GEvent] {
        let items = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        func when(_ o: Any?) -> (Date, Bool)? {
            guard let o = o as? [String: Any] else { return nil }
            if let s = o["dateTime"] as? String, let t = iso.date(from: s) ?? frac.date(from: s) { return (t, false) }
            if let s = o["date"] as? String, let t = day.date(from: s) { return (t, true) }
            return nil
        }
        return items.compactMap { e in
            guard let id = e["id"] as? String, e["status"] as? String != "cancelled", let a = when(e["start"]), let b = when(e["end"]) else { return nil }
            return GEvent(id: id, cal: cal, title: e["summary"] as? String ?? "Busy", start: a.0, end: b.0, allDay: a.1)
        }
    }
    /// Calendar ids can hold colons; event ids can't.
    nonisolated static func split(_ key: String) -> (cal: String, id: String)? {
        guard key.hasPrefix("g:"), let c = key.lastIndex(of: ":"), c > key.index(key.startIndex, offsetBy: 1) else { return nil }
        return (String(key[key.index(key.startIndex, offsetBy: 2)..<c]), String(key[key.index(after: c)...]))
    }

    // MARK: Sync

    func start() {
        guard !looping else { return }
        looping = true
        Task { while true { await sync(); try? await Task.sleep(for: .seconds(300)) } }
    }

    func sync() async {
        guard connected else { return }
        touched = []
        for id in dirty where !creating.contains(id) {
            if let b = Store.shared.data.blocks.first(where: { $0.id == id }) { push(b) } else { dirty.remove(id) }
        }
        do {
            calendars = Self.parseCalendars(try await call("GET", "users/me/calendarList?minAccessRole=reader"))
            // ponytail: fetches a fixed window and one page per calendar; widen the window or follow nextPageToken if someone plans further out.
            let from = Date().adding(days: -30), to = Date().adding(days: 120)
            let f = ISO8601DateFormatter()
            var all: [GEvent] = [], fetched = Set<String>()
            for c in calendars where c.selected {
                let q = "calendars/\(enc(c.id))/events?singleEvents=true&orderBy=startTime&maxResults=2500&timeMin=\(enc(f.string(from: from)))&timeMax=\(enc(f.string(from: to)))"
                if let d = try? await call("GET", q) { all += Self.parseEvents(d, cal: c.id); fetched.insert(c.id) }
            }
            events = all
            reconcile(fetched: fetched, from: from, to: to)
            status = "Connected · \(calendars.count) calendar\(calendars.count == 1 ? "" : "s")"
        } catch { if connected { status = error.localizedDescription } }
    }

    /// Changes made in Google flow back into blocks, the same way Apple's do.
    func reconcile(fetched: Set<String>, from: Date, to: Date) {
        let s = Store.shared
        let byKey = Dictionary(events.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for b in s.data.blocks {
            guard let key = b.eventID, let p = Self.split(key), fetched.contains(p.cal), b.start >= from, b.start < to,
                  !dirty.contains(b.id), !touched.contains(b.id), let i = s.data.blocks.firstIndex(where: { $0.id == b.id }) else { continue }
            if let e = byKey[key] {
                if e.start != b.start || e.end != b.end || e.title != b.title {
                    s.data.blocks[i].start = e.start; s.data.blocks[i].end = e.end; s.data.blocks[i].title = e.title
                }
            } else { s.data.blocks.remove(at: i) } // ponytail: an event moved outside the fetch window also lands here; it's still safe in Google.
        }
    }

    // MARK: Writing

    var isTarget: Bool {
        guard connected else { return false }
        let id = Store.shared.data.prefs.calendarID
        return id?.hasPrefix("google:") == true || (id == nil && !CalendarService.shared.granted)
    }
    private var targetCal: String {
        if let id = Store.shared.data.prefs.calendarID, id.hasPrefix("google:") { return String(id.dropFirst(7)) }
        return calendars.first(where: \.primary)?.id ?? "primary"
    }
    private func body(_ b: Block) -> [String: Any] {
        let f = ISO8601DateFormatter()
        return ["summary": b.title, "start": ["dateTime": f.string(from: b.start)], "end": ["dateTime": f.string(from: b.end)]]
    }

    func push(_ b: Block) {
        guard connected else { return }
        dirty.insert(b.id); touched.insert(b.id)
        guard !creating.contains(b.id) else { return }
        let target = b.eventID == nil ? targetCal : nil
        if target != nil { creating.insert(b.id) }
        Task {
            defer { touched.insert(b.id) }
            do {
                if let target {
                    defer { creating.remove(b.id) }
                    let d = try await call("POST", "calendars/\(enc(target))/events", json: body(b))
                    guard let id = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["id"] as? String else { return }
                    let s = Store.shared
                    if let i = s.data.blocks.firstIndex(where: { $0.id == b.id }) {
                        s.data.blocks[i].eventID = "g:\(target):\(id)"
                        let cur = s.data.blocks[i]
                        dirty.remove(b.id)
                        creating.remove(b.id)
                        if cur.title != b.title || cur.start != b.start || cur.end != b.end { push(cur) }
                    } else { // deleted while the create was in flight
                        dirty.remove(b.id)
                        _ = try? await call("DELETE", "calendars/\(enc(target))/events/\(enc(id))")
                    }
                } else if let key = b.eventID, let p = Self.split(key) {
                    _ = try await call("PATCH", "calendars/\(enc(p.cal))/events/\(enc(p.id))", json: body(b))
                    dirty.remove(b.id)
                }
            } catch { status = error.localizedDescription }
        }
    }

    func remove(_ key: String) {
        guard connected, let p = Self.split(key) else { return }
        events.removeAll { $0.key == key }
        Task {
            do { _ = try await call("DELETE", "calendars/\(enc(p.cal))/events/\(enc(p.id))") }
            catch let e as GoogleError where e.code == 404 || e.code == 410 {}
            catch { status = error.localizedDescription }
        }
    }
}

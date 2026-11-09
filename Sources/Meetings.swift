import SwiftUI

// Meeting notes from Granola and Wispr Flow through their official remote MCP servers.
// Sign-in is OAuth 2.1 with dynamic client registration and PKCE; no API keys.

@Observable @MainActor final class MeetingLink: Identifiable {
    let id: String, name: String, server: String, auth: String, scope: String
    var status = ""
    var recent = ""
    @ObservationIgnored private var access = ""
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var fetched = Date.distantPast
    @ObservationIgnored private var session = ""
    var connected: Bool { !Store.isTesting && !Keychain.get("mcp.\(id).client").isEmpty }

    init(_ id: String, _ name: String, server: String, auth: String, scope: String) {
        (self.id, self.name, self.server, self.auth, self.scope) = (id, name, server, auth, scope)
    }
    static let granola = MeetingLink("granola", "Granola", server: "https://mcp.granola.ai/mcp", auth: "https://mcp-auth.granola.ai", scope: "mcp")
    static let wispr = MeetingLink("wispr", "Wispr Flow", server: "https://api.wisprflow.ai/connect/mcp", auth: "https://mcp-auth.wisprflow.com", scope: "openid offline_access")
    static let all = [granola, wispr]
    /// Refreshes every connected source at most every 30 minutes; called before Coach replies.
    static func refresh() async { for l in all where l.connected && l.fetched < Date().addingTimeInterval(-1800) { await l.fetch() } }

    private func post(_ url: String, _ form: [String: String]? = nil, json: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = "POST"; r.timeoutInterval = 120
        if let form {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").utf8)
        } else {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: json ?? [:])
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        return (d, resp as! HTTPURLResponse)
    }
    private func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
    private func random() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "") }

    func connect() async {
        guard let lb = try? Loopback() else { status = "Couldn't open a local port for sign-in."; return }
        status = "Finish signing in to \(name) in your browser…"
        let verifier = random(), state = random()
        final class Box: @unchecked Sendable { var port: UInt16 = 0, client = "" }
        let box = Box()
        let (auth, scope, name) = (auth, scope, name)
        let got = await lb.wait { p in
            box.port = p
            Task { @MainActor in
                let redirect = "http://127.0.0.1:\(p)/"
                guard let (d, _) = try? await self.post(auth + "/oauth2/register", json: ["client_name": "Bearing", "redirect_uris": [redirect],
                        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"]),
                      let cid = self.obj(d)["client_id"] as? String else { self.status = "\(name) didn't accept the sign-in request."; return }
                box.client = cid
                var u = URLComponents(string: auth + "/oauth2/authorize")!
                u.queryItems = [.init(name: "client_id", value: cid), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                                .init(name: "scope", value: scope), .init(name: "state", value: state), .init(name: "resource", value: self.server),
                                .init(name: "code_challenge", value: GoogleCalendar.challenge(verifier)), .init(name: "code_challenge_method", value: "S256")]
                NSWorkspace.shared.open(u.url!)
            }
        }
        guard let got, got["state"] == state, let code = got["code"] else { status = "\(name) sign-in didn't finish."; return }
        do {
            try await token(["grant_type": "authorization_code", "code": code, "client_id": box.client, "code_verifier": verifier,
                             "redirect_uri": "http://127.0.0.1:\(box.port)/", "resource": server])
            Keychain.set("mcp.\(id).client", box.client)
            await fetch()
        } catch { status = error.localizedDescription }
    }
    func disconnect() { ["client", "refresh"].forEach { Keychain.set("mcp.\(id).\($0)", "") }; access = ""; recent = ""; status = "" }

    private func token(_ f: [String: String]) async throws {
        let (d, r) = try await post(auth + "/oauth2/token", f), j = obj(d)
        guard r.statusCode == 200, let t = j["access_token"] as? String else { throw AIError(errorDescription: "\(name) sign-in expired. Connect again.") }
        access = t; expiry = Date().addingTimeInterval((j["expires_in"] as? Double ?? 3600) - 60)
        if let rt = j["refresh_token"] as? String { Keychain.set("mcp.\(id).refresh", rt) }
    }
    /// One JSON-RPC call over streamable HTTP; replies may be plain JSON or server-sent events.
    private func rpc(_ method: String, _ params: [String: Any]? = nil) async throws -> [String: Any] {
        if access.isEmpty || expiry < Date() {
            let rt = Keychain.get("mcp.\(id).refresh")
            guard !rt.isEmpty else { throw AIError(errorDescription: "\(name) sign-in expired. Connect again.") }
            try await token(["grant_type": "refresh_token", "refresh_token": rt, "client_id": Keychain.get("mcp.\(id).client"), "resource": server])
        }
        var r = URLRequest(url: URL(string: server)!); r.httpMethod = "POST"; r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if !session.isEmpty { r.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !method.hasPrefix("notifications/") { body["id"] = 1 }
        if let params { body["params"] = params }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let h = resp as! HTTPURLResponse
        if let s = h.value(forHTTPHeaderField: "Mcp-Session-Id") { session = s }
        guard (200..<300).contains(h.statusCode) else { throw AIError(errorDescription: "\(name) returned \(h.statusCode).") }
        return MeetingLink.reply(String(decoding: d, as: UTF8.self))
    }
    nonisolated static func reply(_ s: String) -> [String: Any] {
        let parts = s.hasPrefix("{") ? [s] : s.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) }
        for p in parts.reversed() { if let o = (try? JSONSerialization.jsonObject(with: Data(p.utf8))) as? [String: Any], o["id"] != nil { return o["result"] as? [String: Any] ?? [:] } }
        return [:]
    }

    /// Asks the server for the last week's meetings and keeps the text for Coach.
    func fetch() async {
        do {
            session = ""
            _ = try await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Bearing", "version": "1"]])
            _ = try? await rpc("notifications/initialized")
            let tools = try await rpc("tools/list")["tools"] as? [[String: Any]] ?? []
            // ponytail: picks the tool by name; update the preference list if a server renames its tools.
            let prefs = ["query_granola_meetings", "search_meetings", "list_meetings", "get_meetings"]
            guard let tool = prefs.lazy.compactMap({ n in tools.first { $0["name"] as? String == n } }).first
                    ?? tools.first(where: { ($0["name"] as? String ?? "").contains("meeting") }) else { status = "\(name) has no meeting tools."; return }
            let props = ((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            var args: [String: Any] = [:]
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!.formatted(.iso8601.year().month().day())
            for k in props.keys {
                if ["query", "question", "q"].contains(k) { args[k] = "My meetings in the last 7 days: for each, the date, title, key decisions, and action items for me with deadlines." }
                if ["from_date", "start_date", "after", "since", "created_after"].contains(k) { args[k] = since }
            }
            let res = try await rpc("tools/call", ["name": tool["name"]!, "arguments": args])
            let text = (res["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            recent = String(text.prefix(4000)); fetched = Date()
            status = recent.isEmpty ? "Connected, no recent meetings" : "Connected · updated \(Date().clock)"
        } catch { status = error.localizedDescription }
    }
}

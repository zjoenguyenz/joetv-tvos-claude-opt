// JoeYtPoMinter — the TV ("living room") BotGuard PO-token
// minter, ported from SmartTube's MediaServiceCore @ 09a1e13
// (TvPoTokenProvider.kt, generators/TvPoTokenWebView4.kt,
// assets/potokennp2/po_token2.html; the page itself is
// JoeTV/po_token.html).
//
// RESERVE ONLY (claude/po-minter-core): nothing in the app
// calls this yet. Attaching the token to /player or to stream
// URLs is the resolver's job and is wired separately.
//
// Shape:
//   - All HTTP is native (URLSession). The web view loads a
//     LOCAL page in the MinterLockdown navigation mode (every
//     navigation and every subresource load refused), so it
//     performs zero network I/O.
//   - The web view is an offscreen JoeWebHostView (never in a
//     window), touched only on the main actor.
//   - Every failure returns nil. Page-stage (WebView/JS)
//     failures also mark the minter unsupported for the rest
//     of the process — no retry storms.
//   - The cache (token + living-room id + visitorData + expiry)
//     is in memory only. Nothing is persisted.
//   - Logging: step codes, the winning challenge source, token
//     LENGTH and TTL only — never the token, the id, a key or a
//     response body.

import Foundation

struct JoeYtPoToken: Sendable {
    let token: String
    let livingRoomId: String
    let visitorData: String
    let expiry: Date
}

final class JoeYtPoMinter: @unchecked Sendable {
    // @unchecked: all mutable state below is guarded by `lock`;
    // the page object is main-actor isolated and only touched
    // from main-actor code.

    static let shared = JoeYtPoMinter()

    // MARK: Constants (spec §5)

    /// UA for the minter page (navigator.userAgent) and for
    /// EVERY BotGuard service request (att/get, GenerateIT,
    /// interpreter download, homepage). Verbatim from
    /// TvPoTokenWebView4.USER_AGENT — including the missing
    /// space before "(KHTML".
    static let botGuardUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36(KHTML, like Gecko)"

    /// The public API key BotGuard's own requests carry.
    /// LEADER: fill the real public value from SmartTube's
    /// TvPoTokenWebView4.kt (companion `GOOGLE_API_KEY`) before
    /// building. While this placeholder is in place the
    /// minter fails CLOSED (nil) at GenerateIT.
    static let botGuardAPIKey = "FILL_FROM_SMARTTUBE_TvPoTokenWebView4_GOOGLE_API_KEY"

    /// The app's existing /tv fetch convention (the same
    /// Tizen 6.5 UA JoeYtResolver.tvScrapeUA and
    /// JoeYtIdentity use for www.youtube.com/tv; duplicated
    /// here because that constant is private to the resolver).
    static let tvPageUserAgent =
        "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36"

    static let resetThrottle: TimeInterval = 60
    static let expiryMargin: TimeInterval = 600
    static let pageInitBudget: TimeInterval = 20
    static let pageOperationBudget: TimeInterval = 10
    static let networkTimeout: TimeInterval = 15
    static let pageBaseURL = "https://www.youtube.com"

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var cached: JoeYtPoToken?
    private var inflight: Task<JoeYtPoToken?, Never>?
    private var unsupported = false
    private var lastReset: Date?
    private var page: JoeYtPoPage?
    /// Bumped by every reset so a mint that started before a
    /// reset cannot write its result into the fresh cache.
    private var generation = 0

    private init() {}

    // MARK: Public API (spec §6)

    /// Cached token if unexpired; otherwise a full mint. nil
    /// on ANY failure. Concurrent callers share one mint.
    func sessionToken() async -> JoeYtPoToken? {
        let step: SessionStep = lock.withLock {
            if unsupported { return .none }
            if let cached, cached.expiry > Date() { return .ready(cached) }
            if let inflight { return .wait(inflight) }
            let gen = generation
            let task = Task<JoeYtPoToken?, Never> {
                await self.mintAndStore(generation: gen)
            }
            inflight = task
            return .wait(task)
        }
        switch step {
        case .none: return nil
        case .ready(let token): return token
        case .wait(let task): return await task.value
        }
    }

    private enum SessionStep {
        case none
        case ready(JoeYtPoToken)
        case wait(Task<JoeYtPoToken?, Never>)
    }

    /// Failure-driven reset (60 s throttled). Returns true if
    /// the cache was cleared. Mirrors TvPoTokenProvider.reset():
    /// the cached token AND the page (generator) are dropped.
    @discardableResult
    func resetCache() -> Bool {
        let outcome: (cleared: Bool, page: JoeYtPoPage?) = lock.withLock {
            let now = Date()
            if let lastReset, now.timeIntervalSince(lastReset) < Self.resetThrottle {
                return (false, nil)
            }
            lastReset = now
            generation += 1
            cached = nil
            inflight = nil
            let old = page
            page = nil
            return (true, old)
        }
        guard outcome.cleared else {
            DiagLog.write("YT-POT", "reset: throttled (<60s)")
            return false
        }
        if let old = outcome.page {
            Task { @MainActor in old.teardown() }
        }
        DiagLog.write("YT-POT", "reset: cache cleared")
        return true
    }

    // MARK: Mint (spec §3)

    private func mintAndStore(generation gen: Int) async -> JoeYtPoToken? {
        let result = await mint()
        lock.withLock {
            if generation == gen {
                inflight = nil
                if let result { cached = result }
            }
        }
        return result
    }

    private func markUnsupported(_ code: String) {
        let old: JoeYtPoPage? = lock.withLock {
            unsupported = true
            cached = nil
            let p = page
            page = nil
            return p
        }
        if let old { Task { @MainActor in old.teardown() } }
        DiagLog.write("YT-POT", "UNSUPPORTED for this process (\(code))")
    }

    private func mint() async -> JoeYtPoToken? {
        let t0 = Date()
        // 1. Support gate.
        guard JoeWebBridge.webKitAvailable() else {
            markUnsupported("S1-webkit-unavailable")
            return nil
        }
        // 2. tv_config → challengeRequestKey (fresh every mint).
        guard let tvConfig = await getText(
                "https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl",
                headers: ["User-Agent": Self.tvPageUserAgent]),
              let requestKey = Self.capture(#""challengeRequestKey":"(.*?)""#, in: tvConfig) else {
            DiagLog.write("YT-POT", "S2 fail: tv_config/challengeRequestKey")
            return nil
        }
        // 3. /tv → living-room id + visitorData (same response).
        guard let tvPage = await getText(Self.pageBaseURL + "/tv",
                                         headers: ["User-Agent": Self.tvPageUserAgent]),
              let rawId = Self.capture(#""LIVING_ROOM_PO_TOKEN_ID":"(.*?)""#, in: tvPage),
              let visitorData = Self.capture(#""visitorData":"(.*?)""#, in: tvPage) else {
            DiagLog.write("YT-POT", "S3 fail: /tv LIVING_ROOM_PO_TOKEN_ID/visitorData")
            return nil
        }
        let livingRoomId = rawId.replacingOccurrences(of: "\\u003d", with: "=")

        // 4–7: generator init, ≤ 20 s.
        let initResult: InitResult? = await Self.withDeadline(Self.pageInitBudget) {
            await self.initGenerator(requestKey: requestKey)
        }
        guard let initResult else {
            // Like SmartTube's init timeout (a PoTokenException,
            // not a BadWebViewException): nil, but the minter
            // stays supported — the budget also covers network.
            DiagLog.write("YT-POT", "S4-7 fail: generator init over \(Int(Self.pageInitBudget))s budget")
            return nil
        }
        guard case .ready(let page, ttl: let ttl) = initResult else {
            if case .hardFailure(let code) = initResult { markUnsupported(code) }
            return nil
        }

        // 8. Session token for the living-room id, ≤ 10 s.
        let bytes = Array(livingRoomId.utf8)
        let tokenBytes: String? = await Self.withDeadline(Self.pageOperationBudget) {
            await page.mint(identifier: bytes)
        } ?? nil
        guard let tokenBytes, let token = Self.potFromByteList(tokenBytes) else {
            DiagLog.write("YT-POT", "S8 fail: __poMint")
            await page.teardown()
            markUnsupported("S8-mint")
            return nil
        }
        let expiry = Date().addingTimeInterval(TimeInterval(ttl) - Self.expiryMargin)
        lock.withLock { self.page = page }
        DiagLog.write("YT-POT", "S8 OK: token len \(token.count), ttl \(ttl)s, total \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        return JoeYtPoToken(token: token, livingRoomId: livingRoomId,
                            visitorData: visitorData, expiry: expiry)
    }

    private enum InitResult: Sendable {
        case ready(JoeYtPoPage, ttl: Int)
        case softFailure            // network/server: nil, minter stays supported
        case hardFailure(String)    // WebView/JS: nil + unsupported
    }

    private func initGenerator(requestKey: String) async -> InitResult {
        // 4. Challenge: att/get (TV) → homepage → att/get (WEB).
        guard let challenge = await fetchChallenge() else {
            DiagLog.write("YT-POT", "S4 fail: no challenge from any source")
            return .softFailure
        }
        DiagLog.write("YT-POT", "S4 OK: challenge source \(challenge.source)")

        // 5. Page: load, optional ytcfg, run BotGuard.
        guard let html = Self.loadPageAsset() else {
            DiagLog.write("YT-POT", "S5 fail: po_token.html missing from bundle")
            return .hardFailure("S5-asset")
        }
        let page = await JoeYtPoPage.make()
        guard await page.load(html: html, baseURL: Self.pageBaseURL,
                              userAgent: Self.botGuardUserAgent,
                              budget: Self.pageOperationBudget) else {
            DiagLog.write("YT-POT", "S5 fail: page load")
            await page.teardown()
            return .hardFailure("S5-load")
        }
        if let ytcfg = challenge.ytcfg {
            // Same injection as SmartTube (`yt = { config_: <ytcfg> }`),
            // guarded so a malformed ytcfg cannot kill the page.
            let r = await page.evaluate(
                "(function(){try{yt={config_:\(ytcfg)};return 'ok'}catch(e){return 'err'}})()",
                budget: Self.pageOperationBudget)
            DiagLog.write("YT-POT", "S5 ytcfg install: \(r ?? "nil")")
        }
        guard let challengeLiteral = Self.jsStringLiteral(challenge.json) else {
            await page.teardown()
            return .hardFailure("S5-encode")
        }
        guard let botguardResponse = await page.runBotGuard(
                challengeLiteral: challengeLiteral, budget: Self.pageOperationBudget) else {
            DiagLog.write("YT-POT", "S5 fail: runBotGuard")
            await page.teardown()
            return .hardFailure("S5-botguard")
        }
        DiagLog.write("YT-POT", "S5 OK: botguardResponse len \(botguardResponse.count)")

        // 6. GenerateIT → [integrityToken, ttl].
        guard let it = await generateIT(requestKey: requestKey,
                                        botguardResponse: botguardResponse) else {
            await page.teardown()
            return .softFailure
        }
        DiagLog.write("YT-POT", "S6 OK: integrity token len \(it.token.count), ttl \(it.ttl)s")

        // 7. Install the minter callback.
        guard let itBytes = Self.decodeYouTubeBase64(it.token) else {
            DiagLog.write("YT-POT", "S7 fail: integrity token not base64")
            await page.teardown()
            return .softFailure
        }
        guard await page.setMinter(integrityTokenBytes: itBytes,
                                   budget: Self.pageOperationBudget) else {
            DiagLog.write("YT-POT", "S7 fail: __poSetMinter")
            await page.teardown()
            return .hardFailure("S7-setMinter")
        }
        return .ready(page, ttl: it.ttl)
    }

    // MARK: Step 4 — challenge sources

    private struct Challenge: Sendable {
        let json: String        // the challenge-data JSON the page parses
        let ytcfg: String?      // homepage only
        let source: String      // log code
    }

    private func fetchChallenge() async -> Challenge? {
        let tv = JoeYtClientSpec.tvSamsung
        if let json = await attGet(clientName: tv.clientName, clientVersion: tv.clientVersion) {
            return Challenge(json: json, ytcfg: nil, source: "att-tv")
        }
        if let home = await homepageChallenge() {
            return home
        }
        // SmartTube's AppClient.WEB (Constants.kt CLIENTS.WEB).
        if let json = await attGet(clientName: "WEB", clientVersion: "2.20260907.06.00") {
            return Challenge(json: json, ytcfg: nil, source: "att-web")
        }
        return nil
    }

    private func attGet(clientName: String, clientVersion: String) async -> String? {
        let body: [String: Any] = [
            "context": ["client": ["clientName": clientName, "clientVersion": clientVersion]],
            "engagementType": "ENGAGEMENT_TYPE_UNBOUND",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        // SmartTube overrides Content-Type to application/json
        // for this one call (getLegacyChallengeData).
        var headers = Self.botGuardHeaders
        headers["Content-Type"] = "application/json"
        guard let (status, text) = await post(
                "https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false",
                body: data, headers: headers) else {
            DiagLog.write("YT-POT", "S4 att/get \(clientName): network error")
            return nil
        }
        guard status == 200 else {
            DiagLog.write("YT-POT", "S4 att/get \(clientName): HTTP \(status)")
            return nil
        }
        return await buildChallengeJSON(fromBgChallengeContainer: text)
    }

    private func homepageChallenge() async -> Challenge? {
        var headers = Self.botGuardHeaders
        headers["Accept"] = "*/*"
        headers["Accept-Language"] = "en-US,en;q=0.7"
        guard let html = await getText(Self.pageBaseURL, headers: headers) else {
            DiagLog.write("YT-POT", "S4 homepage: fetch failed")
            return nil
        }
        let ytcfg = Self.capture(#"ytcfg\.set\((\{.+?\})\);"#, in: html, dotAll: true)
        if ytcfg == nil {
            DiagLog.write("YT-POT", "S4 homepage: no ytcfg (EVENT_ID missing)")
        }
        guard let atn = Self.capture(#"window\.ytAtN\(\s*(\{[\s\S]*?\})\s*\)"#, in: html),
              let loose = Self.parseLooseJSON(atn),
              let raw = loose["R"],
              raw.contains("bgChallenge"), raw.contains("program"),
              raw.contains("interpreterUrl") else {
            DiagLog.write("YT-POT", "S4 homepage: no usable ytAtN payload")
            return nil
        }
        guard let json = await buildChallengeJSON(fromBgChallengeContainer: raw) else {
            return nil
        }
        return Challenge(json: json, ytcfg: ytcfg, source: "homepage")
    }

    /// parseDescrambledChallengeData: read bgChallenge, download
    /// the interpreter natively, inline it.
    private func buildChallengeJSON(fromBgChallengeContainer text: String) async -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let bg = root["bgChallenge"] as? [String: Any],
              let interpreterHash = bg["interpreterHash"] as? String,
              let program = bg["program"] as? String,
              let globalName = bg["globalName"] as? String,
              let urlBox = bg["interpreterUrl"] as? [String: Any],
              let wrappedURL = urlBox["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"] as? String else {
            DiagLog.write("YT-POT", "S4 challenge: bgChallenge fields missing")
            return nil
        }
        let blob = bg["clientExperimentsStateBlob"] as? String ?? ""
        let interpreterURL = wrappedURL.hasPrefix("//") ? "https:" + wrappedURL : wrappedURL
        guard let script = await getText(interpreterURL,
                                         headers: ["User-Agent": Self.botGuardUserAgent]),
              !script.isEmpty else {
            DiagLog.write("YT-POT", "S4 challenge: interpreter download failed")
            return nil
        }
        let challenge: [String: Any] = [
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": script,
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": wrappedURL,
            ],
            "interpreterHash": interpreterHash,
            "program": program,
            "globalName": globalName,
            "clientExperimentsStateBlob": blob,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: challenge) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Step 6 — GenerateIT

    private func generateIT(requestKey: String,
                            botguardResponse: String) async -> (token: String, ttl: Int)? {
        guard let body = try? JSONSerialization.data(withJSONObject: [requestKey, botguardResponse]) else {
            return nil
        }
        guard let (status, text) = await post("https://www.youtube.com/api/jnn/v1/GenerateIT",
                                              body: body, headers: Self.botGuardHeaders) else {
            DiagLog.write("YT-POT", "S6 fail: GenerateIT network error")
            return nil
        }
        guard status == 200 else {
            DiagLog.write("YT-POT", "S6 fail: GenerateIT HTTP \(status)")
            return nil
        }
        guard let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any],
              array.count >= 2,
              let token = array[0] as? String, !token.isEmpty else {
            DiagLog.write("YT-POT", "S6 fail: GenerateIT response shape")
            return nil
        }
        // The TTL is whatever the server states — never hardcoded.
        let ttl: Int
        if let n = array[1] as? NSNumber {
            ttl = n.intValue
        } else if let s = array[1] as? String, let n = Int(s) {
            ttl = n
        } else {
            DiagLog.write("YT-POT", "S6 fail: GenerateIT TTL missing")
            return nil
        }
        return (token, ttl)
    }

    // MARK: Native transport

    static var botGuardHeaders: [String: String] {
        [
            "User-Agent": botGuardUserAgent,
            "Accept": "application/json",
            "Content-Type": "application/json+protobuf",
            "x-goog-api-key": botGuardAPIKey,
            "x-user-agent": "grpc-web-javascript/0.1",
        ]
    }

    private func getText(_ urlString: String, headers: [String: String]) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.networkTimeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func post(_ urlString: String, body: Data,
                      headers: [String: String]) async -> (Int, String)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.networkTimeout
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    // MARK: Helpers (pure)

    static func loadPageAsset() -> String? {
        guard let url = Bundle.main.url(forResource: "po_token", withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func capture(_ pattern: String, in text: String, dotAll: Bool = false) -> String? {
        guard let regex = try? NSRegularExpression(
                pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// A JSON string literal is a valid JavaScript string
    /// literal except for raw U+2028/U+2029, escaped here.
    static func jsStringLiteral(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else { return nil }
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// YouTube's base64 variant (JavaScriptUtil.base64ToByteString):
    /// '-'→'+', '_'→'/', '.'→'=', then standard decoding.
    static func decodeYouTubeBase64(_ s: String) -> [UInt8]? {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
        let rem = b.count % 4
        if rem != 0 { b += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b) else { return nil }
        return [UInt8](data)
    }

    /// "97,98,99" → base64 URL-safe ('+'→'-', '/'→'_'),
    /// padding retained (JavaScriptUtil.u8ToBase64).
    static func potFromByteList(_ list: String) -> String? {
        let parts = list.split(separator: ",")
        guard !parts.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(parts.count)
        for p in parts {
            guard let v = UInt8(p.trimmingCharacters(in: .whitespaces)) else { return nil }
            bytes.append(v)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func uint8ArrayLiteral(_ bytes: [UInt8]) -> String {
        "new Uint8Array([" + bytes.map(String.init).joined(separator: ",") + "])"
    }

    /// Port of JavaScriptUtil.parseLooseJSON (BgUtils v4.0.3,
    /// MIT): the ytAtN payload is a JS object literal, not
    /// strict JSON. Returns every top-level value as a string
    /// (non-string values re-serialised as JSON).
    static func parseLooseJSON(_ loose: String) -> [String: String]? {
        // \xHH escapes → the character.
        var s = loose
        if let hex = try? NSRegularExpression(pattern: #"\\x([0-9A-Fa-f]{2})"#) {
            var out = ""
            var last = s.startIndex
            for m in hex.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) {
                guard let whole = Range(m.range, in: s), let g = Range(m.range(at: 1), in: s),
                      let code = UInt32(s[g], radix: 16), let scalar = Unicode.Scalar(code) else { continue }
                out += s[last..<whole.lowerBound]
                out.unicodeScalars.append(scalar)
                last = whole.upperBound
            }
            out += s[last...]
            s = out
        }
        // Trailing commas.
        s = s.replacingOccurrences(of: #",\s*([\]}])"#, with: "$1", options: .regularExpression)
        // Single-quoted strings → JSON strings.
        if let single = try? NSRegularExpression(pattern: #"'((?:[^'\\]|\\[\s\S])*)'"#) {
            var out = ""
            var last = s.startIndex
            for m in single.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) {
                guard let whole = Range(m.range, in: s), let g = Range(m.range(at: 1), in: s) else { continue }
                out += s[last..<whole.lowerBound]
                out += quoteJSON(String(s[g]).replacingOccurrences(of: "\\'", with: "'"))
                last = whole.upperBound
            }
            out += s[last...]
            s = out
        }
        // Unquoted keys.
        s = s.replacingOccurrences(of: #"([{,]\s*)([a-zA-Z0-9_$]+)\s*:"#, with: "$1\"$2\":",
                                   options: .regularExpression)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else {
            return nil
        }
        var result: [String: String] = [:]
        for (k, v) in obj {
            if let str = v as? String {
                result[k] = str
            } else if v is NSNull {
                result[k] = "null"
            } else if JSONSerialization.isValidJSONObject(v),
                      let d = try? JSONSerialization.data(withJSONObject: v) {
                result[k] = String(decoding: d, as: UTF8.self)
            } else {
                result[k] = "\(v)"
            }
        }
        return result
    }

    private static func quoteJSON(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Runs `operation`, returning nil if it has not finished
    /// within `seconds`. The loser is cancelled; page
    /// operations poll Task.isCancelled, URLSession honours it.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - The page (main actor)

/// The offscreen BotGuard page. Every member runs on the main
/// actor (WebKit). Results move through the page's string slots
/// (po_token.html §4 wrappers), polled with bounded loops — no
/// continuation can be left hanging if WebKit never answers.
@MainActor
final class JoeYtPoPage {
    private var surface: JoeWebOffscreenHost?
    private var loadState: LoadState = .idle

    private enum LoadState { case idle, loading, finished, failed }

    private init(surface: JoeWebOffscreenHost) {
        self.surface = surface
    }

    static func make() -> JoeYtPoPage {
        let surface = JoeWebOffscreenHost()
        let page = JoeYtPoPage(surface: surface)
        surface.controller.onFinishLoad = { [weak page] in
            if page?.loadState == .loading { page?.loadState = .finished }
        }
        surface.controller.onFailLoad = { [weak page] message in
            DiagLog.write("YT-POT", "page load failed: \(message)")
            page?.loadState = .failed
        }
        surface.controller.onTerminated = { [weak page] in
            DiagLog.write("YT-POT", "page web content terminated")
            page?.loadState = .failed
        }
        // MinterLockdown never reports exits; a no-op keeps the
        // contract explicit.
        surface.controller.onExitURL = { _ in }
        return page
    }

    func teardown() {
        surface?.teardown()
        surface = nil
        loadState = .failed
    }

    func load(html: String, baseURL: String, userAgent: String,
              budget: TimeInterval) async -> Bool {
        guard let surface else { return false }
        loadState = .loading
        surface.loadLocalPage(html: html, baseURL: baseURL, userAgent: userAgent)
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline, !Task.isCancelled {
            switch loadState {
            case .finished:
                // The page's own functions must exist (the
                // wrappers are the contract with Swift).
                let ok = await evaluate("typeof __poRunBotGuard === 'function' ? '1' : '0'",
                                        budget: budget)
                return ok == "1"
            case .failed:
                return false
            default:
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return false
    }

    /// One evaluation, bounded. nil on timeout, on a nil
    /// result, or if the surface is gone.
    func evaluate(_ js: String, budget: TimeInterval) async -> String? {
        guard let surface else { return nil }
        let box = ResultBox()
        surface.controller.evaluateForResult(js) { result in
            box.value = result
            box.done = true
        }
        let deadline = Date().addingTimeInterval(budget)
        while !box.done, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return box.done ? box.value : nil
    }

    /// §3 step 5. Returns the botguardResponse string.
    func runBotGuard(challengeLiteral: String, budget: TimeInterval) async -> String? {
        let started = await evaluate("__poRunBotGuard(\(challengeLiteral)); 'started'", budget: budget)
        guard started == "started" else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline, !Task.isCancelled {
            if let state = await evaluate(
                    "JSON.stringify([window.__poError, window.__poBotguardResponse, " +
                    "(window.__poSignalOutput && window.__poSignalOutput.length) ? 1 : 0])",
                    budget: budget),
               let parsed = (try? JSONSerialization.jsonObject(with: Data(state.utf8))) as? [Any],
               parsed.count == 3 {
                let error = parsed[0] as? String ?? ""
                let response = parsed[1] as? String ?? ""
                let signals = (parsed[2] as? NSNumber)?.intValue ?? 0
                if !error.isEmpty {
                    DiagLog.write("YT-POT", "S5 page error (len \(error.count))")
                    return nil
                }
                if !response.isEmpty {
                    // SmartTube: an empty webPoSignalOutput is an
                    // initialization error.
                    if signals == 0 {
                        DiagLog.write("YT-POT", "S5 webPoSignalOutput is empty")
                        return nil
                    }
                    return response
                }
            } else {
                return nil   // evaluation itself failed
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// §3 step 7.
    func setMinter(integrityTokenBytes: [UInt8], budget: TimeInterval) async -> Bool {
        let js = "__poSetMinter(\(JoeYtPoMinter.uint8ArrayLiteral(integrityTokenBytes))); " +
                 "JSON.stringify([window.__poError, (typeof mintCallback === 'function') ? 1 : 0])"
        guard let state = await evaluate(js, budget: budget),
              let parsed = (try? JSONSerialization.jsonObject(with: Data(state.utf8))) as? [Any],
              parsed.count == 2 else { return false }
        let error = parsed[0] as? String ?? ""
        let isFunction = (parsed[1] as? NSNumber)?.intValue ?? 0
        return error.isEmpty && isFunction == 1
    }

    /// §3 step 8. Returns the comma-separated byte string.
    func mint(identifier: [UInt8]) async -> String? {
        let js = "__poMint(\(JoeYtPoMinter.uint8ArrayLiteral(identifier))); " +
                 "JSON.stringify([window.__poError, window.__poTokenBytes])"
        guard let state = await evaluate(js, budget: JoeYtPoMinter.pageOperationBudget),
              let parsed = (try? JSONSerialization.jsonObject(with: Data(state.utf8))) as? [Any],
              parsed.count == 2 else { return nil }
        let error = parsed[0] as? String ?? ""
        let bytes = parsed[1] as? String ?? ""
        guard error.isEmpty, !bytes.isEmpty else { return nil }
        return bytes
    }

    private final class ResultBox {
        var value: String?
        var done = false
    }
}

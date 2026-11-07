import Foundation

/// Connection parameters for the native ATEN iKVM client, taken from the BMC's JNLP.
public struct KVMConsoleParams: Sendable {
    public let host: String
    public let token: String
    public let videoPort: UInt16

    public init(host: String, token: String, videoPort: UInt16 = 5900) {
        self.host = host
        self.token = token
        self.videoPort = videoPort
    }
}

extension SupermicroWeb {
    /// Logs into the BMC web UI over plain HTTP, mints a single-use iKVM token and logs out again
    /// (X9 BMCs allow only about two concurrent web sessions).
    public static func mintKVMConsole(host: String, username: String, password: String,
                                      log: (@Sendable (String) -> Void)? = nil) async throws -> KVMConsoleParams {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let base = "http://\(host)"

        guard let loginURL = URL(string: "\(base)/cgi/login.cgi"),
              let mintURL = URL(string: "\(base)/cgi/url_redirect.cgi?url_name=ikvm&url_type=jwsk"),
              let logoutURL = URL(string: "\(base)/cgi/logout.cgi") else {
            throw IPMIError.network("Ungültige Adresse")
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

        // 1. Login – the BMC sends two SID cookies (the first one empty); keep the last non-empty one.
        var login = URLRequest(url: loginURL)
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        login.setValue("\(base)/", forHTTPHeaderField: "Referer")
        login.httpBody = Data("name=\(enc(username))&pwd=\(enc(password))".utf8)
        let (loginData, loginResp) = try await session.data(for: login)
        guard let http = loginResp as? HTTPURLResponse else { throw IPMIError.network("Keine HTTP-Antwort") }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { r, kv in
            if let k = kv.key as? String, let v = kv.value as? String { r[k] = v }
        }
        let sid = HTTPCookie.cookies(withResponseHeaderFields: headers, for: loginURL)
            .filter { $0.name == "SID" && !$0.value.isEmpty }.last?.value
        log?("Login → HTTP \(http.statusCode), SID \(sid == nil ? "fehlt" : "erhalten")")
        guard let sid else {
            throw IPMIError.sessionSetup("Webinterface-Login fehlgeschlagen – Zugangsdaten falsch oder bereits zwei Web-Sitzungen offen. \(excerpt(decode(loginData)))")
        }

        // 2. Mint – without the language cookie and Referer the BMC answers 500.
        var mint = URLRequest(url: mintURL)
        mint.setValue("langSetFlag=0; language=English; SID=\(sid)", forHTTPHeaderField: "Cookie")
        mint.setValue("\(base)/cgi/url_redirect.cgi?url_name=man_ikvm", forHTTPHeaderField: "Referer")
        let (jnlpData, mintResp) = try await session.data(for: mint)
        log?("Token-Abruf → HTTP \((mintResp as? HTTPURLResponse)?.statusCode ?? 0), \(jnlpData.count) Bytes")

        // 3. Logout, regardless of the result.
        var logout = URLRequest(url: logoutURL)
        logout.setValue("SID=\(sid)", forHTTPHeaderField: "Cookie")
        _ = try? await session.data(for: logout)

        let jnlp = try JNLPDescriptor.parse(jnlpData)
        let args = jnlp.arguments
        guard args.count >= 5, !args[1].isEmpty else {
            throw IPMIError.malformed("Unerwartete JNLP (\(args.count) Argumente)")
        }
        let target = (args[0].isEmpty || args[0] == "null") ? host : args[0]
        return KVMConsoleParams(host: target, token: args[1], videoPort: UInt16(args[4]) ?? 5900)
    }
}

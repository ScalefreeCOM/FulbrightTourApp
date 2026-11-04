import Foundation
import Network
import Security
import CryptoKit

// MARK: - Errors

public struct APIError: LocalizedError, Sendable {
    public let service: String
    public let status: Int
    public let body: String
    public var errorDescription: String? { "\(service) error \(status): \(body.prefix(400))" }
}

public struct AppError: LocalizedError, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

// MARK: - HTTP

public enum HTTP {
    public static func send(_ req: URLRequest, service: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError(service: service, status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    public static func json(_ data: Data) throws -> Any {
        data.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: data)
    }

    public static func formBody(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)!
    }
}

// MARK: - Keychain

public enum Keychain {
    static let service = "org.fulbright.studytours"

    public static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public enum Key {
        public static let sfRefresh = "salesforce.refreshToken"
        public static let sfInstance = "salesforce.instanceURL"
        public static let googleSecret = "google.clientSecret"
        public static let googleRefresh = "google.refreshToken"
        public static let geminiKey = "gemini.apiKey"
    }
}

// MARK: - PKCE

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = PKCE.b64url(Data(bytes))
        challenge = PKCE.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func b64urlDecode(_ s: String) -> Data? {
        var v = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while v.count % 4 != 0 { v += "=" }
        return Data(base64Encoded: v)
    }
}

// MARK: - Loopback OAuth receiver

/// Minimal one-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
public final class LoopbackReceiver: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    public init(port: Int) { self.port = UInt16(port) }

    /// Starts listening, calls `open` (which should launch the browser), and waits for the redirect.
    public func waitForCode(open: @escaping () -> Void) async throws -> [String: String] {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        listener = l
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state { self?.finish(.failure(e)) }
                if case .ready = state { DispatchQueue.main.async { open() } }
            }
            l.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(.failure(AppError("Sign-in timed out")))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]) else { conn.cancel(); return }
            var q: [String: String] = [:]
            comps.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
            // Ignore favicon and other stray requests.
            guard q["code"] != nil || q["error"] != nil else {
                conn.send(content: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".data(using: .utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let html = "<html><body style='font-family:-apple-system;padding:40px'><h2>Signed in.</h2><p>You can close this tab and return to Study Tours.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if let err = q["error"] {
                self.finish(.failure(AppError("Sign-in failed: \(err) \(q["error_description"] ?? "")")))
            } else {
                self.finish(.success(q))
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        let c = continuation; continuation = nil
        lock.unlock()
        listener?.cancel()
        c?.resume(with: result)
    }
}

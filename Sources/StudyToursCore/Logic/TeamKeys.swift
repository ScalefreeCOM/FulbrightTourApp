import Foundation
import CryptoKit
import CommonCrypto

/// Encrypted file for handing the shared API keys to team members ("team key file").
///
/// Contains only shared secrets (AI keys, Google OAuth client secret) — never personal sign-ins (refresh tokens).
/// The file is AES-256-GCM encrypted with a key derived from a passphrase (PBKDF2-HMAC-SHA256, 600 000 rounds).
/// Send the file and the passphrase through different channels (e.g. file by email, passphrase by phone).
public enum TeamKeys {
    public static let fileExtension = "fbtkeys"
    public static let minimumPassphraseLength = 12
    static let format = "fulbright-team-keys"
    public static let iterations: UInt32 = 600_000

    /// Keychain items that may be shared.
    public static let shareable: [(key: String, label: String)] = [
        (Keychain.Key.geminiKey, "Gemini API key"),
        (Keychain.Key.claudeKey, "Claude API key"),
        (Keychain.Key.googleSecret, "Google OAuth client secret"),
    ]

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: UInt32
        var salt: String          // base64
        var sealed: String        // base64 of AES-GCM combined (nonce + ciphertext + tag)
    }

    struct Payload: Codable {
        var created: Date
        var secrets: [String: String]
        var aiProvider: String?
    }

    static func deriveKey(_ passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let pw = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        guard status == kCCSuccess else { throw AppError("Could not derive the encryption key.") }
        return SymmetricKey(data: out)
    }

    /// Encrypts the given secrets. Throws if the passphrase is too short or there is nothing to share.
    public static func seal(secrets: [String: String], aiProvider: String?, passphrase: String,
                            iterations: UInt32 = iterations) throws -> Data {
        guard passphrase.count >= minimumPassphraseLength else {
            throw AppError("Use a passphrase of at least \(minimumPassphraseLength) characters.")
        }
        let filled = secrets.filter { !$0.value.isEmpty }
        guard !filled.isEmpty else { throw AppError("There are no keys saved on this Mac to share.") }
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw AppError("Could not create random data.") }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let plain = try enc.encode(Payload(created: Date(), secrets: filled, aiProvider: aiProvider))
        let box = try AES.GCM.seal(plain, using: try deriveKey(passphrase, salt: salt, iterations: iterations))
        guard let combined = box.combined else { throw AppError("Encryption failed.") }
        let env = Envelope(format: format, version: 1, kdf: "PBKDF2-HMAC-SHA256", iterations: iterations,
                           salt: salt.base64EncodedString(), sealed: combined.base64EncodedString())
        let out = JSONEncoder(); out.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try out.encode(env)
    }

    /// Decrypts a team key file. A wrong passphrase or a modified file both fail authentication.
    public static func open(_ data: Data, passphrase: String) throws -> (secrets: [String: String], aiProvider: String?, created: Date) {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.format == format else {
            throw AppError("This is not a team key file.")
        }
        guard env.version == 1, env.kdf == "PBKDF2-HMAC-SHA256", (100_000...5_000_000).contains(env.iterations),
              let salt = Data(base64Encoded: env.salt), let sealed = Data(base64Encoded: env.sealed) else {
            throw AppError("This team key file uses an unknown format — update the app.")
        }
        let plain: Data
        do {
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed),
                                     using: try deriveKey(passphrase, salt: salt, iterations: env.iterations))
        } catch {
            throw AppError("Wrong passphrase, or the file was changed.")
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let p = try dec.decode(Payload.self, from: plain)
        let allowed = Set(shareable.map(\.key))
        return (p.secrets.filter { allowed.contains($0.key) }, p.aiProvider, p.created)
    }
}

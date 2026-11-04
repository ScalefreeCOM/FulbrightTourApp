import Foundation

/// Organisation-specific settings that are NOT part of the open-source code.
/// Copy `config/studytours.config.example.json` to `config/studytours.config.json` and fill in your values.
///
/// Lookup order: `~/Library/Application Support/FulbrightStudyTours/config.json`
/// → app bundle (`Contents/Resources/config.json`, added by scripts/build-app.sh)
/// → `config/studytours.config.json` in the source tree (for `swift run`).
public struct AppConfig: Codable, Equatable, Sendable {
    /// Salesforce My Domain URL, e.g. https://your-domain.my.salesforce.com
    public var salesforceURL: String
    /// Consumer Key of the Salesforce External Client App (OAuth with PKCE, no secret).
    public var salesforceConsumerKey: String
    /// Google OAuth client ID (Desktop app). The client secret is entered once in Settings and kept in the Keychain.
    public var googleClientId: String
    /// Shared Google Drive folder that contains one folder per study tour.
    public var driveParentFolderId: String
    /// Google Slides template copied into each tour folder as the agenda.
    public var agendaTemplateId: String
    /// Default knowledge base (Google Doc) for the email assistant.
    public var knowledgeBaseURL: String

    public static let empty = AppConfig(salesforceURL: "", salesforceConsumerKey: "", googleClientId: "",
                                        driveParentFolderId: "", agendaTemplateId: "", knowledgeBaseURL: "")

    public var isComplete: Bool { !salesforceURL.isEmpty && !driveParentFolderId.isEmpty && !agendaTemplateId.isEmpty }

    /// Loaded once at start-up.
    public static let current: AppConfig = load()

    public static var searchPaths: [URL] {
        var p = [Store.directory.appendingPathComponent("config.json")]
        if let r = Bundle.main.resourceURL { p.append(r.appendingPathComponent("config.json")) }
        // source tree (…/Sources/StudyToursCore/Model/AppConfig.swift → …/config/)
        p.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/studytours.config.json"))
        return p
    }

    public static func load() -> AppConfig {
        for url in searchPaths {
            if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(AppConfig.self, from: d) { return c }
        }
        return .empty
    }

    public static var loadedFrom: URL? {
        searchPaths.first { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) } != nil }
    }
}

import Foundation

/// Google Drive structure of the study tours (shared with all team members). IDs come from the config file.
public enum DriveStructure {
    /// Shared parent folder; every study tour gets its own sub-folder named like its program (from the config file).
    public static var parentFolderId: String { AppConfig.current.driveParentFolderId }
    /// Google Slides template copied into each tour folder as the agenda (from the config file).
    public static var agendaTemplateId: String { AppConfig.current.agendaTemplateId }

    public static func folderURL(_ id: String) -> String { "https://drive.google.com/drive/folders/\(id)" }
    public static func slidesURL(_ id: String) -> String { "https://docs.google.com/presentation/d/\(id)/edit" }

    /// File/folder id from a Drive, Docs or Slides URL.
    public static func id(from url: String) -> String? {
        for pattern in [#"/folders/([A-Za-z0-9_-]{10,})"#, #"/d/([A-Za-z0-9_-]{10,})"#, #"[?&]id=([A-Za-z0-9_-]{10,})"#] {
            if let r = url.range(of: pattern, options: .regularExpression) {
                let m = String(url[r])
                if let i = m.lastIndex(where: { $0 == "/" || $0 == "=" }) { return String(m[m.index(after: i)...]) }
            }
        }
        return nil
    }

    public static func agendaName(program: String) -> String { "\(program) – Agenda" }
}

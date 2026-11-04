import Foundation

/// Everything persisted to disk. Participant data (incl. passports) is NOT stored here —
/// it is always loaded live from Salesforce and only kept in memory.
public struct AppData: Codable, Sendable {
    public var tours: [Tour] = []
    public var selectedTourId: UUID?
    public var settings = AppSettings()
    public init() {}

    enum CodingKeys: String, CodingKey { case tours, selectedTourId, settings }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tours = try c.decodeIfPresent([Tour].self, forKey: .tours) ?? []
        selectedTourId = try c.decodeIfPresent(UUID.self, forKey: .selectedTourId)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

public enum Store {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FulbrightStudyTours", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var file: URL { directory.appendingPathComponent("data.json") }
    public static var exportsDirectory: URL {
        let d = directory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var logosDirectory: URL {
        let d = directory.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public static func load() -> AppData {
        guard let d = try? Data(contentsOf: file) else { return AppData() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { return try dec.decode(AppData.self, from: d) }
        catch {
            // Keep a copy of the unreadable file rather than silently overwriting it.
            try? FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("data.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return AppData()
        }
    }

    public static func save(_ data: AppData) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(data).write(to: file, options: [.atomic])
    }
}

import Foundation

/// Fills the agenda presentation (a copy of the Google Slides template) from the tour's public agenda entries.
///
/// Placeholders in the template:
/// - anywhere: `{{tour}}`, `{{city}}`, `{{dates}}`, `{{year}}`
/// - the *entry slide* — the first slide containing `{{title}}` — is duplicated once per public agenda entry
///   (in date order) and filled with `{{title}}`, `{{date}}`, `{{time}}`, `{{address}}`, `{{speakers}}`, `{{details}}`.
///   The original entry slide is removed afterwards.
public enum AgendaSlides {
    public struct Entry: Equatable, Sendable {
        public var title, date, time, address, speakers, details: String
    }

    /// Placeholder that marks the slide to repeat for every agenda entry.
    public static let entryMarker = "{{title}}"

    static func dayFormatter(_ format: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.timeZone = tz; f.dateFormat = format; return f
    }

    /// Public agenda entries in date order, formatted for the slides. Speakers come from "Speakers: a; b" in the details.
    public static func entries(_ items: [AgendaItem], timeZone tz: TimeZone = .current) -> [Entry] {
        let day = dayFormatter("EEEE, d MMMM yyyy", tz), hm = dayFormatter("HH:mm", tz)
        return items.filter(\.publicItem).sorted { $0.start < $1.start }.map { i in
            var speakers = "", details = i.details.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.hasPrefix("Speakers:") {
                let lines = details.split(separator: "\n", maxSplits: 1).map(String.init)
                speakers = lines[0].dropFirst("Speakers:".count).split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                details = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            return Entry(title: i.title, date: day.string(from: i.start),
                         time: "\(hm.string(from: i.start)) – \(hm.string(from: i.end))",
                         address: i.location, speakers: speakers, details: details)
        }
    }

    /// Tour-wide placeholders.
    public static func globals(_ tour: Tour, timeZone tz: TimeZone = .current) -> [String: String] {
        let cal = Calendar(identifier: .gregorian)
        let sameYear = cal.component(.year, from: tour.startDate) == cal.component(.year, from: tour.endDate)
        let sameMonth = sameYear && cal.component(.month, from: tour.startDate) == cal.component(.month, from: tour.endDate)
        let from = dayFormatter(sameMonth ? "d" : sameYear ? "d MMMM" : "d MMMM yyyy", tz).string(from: tour.startDate)
        let to = dayFormatter("d MMMM yyyy", tz).string(from: tour.endDate)
        return ["{{tour}}": tour.name, "{{city}}": tour.city, "{{dates}}": "\(from) – \(to)",
                "{{year}}": dayFormatter("yyyy", tz).string(from: tour.startDate)]
    }

    /// Object id of the entry slide: the first slide whose text contains `{{title}}`.
    public static func entrySlideId(in presentation: [String: Any]) -> String? {
        for slide in presentation["slides"] as? [[String: Any]] ?? [] {
            if let data = try? JSONSerialization.data(withJSONObject: slide),
               let text = String(data: data, encoding: .utf8), text.contains(entryMarker) {
                return slide["objectId"] as? String
            }
        }
        return nil
    }

    /// One batchUpdate: duplicate the entry slide per entry (in reverse, so they end up in date order right after it),
    /// fill each copy, delete the original entry slide, then replace the tour-wide placeholders everywhere.
    public static func requests(entrySlideId tpl: String, entries: [Entry], globals: [String: String]) -> [[String: Any]] {
        var r: [[String: Any]] = []
        let ids = entries.indices.map { "agenda_entry_\($0)" }
        for n in entries.indices.reversed() {
            r.append(["duplicateObject": ["objectId": tpl, "objectIds": [tpl: ids[n]]]])
        }
        func replace(_ key: String, _ value: String, pages: [String]? = nil) -> [String: Any] {
            var req: [String: Any] = ["containsText": ["text": key, "matchCase": true], "replaceText": value]
            if let pages { req["pageObjectIds"] = pages }
            return ["replaceAllText": req]
        }
        for (n, e) in entries.enumerated() {
            for (k, v) in [("{{title}}", e.title), ("{{date}}", e.date), ("{{time}}", e.time), ("{{address}}", e.address),
                           ("{{speakers}}", e.speakers), ("{{details}}", e.details)] {
                r.append(replace(k, v, pages: [ids[n]]))
            }
        }
        r.append(["deleteObject": ["objectId": tpl]])
        for (k, v) in globals.sorted(by: { $0.key < $1.key }) { r.append(replace(k, v)) }
        return r
    }
}

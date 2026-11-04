import Foundation

/// Renders the agenda as HTML; Drive converts it into a Google Doc.
public enum AgendaDocument {
    public static let partners = ["Fulbright Alumni e.V. (Germany)", "Hungarian Fulbright Association",
                                  "ENAM – European Network of American Alumni Associations"]

    public static func html(tour: Tour, includeInternal: Bool = false, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter(); day.dateFormat = "EEEE, d MMMM yyyy"; day.timeZone = timeZone
        let time = DateFormatter(); time.dateFormat = "HH:mm"; time.timeZone = timeZone
        let items = tour.agenda.filter { includeInternal || $0.publicItem }.sorted { $0.start < $1.start }
        let byDay = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.start) }
        func e(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var h = """
        <html><head><meta charset="utf-8"></head><body style="font-family:Arial">
        <h1>\(e(tour.name))</h1>
        <p><b>\(e(tour.city))</b> · \(day.string(from: tour.startDate)) – \(day.string(from: tour.endDate))</p>
        <p style="color:#555">A cooperation of \(partners.map(e).joined(separator: ", ")).</p>
        """
        for d in byDay.keys.sorted() {
            h += "<h2>\(day.string(from: d))</h2><table border=\"1\" cellpadding=\"6\" style=\"border-collapse:collapse;width:100%\">"
            h += "<tr style=\"background:#DCE6F1\"><th>Time</th><th>Programme</th><th>Location</th></tr>"
            for i in byDay[d]!.sorted(by: { $0.start < $1.start }) {
                let details = i.details.isEmpty ? "" : "<br><span style=\"color:#555\">\(e(i.details).replacingOccurrences(of: "\n", with: "<br>"))</span>"
                h += "<tr><td>\(time.string(from: i.start))–\(time.string(from: i.end))</td><td><b>\(e(i.title))</b>\(details)</td><td>\(e(i.location))</td></tr>"
            }
            h += "</table>"
        }
        if items.isEmpty { h += "<p><i>Agenda to be announced.</i></p>" }
        let stamp = DateFormatter(); stamp.dateStyle = .medium; stamp.timeStyle = .short
        h += "<p style=\"color:#999;font-size:9pt\">Last updated \(stamp.string(from: Date())). Subject to change.</p></body></html>"
        return h
    }
}

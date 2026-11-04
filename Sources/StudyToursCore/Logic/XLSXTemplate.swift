import Foundation
import Compression

// MARK: - ZIP reading (STORE + DEFLATE)

public enum ZipReader {
    public struct Entry { public let name: String; public let data: Data }

    /// Reads all entries of a ZIP archive (no ZIP64 / encryption — fine for Office files).
    public static func entries(_ zip: Data) throws -> [Entry] {
        let b = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { throw AppError("Not a valid Excel file") }
        var eocd = -1
        for i in stride(from: b.count - 22, through: max(0, b.count - 66_000), by: -1) where u32(i) == 0x06054b50 { eocd = i; break }
        guard eocd >= 0 else { throw AppError("Not a valid Excel file (no ZIP directory)") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw AppError("Corrupt Excel file") }
            let method = u16(p + 10), compSize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            let raw = Data(b[dataStart..<(dataStart + compSize)])
            let data: Data
            switch method {
            case 0: data = raw
            case 8: data = try inflate(raw, size: size)
            default: throw AppError("Unsupported compression in Excel file")
            }
            out.append(Entry(name: name, data: data))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: size)
        let n = data.withUnsafeBytes { src in
            compression_decode_buffer(&dst, size, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard n == size else { throw AppError("Could not decompress Excel file") }
        return Data(dst)
    }
}

// MARK: - Template model

/// What goes into one column of the host's template.
public enum ColumnSource: Hashable, Sendable {
    case field(ParticipantField)
    case index                       // running number 1, 2, 3 …
    case fullName                    // "First Last"
    case fullNameLastFirst           // "Last, First"
    case constant(String)            // e.g. organisation name of the group
    case none

    public var label: String {
        switch self {
        case .field(let f): return f.label
        case .index: return "No."
        case .fullName: return "Full name"
        case .fullNameLastFirst: return "Last name, first name"
        case .constant(let s): return "“\(s)”"
        case .none: return "— leave empty —"
        }
    }

    /// Key used in the Gemini JSON contract.
    public var key: String {
        switch self {
        case .field(let f): return f.rawValue
        case .index: return "index"
        case .fullName: return "fullName"
        case .fullNameLastFirst: return "fullNameLastFirst"
        case .constant: return "constant"
        case .none: return "none"
        }
    }

    public static func from(key: String, value: String?) -> ColumnSource {
        switch key {
        case "index": return .index
        case "fullName": return .fullName
        case "fullNameLastFirst": return .fullNameLastFirst
        case "constant": return .constant(value ?? "")
        case "none", "": return .none
        default: return ParticipantField(rawValue: key).map(ColumnSource.field) ?? .none
        }
    }

    public static var allChoices: [ColumnSource] {
        [.none, .index, .fullName, .fullNameLastFirst] + ParticipantField.allCases.map(ColumnSource.field)
    }
}

public enum CountryFormat: String, Sendable { case name, iso3 }

public struct ColumnMapping: Identifiable, Equatable, Sendable {
    public var id: String { column }
    public var column: String          // "A", "B", …
    public var header: String          // header text found in the template
    public var source: ColumnSource
    /// Dropdown values the form allows in this column (from its data validation), if any.
    public var allowedValues: [String] = []
    public var countryFormat: CountryFormat = .name
    /// The form formats this column as a date → write real Excel dates.
    public var dateCell = false
    public init(column: String, header: String, source: ColumnSource) {
        self.column = column; self.header = header; self.source = source
    }
}

public struct TemplateMapping: Equatable, Sendable {
    public var sheetPath: String       // e.g. "xl/worksheets/sheet1.xml"
    public var headerRow: Int
    public var firstDataRow: Int
    /// Last row reserved for data in the template (example rows are cleared up to here).
    public var lastTemplateRow: Int
    public var dateFormat: String
    public var columns: [ColumnMapping]
    public var notes: String = ""
}

/// A grid of the template's first rows (text only) — what Gemini sees. No participant data.
public struct SheetPreview: Sendable {
    public var sheetPath: String
    public var sheetName: String
    public var rows: [Int: [String: String]]     // row → column → text

    public var maxRow: Int { rows.keys.max() ?? 0 }

    public func asText(maxRows: Int = 25) -> String {
        rows.keys.sorted().prefix(maxRows).map { r in
            let cells = rows[r]!.sorted { XLSXTemplate.columnIndex($0.key) < XLSXTemplate.columnIndex($1.key) }
                .map { "\($0.key)\(r)=\($0.value)" }
            return "Row \(r): " + cells.joined(separator: " | ")
        }.joined(separator: "\n")
    }
}

// MARK: - Reading and filling a host's Excel template

public struct XLSXTemplate {
    public let entries: [ZipReader.Entry]
    public let sheetPath: String
    public let sheetName: String
    let sharedStrings: [String]

    public struct ListValidation: Sendable { public let column: String; public let firstRow: Int; public let lastRow: Int; public let values: [String] }

    public init(data: Data) throws {
        let all = try ZipReader.entries(data)
        func entry(_ n: String) -> Data? { all.first { $0.name == n }?.data }
        // first sheet via workbook.xml → relationships
        var path = "xl/worksheets/sheet1.xml", name = "Sheet1"
        if let wb = entry("xl/workbook.xml"), let doc = try? XMLDocument(data: wb),
           let sheet = (try? doc.nodes(forXPath: "//*[local-name()='sheet']"))?.first as? XMLElement {
            name = sheet.attribute(forName: "name")?.stringValue ?? name
            let rid = sheet.attributes?.first { $0.localName == "id" }?.stringValue
            if let rid, let rels = entry("xl/_rels/workbook.xml.rels"), let rdoc = try? XMLDocument(data: rels),
               let rel = (try? rdoc.nodes(forXPath: "//*[local-name()='Relationship'][@Id='\(rid)']"))?.first as? XMLElement,
               let target = rel.attribute(forName: "Target")?.stringValue {
                path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        var strings: [String] = []
        if let ss = entry("xl/sharedStrings.xml"), let doc = try? XMLDocument(data: ss) {
            for si in (try? doc.nodes(forXPath: "//*[local-name()='si']")) ?? [] {
                let texts = (try? si.nodes(forXPath: ".//*[local-name()='t']")) ?? []
                strings.append(texts.compactMap(\.stringValue).joined())
            }
        }
        guard all.contains(where: { $0.name == path }) else { throw AppError("The Excel file has no readable worksheet") }
        entries = all; sheetPath = path; sheetName = name; sharedStrings = strings
    }

    func sheetDocument() throws -> XMLDocument {
        guard let d = entries.first(where: { $0.name == sheetPath })?.data else { throw AppError("Worksheet missing") }
        return try XMLDocument(data: d, options: [.nodePreserveAll])
    }

    // MARK: Preview

    public func preview(maxRows: Int = 30) throws -> SheetPreview {
        let doc = try sheetDocument()
        var rows: [Int: [String: String]] = [:]
        for case let c as XMLElement in (try doc.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']/*[local-name()='c']")) {
            guard let ref = c.attribute(forName: "r")?.stringValue, let (col, row) = Self.split(ref), row <= maxRows else { continue }
            let t = c.attribute(forName: "t")?.stringValue
            var text = ""
            if t == "inlineStr" {
                text = ((try? c.nodes(forXPath: ".//*[local-name()='t']")) ?? []).compactMap(\.stringValue).joined()
            } else if let v = (c.elements(forName: "v").first ?? c.children?.compactMap { $0 as? XMLElement }.first { $0.localName == "v" })?.stringValue {
                text = t == "s" ? (Int(v).flatMap { $0 < sharedStrings.count ? sharedStrings[$0] : nil } ?? v) : v
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { rows[row, default: [:]][col] = text }
        }
        return SheetPreview(sheetPath: sheetPath, sheetName: sheetName, rows: rows)
    }

    // MARK: Filling

    /// Writes one row per participant into the template, keeping the template's cell styles.
    /// Returns a new .xlsx file.
    public func filled(with participants: [Participant], mapping: TemplateMapping, groupName: String = "") throws -> Data {
        let doc = try sheetDocument()
        guard let sheetData = (try doc.nodes(forXPath: "//*[local-name()='sheetData']")).first as? XMLElement else {
            throw AppError("Worksheet has no data area")
        }
        let ns = sheetData.uri
        var rowsByNumber: [Int: XMLElement] = [:]
        for case let r as XMLElement in sheetData.children ?? [] where r.localName == "row" {
            if let n = r.attribute(forName: "r")?.stringValue.flatMap(Int.init) { rowsByNumber[n] = r }
        }
        let active = mapping.columns.filter { $0.source != .none }

        // template styles per column (from the first data row, else the header row)
        var styles: [String: String] = [:]
        for m in active {
            for rowNo in [mapping.firstDataRow, mapping.headerRow] {
                if let s = cell(in: rowsByNumber[rowNo], column: m.column)?.attribute(forName: "s")?.stringValue, styles[m.column] == nil {
                    styles[m.column] = rowNo == mapping.firstDataRow ? s : nil
                }
            }
        }

        func row(_ n: Int) -> XMLElement {
            if let r = rowsByNumber[n] { return r }
            let r = XMLElement(name: "row", uri: ns)
            r.addAttribute(XMLNode.attribute(withName: "r", stringValue: "\(n)") as! XMLNode)
            // insert in order
            let later = (sheetData.children ?? []).compactMap { $0 as? XMLElement }
                .first { ($0.attribute(forName: "r")?.stringValue).flatMap(Int.init).map { $0 > n } ?? false }
            if let later { sheetData.insertChild(r, at: later.index) } else { sheetData.addChild(r) }
            rowsByNumber[n] = r
            return r
        }

        func set(_ text: String, column: String, rowNo: Int) {
            let r = row(rowNo)
            let ref = "\(column)\(rowNo)"
            let c: XMLElement
            if let existing = cell(in: r, column: column) {
                c = existing
                c.setChildren(nil)
            } else {
                c = XMLElement(name: "c", uri: ns)
                c.addAttribute(XMLNode.attribute(withName: "r", stringValue: ref) as! XMLNode)
                if let s = styles[column] { c.addAttribute(XMLNode.attribute(withName: "s", stringValue: s) as! XMLNode) }
                let idx = Self.columnIndex(column)
                let next = (r.children ?? []).compactMap { $0 as? XMLElement }
                    .first { ($0.attribute(forName: "r")?.stringValue).flatMap(Self.split).map { Self.columnIndex($0.0) > idx } ?? false }
                if let next { r.insertChild(c, at: next.index) } else { r.addChild(c) }
            }
            c.removeAttribute(forName: "t")
            if text.isEmpty { return }
            c.addAttribute(XMLNode.attribute(withName: "t", stringValue: "inlineStr") as! XMLNode)
            let isEl = XMLElement(name: "is", uri: ns)
            let t = XMLElement(name: "t", uri: ns)
            t.stringValue = text
            t.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
            isEl.addChild(t)
            c.addChild(isEl)
        }

        func setNumber(_ n: Double, column: String, rowNo: Int) {
            set("", column: column, rowNo: rowNo)
            guard let c = cell(in: rowsByNumber[rowNo], column: column) else { return }
            let v = XMLElement(name: "v", uri: ns)
            v.stringValue = n == n.rounded() ? String(Int(n)) : String(n)
            c.addChild(v)
        }

        let sorted = participants.sorted { ($0[.lastName], $0[.firstName]) < ($1[.lastName], $1[.firstName]) }
        for (i, p) in sorted.enumerated() {
            for m in active {
                let rowNo = mapping.firstDataRow + i
                if m.dateCell, case .field(let f) = m.source, let d = Dates.parse(p[f]) {
                    setNumber(Self.excelSerial(d), column: m.column, rowNo: rowNo)
                    continue
                }
                set(Self.cellText(m, participant: p, index: i + 1, dateFormat: mapping.dateFormat), column: m.column, rowNo: rowNo)
            }
        }
        // clear example rows of the template that were not overwritten
        let lastWritten = mapping.firstDataRow + sorted.count - 1
        if mapping.lastTemplateRow > lastWritten {
            for rowNo in (lastWritten + 1)...mapping.lastTemplateRow where rowsByNumber[rowNo] != nil {
                for m in active { if cell(in: rowsByNumber[rowNo], column: m.column) != nil { set("", column: m.column, rowNo: rowNo) } }
            }
        }
        // keep the dimension consistent
        if let dim = (try doc.nodes(forXPath: "//*[local-name()='dimension']")).first as? XMLElement,
           let ref = dim.attribute(forName: "ref")?.stringValue, let colon = ref.firstIndex(of: ":"),
           let (endCol, endRow) = Self.split(String(ref[ref.index(after: colon)...])), lastWritten > endRow {
            dim.attribute(forName: "ref")?.stringValue = "\(ref[..<colon]):\(endCol)\(lastWritten)"
        }

        var zip = ZipWriter()
        for e in entries {
            if e.name == sheetPath { zip.add(e.name, doc.xmlData(options: [.nodeCompactEmptyElement])) }
            else if e.name == "xl/calcChain.xml" { continue }            // recalculated by Excel
            else if e.name == "[Content_Types].xml" {
                let s = String(decoding: e.data, as: UTF8.self)
                    .replacingOccurrences(of: #"<Override[^>]*calcChain[^>]*/>"#, with: "", options: .regularExpression)
                zip.add(e.name, Data(s.utf8))
            } else if e.name == "xl/_rels/workbook.xml.rels" {
                let s = String(decoding: e.data, as: UTF8.self)
                    .replacingOccurrences(of: #"<Relationship[^>]*calcChain[^>]*/>"#, with: "", options: .regularExpression)
                zip.add(e.name, Data(s.utf8))
            } else { zip.add(e.name, e.data) }
        }
        return zip.finish()
    }

    func cell(in row: XMLElement?, column: String) -> XMLElement? {
        guard let row else { return nil }
        return (row.children ?? []).compactMap { $0 as? XMLElement }
            .first { ($0.attribute(forName: "r")?.stringValue).flatMap(Self.split)?.0 == column }
    }

    // MARK: Values

    /// Final text for a cell: base value → country code format → nearest dropdown entry.
    public static func cellText(_ m: ColumnMapping, participant p: Participant, index: Int, dateFormat: String) -> String {
        var v = value(for: m.source, participant: p, index: index, dateFormat: dateFormat)
        var isCountry = false
        if case .field(let f) = m.source, f == .nationality || f == .passportIssuingCountry {
            isCountry = true
            if m.countryFormat == .iso3, let code = CountryCodes.iso3(of: v) { v = code }
        }
        return fit(v, to: m.allowedValues, isCountry: isCountry)
    }

    /// Excel date serial (days since 1899-12-30).
    public static func excelSerial(_ d: Date) -> Double {
        let base = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 1899, month: 12, day: 30).date!
        return (d.timeIntervalSince(base) / 86400).rounded()
    }

    public static func value(for source: ColumnSource, participant p: Participant, index: Int, dateFormat: String) -> String {
        switch source {
        case .field(let f) where f.isDate:
            guard let d = Dates.parse(p[f]) else { return p[f] }
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = dateFormat.isEmpty ? "dd.MM.yyyy" : dateFormat
            return df.string(from: d)
        case .field(let f): return p[f]
        case .index: return "\(index)"
        case .fullName: return "\(p[.firstName]) \(p[.lastName])".trimmingCharacters(in: .whitespaces)
        case .fullNameLastFirst: return [p[.lastName], p[.firstName]].filter { !$0.isEmpty }.joined(separator: ", ")
        case .constant(let s): return s
        case .none: return ""
        }
    }

    // MARK: Form rules: dropdowns, date styles, prefilled defaults

    /// List validations ("dropdowns") of the sheet with their allowed values.
    public func listValidations() throws -> [ListValidation] {
        let doc = try sheetDocument()
        var out: [ListValidation] = []
        for case let dv as XMLElement in try doc.nodes(forXPath: "//*[local-name()='dataValidation']") {
            guard dv.attribute(forName: "type")?.stringValue == "list",
                  let sqref = dv.attribute(forName: "sqref")?.stringValue,
                  let f1 = (try? dv.nodes(forXPath: "./*[local-name()='formula1']"))?.first?.stringValue else { continue }
            let values = try resolveList(f1)
            guard !values.isEmpty else { continue }
            for range in sqref.split(separator: " ") {
                let parts = range.split(separator: ":").map(String.init)
                guard let (c1, r1) = Self.split(parts[0].replacingOccurrences(of: "$", with: "")) else { continue }
                let (c2, r2) = parts.count > 1 ? (Self.split(parts[1].replacingOccurrences(of: "$", with: "")) ?? (c1, r1)) : (c1, r1)
                for ci in Self.columnIndex(c1)...Self.columnIndex(c2) {
                    out.append(ListValidation(column: XLSXWriter.colName(ci - 1), firstRow: r1, lastRow: r2, values: values))
                }
            }
        }
        return out
    }

    /// Values of a list formula: "\"A,B\"", "$K$7:$M$7" or "'Sheet'!$A$1:$A$9".
    func resolveList(_ formula: String) throws -> [String] {
        let f = formula.trimmingCharacters(in: .whitespaces)
        if f.hasPrefix("\"") { return f.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        var ref = f
        var source = self
        if let bang = f.lastIndex(of: "!") {
            let sheet = f[..<bang].trimmingCharacters(in: CharacterSet(charactersIn: "'="))
            ref = String(f[f.index(after: bang)...])
            guard let other = try? sheetNamed(sheet) else { return [] }
            source = other
        }
        let parts = ref.replacingOccurrences(of: "$", with: "").split(separator: ":").map(String.init)
        guard let (c1, r1) = Self.split(parts[0]) else { return [] }
        let (c2, r2) = parts.count > 1 ? (Self.split(parts[1]) ?? (c1, r1)) : (c1, r1)
        let pv = try source.preview(maxRows: r2)
        var vals: [String] = []
        for r in r1...r2 { for ci in Self.columnIndex(c1)...Self.columnIndex(c2) {
            if let v = pv.rows[r]?[XLSXWriter.colName(ci - 1)], !v.isEmpty { vals.append(v) }
        } }
        return vals
    }

    /// Same workbook, another sheet (for dropdown sources on helper sheets).
    func sheetNamed(_ name: String) throws -> XLSXTemplate {
        func entry(_ n: String) -> Data? { entries.first { $0.name == n }?.data }
        guard let wb = entry("xl/workbook.xml"), let doc = try? XMLDocument(data: wb),
              let sheet = (try? doc.nodes(forXPath: "//*[local-name()='sheet'][@name='\(name)']"))?.first as? XMLElement,
              let rid = sheet.attributes?.first(where: { $0.localName == "id" })?.stringValue,
              let rels = entry("xl/_rels/workbook.xml.rels"), let rdoc = try? XMLDocument(data: rels),
              let rel = (try? rdoc.nodes(forXPath: "//*[local-name()='Relationship'][@Id='\(rid)']"))?.first as? XMLElement,
              let target = rel.attribute(forName: "Target")?.stringValue else { throw AppError("Sheet \(name) not found") }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        return XLSXTemplate(entries: entries, sheetPath: path, sheetName: name, sharedStrings: sharedStrings)
    }

    init(entries: [ZipReader.Entry], sheetPath: String, sheetName: String, sharedStrings: [String]) {
        self.entries = entries; self.sheetPath = sheetPath; self.sheetName = sheetName; self.sharedStrings = sharedStrings
    }

    /// Style indexes (cellXfs) whose number format is a date.
    func dateStyleIndexes() -> Set<Int> {
        guard let d = entries.first(where: { $0.name == "xl/styles.xml" })?.data, let doc = try? XMLDocument(data: d) else { return [] }
        var custom: [Int: String] = [:]
        for case let nf as XMLElement in (try? doc.nodes(forXPath: "//*[local-name()='numFmt']")) ?? [] {
            if let id = nf.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init) { custom[id] = nf.attribute(forName: "formatCode")?.stringValue ?? "" }
        }
        func isDate(_ id: Int) -> Bool {
            if (14...22).contains(id) || (45...47).contains(id) { return true }
            guard let code = custom[id]?.lowercased() else { return false }
            let stripped = code.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*""#, with: "", options: .regularExpression)
            return stripped.contains("d") && stripped.contains("m") || stripped.contains("y")
        }
        let xfs = ((try? doc.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']")) ?? []).compactMap { $0 as? XMLElement }
        return Set(xfs.enumerated().compactMap { i, xf in
            (xf.attribute(forName: "numFmtId")?.stringValue).flatMap(Int.init).map(isDate) == true ? i : nil
        })
    }

    /// Applies the form's own rules to a mapping (from Gemini or keywords): dropdown values, country code format,
    /// date cells and formats, prefilled defaults and the reserved data range.
    public func enrich(_ mapping: TemplateMapping) throws -> TemplateMapping {
        var m = mapping
        let pv = try preview(maxRows: max(mapping.firstDataRow + 5, 40))
        let validations = (try? listValidations()) ?? []
        let dateStyles = dateStyleIndexes()
        let doc = try sheetDocument()
        func styleOf(_ col: String, _ row: Int) -> Int? {
            let node = (try? doc.nodes(forXPath: "//*[local-name()='c'][@r='\(col)\(row)']"))?.first as? XMLElement
            return node?.attribute(forName: "s")?.stringValue.flatMap(Int.init)
        }
        for i in m.columns.indices {
            let col = m.columns[i].column
            let header = Text.fold(m.columns[i].header)
            if let v = validations.first(where: { $0.column == col && $0.lastRow >= m.firstDataRow }) {
                m.columns[i].allowedValues = v.values
                m.lastTemplateRow = max(m.lastTemplateRow, v.lastRow)
            }
            // countries: ISO3 if the header says so or the dropdown holds 3-letter codes
            let allowedAreCodes = !m.columns[i].allowedValues.isEmpty &&
                m.columns[i].allowedValues.prefix(20).allSatisfy { $0.count == 3 && $0 == $0.uppercased() }
            if header.contains("iso3") || header.contains("iso 3") || header.contains("iso-3") || allowedAreCodes || header.hasSuffix("code") {
                m.columns[i].countryFormat = .iso3
            }
            // dates: explicit format in the header, real Excel dates if the form formats the cells as dates
            if case .field(let f) = m.columns[i].source, f.isDate {
                if let fmt = Self.dateFormat(inHeader: m.columns[i].header) { m.dateFormat = fmt }
                if let s = styleOf(col, m.firstDataRow), dateStyles.contains(s) { m.columns[i].dateCell = true }
            }
            // prefilled default in the example rows (e.g. "Visitor") → write it for every participant
            if m.columns[i].source == .none, let first = pv.rows[m.firstDataRow]?[col], !first.isEmpty,
               pv.rows[m.firstDataRow + 1]?[col] == first || !m.columns[i].allowedValues.isEmpty {
                m.columns[i].source = .constant(first)
            }
        }
        // columns that only exist as dropdowns (no header text) are not touched
        return m
    }

    /// "Date of birth (dd/mm/yyyy)" → "dd/MM/yyyy".
    static func dateFormat(inHeader h: String) -> String? {
        guard let r = h.range(of: #"(?i)(dd|tt)[./-](mm)[./-](yyyy|jjjj|yy)"#, options: .regularExpression) else { return nil }
        let raw = String(h[r]).lowercased()
        let sep = raw.first { ".-/".contains($0) } ?? "."
        return "dd\(sep)MM\(sep)" + (raw.hasSuffix("yy") && !raw.hasSuffix("yyyy") && !raw.hasSuffix("jjjj") ? "yy" : "yyyy")
    }

    /// Picks the dropdown entry that corresponds to an org value (countries by ISO code, ID types by meaning).
    public static func fit(_ value: String, to allowed: [String], isCountry: Bool) -> String {
        guard !allowed.isEmpty, !value.isEmpty else { return value }
        if let exact = allowed.first(where: { Text.fold($0) == Text.fold(value) }) { return exact }
        if isCountry, let code = CountryCodes.iso2(value),
           let match = allowed.first(where: { CountryCodes.iso2($0) == code }) { return match }
        let v = Text.fold(value)
        let passport = v.contains("passport") || v.contains("reisepass")
        let idCard = !passport && (v.contains("id") || v.contains("identity") || v.contains("personal") || v.contains("ausweis"))
        if passport, let a = allowed.first(where: { Text.fold($0).contains("passport") || Text.fold($0).contains("pass") }) { return a }
        if idCard, let a = allowed.first(where: { let f = Text.fold($0); return f.contains("identity") || f.contains("id card") || f.contains("ausweis") || f.contains("personal") }) { return a }
        return value
    }

    // MARK: Cell references

    static func split(_ ref: String) -> (String, Int)? {
        let letters = ref.prefix { $0.isLetter }
        guard !letters.isEmpty, let n = Int(ref.dropFirst(letters.count)) else { return nil }
        return (String(letters).uppercased(), n)
    }

    public static func columnIndex(_ col: String) -> Int {
        col.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
    }
}

// MARK: - Mapping (Gemini + deterministic fallback)

public enum TemplateMapper {
    /// Prompt for Gemini: only the template's text grid, never participant data.
    public static func prompt(_ preview: SheetPreview) -> (system: String, prompt: String) {
        let fields = ParticipantField.allCases.map { "\($0.rawValue) (\($0.label) / \($0.germanLabel))" }.joined(separator: ", ")
        let system = """
        You analyse an Excel form that a host institution (ministry, parliament, embassy …) sent to collect visitor data \
        for a security check. Identify the header row, the first row where visitor data must be entered, the last row \
        the form reserves for visitors (including example rows), and which participant attribute belongs in each column.
        Allowed sources: index (running number), fullName ("First Last"), fullNameLastFirst ("Last, First"), \
        constant (fixed text, give it in "value"), none, or one of these participant fields: \(fields).
        Also infer the date format the form expects (Unicode pattern such as dd.MM.yyyy or yyyy-MM-dd).
        Respond ONLY with JSON:
        {"headerRow": int, "firstDataRow": int, "lastTemplateRow": int, "dateFormat": string,
         "columns": [{"column": "A", "header": string, "source": string, "value": string|null}], "notes": string}
        Include every column that has a header. Use "none" for columns the organisers must not fill (e.g. "for official use").
        """
        return (system, "Worksheet \"\(preview.sheetName)\":\n\(preview.asText())")
    }

    struct GeminiMapping: Decodable {
        struct Col: Decodable { let column: String; let header: String?; let source: String; let value: String? }
        let headerRow: Int; let firstDataRow: Int; let lastTemplateRow: Int?; let dateFormat: String?
        let columns: [Col]; let notes: String?
    }

    public static func parse(_ json: String, preview: SheetPreview) -> TemplateMapping? {
        guard let g = Assistant.decode(GeminiMapping.self, from: json), g.headerRow >= 1, g.firstDataRow > g.headerRow else { return nil }
        let cols = g.columns.compactMap { c -> ColumnMapping? in
            let col = c.column.uppercased().filter(\.isLetter)
            guard !col.isEmpty else { return nil }
            return ColumnMapping(column: col, header: c.header ?? preview.rows[g.headerRow]?[col] ?? "",
                                 source: ColumnSource.from(key: c.source, value: c.value))
        }
        return TemplateMapping(sheetPath: preview.sheetPath, headerRow: g.headerRow, firstDataRow: g.firstDataRow,
                               lastTemplateRow: max(g.lastTemplateRow ?? g.firstDataRow, g.firstDataRow),
                               dateFormat: g.dateFormat ?? "dd.MM.yyyy", columns: cols, notes: g.notes ?? "")
    }

    static let synonyms: [(ColumnSource, [String])] = [
        (.index, ["nr", "no", "no.", "nr.", "lfd", "lfd. nr.", "#", "s/n", "item"]),
        (.field(.lastName), ["nachname", "familienname", "surname", "last name", "lastname", "family name", "name, vorname"]),
        (.field(.firstName), ["vorname", "first name", "firstname", "given name", "rufname"]),
        (.field(.birthDate), ["geburtsdatum", "date of birth", "birth date", "dob", "geb."]),
        (.field(.nationality), ["staatsangehörigkeit", "nationalität", "nationality", "citizenship", "staatsbürgerschaft"]),
        (.field(.identificationType), ["ausweisart", "dokumentenart", "document type", "id type", "type of document"]),
        (.field(.passportNumber), ["ausweisnummer", "passnummer", "reisepass", "personalausweis", "passport", "id number", "document number", "dokumentennummer"]),
        (.field(.passportExpiry), ["gültig bis", "ablaufdatum", "expiry", "valid until", "expiration"]),
        (.field(.passportIssuingCountry), ["ausstellungsstaat", "ausstellungsland", "issuing country", "country of issue"]),
        (.field(.organization), ["organisation", "institution", "arbeitgeber", "organization", "company", "firma", "affiliation"]),
        (.field(.title), ["funktion", "position", "title", "job", "beruf"]),
        (.field(.email), ["e-mail", "email", "mail"]),
        (.field(.phone), ["telefon", "phone", "mobil", "handy"]),
        (.fullName, ["name", "full name", "vollständiger name"]),
    ]

    /// Best-matching source for a header text: exact > prefix > contained; longer synonyms win.
    static func score(_ header: String) -> ColumnSource? {
        let t = Text.fold(header).trimmingCharacters(in: CharacterSet(charactersIn: " :*"))
        guard !t.isEmpty else { return nil }
        var best: (ColumnSource, Int)?
        for (src, words) in synonyms {
            for w in words.map(Text.fold) {
                var sc = 0
                if t == w { sc = 1000 + w.count }
                else if w.count >= 3, t.hasPrefix(w + " ") || t.hasPrefix(w + "/") || t.hasPrefix(w + ",") || t.hasPrefix(w + "(") { sc = 500 + w.count }
                else if src != .index, w.count >= 4, t.contains(w) { sc = 100 + w.count }
                if sc > (best?.1 ?? 0) { best = (src, sc) }
            }
        }
        return best?.0
    }

    /// Header-keyword mapping used when Gemini is unavailable (or to sanity-check it).
    public static func fallback(_ preview: SheetPreview) -> TemplateMapping? {
        var best: (row: Int, cols: [ColumnMapping])?
        for r in preview.rows.keys.sorted() {
            let cols = preview.rows[r]!.compactMap { col, text -> ColumnMapping? in
                score(text).map { ColumnMapping(column: col, header: text, source: $0) }
            }
            if cols.count >= 2, cols.count > (best?.cols.count ?? 1) { best = (r, cols) }
        }
        guard let best else { return nil }
        let all = preview.rows[best.row]!.keys.sorted { XLSXTemplate.columnIndex($0) < XLSXTemplate.columnIndex($1) }.map { col in
            best.cols.first { $0.column == col } ?? ColumnMapping(column: col, header: preview.rows[best.row]![col] ?? "", source: .none)
        }
        return TemplateMapping(sheetPath: preview.sheetPath, headerRow: best.row, firstDataRow: best.row + 1,
                               lastTemplateRow: best.row + 1, dateFormat: "dd.MM.yyyy", columns: all,
                               notes: "Mapped by header keywords — please check.")
    }
}

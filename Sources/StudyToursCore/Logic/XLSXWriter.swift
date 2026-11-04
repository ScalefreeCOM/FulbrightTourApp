import Foundation

/// Minimal, dependency-free ZIP writer (STORE method) — enough for OOXML files.
public struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    public mutating func add(_ name: String, _ content: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(data.count)
        let (time, date) = Self.dosDateTime(Date())

        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(0)
        local.le16(time); local.le16(date); local.le32(crc)
        local.le32(UInt32(content.count)); local.le32(UInt32(content.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        data.append(local); data.append(nameData); data.append(content)

        var c = Data()
        c.le32(0x02014b50); c.le16(20); c.le16(20); c.le16(0x0800); c.le16(0)
        c.le16(time); c.le16(date); c.le32(crc)
        c.le32(UInt32(content.count)); c.le32(UInt32(content.count))
        c.le16(UInt16(nameData.count)); c.le16(0); c.le16(0); c.le16(0); c.le16(0)
        c.le32(0); c.le32(offset)
        central.append(c); central.append(nameData)
        count += 1
    }

    public func finish() -> Data {
        var out = data
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(UInt32(central.count)); end.le32(cdOffset); end.le16(0)
        out.append(end)
        return out
    }

    static func dosDateTime(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let date = UInt16(((c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func checksum(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

/// Writes a simple single-sheet .xlsx: bold header row, frozen header, auto-filter, column widths.
public enum XLSXWriter {
    public struct Sheet {
        public var name: String
        public var title: String?          // optional title row above the header
        public var headers: [String]
        public var rows: [[String]]
        public init(name: String, title: String? = nil, headers: [String], rows: [[String]]) {
            self.name = name; self.title = title; self.headers = headers; self.rows = rows
        }
    }

    public static func build(_ sheets: [Sheet]) -> Data {
        var zip = ZipWriter()
        let sheetOverrides = sheets.indices.map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        zip.add("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(sheetOverrides)</Types>
        """.utf8))
        zip.add("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8))
        let sheetEntries = sheets.enumerated().map { i, s in
            "<sheet name=\"\(esc(String(safeSheetName(s.name))))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }.joined()
        zip.add("xl/workbook.xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetEntries)</sheets></workbook>
        """.utf8))
        let rels = sheets.indices.map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined() + "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        zip.add("xl/_rels/workbook.xml.rels", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """.utf8))
        // style 0 = normal, 1 = bold header with fill + border, 2 = bold large title
        zip.add("xl/styles.xml", Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border/><border><bottom style="thin"><color auto="1"/></bottom></border></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="3"><xf xfId="0"/><xf fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/><xf fontId="2" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """.utf8))
        for (i, s) in sheets.enumerated() {
            zip.add("xl/worksheets/sheet\(i + 1).xml", Data(sheetXML(s).utf8))
        }
        return zip.finish()
    }

    static func sheetXML(_ s: Sheet) -> String {
        var rows: [String] = []
        var r = 1
        if let title = s.title {
            rows.append("<row r=\"1\">\(cell(col: 0, row: 1, value: title, style: 2))</row>")
            r = 3
        }
        let headerRow = r
        rows.append("<row r=\"\(r)\">" + s.headers.enumerated().map { cell(col: $0, row: r, value: $1, style: 1) }.joined() + "</row>")
        for row in s.rows {
            r += 1
            rows.append("<row r=\"\(r)\">" + row.enumerated().map { cell(col: $0, row: r, value: $1, style: 0) }.joined() + "</row>")
        }
        let widths = s.headers.indices.map { c -> Int in
            let maxLen = ([s.headers[c]] + s.rows.map { c < $0.count ? $0[c] : "" }).map(\.count).max() ?? 10
            return min(max(maxLen + 2, 10), 60)
        }
        let cols = "<cols>" + widths.enumerated().map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\($1)\" customWidth=\"1\"/>" }.joined() + "</cols>"
        let lastCol = colName(max(s.headers.count - 1, 0))
        let pane = "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"\(headerRow)\" topLeftCell=\"A\(headerRow + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(pane)\(cols)<sheetData>\(rows.joined())</sheetData><autoFilter ref="A\(headerRow):\(lastCol)\(max(r, headerRow))"/></worksheet>
        """
    }

    static func cell(col: Int, row: Int, value: String, style: Int) -> String {
        "<c r=\"\(colName(col))\(row)\" t=\"inlineStr\"\(style > 0 ? " s=\"\(style)\"" : "")><is><t xml:space=\"preserve\">\(esc(value))</t></is></c>"
    }

    public static func colName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func safeSheetName(_ s: String) -> Substring {
        let cleaned = s.filter { !"[]:*?/\\".contains($0) }
        return (cleaned.isEmpty ? "Sheet" : cleaned).prefix(31)
    }

    static func esc(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // drop control characters that are illegal in XML
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

/// Builds host submission sheets from participants.
public enum ParticipantExport {
    public static func sheet(host: Host, tour: Tour, participants: [Participant]) -> XLSXWriter.Sheet {
        let fields = host.requiredFields
        let rows = participants
            .sorted { ($0[.lastName], $0[.firstName]) < ($1[.lastName], $1[.firstName]) }
            .map { p in fields.map { f in f.isDate ? Dates.display(p[f]) : p[f] } }
        let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"
        let visit = host.visitDate.map { " – visit on \(df.string(from: $0))" } ?? ""
        return XLSXWriter.Sheet(name: "Participants", title: "\(tour.name): participants for \(host.name)\(visit)",
                                headers: ["No."] + fields.map(host.header(for:)),
                                rows: rows.enumerated().map { [String($0.offset + 1)] + $0.element })
    }

    public static func fileName(host: Host, tour: Tour, date: Date = Date()) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let safe = { (s: String) in s.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.replacingOccurrences(of: " ", with: "_") }
        return "\(safe(tour.name))_\(safe(host.name))_participants_\(df.string(from: date)).xlsx"
    }
}

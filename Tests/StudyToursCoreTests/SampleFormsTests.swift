import XCTest
@testable import StudyToursCore

/// Runs only when SAMPLE_FORMS_DIR points at real host forms (not part of the normal test run).
/// Fills each form with fictitious members and writes "<name>.filled.xlsx" next to OUTPUT_DIR for inspection.
final class SampleFormsTests: XCTestCase {
    func testFillRealHostForms() throws {
        guard let dir = ProcessInfo.processInfo.environment["SAMPLE_FORMS_DIR"],
              let outDir = ProcessInfo.processInfo.environment["OUTPUT_DIR"] else { throw XCTSkip("no sample forms") }
        let members = [
            Participant(id: "1", values: [.firstName: "Max", .lastName: "Muster", .email: "max@example.com", .birthDate: "1990-04-03",
                                         .nationality: "Germany", .identificationType: "Passport", .passportNumber: "C01X00T47",
                                         .passportExpiry: "2031-05-01", .organization: "Example GmbH"]),
            Participant(id: "2", values: [.firstName: "Jane", .lastName: "Doe", .email: "jane@example.com", .birthDate: "1985-01-02",
                                         .nationality: "United States of America", .identificationType: "National/Personal ID card",
                                         .passportNumber: "X1234567", .passportExpiry: "2030-01-31", .organization: "Example Inc."]),
            Participant(id: "3", values: [.firstName: "Ana", .lastName: "Beispiel", .email: "ana@example.com", .birthDate: "1979-12-24",
                                         .nationality: "Hungary", .identificationType: "Passport", .passportNumber: "HU998877",
                                         .passportExpiry: "2029-07-15", .organization: "Example Kft."]),
        ]
        for f in try FileManager.default.contentsOfDirectory(atPath: dir) where f.hasSuffix(".xlsx") && !f.contains(".filled") {
            let t = try XLSXTemplate(data: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f)))
            let base = try XCTUnwrap(TemplateMapper.fallback(try t.preview()), f)
            let m = try t.enrich(base)
            print("== \(f): sheet \(t.sheetName), header row \(m.headerRow), data \(m.firstDataRow)…\(m.lastTemplateRow), dates \(m.dateFormat)")
            for c in m.columns { print("   \(c.column) \(c.header) → \(c.source.label)\(c.countryFormat == .iso3 ? " [ISO3]" : "")\(c.dateCell ? " [date cell]" : "")\(c.allowedValues.isEmpty ? "" : " [\(c.allowedValues.count) allowed]")") }
            let out = try t.filled(with: members, mapping: m)
            try out.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(f.replacingOccurrences(of: ".xlsx", with: ".filled.xlsx")))
        }
    }
}
